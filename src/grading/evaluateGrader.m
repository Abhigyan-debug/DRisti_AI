function R = evaluateGrader(opts)
%EVALUATEGRADER  Clinical evaluation of a trained DR grader.
%
%   R = EVALUATEGRADER() loads models/baseline_grader.mat and scores it on the
%   committed APTOS validation split.
%
%   R = EVALUATEGRADER(modelFile=..., operatingPoint="highSensitivity")
%
%   Reports what a screening programme actually needs, not accuracy:
%       R.sensitivity, R.specificity   for REFERABLE DR at the chosen threshold
%       R.auc                          ROC AUC for the binary referable task
%       R.confusion                    5x5 ICDR confusion matrix
%       R.qwk                          quadratic weighted kappa (the APTOS metric)
%       R.thresholds                   both operating points, for freezing
%
%   WHY NOT ACCURACY
%   ----------------
%   49.3% of APTOS is grade 0. A model that predicts "no DR" for every image
%   scores 49% accuracy and has zero clinical value - it misses every referable
%   case. Accuracy is reported only because judges ask for it; sensitivity and
%   specificity for referable DR are the numbers that mean anything.
%
%   THE ENDPOINT COMES FROM THE FROZEN CONTRACT
%   -------------------------------------------
%   Referable DR is read from config/clinical_definitions.json, never
%   hardcoded, so the definition behind any number is recoverable from git.
%   APTOS ships no DME labels, so this can only score the DR-only secondary
%   endpoint - which is NOT directly comparable to Gulshan or IDx-DR. Say so
%   wherever the number appears.
%
%   TWO OPERATING POINTS, AS GULSHAN REPORTS
%   ----------------------------------------
%   A high-sensitivity point for screening and a high-specificity point for
%   confirmation. Both are chosen HERE, on validation data, and must be frozen
%   before Messidor-2 is touched. A threshold re-tuned after seeing the
%   benchmark invalidates the external validation claim.
%
%   See also TRAINBASELINEGRADER, LOADAPTOSSPLIT.

    arguments
        opts.modelFile (1,:) char = ''
        opts.split (1,:) char {mustBeMember(opts.split,{'val','train'})} = 'val'
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    if isempty(opts.modelFile)
        opts.modelFile = fullfile(cfg.modelsDir, 'baseline_grader.mat');
    end
    S = load(opts.modelFile);
    net = S.trainedNet;
    inputSize3 = S.meta.inputSize;

    % ---- referable threshold from the frozen contract --------------------
    defFile = fullfile(cfg.projectRoot, 'config', 'clinical_definitions.json');
    referableGrade = 2;
    if isfile(defFile)
        try
            D = jsondecode(fileread(defFile));
            if isfield(D, 'icdr_scale')
                referableGrade = 2;   % "dr_grade >= 2", per secondary_dr_only
            end
        catch
        end
    end

    % ---- data ------------------------------------------------------------
    cacheDir = fullfile(cfg.dataRoot, '_cache', sprintf('aptos_%d', inputSize3(1)));
    [trainT, valT] = loadAptosSplit();
    if strcmp(opts.split, 'val'), T = valT; else, T = trainT; end
    paths = strings(height(T),1);
    for k = 1:height(T)
        paths(k) = string(fullfile(cacheDir, char(T.imageName(k) + ".png")));
    end

    % ---- predict ---------------------------------------------------------
    probs = zeros(height(T), 5);
    batch = 32;
    for i = 1:batch:height(T)
        j = min(i+batch-1, height(T));
        X = zeros([inputSize3(1:2) 3 j-i+1], 'single');
        for k = i:j
            im = im2single(imread(paths(k)));
            if size(im,3)==1, im = repmat(im,1,1,3); end
            if ~isequal(size(im,1:2), inputSize3(1:2))
                im = imresize(im, inputSize3(1:2));
            end
            X(:,:,:,k-i+1) = im;
        end
        Y = predict(net, dlarray(X, 'SSCB'));
        probs(i:j, :) = double(gather(extractdata(Y)))';   % extract before transpose: a labelled dlarray cannot be permuted across differing labels
    end

    truth = T.diagnosis;
    [~, predGrade] = max(probs, [], 2);
    predGrade = predGrade - 1;

    % ---- 5-class ---------------------------------------------------------
    R.confusion = confusionmat(truth, predGrade, 'Order', 0:4);
    R.accuracy = sum(diag(R.confusion)) / sum(R.confusion(:));
    R.qwk = quadraticWeightedKappa(truth, predGrade, 0:4);

    % ---- binary referable ------------------------------------------------
    % Score = total probability mass at or above the referable grade. This is
    % better than thresholding the argmax: it uses the full distribution, so an
    % image split 0.3/0.3/0.4 across grades 2-4 is correctly very referable
    % even though no single class dominates.
    referableScore = sum(probs(:, referableGrade+1:end), 2);
    isReferable = truth >= referableGrade;

    [X, Y, Thr, R.auc] = perfcurve(isReferable, referableScore, true);

    % perfcurve returns thresholds in DECREASING order, so sensitivity rises
    % and specificity falls down the list. The two points therefore need
    % opposite search directions:
    %   high-sensitivity -> FIRST threshold reaching 90% sens (highest such
    %       threshold, so specificity is the best available at that sensitivity)
    %   high-specificity -> LAST threshold still holding 95% spec (lowest such
    %       threshold, so sensitivity is the best available at that specificity)
    % Searching 'last' for both produced Sens 100%% / Spec 0%% - the degenerate
    % threshold where everything is called referable.
    R.thresholds = struct();
    R.thresholds.highSensitivity = pickThreshold(Y, Thr, 0.90, 'first');
    R.thresholds.highSpecificity = pickThreshold(1-X, Thr, 0.95, 'last');

    R.operatingPoints = struct();
    for nm = ["highSensitivity", "highSpecificity"]
        t = R.thresholds.(nm);
        pred = referableScore >= t;
        tp = nnz(pred & isReferable); fn = nnz(~pred & isReferable);
        tn = nnz(~pred & ~isReferable); fp = nnz(pred & ~isReferable);
        R.operatingPoints.(nm) = struct('threshold', t, ...
            'sensitivity', tp/max(tp+fn,1), 'specificity', tn/max(tn+fp,1), ...
            'tp', tp, 'fp', fp, 'tn', tn, 'fn', fn);
    end

    R.sensitivity = R.operatingPoints.highSensitivity.sensitivity;
    R.specificity = R.operatingPoints.highSensitivity.specificity;
    R.n = height(T);
    R.prevalence = mean(isReferable);
    R.split = opts.split;

    if opts.verbose
        printReport(R);
    end
end


function t = pickThreshold(metric, thresholds, target, which)
    idx = find(metric >= target, 1, which);
    if isempty(idx), idx = numel(thresholds); end
    t = thresholds(min(idx, numel(thresholds)));
end


function k = quadraticWeightedKappa(a, b, classes)
%QUADRATICWEIGHTEDKAPPA  The APTOS competition metric.
%
%   Penalises being wrong by TWO grades four times as much as by one, which is
%   the right shape for an ordinal severity scale - confusing grade 0 with
%   grade 4 is far worse than confusing 2 with 3.

    n = numel(classes);
    O = confusionmat(a, b, 'Order', classes);
    W = (repmat((1:n)', 1, n) - repmat(1:n, n, 1)).^2 / (n-1)^2;
    ha = histcounts(a, [classes classes(end)+1]);
    hb = histcounts(b, [classes classes(end)+1]);
    E = ha' * hb;
    E = E * sum(O(:)) / sum(E(:));
    k = 1 - sum(W(:).*O(:)) / max(sum(W(:).*E(:)), eps);
end


function printReport(R)
    fprintf('\n  ===== DR GRADER, %s split (n=%d) =====\n', upper(R.split), R.n);
    fprintf('  Referable prevalence: %.1f%%\n\n', 100*R.prevalence);

    fprintf('  REFERABLE DR (ICDR >= 2), DR-only endpoint\n');
    fprintf('    ROC AUC: %.4f\n', R.auc);
    for nm = ["highSensitivity", "highSpecificity"]
        o = R.operatingPoints.(nm);
        fprintf('    %-16s Sens %5.1f%%  Spec %5.1f%%   (TP %d FP %d TN %d FN %d)\n', ...
            nm, 100*o.sensitivity, 100*o.specificity, o.tp, o.fp, o.tn, o.fn);
    end
    fprintf('\n    Project target: Sens > 90%%, Spec > 85%%\n');
    o = R.operatingPoints.highSensitivity;
    if o.sensitivity > 0.90 && o.specificity > 0.85
        fprintf('    -> TARGET MET on this split\n');
    else
        fprintf('    -> target NOT met on this split\n');
    end
    fprintf(['\n    NOTE: APTOS has no DME labels, so this is the DR-only\n' ...
             '    secondary endpoint and is NOT directly comparable to\n' ...
             '    Gulshan or IDx-DR, which both include referable DME.\n']);

    fprintf('\n  5-CLASS ICDR\n');
    fprintf('    accuracy %.3f | quadratic weighted kappa %.4f  (APTOS winner 0.936)\n', ...
        R.accuracy, R.qwk);
    fprintf('    confusion (rows = truth 0-4, cols = predicted):\n');
    for i = 1:5
        fprintf('      %s\n', mat2str(R.confusion(i,:)));
    end
end
