function R = evaluateMessidor2(opts)
%EVALUATEMESSIDOR2  External validation on the held-out benchmark. RUN ONCE.
%
%   R = EVALUATEMESSIDOR2() scores the frozen grader against the Krause et al.
%   adjudicated reference standard for Messidor-2.
%
%   ⚠️  THIS IS THE HELD-OUT SET. Running it is spending it - AND IT IS ALREADY
%   SPENT. It was read once on 2026-09-12: Sens 31.2%, Spec 99.5%, AUC 0.8848.
%   This function now refuses to run while results/messidor2_external_validation.mat
%   exists. Analyse that run with ANALYSEFAILURECASES, which reads the saved
%   per-image scores and performs no inference.
%
%   The operating-point thresholds MUST already be frozen (they are chosen in
%   evaluateGrader on the APTOS validation split and written to
%   results/phase3_val_result.mat). This function refuses to run without them,
%   and it never selects a threshold of its own. A threshold tuned after seeing
%   this set would invalidate the external-validation claim entirely - the
%   result would be indistinguishable from a tuned-on-test number, which is
%   exactly what most published DR results cannot rule out.
%
%   Why this set specifically
%   -------------------------
%   These are the same 1748 images (874 patients) Gulshan et al. validated on
%   in JAMA 2016, so the comparison is direct rather than approximate. Their
%   reference standard was a majority vote of >= 7 ophthalmologists; ours is
%   Krause et al.'s adjudicated standard (3 retina specialists to consensus),
%   which is the stricter of the two and yields a HIGHER referable prevalence
%   (26.7% vs their 14.6%). Different reference standard, same images - state
%   that when comparing.
%
%   Three endpoints are reported, per config/clinical_definitions.json:
%     primary_referable     DR >= 2 OR referable DME   <- the headline
%     secondary_dr_only     DR >= 2                    <- comparable to APTOS
%     referral_or_recapture referable OR ungradable    <- the deployed system
%
%   DME encoding is resolved through the contract's per-dataset map, NOT by
%   comparing a raw integer. Messidor-2 encodes referable DME as 1; IDRiD
%   encodes it as 2. Assuming one scale covers both was blocker B12.
%
%   See also EVALUATEGRADER, LOADAPTOSSPLIT.

    arguments
        opts.modelFile (1,:) char = ''
        opts.confirm (1,1) logical = false
        opts.limit (1,1) double = Inf
        % Deliberately long and unpleasant to type. It should be impossible to
        % pass this by habit or by copying a command from a chat log.
        opts.rerunAfterRetraining (1,1) logical = false
    end

    cfg = drishti_paths();

    if ~opts.confirm
        error('drishti:heldOutGuard', ...
            ['Messidor-2 is the held-out benchmark and is evaluated ONCE.\n' ...
             'Confirm deliberately:  evaluateMessidor2(''confirm'', true)']);
    end

    % ---- the shot is already spent ---------------------------------------
    % The confirm flag above was written BEFORE the one shot was taken, when it
    % still meant "are you sure you want to spend this?". It was spent on
    % 2026-09-12, so on its own that flag now means nothing: a second
    % confirm:true would quietly read the benchmark again and the
    % external-validation claim would stop being true with no error and no
    % failing test.
    %
    % A held-out set is not spent by intent, it is spent by ACCESS. So the
    % refusal is tied to evidence that the read already happened - the saved
    % result - rather than to anyone remembering that it did.
    spentFile = fullfile(cfg.resultsDir, 'messidor2_external_validation.mat');
    if isfile(spentFile) && ~opts.rerunAfterRetraining
        error('drishti:holdoutAlreadySpent', ...
            ['Messidor-2 has ALREADY been read (2026-09-12): Sens 31.2%%, ' ...
             'Spec 99.5%%, AUC 0.8848 at the frozen threshold.\n' ...
             'The result is in %s.\n\n' ...
             'Do not read it again. To analyse that run - failure modes, ' ...
             'per-grade misses, calibration demonstrations - use ' ...
             'analyseFailureCases, which reads the SAVED per-image scores and ' ...
             'performs no inference.\n\n' ...
             'Re-running is only defensible for a genuinely new model whose ' ...
             'thresholds were frozen without reference to this set, and it is ' ...
             'a second external validation, not a repeat of the first: report ' ...
             'both. If that is really what you are doing, pass ' ...
             '''rerunAfterRetraining'', true AND move the existing result ' ...
             'aside first, so the record of the first read is not overwritten.'], ...
            spentFile);
    end

    % ---- frozen thresholds, or refuse ------------------------------------
    frozenFile = fullfile(cfg.resultsDir, 'phase3_val_result.mat');
    if ~isfile(frozenFile)
        error('drishti:noFrozenThreshold', ...
            ['No frozen operating point found at %s.\n' ...
             'Run evaluateGrader on the validation split FIRST. This function ' ...
             'will not choose a threshold on the benchmark.'], frozenFile);
    end
    V = load(frozenFile);
    thrSens = V.R.thresholds.highSensitivity;
    thrSpec = V.R.thresholds.highSpecificity;

    % ---- model ------------------------------------------------------------
    if isempty(opts.modelFile)
        opts.modelFile = fullfile(cfg.modelsDir, 'baseline_grader.mat');
    end
    S = load(opts.modelFile);
    net = S.trainedNet;
    inputSize3 = S.meta.inputSize;

    % ---- contract ---------------------------------------------------------
    D = jsondecode(fileread(fullfile(cfg.projectRoot, 'config', 'clinical_definitions.json')));
    dmeRule = D.dme_encoding.per_dataset.messidor2.dme_referable;   % "value == 1"
    dmeReferableValue = sscanf(dmeRule, 'value == %d');
    if isempty(dmeReferableValue)
        error('drishti:badDmeRule', 'Could not parse Messidor-2 DME rule: %s', dmeRule);
    end

    % ---- labels -----------------------------------------------------------
    labelFile = fullfile(cfg.datasets.messidor2, 'messidor_data.csv');
    T = readtable(labelFile, 'TextType', 'string');

    imageId  = T.image_id;
    drGrade  = T.adjudicated_dr_grade;
    dmeGrade = T.adjudicated_dme;
    gradable = T.adjudicated_gradable;

    if ~isnumeric(drGrade),  drGrade  = str2double(drGrade);  end
    if ~isnumeric(dmeGrade), dmeGrade = str2double(dmeGrade); end
    if ~isnumeric(gradable), gradable = str2double(gradable); end

    n = min(numel(imageId), opts.limit);

    % ---- resolve files case-insensitively ---------------------------------
    % Messidor-2 is mixed-format: 1058 lowercase .png and 690 uppercase .JPG.
    % Matching on the CSV spelling alone silently drops 40% of the benchmark.
    imgDir = cfg.messidor2.images;
    listing = dir(fullfile(imgDir, '*'));
    listing = listing(~[listing.isdir]);
    onDisk = string({listing.name})';
    [~, stems] = arrayfun(@(f) fileparts(f), onDisk, 'UniformOutput', false);
    stemOnDisk = lower(string(stems));

    paths = strings(n, 1);
    for k = 1:n
        [~, stem] = fileparts(imageId(k));
        hit = find(stemOnDisk == lower(stem), 1);
        if ~isempty(hit)
            paths(k) = string(fullfile(imgDir, onDisk(hit)));
        end
    end
    missing = paths == "";
    if any(missing)
        warning('drishti:missingImages', '%d images not found on disk', nnz(missing));
    end

    % ---- inference --------------------------------------------------------
    fprintf('  running %d images through the frozen grader...\n', n);
    probs = nan(n, 5);
    t0 = tic;
    batch = 16;
    for i = 1:batch:n
        j = min(i + batch - 1, n);
        idx = i:j;
        idx = idx(~missing(idx));
        if isempty(idx), continue; end
        X = zeros([inputSize3(1:2) 3 numel(idx)], 'single');
        for m = 1:numel(idx)
            X(:,:,:,m) = im2single(prepFundusExt(imread(paths(idx(m))), inputSize3(1)));
        end
        Y = predict(net, dlarray(X, 'SSCB'));
        probs(idx, :) = double(gather(extractdata(Y)))';
        if mod(i-1, 320) == 0
            fprintf('    %d/%d  (%.1f min)\n', j, n, toc(t0)/60);
        end
    end
    fprintf('  inference done in %.1f min\n', toc(t0)/60);

    referableScore = sum(probs(:, 3:end), 2);

    % ---- endpoints --------------------------------------------------------
    isUngradable = gradable(1:n) == 0 | isnan(drGrade(1:n));
    okIdx = ~isUngradable & ~missing & ~isnan(referableScore);

    truthPrimary   = drGrade(1:n) >= 2 | dmeGrade(1:n) == dmeReferableValue;
    truthSecondary = drGrade(1:n) >= 2;

    R = struct();
    R.n_total = n;
    R.n_ungradable = nnz(isUngradable);
    R.n_scored = nnz(okIdx);
    R.model = S.meta;
    R.thresholds = struct('highSensitivity', thrSens, 'highSpecificity', thrSpec);
    R.dmeRule = dmeRule;
    R.contractVersion = D.x_version;

    R.primary   = scoreEndpoint(truthPrimary(okIdx),   referableScore(okIdx), thrSens, thrSpec);
    R.secondary = scoreEndpoint(truthSecondary(okIdx), referableScore(okIdx), thrSens, thrSpec);

    % referral_or_recapture: ungradable images count as positives, because the
    % deployed system sends them to a human too. Their score is irrelevant -
    % Module 1 would have rejected them before the grader ever ran.
    truthRR = truthPrimary | isUngradable;
    scoreRR = referableScore;
    scoreRR(isUngradable) = 1;       % forced referral
    rrIdx = ~missing & (~isnan(scoreRR));
    R.referralOrRecapture = scoreEndpoint(truthRR(rrIdx), scoreRR(rrIdx), thrSens, thrSpec);

    % Persist the raw per-image scores and truth vectors. Without these the
    % result is a printed summary that nobody can re-analyse, and any follow-up
    % question ("was it the model or the threshold?") needs the benchmark run
    % again. Saving them costs nothing and makes the run answer future
    % questions without being re-spent.
    R.perImage = table(imageId(1:n), paths, referableScore, drGrade(1:n), ...
        dmeGrade(1:n), gradable(1:n), truthPrimary, truthSecondary, isUngradable, ...
        'VariableNames', {'imageId','path','referableScore','drGrade','dmeGrade', ...
                          'gradable','truthPrimary','truthSecondary','ungradable'});

    printReport(R);

    out = fullfile(cfg.resultsDir, 'messidor2_external_validation.mat');
    save(out, 'R');
    fprintf('\n  saved -> results/messidor2_external_validation.mat\n');
end


% ------------------------------------------------------------------ helpers

function img = prepFundusExt(img, sz)
    if size(img,3) == 1, img = repmat(img,1,1,3); end
    gray = 0.299*double(img(:,:,1)) + 0.587*double(img(:,:,2)) + 0.114*double(img(:,:,3));
    lit = gray > 12;
    r = find(any(lit,2)); c = find(any(lit,1));
    if numel(r) > 10 && numel(c) > 10
        img = img(r(1):r(end), c(1):c(end), :);
    end
    img = imresize(img, [sz sz]);
end


function E = scoreEndpoint(truth, score, thrSens, thrSpec)
    truth = logical(truth(:));
    score = score(:);
    E.n = numel(truth);
    E.prevalence = mean(truth);
    if numel(unique(truth)) < 2
        E.auc = NaN;
    else
        [~, ~, ~, E.auc] = perfcurve(truth, score, true);
    end
    E.atHighSensitivity = opPoint(truth, score, thrSens);
    E.atHighSpecificity = opPoint(truth, score, thrSpec);
end


function o = opPoint(truth, score, thr)
    pred = score >= thr;
    o.threshold = thr;
    o.tp = nnz(pred & truth);  o.fn = nnz(~pred & truth);
    o.tn = nnz(~pred & ~truth); o.fp = nnz(pred & ~truth);
    o.sensitivity = o.tp / max(o.tp + o.fn, 1);
    o.specificity = o.tn / max(o.tn + o.fp, 1);
    % Wilson score interval - the contract requires a CI and its method, and
    % Wilson behaves properly near 0 and 1 where the normal approximation does not.
    o.sensitivityCI = wilson(o.tp, o.tp + o.fn);
    o.specificityCI = wilson(o.tn, o.tn + o.fp);
end


function ci = wilson(k, n)
    if n == 0, ci = [NaN NaN]; return; end
    z = 1.96; p = k / n;
    d = 1 + z^2/n;
    c = (p + z^2/(2*n)) / d;
    h = z * sqrt(p*(1-p)/n + z^2/(4*n^2)) / d;
    ci = [max(0, c-h), min(1, c+h)];
end


function printReport(R)
    fprintf('\n  ============================================================\n');
    fprintf('   MESSIDOR-2 EXTERNAL VALIDATION  (held-out, evaluated once)\n');
    fprintf('  ============================================================\n');
    fprintf('   model      : %s @ %dpx, trained on APTOS only\n', R.model.backbone, R.model.inputSize(1));
    fprintf('   contract   : v%s   DME rule: %s\n', R.contractVersion, R.dmeRule);
    fprintf('   thresholds : FROZEN before this run (highSens %.4f)\n', R.thresholds.highSensitivity);
    fprintf('   images     : %d total, %d ungradable, %d scored\n', ...
        R.n_total, R.n_ungradable, R.n_scored);

    names = {'primary', 'PRIMARY  (DR>=2 OR referable DME)'; ...
             'secondary', 'secondary (DR>=2 only)'; ...
             'referralOrRecapture', 'referral-or-recapture (incl. ungradable)'};
    for k = 1:size(names,1)
        E = R.(names{k,1});
        fprintf('\n   %s\n', names{k,2});
        fprintf('     n %d | prevalence %.1f%% | AUC %.4f\n', E.n, 100*E.prevalence, E.auc);
        for op = {'atHighSensitivity','atHighSpecificity'}
            o = E.(op{1});
            fprintf('     %-18s Sens %5.1f%% [%.1f-%.1f]  Spec %5.1f%% [%.1f-%.1f]\n', ...
                op{1}(3:end), 100*o.sensitivity, 100*o.sensitivityCI(1), 100*o.sensitivityCI(2), ...
                100*o.specificity, 100*o.specificityCI(1), 100*o.specificityCI(2));
        end
    end

    fprintf('\n   Gulshan et al. 2016, SAME 1748 images (different reference\n');
    fprintf('   standard: >=7-grader majority, 14.6%% prevalence):\n');
    fprintf('     high-spec OP  Sens 87.0%%  Spec 98.5%%   AUC 0.990\n');
    fprintf('     high-sens OP  Sens 96.1%%  Spec 93.9%%\n');
    fprintf('  ============================================================\n');
end
