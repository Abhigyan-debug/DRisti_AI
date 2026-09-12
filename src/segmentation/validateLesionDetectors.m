function R = validateLesionDetectors(opts)
%VALIDATELESIONDETECTORS  Score all four lesion channels against IDRiD ground truth.
%
%   R = VALIDATELESIONDETECTORS                 % held-out TEST split, saves result
%   R = VALIDATELESIONDETECTORS(split="train")  % diagnostic only - see below
%   R = VALIDATELESIONDETECTORS(limit=5, save=false)
%
%   Measures per-lesion PRECISION, RECALL and F1 for microaneurysms,
%   haemorrhages, hard exudates and soft exudates, then decides `reliable` by
%   comparing against a bar that was frozen BEFORE this ever ran:
%   CONFIG/LESION_VALIDATION_THRESHOLDS.JSON.
%
%   THE ORDERING IS THE POINT
%   -------------------------
%   A threshold picked after seeing the numbers describes the numbers; it does
%   not test them. So the gates live in a separate committed file, and the
%   SHA-256 of that file is written into the saved result. If anybody later
%   edits the gates to make a channel pass, the recorded hash stops matching
%   the file and the edit is visible. Nothing here reads the results and then
%   decides what counts as good.
%
%   WHY THE TEST SPLIT
%   ------------------
%   SEGMENTEXUDATES ships thresholdK = 3.0, chosen by SWEEPEXUDATETHRESHOLD on
%   the TRAINING split. Scoring it there measures how well it fits the data used
%   to pick it. The testing split has never fed a parameter choice, so it is the
%   only split on which these numbers mean what they appear to mean. `train` is
%   offered for diagnosis and is labelled optimistic in the output.
%
%   ABSENT MASKS ARE EMPTY GROUND TRUTH, NOT MISSING LABELS
%   -------------------------------------------------------
%   IDRiD ships a mask for a lesion type only where that lesion occurs. Soft
%   exudates appear in 14 of the 27 test images. Scoring soft exudates on only
%   those 14 would silently discard every false positive the detector produces
%   on the 13 negative images - which is exactly how a weak detector comes to
%   look strong. All four channels are therefore scored on all 27 images, and an
%   absent mask counts as "no lesion here", so a detection on it is a false
%   positive.
%
%   PER-LESION, NOT PIXELWISE
%   -------------------------
%   Microaneurysms are a few pixels across; a one-pixel offset annihilates
%   pixelwise Dice while being clinically irrelevant. A ground-truth component
%   counts as recalled if any predicted pixel lands on it, and a predicted
%   component counts as a true positive if any of its pixels land on ground
%   truth. Everything is FOV-masked on both sides.
%
%   See also EXTRACTLESIONFEATURES, LOADLESIONRELIABILITY, EVALUATESEGMENTATION.

    arguments
        opts.split (1,:) char {mustBeMember(opts.split,{'test','train'})} = 'test'
        opts.limit (1,1) double = Inf
        opts.save (1,1) logical = true
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();

    % ---- the frozen bar, read before anything is measured -----------------
    thrFile = fullfile(cfg.projectRoot, 'config', 'lesion_validation_thresholds.json');
    if ~isfile(thrFile)
        error('drishti:noThresholdFile', ...
            ['The pre-registered threshold file is missing: %s\n' ...
             'Validation cannot run without a bar that was set in advance.'], thrFile);
    end
    T = jsondecode(fileread(thrFile));
    thrSha = sha256File(thrFile);

    if strcmp(opts.split, 'test')
        imgDir   = cfg.idrid.segTestImages;
        maskRoot = cfg.idrid.segTestMasks;
    else
        imgDir   = cfg.idrid.segTrainImages;
        maskRoot = cfg.idrid.segTrainMasks;
    end

    L = dir(fullfile(imgDir, '*.jpg'));
    n = min(numel(L), opts.limit);
    if n == 0
        error('drishti:noImages', 'No IDRiD %s images at %s', opts.split, imgDir);
    end

    chans = { 'microaneurysms', '1. Microaneurysms', '_MA.tif', 'ma'; ...
              'haemorrhages',   '2. Haemorrhages',   '_HE.tif', 'haem'; ...
              'hardExudates',   '3. Hard Exudates',  '_EX.tif', 'hard'; ...
              'softExudates',   '4. Soft Exudates',  '_SE.tif', 'soft' };
    nc = size(chans, 1);

    % micro: pooled counts, each metric on its own side (see LESIONCOUNTS).
    TPp = zeros(nc,1); NP = zeros(nc,1);   % prediction side -> precision
    TPg = zeros(nc,1); NG = zeros(nc,1);   % ground-truth side -> recall
    nPresent = zeros(nc,1);
    macroP = nan(nc, n); macroR = nan(nc, n);

    if opts.verbose
        fprintf('\n  Validating 4 lesion channels on IDRiD %s split, %d images\n', ...
            upper(opts.split), n);
        fprintf('  Gates (frozen %s): precision >= %.2f AND recall >= %.2f\n', ...
            T.frozen, T.gates.displayPrecisionMin, T.gates.displayRecallMin);
        fprintf('  threshold file sha256 %s\n\n', thrSha(1:16));
    end

    for k = 1:n
        base = erase(L(k).name, '.jpg');
        img = imread(fullfile(imgDir, L(k).name));

        % Shared context ONCE per image. The previous evaluator rebuilt the FOV,
        % disc, vessels and fovea separately for every channel, paying for the
        % same work four times over.
        fov  = detectFOV(img);
        disc = locateOpticDisc(img, 'fov', fov);
        v    = segmentVessels(img, 'fov', fov, 'discRadiusPx', disc.radius);
        fv   = locateFovea(img, disc, 'vesselMask', v.mask);
        ctx  = struct('fov', fov, 'disc', disc, 'vesselMask', v.mask, 'fovea', fv);

        % Same call the production path makes (EXTRACTLESIONFEATURES). Scoring a
        % different configuration from the one that ships is how the 0.054
        % two-stage figure and the 0.028 that reports actually used came to
        % coexist in the same project.
        dk = detectDarkLesions(img, ctx, ...
            'candidateClassifier', loadCandidateClassifiers());
        ex = segmentExudates(img, ctx);

        pred = struct('ma', dk.maMask, 'haem', dk.haemMask, ...
                      'hard', ex.hardMask, 'soft', ex.softMask);

        % Release the full-resolution buffers before scoring. IDRiD frames are
        % 4288x2848, and holding the image, both detector results and the
        % context for the whole iteration ran the process out of memory at
        % image 26 of 27.
        clear dk ex v fv disc

        for c = 1:nc
            maskPath = fullfile(maskRoot, chans{c,2}, [base chans{c,3}]);
            if isfile(maskPath)
                g = readBinary(maskPath) & fov.mask;
                nPresent(c) = nPresent(c) + 1;
            else
                % Absent mask = lesion absent. Scored, not skipped.
                g = false(size(fov.mask));
            end
            p = pred.(chans{c,4}) & fov.mask;

            [tpPred, nPred, tpGt, nGt] = lesionCounts(p, g);
            TPp(c) = TPp(c) + tpPred;  NP(c) = NP(c) + nPred;
            TPg(c) = TPg(c) + tpGt;    NG(c) = NG(c) + nGt;

            % Macro rates are undefined where there is nothing to find and
            % nothing was predicted; leaving them NaN keeps them out of the mean
            % rather than scoring a vacuous 1.0 or 0.0.
            if nPred > 0, macroP(c,k) = tpPred / nPred; end
            if nGt   > 0, macroR(c,k) = tpGt   / nGt;   end
        end

        if opts.verbose && mod(k, 5) == 0
            fprintf('    %2d/%d images\n', k, n);
        end
    end

    % ---- assemble -----------------------------------------------------------
    R = struct();
    R.split = opts.split;
    R.n = n;
    R.dataset = sprintf('IDRiD segmentation, %s split', opts.split);
    R.thresholdFile = thrFile;
    R.thresholdSha256 = thrSha;
    R.thresholdsFrozen = T.frozen;
    R.gates = T.gates;
    R.protocol = T.protocol;
    R.measuredAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm'));
    R.optimistic = strcmp(opts.split, 'train');
    R.channels = struct();

    for c = 1:nc
        name = chans{c,1};
        E = struct();
        E.n = n;
        E.nImagesWithLesion = nPresent(c);
        E.predictedComponents = NP(c);
        E.groundTruthComponents = NG(c);
        E.truePositives = TPp(c);              % prediction side
        E.falsePositives = NP(c) - TPp(c);
        E.lesionsFound = TPg(c);               % ground-truth side
        E.falseNegatives = NG(c) - TPg(c);
        E.precision = TPp(c) / max(NP(c), 1);
        E.recall    = TPg(c) / max(NG(c), 1);
        E.f1 = 2 * E.precision * E.recall / max(E.precision + E.recall, eps);
        E.macroPrecision = mean(macroP(c,:), 'omitnan');
        E.macroRecall    = mean(macroR(c,:), 'omitnan');

        % THE GATE. Both conditions, exactly as frozen. Nothing here consults
        % the measured values to decide what the bar should be.
        E.reliable = (E.precision >= T.gates.displayPrecisionMin) && ...
                     (E.recall    >= T.gates.displayRecallMin);
        if E.reliable
            E.verdict = 'VALIDATED - may be displayed';
        elseif E.precision < T.gates.displayPrecisionMin
            E.verdict = sprintf('not validated - precision %.3f below %.2f', ...
                E.precision, T.gates.displayPrecisionMin);
        else
            E.verdict = sprintf('not validated - recall %.3f below %.2f', ...
                E.recall, T.gates.displayRecallMin);
        end
        E.protocol = sprintf(['IDRiD %s split, n=%d, FOV-masked, per-lesion ' ...
            '8-connected component matching, micro-averaged, single fixed ' ...
            'operating point'], opts.split, n);
        R.channels.(name) = E;
    end

    if opts.verbose, printReport(R, chans); end

    if opts.save
        if ~isfolder(cfg.resultsDir), mkdir(cfg.resultsDir); end
        outFile = fullfile(cfg.resultsDir, 'lesion_validation.mat');
        save(outFile, 'R');
        R.savedTo = outFile;
        if opts.verbose
            fprintf('  saved -> %s\n\n', outFile);
        end
    end
end


% ------------------------------------------------------------------ helpers

% LESIONCOUNTS now lives in src/segmentation/lesionCounts.m. It was moved out
% of this file so FITLESIONOPERATINGPOINT can select the stage-2 operating
% point under exactly the matching rule the display gate is measured with,
% rather than re-implementing it and quietly measuring something else.


function b = readBinary(p)
    m = imread(p);
    if ndims(m) == 3, m = m(:,:,1); end
    b = m > 0;
end


function h = sha256File(p)
%SHA256FILE  Hash the frozen threshold file so the ordering stays checkable.
    fid = fopen(p, 'r');
    bytes = fread(fid, Inf, '*uint8');
    fclose(fid);
    md = java.security.MessageDigest.getInstance('SHA-256');
    md.update(bytes);
    d = typecast(md.digest(), 'uint8');
    h = lower(reshape(dec2hex(d, 2)', 1, []));
end


function printReport(R, chans)
    fprintf('\n  ===== MODULE 2 LESION VALIDATION =====\n');
    fprintf('  %s, n=%d images\n', R.dataset, R.n);
    if R.optimistic
        fprintf('  ⚠ TRAINING split - the exudate threshold was tuned here. OPTIMISTIC.\n');
    end
    fprintf('  gates frozen %s (sha %s)\n', R.thresholdsFrozen, R.thresholdSha256(1:16));
    fprintf('  %-16s %7s %7s %7s   %5s %5s %5s  %s\n', ...
        'channel', 'prec', 'recall', 'F1', 'TP', 'FP', 'FN', 'verdict');
    fprintf('  %s\n', repmat('-', 1, 92));
    for c = 1:size(chans,1)
        e = R.channels.(chans{c,1});
        fprintf('  %-16s %7.3f %7.3f %7.3f   %5d %5d %5d  %s\n', ...
            chans{c,1}, e.precision, e.recall, e.f1, ...
            e.truePositives, e.falsePositives, e.falseNegatives, e.verdict);
    end
    fprintf('  %s\n', repmat('-', 1, 92));
    ok = {};
    for c = 1:size(chans,1)
        if R.channels.(chans{c,1}).reliable, ok{end+1} = chans{c,1}; end %#ok<AGROW>
    end
    if isempty(ok)
        fprintf('  NO channel clears the bar. Nothing will be displayed as a finding.\n');
    else
        fprintf('  displayed: %s\n', strjoin(ok, ', '));
    end
end
