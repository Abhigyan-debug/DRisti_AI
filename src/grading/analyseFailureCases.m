function R = analyseFailureCases(opts)
%ANALYSEFAILURECASES  Where does the system fail, and on which patients?
%
%   R = ANALYSEFAILURECASES() characterises the failure modes of the integrated
%   pipeline using ONLY results already on disk. Phase 6 deliverable
%   ("document failure cases ... for transparency").
%
%   ⚠️ THIS PERFORMS NO INFERENCE AND RE-READS NO IMAGES.
%   Project rule 1: "Messidor-2 is touched exactly ONCE". That read happened
%   on 2026-09-12 and is recorded in results/messidor2_external_validation.mat,
%   which stores the per-image scores and truth labels. Analysing that saved
%   table is not a second touch - nothing is re-scored, no threshold moves, and
%   no decision here can feed back into the model. Re-running the pipeline over
%   the Messidor-2 images to "look more closely" WOULD be a second touch, and
%   is exactly what this function exists to avoid.
%
%   THREE FAILURE MODES ARE SEPARATED
%   ---------------------------------
%     1. Domain shift        the score distribution shifts under a new camera,
%                            so a threshold frozen elsewhere lands in the wrong
%                            place. Measured on Messidor-2.
%     2. Severity blindness  which TRUE grades get missed. A system that misses
%                            grade 2 but catches grade 4 fails differently from
%                            one that misses uniformly, and they need different
%                            fixes.
%     3. Gate misdirection   whether the quality gate rejects the images the
%                            grader actually struggles with. Measured on APTOS.
%
%   See also EVALUATEMESSIDOR2, RUNMODULE1ABLATION, FITSITECALIBRATION.

    arguments
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    R = struct();

    % ---- 1. domain shift + severity blindness (saved Messidor-2 read) ------
    mf = fullfile(cfg.resultsDir, 'messidor2_external_validation.mat');
    if ~isfile(mf)
        error('drishti:noMessidorResult', ...
            ['results/messidor2_external_validation.mat not found. Do NOT ' ...
             'regenerate it by re-running the holdout - recover the file.']);
    end
    M = load(mf); T = M.R.perImage;
    thr = M.R.thresholds.highSensitivity;

    scored = T(~T.ungradable, :);
    pred = scored.referableScore >= thr;
    truth = scored.truthPrimary;

    R.messidor2 = struct();
    R.messidor2.n = height(scored);
    R.messidor2.threshold = thr;
    R.messidor2.nUngradable = nnz(T.ungradable);
    R.messidor2.falseNegatives = nnz(~pred & truth);
    R.messidor2.falsePositives = nnz(pred & ~truth);
    R.messidor2.truePositives  = nnz(pred & truth);

    % Score separation: the model still RANKS well (AUC 0.885) while the frozen
    % threshold sits far above the referable score mass. That distinction is the
    % whole diagnosis - a ranking problem and a calibration problem need
    % opposite fixes, and this is the latter.
    R.messidor2.medianScoreReferable    = median(scored.referableScore(truth));
    R.messidor2.medianScoreNonReferable = median(scored.referableScore(~truth));
    R.messidor2.thresholdOverReferableMedian = thr / max(R.messidor2.medianScoreReferable, eps);
    R.messidor2.pctReferableBelowThreshold = 100 * mean(scored.referableScore(truth) < thr);

    % Severity blindness: miss rate by TRUE DR grade.
    grades = unique(scored.drGrade(~isnan(scored.drGrade)));
    byGrade = table();
    for g = grades'
        sel = scored.drGrade == g;
        if ~any(sel), continue; end
        isRef = truth(sel);
        missed = ~pred(sel) & isRef;
        byGrade = [byGrade; table(g, nnz(sel), nnz(isRef), nnz(missed), ...
            100*nnz(missed)/max(nnz(isRef),1), median(scored.referableScore(sel)), ...
            'VariableNames', {'trueDrGrade','n','nReferable','nMissed','missRatePct','medianScore'})]; %#ok<AGROW>
    end
    R.messidor2.byTrueGrade = byGrade;

    % ---- 2. gate misdirection (saved APTOS ablation) ----------------------
    af = fullfile(cfg.resultsDir, 'module1_ablation.mat');
    R.gate = struct('available', false);
    if isfile(af)
        A = load(af); G = A.R;
        R.gate = struct( ...
            'available', true, ...
            'n', G.n, 'nRejected', G.nRejected, 'rejectRate', G.rejectRate, ...
            'errorRateAmongRejected', G.errorRateAmongRejected, ...
            'errorRateAmongPassed',   G.errorRateAmongPassed, ...
            'integrated', G.integratedWholeCohort, ...
            'baseline',   G.baselineWholeCohort);
        % If the gate were selecting images the grader cannot handle, error
        % among rejected would EXCEED error among passed. Measured, it is lower.
        R.gate.selectsHardImages = G.errorRateAmongRejected > G.errorRateAmongPassed;
        R.gate.sensitivityDelta = G.integratedWholeCohort.sensitivity - G.baselineWholeCohort.sensitivity;
        R.gate.specificityDelta = G.integratedWholeCohort.specificity - G.baselineWholeCohort.specificity;
    end

    if opts.verbose, printReport(R); end
end


function printReport(R)
    m = R.messidor2;
    fprintf('\n  ===== FAILURE-CASE ANALYSIS (saved results; no re-inference) =====\n');
    fprintf('\n  [1] DOMAIN SHIFT - Messidor-2, n=%d scored (%d ungradable)\n', m.n, m.nUngradable);
    fprintf('      frozen threshold                  %.4f\n', m.threshold);
    fprintf('      median score, REFERABLE cases     %.4f\n', m.medianScoreReferable);
    fprintf('      median score, non-referable       %.4f\n', m.medianScoreNonReferable);
    fprintf('      threshold sits %.1fx ABOVE the median referable case\n', ...
        m.thresholdOverReferableMedian);
    fprintf('      %.1f%% of referable cases score below the threshold\n', ...
        m.pctReferableBelowThreshold);
    fprintf('      => the model RANKS (AUC 0.885) but the threshold is in the\n');
    fprintf('         wrong place. That is a calibration failure, not a ranking\n');
    fprintf('         failure, and per-site calibration is its fix.\n');

    fprintf('\n  [2] SEVERITY BLINDNESS - miss rate by TRUE DR grade\n');
    fprintf('      grade    n    referable   missed   miss%%   median score\n');
    for i = 1:height(m.byTrueGrade)
        r = m.byTrueGrade(i,:);
        fprintf('        %d   %4d      %4d     %4d   %5.1f    %.4f\n', ...
            r.trueDrGrade, r.n, r.nReferable, r.nMissed, r.missRatePct, r.medianScore);
    end

    if R.gate.available
        g = R.gate;
        fprintf('\n  [3] GATE MISDIRECTION - APTOS val, n=%d\n', g.n);
        fprintf('      gate rejected %d images (%.1f%%)\n', g.nRejected, 100*g.rejectRate);
        fprintf('      grader error among REJECTED images  %.2f%%\n', 100*g.errorRateAmongRejected);
        fprintf('      grader error among PASSED images    %.2f%%\n', 100*g.errorRateAmongPassed);
        if g.selectsHardImages
            fprintf('      => the gate is selecting images the grader struggles with.\n');
        else
            fprintf('      => the gate rejects images the grader handles BETTER than\n');
            fprintf('         average. It is not selecting for grader difficulty.\n');
        end
        fprintf('      integrated vs baseline: sensitivity %+.2f pp, specificity %+.2f pp\n', ...
            100*g.sensitivityDelta, 100*g.specificityDelta);
    end
    fprintf('\n  =================================================================\n');
end
