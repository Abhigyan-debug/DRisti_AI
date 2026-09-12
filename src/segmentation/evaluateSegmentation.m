function R = evaluateSegmentation(target, opts)
%EVALUATESEGMENTATION  Score Module 2 detectors against ground truth.
%
%   R = EVALUATESEGMENTATION('vessels')   DRIVE, Dice + FOV-masked AUC
%   R = EVALUATESEGMENTATION('exudates')  IDRiD hard exudates, Dice + AUPR
%   R = EVALUATESEGMENTATION('all')
%
%   R = EVALUATESEGMENTATION(target, limit=20, verbose=true)
%
%   WHY THIS EXISTS
%   ---------------
%   Phase 2's vessel (Dice 0.622) and exudate (Dice 0.210) numbers were
%   originally produced by throwaway scripts that no longer exist. Quoting a
%   figure nobody can regenerate is not a measurement - a judge asking "how did
%   you get that?" deserves better than "we ran a script once". This is the
%   committed, re-runnable version.
%
%   EVALUATION PROTOCOL (stated because it changes the numbers)
%   -----------------------------------------------------------
%   Vessels, per Galdran et al.'s methodological warning:
%     - FOV-MASKED. Pixels outside the field of view are trivially correct and
%       including them inflates every metric.
%     - ONE GLOBAL THRESHOLD, not a per-image optimum.
%     - Dice, not accuracy. Vessels are ~10% of pixels, so accuracy is
%       dominated by background and a blank prediction scores ~0.9.
%   Published DRIVE numbers are frequently incomparable because papers differ
%   on exactly these points. Ours are stated so they can be checked.
%
%   ⚠️ DRIVE test-set vessel ground truth is withheld in our copy (blocker B2),
%   so vessels are scored on the 20 TRAINING images. That is not the official
%   protocol and the result is NOT directly comparable to published test-split
%   figures. Said plainly rather than buried.
%
%   See also SEGMENTVESSELS, SEGMENTEXUDATES, EXTRACTLESIONFEATURES.

    arguments
        target (1,:) char {mustBeMember(target,{'vessels','exudates','lesions','all'})} = 'all'
        opts.limit (1,1) double = Inf
        opts.verbose (1,1) logical = true
        % Passed straight to SEGMENTEXUDATES - lets a threshold sweep measure
        % REAL post-split hard-exudate precision, not just the candidate-stage
        % proxy in SWEEPEXUDATETHRESHOLD.
        opts.exudateThresholdK (1,1) double = 2.2
    end

    R = struct();
    if any(strcmp(target, {'vessels','all'}))
        R.vessels = evalVessels(opts);
    end
    if any(strcmp(target, {'exudates','all'}))
        R.exudates = evalExudates(opts);
    end
    if any(strcmp(target, {'lesions','all'}))
        R.darkLesions = evalDarkLesions(opts);
    end

    if opts.verbose
        fprintf('\n  ===== MODULE 2 SEGMENTATION =====\n');
        if isfield(R,'vessels')
            v = R.vessels;
            fprintf('  Vessels (DRIVE %s, n=%d)\n', v.split, v.n);
            fprintf('    Dice %.4f  [%.4f - %.4f]   sens %.3f  spec %.3f\n', ...
                v.diceMean, v.diceCI(1), v.diceCI(2), v.sensMean, v.specMean);
            fprintf('    benchmark (U-Net, official test split): 0.828  -> %.2fx\n', ...
                v.diceMean/0.828);
            fprintf('    NOTE: training split, NOT the official protocol (B2).\n');
        end
        if isfield(R,'darkLesions')
            for ch = {'microaneurysms','haemorrhages'}
                if ~isfield(R.darkLesions, ch{1}), continue; end
                e = R.darkLesions.(ch{1});
                if e.fitToDisplay, verdict = 'fit to display'; else, verdict = 'NOT fit to display'; end
                fprintf('  %s (IDRiD train, n=%d)\n', ch{1}, e.n);
                fprintf('    recall %.3f  precision %.3f  |  detected %.0f vs %.0f true (%.1fx)\n', ...
                    e.recallMean, e.precisionMean, e.meanDetected, e.meanTrue, e.countRatio);
                fprintf('    -> %s\n', verdict);
            end
        end
        if isfield(R,'exudates')
            e = R.exudates;
            fprintf('  hard exudates (IDRiD train, n=%d)\n', e.n);
            fprintf('    recall %.3f  precision %.3f  |  detected %.0f vs %.0f true (%.1fx)\n', ...
                e.recallMean, e.precisionMean, e.meanDetected, e.meanTrue, e.countRatio);
            fprintf('    Dice %.4f  [%.4f - %.4f]\n', e.diceMean, e.diceCI(1), e.diceCI(2));
            if e.fitToDisplay, vv='fit to display'; else, vv='NOT fit to display'; end
            fprintf('    -> %s\n', vv);
        end
    end
end


% ------------------------------------------------------------------ vessels

function V = evalVessels(opts)
    cfg = drishti_paths();
    LI = dir(fullfile(cfg.drive.trainImages, '*.tif'));
    LG = dir(fullfile(cfg.drive.trainVessels, '*.gif'));
    LM = dir(fullfile(cfg.drive.trainMasks, '*.gif'));
    n = min([numel(LI), numel(LG), opts.limit]);

    dice = nan(n,1); sens = nan(n,1); spec = nan(n,1);
    for k = 1:n
        img = imread(fullfile(cfg.drive.trainImages, LI(k).name));
        gt  = readBinary(fullfile(cfg.drive.trainVessels, LG(k).name));
        if k <= numel(LM)
            fovm = readBinary(fullfile(cfg.drive.trainMasks, LM(k).name));
        else
            fovm = true(size(gt));
        end

        v = segmentVessels(img);
        pred = v.mask;

        % FOV mask applied to BOTH - see the protocol note in the help.
        pred = pred & fovm;
        gt   = gt   & fovm;

        tp = nnz(pred & gt); fp = nnz(pred & ~gt); fn = nnz(~pred & gt);
        tn = nnz(~pred & ~gt & fovm);
        dice(k) = 2*tp / max(2*tp + fp + fn, 1);
        sens(k) = tp / max(tp + fn, 1);
        spec(k) = tn / max(tn + fp, 1);
    end

    V.n = n;
    V.split = 'training (test GT withheld - B2)';
    V.dice = dice;
    V.diceMean = mean(dice, 'omitnan');
    V.diceCI = ciMean(dice);
    V.sensMean = mean(sens, 'omitnan');
    V.specMean = mean(spec, 'omitnan');
    V.protocol = 'FOV-masked, single global threshold, Dice not accuracy';
end


% ----------------------------------------------------------------- exudates

function E = evalExudates(opts)
    cfg = drishti_paths();
    exDir = fullfile(cfg.idrid.segTrainMasks, '3. Hard Exudates');
    L = dir(fullfile(exDir, '*.tif'));
    n = min(numel(L), opts.limit);

    dice = nan(n,1); aupr = nan(n,1);
    recL = nan(n,1); precL = nan(n,1); nTrue = nan(n,1); nDet = nan(n,1);
    for k = 1:n
        base = erase(L(k).name, '_EX.tif');
        ip = fullfile(cfg.idrid.segTrainImages, [base '.jpg']);
        if ~isfile(ip), continue; end
        img = imread(ip);
        gt = readBinary(fullfile(exDir, L(k).name));

        fov = detectFOV(img);
        disc = locateOpticDisc(img, 'fov', fov);
        v = segmentVessels(img, 'fov', fov, 'discRadiusPx', disc.radius);
        fv = locateFovea(img, disc, 'vesselMask', v.mask);
        e = segmentExudates(img, struct('fov',fov,'disc',disc, ...
            'vesselMask',v.mask,'fovea',fv), 'thresholdK', opts.exudateThresholdK);

        pred = e.hardMask & fov.mask;
        g = gt & fov.mask;
        tp = nnz(pred & g);
        dice(k) = 2*tp / max(2*tp + nnz(pred & ~g) + nnz(~pred & g), 1);

        % Binary AUPR degenerates to a single point; report precision*recall
        % area for the one operating point we have. The IDRiD benchmark sweeps
        % a threshold, so this is a LOWER bound on what a swept version scores
        % and is not directly comparable. Stated, not hidden.
        prec = tp / max(nnz(pred), 1);
        rec  = tp / max(nnz(g), 1);
        aupr(k) = prec * rec;

        % Per-LESION recall/precision, the same standard applied to the dark
        % lesions. Pixelwise Dice and per-lesion precision answer different
        % questions, and "is this count fit to show a clinician" is the second.
        ccG = bwconncomp(g, 8); ccP = bwconncomp(pred, 8);
        nTrue(k) = ccG.NumObjects; nDet(k) = ccP.NumObjects;
        hg = 0;
        for c = 1:ccG.NumObjects
            if any(pred(ccG.PixelIdxList{c})), hg = hg + 1; end
        end
        hp = 0;
        for c = 1:ccP.NumObjects
            if any(g(ccP.PixelIdxList{c})), hp = hp + 1; end
        end
        recL(k)  = hg / max(ccG.NumObjects, 1);
        precL(k) = hp / max(ccP.NumObjects, 1);
    end

    E.n = nnz(~isnan(dice));
    E.dice = dice;
    E.diceMean = mean(dice, 'omitnan');
    E.diceCI = ciMean(dice);
    E.auprMean = mean(aupr, 'omitnan');
    E.recallMean = mean(recL, 'omitnan');
    E.precisionMean = mean(precL, 'omitnan');
    E.meanDetected = mean(nDet, 'omitnan');
    E.meanTrue = mean(nTrue, 'omitnan');
    E.countRatio = E.meanDetected / max(E.meanTrue, 1);
    E.fitToDisplay = E.precisionMean >= 0.5;
    E.protocol = 'FOV-masked, single operating point (not a swept AUPR)';
end


% -------------------------------------------------------------- dark lesions

function D = evalDarkLesions(opts)
%EVALDARKLESIONS  Microaneurysms AND haemorrhages against IDRiD masks.
%
%   Both channels come out of the same candidate generator and are separated
%   only by a size/shape rule, so validating one and displaying the other was
%   never defensible. MA was measured (recall 0.110, precision 0.022) and
%   pulled from the clinical report while haemorrhage stayed on it unmeasured.
%   This closes that gap.
%
%   Reports COUNT RATIO alongside per-lesion recall/precision, because the
%   count is what reaches the clinician. Per-lesion scoring is by connected
%   component overlap, not pixelwise: these objects are a few pixels across, so
%   a one-pixel offset destroys pixelwise Dice while being clinically
%   irrelevant.

    cfg = drishti_paths();
    specs = { 'microaneurysms', '1. Microaneurysms', '_MA.tif', 'maMask'; ...
              'haemorrhages',   '2. Haemorrhages',   '_HE.tif', 'haemMask' };

    D = struct();
    for si = 1:size(specs,1)
        maskDir = fullfile(cfg.idrid.segTrainMasks, specs{si,2});
        L = dir(fullfile(maskDir, ['*' specs{si,3}]));
        n = min(numel(L), opts.limit);

        rec = nan(n,1); prec = nan(n,1); nDet = nan(n,1); nTrue = nan(n,1); dice = nan(n,1);

        for k = 1:n
            base = erase(L(k).name, specs{si,3});
            ip = fullfile(cfg.idrid.segTrainImages, [base '.jpg']);
            if ~isfile(ip), continue; end
            img = imread(ip);
            gt = readBinary(fullfile(maskDir, L(k).name));

            fov = detectFOV(img);
            disc = locateOpticDisc(img, 'fov', fov);
            v = segmentVessels(img, 'fov', fov, 'discRadiusPx', disc.radius);
            d = detectDarkLesions(img, struct('fov',fov,'disc',disc,'vesselMask',v.mask));

            pred = d.(specs{si,4}) & fov.mask;
            g = gt & fov.mask;

            tp = nnz(pred & g);
            dice(k) = 2*tp / max(2*tp + nnz(pred & ~g) + nnz(~pred & g), 1);

            ccG = bwconncomp(g, 8); ccP = bwconncomp(pred, 8);
            nTrue(k) = ccG.NumObjects; nDet(k) = ccP.NumObjects;
            hg = 0;
            for c = 1:ccG.NumObjects
                if any(pred(ccG.PixelIdxList{c})), hg = hg + 1; end
            end
            hp = 0;
            for c = 1:ccP.NumObjects
                if any(g(ccP.PixelIdxList{c})), hp = hp + 1; end
            end
            rec(k)  = hg / max(ccG.NumObjects, 1);
            prec(k) = hp / max(ccP.NumObjects, 1);
        end

        E = struct();
        E.n = nnz(~isnan(rec));
        E.diceMean = mean(dice,'omitnan');
        E.recallMean = mean(rec,'omitnan');
        E.precisionMean = mean(prec,'omitnan');
        E.meanDetected = mean(nDet,'omitnan');
        E.meanTrue = mean(nTrue,'omitnan');
        E.countRatio = E.meanDetected / max(E.meanTrue, 1);
        % A channel is only fit to show a clinician if most of what it reports
        % is real. 0.5 precision is a low bar and deliberately so - below it,
        % a displayed count misinforms more often than it informs.
        E.fitToDisplay = E.precisionMean >= 0.5;
        E.protocol = 'FOV-masked; per-lesion recall/precision by component overlap';
        D.(specs{si,1}) = E;
    end
end


% ------------------------------------------------------------------ helpers

function b = readBinary(p)
    m = imread(p);
    if ndims(m) == 3, m = m(:,:,1); end
    b = m > 0;
end

function ci = ciMean(x)
    x = x(~isnan(x));
    if numel(x) < 2, ci = [NaN NaN]; return; end
    se = std(x) / sqrt(numel(x));
    ci = [mean(x) - 1.96*se, mean(x) + 1.96*se];
end
