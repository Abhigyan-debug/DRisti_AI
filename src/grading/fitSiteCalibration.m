function S = fitSiteCalibration(scores, truth, opts)
%FITSITECALIBRATION  Per-site calibration and operating point from target data.
%
%   S = FITSITECALIBRATION(scores, truth) fits a Platt map AND selects the
%   operating threshold using a small labelled sample from the TARGET domain -
%   the actual camera and clinic where the system will run.
%
%   S = FITSITECALIBRATION(scores, truth, targetSensitivity=0.90)
%
%   Returns S with .a, .b (Platt), .threshold (on the calibrated scale),
%   .thresholdRaw (on the raw score scale), .n, and the achieved calibration-set
%   sensitivity/specificity.
%
%   WHY PER-SITE, AND WHY THIS IS NOT CHEATING
%   ------------------------------------------
%   Our external validation showed the failure precisely: AUC held up across
%   domains (0.989 -> 0.885) while sensitivity collapsed (90.3% -> 31.2%),
%   because the raw score scale shifted. The model still RANKS correctly on
%   unseen cameras; only the cut point is wrong. A threshold is a property of
%   an imaging domain, not of a model, and pretending one number transfers to
%   every camera is what produced the 31.2%.
%
%   The rule that keeps this honest is absolute:
%
%       THE CALIBRATION SET AND THE EVALUATION SET MUST BE DISJOINT.
%
%   Fit here, freeze, then evaluate on images this function never saw. If the
%   same images inform the threshold and the reported number, the result is
%   indistinguishable from tuning on test - which is exactly the failure mode
%   the whole holdout protocol exists to prevent.
%
%   This is also what real deployments do: site-specific validation is standard
%   in clinical AI rollout rather than an admission of weakness. The deployable
%   claim becomes "N labelled images per new camera", which is an operational
%   cost a district programme can actually plan for.
%
%   See also APPLYSITECALIBRATION, FITCALIBRATOR, EVALUATEIDRIDTRANSFER.

    arguments
        scores double
        truth logical
        opts.targetSensitivity (1,1) double {mustBeInRange(opts.targetSensitivity,0.5,1)} = 0.90
    end

    scores = scores(:);
    truth = truth(:);
    ok = ~isnan(scores);
    scores = scores(ok);
    truth = truth(ok);

    if numel(unique(truth)) < 2
        error('drishti:degenerateCalibrationSet', ...
            ['The calibration sample contains only one class (%d images, all %s).\n' ...
             'A per-site calibration set must contain BOTH referable and ' ...
             'non-referable cases.'], numel(truth), mat2str(unique(truth)));
    end

    S = struct();
    S.n = numel(scores);
    S.nPositive = nnz(truth);
    S.targetSensitivity = opts.targetSensitivity;

    % ---- Platt map, fitted on the target domain --------------------------
    % Smoothed targets, as Platt recommends: with few images and near-separable
    % scores a hard 0/1 fit runs off to +/-inf.
    nPos = nnz(truth); nNeg = numel(truth) - nPos;
    tHi = (nPos + 1) / (nPos + 2);
    tLo = 1 / (nNeg + 2);
    target = double(truth) * tHi + double(~truth) * tLo;

    warnState = warning('off', 'stats:glmfit:IterationLimit');
    b = glmfit(scores, target, 'binomial', 'link', 'logit');
    warning(warnState);
    S.a = b(2);
    S.b = b(1);

    calibrated = 1 ./ (1 + exp(-(S.a * scores + S.b)));

    % ---- operating point, chosen on the target domain --------------------
    [X, Y, Thr] = perfcurve(truth, calibrated, true);
    idx = find(Y >= opts.targetSensitivity, 1, 'first');
    if isempty(idx), idx = numel(Thr); end
    S.threshold = Thr(idx);

    % Equivalent cut on the raw scale, for callers that skip the Platt map.
    [Xr, Yr, ThrRaw] = perfcurve(truth, scores, true);
    idxr = find(Yr >= opts.targetSensitivity, 1, 'first');
    if isempty(idxr), idxr = numel(ThrRaw); end
    S.thresholdRaw = ThrRaw(idxr);

    S.calibrationSensitivity = Y(idx);
    S.calibrationSpecificity = 1 - X(idx);
    S.fittedAt = string(datetime('now'));

    % A threshold fitted on a handful of images is a noisy estimate. Say so in
    % the struct so a caller cannot quietly rely on a 20-image calibration.
    if S.n < 50
        S.warning = sprintf(['Calibration set has only %d images (%d positive). ' ...
            'The threshold is a noisy estimate; expect the achieved sensitivity ' ...
            'on new data to fall short of the target.'], S.n, S.nPositive);
    else
        S.warning = '';
    end
end
