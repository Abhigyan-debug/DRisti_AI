function R = fitLesionOperatingPoint(opts)
%FITLESIONOPERATINGPOINT  Choose the stage-2 threshold on the TRAINING split.
%
%   R = FITLESIONOPERATINGPOINT() sweeps the stage-2 classifier score threshold
%   for both dark-lesion channels over the IDRiD segmentation TRAIN split,
%   applies the selection rule recorded in config/lesion_operating_points.json,
%   and writes the chosen operating point back into that file.
%
%   R = FITLESIONOPERATINGPOINT(lesion="haemorrhages", limit=10, write=false)
%
%   WHY THIS EXISTS
%   ---------------
%   DETECTDARKLESIONS shipped `classifierThreshold = 0.5` as a literal in its
%   arguments block. Nobody chose it. 0.5 is the LOOSEST point on the score
%   sweep TRAINCANDIDATECLASSIFIER already prints, so the detector ran at the
%   setting that maximises false positives while the display gate
%   (config/lesion_validation_thresholds.json) gates on PRECISION. The one knob
%   that trades the failing metric against the passing one was pinned to its
%   worst value and written down nowhere.
%
%   TRAIN, NOT TEST - AND WHY THAT IS NOT PEDANTRY
%   ----------------------------------------------
%   The held-out test split decides whether a channel may be DISPLAYED. If the
%   threshold that channel runs at were also picked on the test split, the gate
%   would be measuring a number selected to pass it, and
%   lesion_validation_thresholds.json would certify nothing. So the sweep runs
%   on TRAIN, the choice is committed to a file, and VALIDATELESIONDETECTORS is
%   then run ONCE on test to see whether the choice survived.
%
%   The same reasoning settles the open item in docs/phase2_results.md section
%   4 - "the haemorrhage classifier makes things worse", observed on the test
%   split and therefore not actionable there. Stage-1-alone is entered in this
%   sweep as an ordinary row (threshold -Inf, keep every candidate). If it wins
%   under the selection rule, applyClassifier is written false and the shipped
%   detector skips stage 2 for that channel. The decision is made on train, by
%   a rule fixed in advance, and recorded.
%
%   MATCHING IS THE EVALUATOR'S
%   ---------------------------
%   Scoring calls LESIONCOUNTS and upsamples the candidate mask exactly as
%   VALIDATELESIONDETECTORS does, so a threshold chosen here is a threshold
%   measured under the protocol it will later be gated by. A sweep that
%   re-implemented the matching would optimise a slightly different quantity
%   and the choice would not transfer.
%
%   COST
%   ----
%   One detector pass and one classifier pass per image, then a mask rebuild
%   and a full-resolution component match per threshold. Roughly 20-30 min for
%   54 images across the default grid. Use `limit` while developing; quote only
%   full-split numbers.
%
%   See also LOADLESIONOPERATINGPOINTS, VALIDATELESIONDETECTORS, LESIONCOUNTS,
%   TRAINCANDIDATECLASSIFIER, SWEEPGENERATORRECALL.

    arguments
        opts.lesion (1,:) char {mustBeMember(opts.lesion, ...
            {'microaneurysms','haemorrhages','both'})} = 'both'
        % -Inf is the stage-1-alone row: keep every candidate the generator
        % proposed. It is in the grid rather than reported separately so the
        % selection rule ranks it against the thresholded options on equal terms.
        opts.thresholds (1,:) double = [-Inf 0.5 0.7 0.8 0.9 0.95 0.98 0.995]
        opts.fragmentRejection (1,1) logical = true
        opts.limit (1,1) double = Inf
        % Where to load the stage-2 classifiers from. Empty = the LIVE models in
        % models/. Otherwise either
        %     a directory   -> <dir>/candidate_classifier_<channel>.mat
        %     a %s template -> sprintf(template, channel)
        % e.g. 'models/ablation/candidate_classifier_%s_workingScale_t150.mat'
        %
        % Setting this FORCES write=false. An operating point fitted from a
        % candidate model must never land in the live config by accident - that
        % config is the frozen record of what ships, and a half-explored
        % ablation overwriting it is exactly the kind of silent contamination
        % the freeze exists to prevent. Use `outFile` to keep the result.
        opts.modelPath (1,:) char = ''
        % Where to save the fitted result as a .mat. Empty = do not save.
        opts.outFile (1,:) char = ''
        opts.write (1,1) logical = true
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    opFile = fullfile(cfg.projectRoot, 'config', 'lesion_operating_points.json');
    if ~isfile(opFile)
        error('drishti:noOperatingPointFile', ...
            ['config/lesion_operating_points.json is missing. It carries the ' ...
             'selection rule this function applies; without it there is no ' ...
             'pre-registered objective and the sweep would just be a search.']);
    end
    J = jsondecode(fileread(opFile));
    rule = J.selection_rule;

    % A model loaded from anywhere but models/ is a candidate, not the shipped
    % detector, so its operating point is a measurement - never a decision. The
    % live config stays untouched no matter what `write` says.
    usingAltModels = ~isempty(opts.modelPath);
    if usingAltModels && opts.write
        opts.write = false;
        fprintf(['\n  NOTE: modelPath is set, so config/lesion_operating_points.json\n' ...
                 '        will NOT be written. These are candidate models; the live\n' ...
                 '        config records what ships. Use outFile to keep the result.\n']);
    end

    if strcmp(opts.lesion, 'both')
        channels = {'microaneurysms', 'haemorrhages'};
    else
        channels = {opts.lesion};
    end

    R = struct();
    R.split = 'train';
    R.dataset = 'IDRiD segmentation, TRAIN split';
    R.precisionTarget = rule.precisionTarget;
    R.fragmentRejection = opts.fragmentRejection;
    R.measuredAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm'));
    R.channels = struct();

    for ci = 1:numel(channels)
        ch = channels{ci};
        R.channels.(ch) = sweepChannel(cfg, ch, opts, rule);
    end

    R.modelPath = opts.modelPath;
    R.usingAltModels = usingAltModels;
    R.liveConfigWritten = opts.write;

    if opts.verbose, printReport(R, channels); end

    if ~isempty(opts.outFile)
        % Same anchoring as modelPath: a relative outFile must land in the
        % project, not wherever run() left the working directory.
        opts.outFile = resolveAgainstRoot(cfg, opts.outFile);
        outDir = fileparts(opts.outFile);
        if ~isempty(outDir) && ~isfolder(outDir), mkdir(outDir); end
        save(opts.outFile, 'R');
        R.savedResultTo = opts.outFile;
        if opts.verbose, fprintf('  result saved -> %s\n', opts.outFile); end
    end

    if opts.write
        for ci = 1:numel(channels)
            ch = channels{ci};
            S = R.channels.(ch).selected;
            J.channels.(ch).classifierThreshold = S.threshold;
            J.channels.(ch).applyClassifier = S.applyClassifier;
            J.channels.(ch).status = 'SELECTED_ON_TRAIN';
            J.channels.(ch).note = S.note;
            J.channels.(ch).trainPrecision = R.channels.(ch).selected.precision;
            J.channels.(ch).trainRecall = R.channels.(ch).selected.recall;
            J.channels.(ch).reachedTarget = S.reachedTarget;
        end
        J.status = 'SELECTED - measured on the IDRiD segmentation TRAIN split';
        J.selected_on = R.dataset;
        J.selected_by = 'fitLesionOperatingPoint.m';
        J.selected_at = R.measuredAt;
        J.fragmentRejection = opts.fragmentRejection;

        fid = fopen(opFile, 'w');
        fprintf(fid, '%s', jsonencode(J, 'PrettyPrint', true));
        fclose(fid);
        R.savedTo = opFile;
        if opts.verbose
            fprintf('  operating point written -> %s\n', opFile);
            fprintf('  NEXT: validateLesionDetectors(''split'',''test'') - ONCE.\n\n');
        end
    end
end


% ------------------------------------------------------------------ helpers

function cf = resolveModelPath(cfg, ch, modelPath)
%RESOLVEMODELPATH  Which classifier file this channel should be scored with.
%
%   Empty modelPath   -> the live model, models/candidate_classifier_<ch>.mat
%   A directory       -> <dir>/candidate_classifier_<ch>.mat
%   A '%s' template   -> sprintf(template, ch)
%
%   The template form is what the ablation needs, because its files carry the
%   geometry and threshold in the name and there is no single directory in
%   which "the microaneurysm model" is unambiguous.

    if isempty(modelPath)
        cf = fullfile(cfg.modelsDir, ['candidate_classifier_' ch '.mat']);
        return
    end

    % A RELATIVE path is resolved against the PROJECT ROOT, never against the
    % process working directory. MATLAB's run() changes the working directory to
    % the folder holding the script - measured: a -batch job started in the
    % project root reports pwd = C:\...\Temp once inside run('C:\...\Temp\x.m').
    % So 'models/ablation/...' silently became "file not found" for a file that
    % was plainly there. Anchoring to the project root makes the option behave
    % the same however the caller was invoked.
    if contains(modelPath, '%s')
        cf = sprintf(modelPath, ch);
    else
        base = resolveAgainstRoot(cfg, modelPath);
        if ~isfolder(base)
            error('drishti:badModelPath', ...
                ['modelPath ''%s'' is neither a folder nor a template containing ' ...
                 '%%s. Pass a directory, or a pattern such as ' ...
                 '''models/ablation/candidate_classifier_%%s_workingScale_t150.mat''.'], ...
                modelPath);
        end
        cf = fullfile(base, ['candidate_classifier_' ch '.mat']);
    end
    cf = resolveAgainstRoot(cfg, cf);
end


function p = resolveAgainstRoot(cfg, p)
%RESOLVEAGAINSTROOT  Make a relative path absolute against the project root.
    if isempty(p), return; end
    absolute = ~isempty(regexp(p, '^([A-Za-z]:[\\/]|[\\/]{2}|[\\/])', 'once'));
    if ~absolute
        p = fullfile(cfg.projectRoot, p);
    end
end


function S = sweepChannel(cfg, ch, opts, rule)
%SWEEPCHANNEL  Pooled precision/recall at every threshold for one channel.

    switch ch
        case 'microaneurysms', sub = '1. Microaneurysms'; suf = '_MA.tif';
        case 'haemorrhages',   sub = '2. Haemorrhages';   suf = '_HE.tif';
    end

    cf = resolveModelPath(cfg, ch, opts.modelPath);
    if ~isfile(cf)
        error('drishti:noClassifier', ...
            ['No stage-2 classifier at %s. Build the candidates and train it ' ...
             'first - there is no threshold to choose without one.'], cf);
    end
    C = load(cf);
    genThreshSD = 1.5;
    if isfield(C.meta, 'threshSD'), genThreshSD = C.meta.threshSD; end

    maskDir = fullfile(cfg.idrid.segTrainMasks, sub);
    L = dir(fullfile(cfg.idrid.segTrainImages, '*.jpg'));
    n = min(numel(L), opts.limit);

    thresholds = opts.thresholds;
    nt = numel(thresholds);
    TPp = zeros(nt,1); NP = zeros(nt,1);   % prediction side -> precision
    TPg = zeros(nt,1); NG = zeros(nt,1);   % ground-truth side -> recall

    if opts.verbose
        fprintf('\n  %s: sweeping %d thresholds over %d TRAIN images (threshSD %.2f)\n', ...
            ch, nt, n, genThreshSD);
    end

    for k = 1:n
        base = erase(L(k).name, '.jpg');
        img = imread(fullfile(cfg.idrid.segTrainImages, L(k).name));

        fov  = detectFOV(img);
        disc = locateOpticDisc(img, 'fov', fov);
        v    = segmentVessels(img, 'fov', fov, 'discRadiusPx', disc.radius);
        ctx  = struct('fov', fov, 'disc', disc, 'vesselMask', v.mask);

        % Candidates only - no classifier on this call, so the generator is
        % not filtered before we get to choose how to filter it.
        d = detectDarkLesions(img, ctx, 'threshSD', genThreshSD, ...
            'fragmentRejection', opts.fragmentRejection, 'returnCandidates', true);
        cd = d.candidates;
        centroids = cd.(ch).centroids;

        % An absent mask means the lesion is absent, not unlabelled - the same
        % rule VALIDATELESIONDETECTORS applies, and for the same reason:
        % skipping negative images would discard every false positive produced
        % on them, which is exactly how a weak detector comes to look strong.
        mp = fullfile(maskDir, [base suf]);
        if isfile(mp)
            g = imread(mp);
            if ndims(g) == 3, g = g(:,:,1); end
            gt = (g > 0) & fov.mask;
        else
            gt = false(size(fov.mask));
        end

        if isempty(centroids)
            % Nothing predicted anywhere; every ground-truth lesion is missed
            % at every threshold.
            ccG = bwconncomp(gt, 8);
            NG = NG + ccG.NumObjects;
            continue
        end

        % Cut patches the way THIS model was trained, not the way this file
        % happens to have an image handy - see RESOLVEPATCHSOURCE.
        [srcImg, cScale] = resolvePatchSource(C, img, cd.workImage, cd.scale);
        scores = scoreLesionCandidates(srcImg, centroids, C, 'centroidScale', cScale);
        ccW = bwconncomp(cd.(ch).mask, 8);
        fullSize = [size(img,1) size(img,2)];

        for t = 1:nt
            keep = scores >= thresholds(t);
            m = false(ccW.ImageSize);
            if any(keep)
                m(vertcat(ccW.PixelIdxList{keep})) = true;
            end
            % Upsample exactly as DETECTDARKLESIONS returns its masks, so the
            % components counted here are the components the evaluator counts.
            p = imresize(m, fullSize, 'nearest') & fov.mask;

            [tpPred, nPred, tpGt, nGt] = lesionCounts(p, gt);
            TPp(t) = TPp(t) + tpPred;  NP(t) = NP(t) + nPred;
            TPg(t) = TPg(t) + tpGt;    NG(t) = NG(t) + nGt;
        end

        clear d cd v img
        if opts.verbose && mod(k, 10) == 0
            fprintf('    %2d/%d images\n', k, n);
        end
    end

    prec = TPp ./ max(NP, 1);
    rec  = TPg ./ max(NG, 1);
    f1   = 2 * prec .* rec ./ max(prec + rec, eps);
    stage1 = isinf(thresholds) & thresholds < 0;

    S = struct();
    S.channel = ch;
    S.n = n;
    S.generatorThreshSD = genThreshSD;
    S.classifierFile = cf;
    S.table = table(thresholds(:), stage1(:), prec, rec, f1, NP, NG, ...
        'VariableNames', {'threshold','stage1Alone','precision','recall','f1', ...
                          'predicted','groundTruth'});
    % Generator recall is the row where nothing is discarded: the hard ceiling
    % a false-positive classifier can never rise above.
    S.generatorRecall = max(rec);
    S.selected = applyRule(thresholds, prec, rec, f1, rule);
end


function sel = applyRule(thresholds, prec, rec, f1, rule)
%APPLYRULE  The selection rule, exactly as written in the config file.
%
%   Lowest threshold reaching precisionTarget, ties broken by recall. If
%   nothing reaches it, the best-F1 row is taken and reachedTarget is recorded
%   false - the channel then fails the display gate honestly rather than being
%   searched until it passes.

    target = rule.precisionTarget;
    ok = prec >= target;

    if any(ok)
        idx = find(ok);
        % "Lowest threshold" = the most permissive point that still clears the
        % precision target, because every step tighter costs recall and recall
        % is the other half of the gate. -Inf (stage 1 alone) sorts first, so
        % it wins whenever the classifier is not needed to reach the target.
        [~, o] = sortrows([thresholds(idx)', -rec(idx)], [1 2]);
        best = idx(o(1));
        reached = true;
    else
        [~, best] = max(f1);
        reached = false;
    end

    sel = struct();
    sel.threshold = thresholds(best);
    sel.applyClassifier = ~(isinf(sel.threshold) && sel.threshold < 0);
    sel.precision = prec(best);
    sel.recall = rec(best);
    sel.f1 = f1(best);
    sel.reachedTarget = reached;

    if ~sel.applyClassifier
        % Recorded as a real threshold so the JSON never carries -Inf, which
        % jsonencode cannot represent.
        sel.threshold = 0;
        sel.note = sprintf(['Stage 1 alone won the TRAIN sweep (precision %.3f, ' ...
            'recall %.3f): no classifier threshold beat keeping every candidate ' ...
            'under the selection rule. classifierThreshold is inert while ' ...
            'applyClassifier is false.'], sel.precision, sel.recall);
    elseif reached
        sel.note = sprintf(['Lowest threshold reaching the %.2f TRAIN precision ' ...
            'target. TRAIN precision %.3f, recall %.3f. Not a held-out number.'], ...
            target, sel.precision, sel.recall);
    else
        sel.note = sprintf(['No threshold reached the %.2f TRAIN precision target ' ...
            '(best precision %.3f). Fell back to best TRAIN F1 %.3f at precision ' ...
            '%.3f, recall %.3f. This channel is expected to FAIL the display ' ...
            'gate; that is the honest outcome, not a reason to lower the bar.'], ...
            target, max(prec), sel.f1, sel.precision, sel.recall);
    end
end


function printReport(R, channels)
    fprintf('\n  ======================================================\n');
    fprintf('  STAGE-2 OPERATING POINT - %s\n', R.dataset);
    fprintf('  Selection on TRAIN. The display gate is measured on TEST.\n');
    fprintf('  precision target %.2f | fragmentRejection %d\n', ...
        R.precisionTarget, R.fragmentRejection);
    fprintf('  ======================================================\n');
    for ci = 1:numel(channels)
        ch = channels{ci};
        S = R.channels.(ch);
        fprintf('\n  %s  (n=%d, generator threshSD %.2f)\n', ch, S.n, S.generatorThreshSD);
        disp(S.table);
        fprintf('    generator recall ceiling %.3f\n', S.generatorRecall);
        fprintf('    SELECTED: applyClassifier=%d threshold=%.3f -> TRAIN P %.3f R %.3f F1 %.3f\n', ...
            S.selected.applyClassifier, S.selected.threshold, ...
            S.selected.precision, S.selected.recall, S.selected.f1);
        fprintf('    %s\n', S.selected.note);
    end
    fprintf('\n  These are TRAIN numbers. They are optimistic by construction and\n');
    fprintf('  must never be quoted as detector performance.\n');
end
