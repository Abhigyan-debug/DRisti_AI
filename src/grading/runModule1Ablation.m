function R = runModule1Ablation(opts)
%RUNMODULE1ABLATION  Does the quality gate improve grading? Measured.
%
%   R = RUNMODULE1ABLATION() compares two systems on the APTOS validation
%   split, changing exactly one thing:
%
%     BASELINE    grader alone - every image gets a grade, including images a
%                 clinician would call ungradable
%     INTEGRATED  Module 1 gate first - ungradable images are routed to
%                 recapture instead of being graded
%
%   This is the README's "integrated pipeline must outperform single-technique
%   baselines" claim, reduced to the version we can actually measure today.
%
%   WHY GATING AND NOT ENHANCEMENT
%   ------------------------------
%   Feeding ENHANCED images to this grader would confound the comparison: it
%   was trained on unenhanced images, so any drop could be distribution shift
%   rather than enhancement being harmful. Testing that fairly needs a grader
%   retrained on enhanced input, which is a separate experiment.
%
%   Gating has no such problem. The images that reach the grader are identical
%   in both arms; the only difference is which images reach it at all.
%
%   HOW THE COMPARISON IS SCORED
%   ----------------------------
%   Reporting grading metrics only on images that survived the gate would be
%   rigged - throwing away hard cases always flatters an average. Two honest
%   framings are reported instead:
%
%     (a) ON THE SAME IMAGES. Restrict BOTH arms to gate-passed images. This
%         isolates whether the gate removes images the grader gets wrong.
%     (b) WHOLE COHORT, gate-rejected counted as REFERRALS. This is the
%         deployed system: a rejected image becomes a recapture/referral, not
%         a missed diagnosis. Nobody is discarded.
%
%   (b) is the one to quote. It charges the system for every patient.
%
%   See also PROCESSIMAGE, EVALUATEGRADER.

    arguments
        opts.modelFile (1,:) char = ''
        opts.limit (1,1) double = Inf
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    if isempty(opts.modelFile)
        opts.modelFile = fullfile(cfg.modelsDir, 'baseline_grader.mat');
    end
    S = load(opts.modelFile);
    net = S.trainedNet;
    inputSize3 = S.meta.inputSize;

    V = load(fullfile(cfg.resultsDir, 'phase3_val_result.mat'));
    thr = V.R.thresholds.highSensitivity;

    [~, valT] = loadAptosSplit();
    n = min(height(valT), opts.limit);
    cacheDir = fullfile(cfg.dataRoot, '_cache', sprintf('aptos_%d', inputSize3(1)));

    % ---- grade every image (baseline arm) --------------------------------
    fprintf('  grading %d images...\n', n);
    scores = nan(n,1);
    for i = 1:32:n
        j = min(i+31, n);
        X = zeros([inputSize3(1:2) 3 j-i+1], 'single');
        for k = i:j
            im = im2single(imread(fullfile(cacheDir, char(valT.imageName(k) + ".png"))));
            if size(im,3)==1, im = repmat(im,1,1,3); end
            X(:,:,:,k-i+1) = im;
        end
        Y = predict(net, dlarray(X,'SSCB'));
        P = double(gather(extractdata(Y)))';
        scores(i:j) = sum(P(:,3:end), 2);
    end

    % ---- run Module 1 on the ORIGINAL images ------------------------------
    % The gate must see the full-resolution original, not the 640px cache -
    % its sharpness and noise measures are meaningless on an already-resized
    % image.
    fprintf('  running Module 1 gate on originals...\n');
    gatePass = false(n,1);
    gateReason = strings(n,1);
    paths = valT.imagePath(1:n);
    origDir = cfg.aptos.trainImages;
    names = valT.imageName(1:n);

    parfor k = 1:n
        p = fullfile(origDir, char(names(k) + ".png")); %#ok<PFBNS>
        try
            r = processImage(imread(p));
            gatePass(k) = r.gradable;
            if ~r.gradable && ~isempty(r.reasons)
                isRej = strcmp({r.reasons.severity}, 'reject');
                if any(isRej)
                    f = r.reasons(find(isRej,1));
                    gateReason(k) = string(f.code);
                end
            end
        catch
            gatePass(k) = true;   % a gate failure must not silently drop a patient
            gateReason(k) = "gate_error";
        end
    end

    truth = valT.diagnosis(1:n) >= 2;

    % ---- (a) same images, both arms ---------------------------------------
    sub = gatePass & ~isnan(scores);
    R.onGatedSubset = struct( ...
        'n', nnz(sub), ...
        'baseline', opPoint(truth(sub), scores(sub), thr), ...
        'note', 'both arms restricted to gate-passed images');
    R.onAllImages = struct( ...
        'n', nnz(~isnan(scores)), ...
        'baseline', opPoint(truth(~isnan(scores)), scores(~isnan(scores)), thr));

    % ---- (b) whole cohort, rejected = referral ---------------------------
    integratedScore = scores;
    integratedScore(~gatePass) = 1;      % forced referral, never a missed case
    okAll = ~isnan(integratedScore);
    R.integratedWholeCohort = opPoint(truth(okAll), integratedScore(okAll), thr);
    R.baselineWholeCohort   = R.onAllImages.baseline;

    R.n = n;
    R.nRejected = nnz(~gatePass);
    R.rejectRate = mean(~gatePass);
    R.gateReasons = gateReason(~gatePass);
    R.threshold = thr;

    % Which images does the gate remove - ones the grader was getting wrong?
    wrongBaseline = (scores >= thr) ~= truth;
    R.errorRateAmongRejected = mean(wrongBaseline(~gatePass & ~isnan(scores)));
    R.errorRateAmongPassed   = mean(wrongBaseline(gatePass & ~isnan(scores)));

    if opts.verbose, printAblation(R); end

    save(fullfile(cfg.resultsDir, 'module1_ablation.mat'), 'R');
end


function o = opPoint(truth, score, thr)
    truth = logical(truth(:)); score = score(:);
    pred = score >= thr;
    tp = nnz(pred & truth); fn = nnz(~pred & truth);
    tn = nnz(~pred & ~truth); fp = nnz(pred & ~truth);
    o.sensitivity = tp/max(tp+fn,1);
    o.specificity = tn/max(tn+fp,1);
    o.tp = tp; o.fp = fp; o.tn = tn; o.fn = fn;
    if numel(unique(truth)) > 1
        [~,~,~,o.auc] = perfcurve(truth, score, true);
    else
        o.auc = NaN;
    end
end


function printAblation(R)
    fprintf('\n  ==================================================================\n');
    fprintf('   MODULE 1 ABLATION - does the quality gate earn its place?\n');
    fprintf('   APTOS validation split, n=%d\n', R.n);
    fprintf('  ==================================================================\n');
    fprintf('   gate rejected %d images (%.1f%%)\n', R.nRejected, 100*R.rejectRate);
    if ~isempty(R.gateReasons)
        u = unique(R.gateReasons);
        fprintf('     reasons: ');
        for k = 1:numel(u)
            fprintf('%s(%d) ', u(k), nnz(R.gateReasons==u(k)));
        end
        fprintf('\n');
    end
    fprintf('\n   Baseline grader error rate on images the gate KEPT   : %.1f%%\n', ...
        100*R.errorRateAmongPassed);
    fprintf('   Baseline grader error rate on images the gate REMOVED: %.1f%%\n', ...
        100*R.errorRateAmongRejected);
    if R.errorRateAmongRejected > R.errorRateAmongPassed
        fprintf('   -> the gate is removing images the grader gets wrong more often.\n');
    else
        fprintf('   -> the gate is NOT preferentially removing hard cases.\n');
    end

    fprintf('\n   WHOLE COHORT (rejected counted as referrals - the deployed system)\n');
    b = R.baselineWholeCohort; i = R.integratedWholeCohort;
    fprintf('     %-28s Sens %5.1f%%  Spec %5.1f%%\n', 'baseline (grader alone)', ...
        100*b.sensitivity, 100*b.specificity);
    fprintf('     %-28s Sens %5.1f%%  Spec %5.1f%%\n', 'integrated (gate + grader)', ...
        100*i.sensitivity, 100*i.specificity);
    fprintf('     delta                        %+5.1f pp    %+5.1f pp\n', ...
        100*(i.sensitivity-b.sensitivity), 100*(i.specificity-b.specificity));
    fprintf('  ==================================================================\n');
end
