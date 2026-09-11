function R = runSiteCalibrationStudy(opts)
%RUNSITECALIBRATIONSTUDY  Does per-site calibration fix cross-domain transfer?
%
%   R = RUNSITECALIBRATIONSTUDY() fits a site calibrator on IDRiD's TRAINING
%   split and evaluates on IDRiD's TEST split, which the calibrator never sees.
%
%   R = RUNSITECALIBRATIONSTUDY(sizes=[25 50 100 200 413], repeats=20)
%
%   THE QUESTION THIS ANSWERS
%   -------------------------
%   Not "does calibration help" - that is nearly tautological when the fit and
%   the test are the same images. The operational question is:
%
%       HOW MANY LABELLED IMAGES does a new site need before the operating
%       point transfers?
%
%   That number is the deployment cost. "Recalibrate per camera" is not a plan;
%   "40 labelled images per camera" is one a district programme can budget for.
%
%   PROTOCOL
%   --------
%   IDRiD is used because Messidor-2 is spent - it was evaluated once, by
%   design. IDRiD is a different centre and camera from APTOS, fully labelled,
%   and carries no holdout status, so it can be split repeatedly.
%
%     calibration sample  <- drawn from IDRiD TRAIN (413 images)
%     evaluation          <- IDRiD TEST (103 images), never seen by the fit
%
%   The splits are disjoint by construction. Small calibration sizes are
%   resampled many times because a 25-image estimate is noisy and a single
%   draw would report luck rather than behaviour.
%
%   The baseline is the APTOS-fitted threshold applied unchanged - i.e. what
%   the system does today.
%
%   See also FITSITECALIBRATION, EVALUATEIDRIDTRANSFER.

    arguments
        opts.sizes (1,:) double = [25 50 100 200 413]
        opts.repeats (1,1) double = 20
        opts.targetSensitivity (1,1) double = 0.90
        opts.seed (1,1) double = 0
    end

    cfg = drishti_paths();
    rng(opts.seed);

    % ---- scores on both IDRiD splits -------------------------------------
    fprintf('  scoring IDRiD train (calibration pool)...\n');
    Tr = evaluateIdridTransfer('split', 'train', 'verbose', false);
    fprintf('  scoring IDRiD test (evaluation, held out from the fit)...\n');
    Te = evaluateIdridTransfer('split', 'test',  'verbose', false);

    trScores = Tr.scores(:); trTruth = logical(Tr.truth(:));
    teScores = Te.scores(:); teTruth = logical(Te.truth(:));
    okTr = ~isnan(trScores); trScores = trScores(okTr); trTruth = trTruth(okTr);
    okTe = ~isnan(teScores); teScores = teScores(okTe); teTruth = teTruth(okTe);

    % ---- baseline: the APTOS threshold, unchanged ------------------------
    V = load(fullfile(cfg.resultsDir, 'phase3_val_result.mat'));
    aptosThr = V.R.thresholds.highSensitivity;
    basePred = teScores >= aptosThr;
    R.baseline = struct( ...
        'name', 'APTOS threshold applied unchanged', ...
        'threshold', aptosThr, ...
        'sensitivity', nnz(basePred & teTruth)/max(nnz(teTruth),1), ...
        'specificity', nnz(~basePred & ~teTruth)/max(nnz(~teTruth),1));

    % ---- sweep calibration-set size --------------------------------------
    nSizes = numel(opts.sizes);
    sens = nan(nSizes, opts.repeats);
    spec = nan(nSizes, opts.repeats);

    for si = 1:nSizes
        nCal = min(opts.sizes(si), numel(trScores));
        reps = opts.repeats;
        if nCal >= numel(trScores)
            reps = 1;   % using the whole pool - resampling adds nothing
        end
        for r = 1:reps
            idx = randperm(numel(trScores), nCal);
            try
                S = fitSiteCalibration(trScores(idx), trTruth(idx), ...
                    'targetSensitivity', opts.targetSensitivity);
            catch
                continue    % degenerate draw (one class only) - skip
            end
            pred = teScores >= S.thresholdRaw;
            sens(si, r) = nnz(pred & teTruth) / max(nnz(teTruth), 1);
            spec(si, r) = nnz(~pred & ~teTruth) / max(nnz(~teTruth), 1);
        end
    end

    R.sizes = opts.sizes;
    R.sensitivity = sens;
    R.specificity = spec;
    R.sensMean = mean(sens, 2, 'omitnan');
    R.specMean = mean(spec, 2, 'omitnan');
    R.sensStd  = std(sens, 0, 2, 'omitnan');
    R.nTest = numel(teTruth);
    R.testPrevalence = mean(teTruth);
    R.targetSensitivity = opts.targetSensitivity;

    printStudy(R);

    out = fullfile(cfg.resultsDir, 'site_calibration_study.mat');
    save(out, 'R');
    fprintf('\n  saved -> results/site_calibration_study.mat\n');
end


function printStudy(R)
    fprintf('\n  ==================================================================\n');
    fprintf('   PER-SITE CALIBRATION STUDY\n');
    fprintf('   fit on IDRiD TRAIN  ->  evaluate on IDRiD TEST (disjoint)\n');
    fprintf('   test n=%d, prevalence %.1f%%, target sensitivity %.0f%%\n', ...
        R.nTest, 100*R.testPrevalence, 100*R.targetSensitivity);
    fprintf('  ==================================================================\n');
    b = R.baseline;
    fprintf('   BASELINE  %-34s Sens %5.1f%%  Spec %5.1f%%\n', ...
        b.name, 100*b.sensitivity, 100*b.specificity);
    fprintf('  ------------------------------------------------------------------\n');
    fprintf('   calibration images   Sens (mean +/- sd)      Spec\n');
    for k = 1:numel(R.sizes)
        fprintf('   %6d               %5.1f%% +/- %4.1f          %5.1f%%\n', ...
            R.sizes(k), 100*R.sensMean(k), 100*R.sensStd(k), 100*R.specMean(k));
    end
    fprintf('  ==================================================================\n');
end
