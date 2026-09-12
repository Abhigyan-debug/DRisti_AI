function R = evaluateTwoStageDetector(opts)
%EVALUATETWOSTAGEDETECTOR  Honest, re-runnable measurement of the two-stage pipeline.
%
%   R = EVALUATETWOSTAGEDETECTOR() loads models/candidate_classifier_<lesion>.mat
%   and measures stage-1-alone vs stage-1+classifier recall/precision/count
%   ratio against IDRiD ground truth, using EXACTLY the classifier's own
%   held-out validation images (meta.valImages) so nothing seen in training
%   leaks into the number that gets quoted.
%
%   R = EVALUATETWOSTAGEDETECTOR(lesion='haemorrhages', classifierThreshold=0.9)
%
%   WHY THIS EXISTS
%   ---------------
%   The doc's original "Stage 1 + classifier" row (recall 0.095, precision
%   0.053) came from a one-off script that is not in this repo - exactly the
%   failure EVALUATESEGMENTATION.m was written to close for vessels/exudates.
%   This is that same fix applied to the two-stage detector.
%
%   See also EVALUATESEGMENTATION, TRAINCANDIDATECLASSIFIER, DETECTDARKLESIONS.

    arguments
        opts.lesion (1,:) char {mustBeMember(opts.lesion,{'microaneurysms','haemorrhages'})} = 'microaneurysms'
        opts.classifierFile (1,:) char = ''
        % NaN = use the frozen operating point from
        % config/lesion_operating_points.json, i.e. measure what actually
        % ships. It used to default to a hardcoded 0.5, so this diagnostic
        % reported a configuration the pipeline did not run.
        opts.classifierThreshold (1,1) double = NaN
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    switch opts.lesion
        case 'microaneurysms', sub = '1. Microaneurysms'; suf = '_MA.tif'; fld = 'maMask';
        case 'haemorrhages',   sub = '2. Haemorrhages';   suf = '_HE.tif'; fld = 'haemMask';
    end

    cf = opts.classifierFile;
    if isempty(cf), cf = fullfile(cfg.modelsDir, ['candidate_classifier_' opts.lesion '.mat']); end
    C = load(cf);
    % This function loads the model directly rather than through
    % LOADCANDIDATECLASSIFIERS, so it does not inherit that function's
    % geometry check. Warn here instead of measuring a model whose patches
    % were cut at a scale the detector no longer uses - the numbers would look
    % ordinary and mean nothing.
    if ~isfield(C.meta, 'patchGeometry') || ~strcmp(char(C.meta.patchGeometry), 'workingScale/v2')
        warning('drishti:staleClassifierGeometry', ...
            ['%s was trained on full-resolution patches, but DETECTDARKLESIONS ' ...
             'now cuts working-scale ones (~2x smaller field on IDRiD). These ' ...
             'numbers measure the mismatch, not the classifier. Rebuild first.'], cf);
    end
    valImages = string(C.meta.valImages);

    maskDir = fullfile(cfg.idrid.segTrainMasks, sub);

    rec1 = nan(numel(valImages),1); prec1 = nan(numel(valImages),1);
    nDet1 = nan(numel(valImages),1); nTrue = nan(numel(valImages),1);
    rec2 = nan(numel(valImages),1); prec2 = nan(numel(valImages),1); nDet2 = nan(numel(valImages),1);

    for k = 1:numel(valImages)
        base = char(valImages(k));
        ip = fullfile(cfg.idrid.segTrainImages, [base '.jpg']);
        mp = fullfile(maskDir, [base suf]);
        if ~isfile(ip) || ~isfile(mp)
            warning('drishti:missingValImage', 'Skipping %s: image or mask not found.', base);
            continue
        end
        img = imread(ip);
        gt = imread(mp);
        if ndims(gt) == 3, gt = gt(:,:,1); end
        gt = gt > 0;

        fov = detectFOV(img);
        disc = locateOpticDisc(img, 'fov', fov);
        v = segmentVessels(img, 'fov', fov, 'discRadiusPx', disc.radius);
        ctx = struct('fov', fov, 'disc', disc, 'vesselMask', v.mask);

        % The classifier was trained on candidates generated at ITS threshSD
        % (meta.threshSD). Scoring "stage 1 alone" at a different threshold
        % would compare two different generators, not measure what the
        % classifier adds on top of the one it actually sees. Older saved
        % classifiers (trained before this field existed) fall back to 1.5,
        % the previous default.
        genThreshSD = 1.5;
        if isfield(C.meta, 'threshSD'), genThreshSD = C.meta.threshSD; end

        % stage 1 alone, at the SAME generator setting the classifier consumes
        d1 = detectDarkLesions(img, ctx, 'threshSD', genThreshSD);
        [rec1(k), prec1(k), nDet1(k), nTrue(k)] = scoreOne(d1.(fld) & fov.mask, gt & fov.mask);

        % stage 1 + classifier
        d2 = detectDarkLesions(img, ctx, 'threshSD', genThreshSD, 'candidateClassifier', C, ...
            'classifierThreshold', opts.classifierThreshold);   % NaN -> frozen point
        [rec2(k), prec2(k), nDet2(k)] = scoreOne(d2.(fld) & fov.mask, gt & fov.mask);

        if opts.verbose
            fprintf('  %-12s  stage1 rec %.3f prec %.3f (n=%d) | +classifier rec %.3f prec %.3f (n=%d) | true %d\n', ...
                base, rec1(k), prec1(k), nDet1(k), rec2(k), prec2(k), nDet2(k), nTrue(k));
        end
    end

    R = struct();
    R.lesion = opts.lesion;
    R.n = nnz(~isnan(rec1));
    % Record the threshold that was APPLIED. opts.classifierThreshold is NaN
    % when the caller wants the frozen operating point, and a saved result
    % carrying NaN would not say what was measured.
    R.classifierThreshold = opts.classifierThreshold;
    if ~isfinite(R.classifierThreshold)
        OPrec = loadLesionOperatingPoints();
        R.classifierThreshold = OPrec.(opts.lesion).classifierThreshold;
        R.classifierApplied = OPrec.(opts.lesion).applyClassifier;
    else
        R.classifierApplied = true;
    end
    R.stage1 = struct('recall', mean(rec1,'omitnan'), 'precision', mean(prec1,'omitnan'), ...
        'meanDetected', mean(nDet1,'omitnan'), 'meanTrue', mean(nTrue,'omitnan'));
    R.stage1.countRatio = R.stage1.meanDetected / max(R.stage1.meanTrue, 1);
    R.twoStage = struct('recall', mean(rec2,'omitnan'), 'precision', mean(prec2,'omitnan'), ...
        'meanDetected', mean(nDet2,'omitnan'), 'meanTrue', mean(nTrue,'omitnan'));
    R.twoStage.countRatio = R.twoStage.meanDetected / max(R.twoStage.meanTrue, 1);
    R.fitToDisplay = R.twoStage.precision >= 0.5;
    R.protocol = ['FOV-masked; per-lesion recall/precision by component overlap; ' ...
                  'measured ONLY on the classifier''s held-out validation images (no train leakage).'];

    if opts.verbose
        % Report the value that was actually applied, not the NaN sentinel.
        effThr = R.classifierThreshold;
        fprintf('\n  ===== TWO-STAGE %s  (n=%d held-out images, threshold %.2f) =====\n', ...
            upper(opts.lesion), R.n, effThr);
        fprintf('  stage 1 alone      recall %.3f  precision %.3f  (%.1fx over-detection)\n', ...
            R.stage1.recall, R.stage1.precision, R.stage1.countRatio);
        fprintf('  stage 1 + classifier  recall %.3f  precision %.3f  (%.1fx)\n', ...
            R.twoStage.recall, R.twoStage.precision, R.twoStage.countRatio);
        if R.fitToDisplay
            fprintf('  -> fit to display (precision >= 0.5)\n');
        else
            fprintf('  -> NOT fit to display (precision < 0.5)\n');
        end
    end
end

function [rec, prec, nDet, nTrue] = scoreOne(pred, gt)
    ccG = bwconncomp(gt, 8); ccP = bwconncomp(pred, 8);
    nTrue = ccG.NumObjects; nDet = ccP.NumObjects;
    hg = 0;
    for c = 1:ccG.NumObjects
        if any(pred(ccG.PixelIdxList{c})), hg = hg + 1; end
    end
    hp = 0;
    for c = 1:ccP.NumObjects
        if any(gt(ccP.PixelIdxList{c})), hp = hp + 1; end
    end
    rec = hg / max(ccG.NumObjects, 1);
    prec = hp / max(ccP.NumObjects, 1);
end
