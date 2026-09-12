function A = buildSiteCalibration(opts)
%BUILDSITECALIBRATION  Fit, evaluate and SAVE a deployable site-calibration artifact.
%
%   A = BUILDSITECALIBRATION() fits the per-site operating point on the IDRiD
%   grading TRAIN split, evaluates it on the IDRiD TEST split, and writes
%   models/site_calibration.mat for the pipeline to load at runtime.
%
%   A = BUILDSITECALIBRATION(targetSensitivity=0.90, site='PHC Mathura-01')
%   A = BUILDSITECALIBRATION(outFile='models/site_calibration_mathura.mat')
%
%   WHAT FITSITECALIBRATION FITS, AND WHAT IT NEEDS
%   -----------------------------------------------
%   FITSITECALIBRATION fits TWO things from one labelled sample drawn from the
%   target camera, and needs nothing else:
%
%     INPUT   scores  - the grader's raw referable score per image, i.e. the
%                       probability mass at ICDR grade >= 2 (EXPLAINGRADING's
%                       E.referableScore). NOT a calibrated probability.
%             truth   - logical referable label per image, resolved through
%                       config/clinical_definitions.json (never a raw integer).
%             Both classes must be present or it errors; >= 50 images or it
%             returns a noise warning in S.warning.
%
%     FITS    a, b            - a Platt map (logistic on the raw score) fitted
%                               with smoothed targets, so near-separable
%                               scores do not run the fit off to +/-inf. This
%                               only changes the number SHOWN as a confidence.
%             threshold       - the cut on the Platt-calibrated scale.
%             thresholdRaw    - the equivalent cut on the RAW score scale.
%                               THIS is what decides refer / no-refer, because
%                               RUNDRISHTIPIPELINE compares E.referableScore
%                               against it directly.
%
%     PICKS   the lowest threshold reaching `targetSensitivity` on the
%             calibration sample, and reports the specificity that came with
%             it. Sensitivity is the target; specificity is the price, and
%             both are recorded - neither is optimised alone.
%
%   WHY THE SCORE MUST BE THE RAW ONE
%   ---------------------------------
%   EVALUATEIDRIDTRANSFER returns both `rawScores` and `scores`; they differ
%   only when an APTOS calibrator was passed in. This function fits on
%   `rawScores` explicitly. Fitting on a Platt-mapped score and then handing
%   `thresholdRaw` to a pipeline that compares raw scores would be a silent
%   scale mismatch - the same class of train/serve defect that cost the
%   dark-lesion detectors a rebuild.
%
%   THE HELD-OUT BENCHMARK IS NOT INVOLVED, BY CONSTRUCTION
%   -------------------------------------------------------
%   Messidor-2 is SPENT - read once, on 2026-09-12. It is not read here, not
%   fitted on here, and not consulted to choose anything here. The calibration
%   set is IDRiD TRAIN and the evaluation set is IDRiD TEST; they are disjoint
%   by construction, and IDRiD carries no holdout status, so it can be used
%   repeatedly to develop and verify a fix.
%
%   A number measured here is evidence about IDRiD's camera. It is NOT a
%   Messidor-2 result and must never be quoted as one.
%
%   A CALIBRATION IS SITE-SPECIFIC - THAT IS THE WHOLE POINT
%   --------------------------------------------------------
%   The artifact records the site it was fitted for. Loading an IDRiD-fitted
%   calibration and screening a different camera with it is not "calibrated",
%   it is miscalibrated with extra confidence. LOADSITECALIBRATION surfaces
%   the site label so the operator can see which camera the operating point
%   belongs to, and the dashboard prints it beside the result.
%
%   See also FITSITECALIBRATION, LOADSITECALIBRATION, EVALUATEIDRIDTRANSFER,
%   RUNSITECALIBRATIONSTUDY.

    arguments
        opts.site (1,:) char = 'IDRiD (Aravind Eye Hospital, Kowa VX-10alpha)'
        opts.targetSensitivity (1,1) double {mustBeInRange(opts.targetSensitivity,0.5,1)} = 0.90
        opts.modelFile (1,:) char = ''
        opts.outFile (1,:) char = ''
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    if isempty(opts.outFile)
        opts.outFile = fullfile(cfg.modelsDir, 'site_calibration.mat');
    end

    % ---- 1. score both IDRiD splits --------------------------------------
    % Fresh inference, not the cached results/idrid_transfer_raw.mat: the
    % artifact records which grader it belongs to, so it must be fitted on
    % that grader's actual scores rather than on whatever a stale cache holds.
    if opts.verbose
        fprintf('\n  1/4  scoring IDRiD TRAIN (the calibration set)\n');
    end
    Tr = evaluateIdridTransfer('split', 'train', 'modelFile', opts.modelFile, ...
        'verbose', false);
    if opts.verbose
        fprintf('  2/4  scoring IDRiD TEST (evaluation, disjoint from the fit)\n');
    end
    Te = evaluateIdridTransfer('split', 'test', 'modelFile', opts.modelFile, ...
        'verbose', false);

    [trScores, trTruth] = cleanPair(Tr.rawScores, Tr.truth);
    [teScores, teTruth] = cleanPair(Te.rawScores, Te.truth);

    % ---- 2. fit on TRAIN only --------------------------------------------
    if opts.verbose
        fprintf('  3/4  fitting the operating point on %d calibration images\n', ...
            numel(trScores));
    end
    S = fitSiteCalibration(trScores, trTruth, ...
        'targetSensitivity', opts.targetSensitivity);

    % ---- 3. evaluate on TEST, which the fit never saw --------------------
    % Both sensitivity AND specificity, and the uncalibrated baseline beside
    % them. A sensitivity quoted without the specificity it cost is not a
    % result, it is an advertisement.
    if opts.verbose
        fprintf('  4/4  evaluating on %d held-back images\n', numel(teScores));
    end
    V = load(fullfile(cfg.resultsDir, 'phase3_val_result.mat'));
    shippedThr = V.R.thresholds.highSensitivity;

    calEval  = sensSpec(teScores >= S.thresholdRaw, teTruth);
    baseEval = sensSpec(teScores >= shippedThr,     teTruth);

    % ---- 4. the artifact --------------------------------------------------
    A = struct();
    A.a = S.a;
    A.b = S.b;
    A.threshold = S.threshold;
    A.thresholdRaw = S.thresholdRaw;
    A.n = S.n;
    A.nPositive = S.nPositive;
    A.targetSensitivity = S.targetSensitivity;
    A.calibrationSensitivity = S.calibrationSensitivity;
    A.calibrationSpecificity = S.calibrationSpecificity;
    A.warning = S.warning;

    A.meta = struct();
    A.meta.artifactVersion = 'siteCalibration/v1';
    A.meta.site = opts.site;
    A.meta.fittedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm'));
    A.meta.graderModel = graderName(opts.modelFile, cfg);
    A.meta.calibrationSet = sprintf('IDRiD grading TRAIN split, n=%d (%d referable)', ...
        S.n, S.nPositive);
    A.meta.evaluationSet = sprintf('IDRiD grading TEST split, n=%d (%d referable)', ...
        numel(teTruth), nnz(teTruth));
    % Disjointness is not an assertion to record, it is a fact to check. IDRiD's
    % TRAIN and TEST splits are separate directory-backed sets, so they are
    % disjoint by construction - but "by construction" stops being true the
    % moment someone changes which splits are used, and `disjoint: true` frozen
    % into a saved artifact is exactly the kind of claim nobody goes back to
    % re-read. It would then be quoted as held-back performance forever.
    if strcmp(Tr.split, Te.split)
        error('drishti:calibrationNotDisjoint', ...
            ['Calibration and evaluation are both the "%s" split. The ' ...
             'evaluation figures would be fitting performance while the ' ...
             'artifact recorded them as held-back. Refusing to write it.'], ...
            Tr.split);
    end
    A.meta.disjoint = true;
    A.meta.disjointBasis = sprintf(['fitted on IDRiD %s, evaluated on IDRiD %s - ' ...
        'separate directory-backed splits, checked at fit time, not assumed'], ...
        Tr.split, Te.split);
    A.meta.heldOutBenchmarkUsed = ['none - Messidor-2 was not read, fitted on, ' ...
        'or consulted to choose anything in this artifact'];
    A.meta.shippedThreshold = shippedThr;

    % Held-back performance. These are the numbers that may be quoted.
    A.evaluation = struct();
    A.evaluation.dataset = 'IDRiD grading TEST split';
    A.evaluation.n = numel(teTruth);
    A.evaluation.prevalence = mean(teTruth);
    A.evaluation.calibratedSensitivity = calEval.sens;
    A.evaluation.calibratedSpecificity = calEval.spec;
    A.evaluation.uncalibratedSensitivity = baseEval.sens;
    A.evaluation.uncalibratedSpecificity = baseEval.spec;

    if ~isfolder(cfg.modelsDir), mkdir(cfg.modelsDir); end
    save(opts.outFile, 'A');
    A.savedTo = opts.outFile;

    if opts.verbose, printArtifact(A, opts); end
end


% ------------------------------------------------------------------ helpers

function [s, t] = cleanPair(scores, truth)
    s = scores(:);
    t = logical(truth(:));
    ok = ~isnan(s);
    s = s(ok);
    t = t(ok);
end


function E = sensSpec(pred, truth)
    E.sens = nnz(pred & truth) / max(nnz(truth), 1);
    E.spec = nnz(~pred & ~truth) / max(nnz(~truth), 1);
end


function nm = graderName(modelFile, cfg)
    if isempty(modelFile)
        modelFile = fullfile(cfg.modelsDir, 'baseline_grader.mat');
    end
    [~, n, e] = fileparts(modelFile);
    nm = [n e];
end


function printArtifact(A, opts)
    fprintf('\n  ==================================================================\n');
    fprintf('   SITE CALIBRATION ARTIFACT\n');
    fprintf('   site  : %s\n', A.meta.site);
    fprintf('   fit   : %s\n', A.meta.calibrationSet);
    fprintf('   eval  : %s  (disjoint)\n', A.meta.evaluationSet);
    fprintf('   grader: %s\n', A.meta.graderModel);
    fprintf('  ==================================================================\n');
    fprintf('   target sensitivity            %5.1f%%\n', 100*A.targetSensitivity);
    fprintf('   threshold (raw score scale)   %.6f\n', A.thresholdRaw);
    fprintf('  ------------------------------------------------------------------\n');
    fprintf('   ON THE CALIBRATION SET (optimistic - the fit saw these)\n');
    fprintf('     sensitivity %5.1f%%   specificity %5.1f%%\n', ...
        100*A.calibrationSensitivity, 100*A.calibrationSpecificity);
    fprintf('  ------------------------------------------------------------------\n');
    fprintf('   ON THE HELD-BACK SET (n=%d, prevalence %.1f%%) - QUOTE THESE\n', ...
        A.evaluation.n, 100*A.evaluation.prevalence);
    fprintf('     uncalibrated   sensitivity %5.1f%%   specificity %5.1f%%\n', ...
        100*A.evaluation.uncalibratedSensitivity, ...
        100*A.evaluation.uncalibratedSpecificity);
    fprintf('     site-calibrated sensitivity %5.1f%%  specificity %5.1f%%\n', ...
        100*A.evaluation.calibratedSensitivity, ...
        100*A.evaluation.calibratedSpecificity);
    fprintf('  ==================================================================\n');
    if ~isempty(A.warning)
        fprintf('   WARNING: %s\n', A.warning);
    end
    fprintf(['   These are IDRiD numbers. They are NOT a Messidor-2 result and\n' ...
             '   must not be quoted as one. Messidor-2 stays at 31.2%% sensitivity\n' ...
             '   uncalibrated; nothing here re-measures it.\n']);
    fprintf('   saved -> %s\n\n', opts.outFile);
end
