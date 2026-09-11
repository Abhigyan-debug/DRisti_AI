function R = evaluateIdridTransfer(opts)
%EVALUATEIDRIDTRANSFER  Cross-domain transfer test on IDRiD. NOT the holdout.
%
%   R = EVALUATEIDRIDTRANSFER() scores the APTOS-trained grader on IDRiD's
%   grading split, which the model has never seen.
%
%   WHY THIS EXISTS
%   ---------------
%   Messidor-2 revealed that the frozen operating point does not transfer
%   across imaging domains: sensitivity fell 90.3% -> 31.2% because the score
%   distribution collapses on unseen equipment. Messidor-2 is now SPENT - it
%   was evaluated once, by design, and re-running it after every fix would
%   turn it into a tuning set and destroy the one honest external number we
%   have.
%
%   IDRiD is the right surrogate. It is a different centre and camera from
%   APTOS, we hold full grading labels for all 516 images, and it carries no
%   holdout status. So it can be used repeatedly to develop and verify a fix,
%   and a fix that demonstrably restores transfer here is evidence - not
%   proof - that it would have helped on Messidor-2.
%
%   R = EVALUATEIDRIDTRANSFER(calibrator=..., split='test'|'train'|'both')
%
%   Reports the same endpoints and the same frozen thresholds as the Messidor-2
%   run, so the three datasets are directly comparable.
%
%   See also EVALUATEGRADER, EVALUATEMESSIDOR2, FITCALIBRATOR.

    arguments
        opts.modelFile (1,:) char = ''
        opts.split (1,:) char {mustBeMember(opts.split,{'train','test','both'})} = 'both'
        opts.calibrator struct = struct()
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
    thrSens = V.R.thresholds.highSensitivity;

    % ---- labels ----------------------------------------------------------
    % srcDir is returned PER ROW. IDRiD reuses filenames across splits -
    % IDRiD_001.jpg exists in BOTH the training and testing folders as
    % different images - so a name alone does not identify an image. Searching
    % the training folder first silently scored train images against test
    % labels for all 103 test rows.
    [names, dr, dme, srcDir] = loadIdridGrades(cfg, opts.split);
    n = numel(names);

    % IDRiD encodes referable DME as 2 (Messidor-2 uses 1) - resolve through
    % the contract, never by comparing a raw integer. That was blocker B12.
    D = jsondecode(fileread(fullfile(cfg.projectRoot,'config','clinical_definitions.json')));
    dmeVal = sscanf(D.dme_encoding.per_dataset.idrid.dme_referable, 'value == %d');

    % ---- inference -------------------------------------------------------
    scores = nan(n,1);
    t0 = tic;
    for i = 1:8:n
        j = min(i+7, n);
        X = []; keep = [];
        for k = i:j
            p = string(fullfile(srcDir(k), char(names(k) + ".jpg")));
            if ~isfile(p), continue; end
            img = imread(p);
            X = cat(4, X, im2single(prepFundusIdrid(img, inputSize3(1))));
            keep(end+1) = k; %#ok<AGROW>
        end
        if isempty(keep), continue; end
        Y = predict(net, dlarray(X, 'SSCB'));
        P = double(gather(extractdata(Y)))';
        scores(keep) = sum(P(:, 3:end), 2);
    end

    % ---- optional calibration -------------------------------------------
    rawScores = scores;
    if isfield(opts.calibrator, 'type')
        scores = applyCalibrator(opts.calibrator, scores);
    end

    ok = ~isnan(scores);
    truth = (dr >= 2) | (dme == dmeVal);

    R = struct();
    R.n = nnz(ok);
    R.split = opts.split;
    R.prevalence = mean(truth(ok));
    R.rawScores = rawScores;
    R.scores = scores;
    R.truth = truth;
    R.threshold = thrSens;
    R.elapsed = toc(t0);

    [~,~,~,R.auc] = perfcurve(truth(ok), scores(ok), true);
    pred = scores(ok) >= thrSens;
    tp = nnz(pred & truth(ok)); fn = nnz(~pred & truth(ok));
    tn = nnz(~pred & ~truth(ok)); fp = nnz(pred & ~truth(ok));
    R.sensitivity = tp/max(tp+fn,1);
    R.specificity = tn/max(tn+fp,1);

    R.medianReferableScore = median(scores(ok & truth));
    R.medianNonReferableScore = median(scores(ok & ~truth));

    if opts.verbose
        fprintf('\n  IDRiD transfer (%s split, n=%d, prevalence %.1f%%)\n', ...
            opts.split, R.n, 100*R.prevalence);
        fprintf('    AUC %.4f\n', R.auc);
        fprintf('    at frozen threshold %.4f:  Sens %5.1f%%  Spec %5.1f%%\n', ...
            thrSens, 100*R.sensitivity, 100*R.specificity);
        fprintf('    median score: referable %.4f | non-referable %.4f\n', ...
            R.medianReferableScore, R.medianNonReferableScore);
        fprintf('    %.1f min\n', R.elapsed/60);
    end
end


% ------------------------------------------------------------------ helpers

function [names, dr, dme, srcDir] = loadIdridGrades(cfg, split)
    files = {}; dirs = {};
    if any(strcmp(split, {'train','both'}))
        files{end+1} = fullfile(cfg.idrid.gradeLabels, 'a. IDRiD_Disease Grading_Training Labels.csv');
        dirs{end+1}  = cfg.idrid.gradeTrainImages;
    end
    if any(strcmp(split, {'test','both'}))
        files{end+1} = fullfile(cfg.idrid.gradeLabels, 'b. IDRiD_Disease Grading_Testing Labels.csv');
        dirs{end+1}  = cfg.idrid.gradeTestImages;
    end
    names = strings(0,1); dr = []; dme = []; srcDir = strings(0,1);
    for f = 1:numel(files)
        T = readtable(files{f}, 'VariableNamingRule', 'preserve');
        nm = string(T{:,1});
        g  = T{:,2};
        d  = T{:,3};
        if ~isnumeric(g), g = str2double(string(g)); end
        if ~isnumeric(d), d = str2double(string(d)); end
        keep = nm ~= "" & ~ismissing(nm) & ~isnan(g);
        names  = [names; nm(keep)];                              %#ok<AGROW>
        dr     = [dr; double(g(keep))];                          %#ok<AGROW>
        dme    = [dme; double(d(keep))];                         %#ok<AGROW>
        srcDir = [srcDir; repmat(string(dirs{f}), nnz(keep), 1)]; %#ok<AGROW>
    end
end



function img = prepFundusIdrid(img, sz)
    if size(img,3) == 1, img = repmat(img,1,1,3); end
    gray = 0.299*double(img(:,:,1)) + 0.587*double(img(:,:,2)) + 0.114*double(img(:,:,3));
    lit = gray > 12;
    r = find(any(lit,2)); c = find(any(lit,1));
    if numel(r) > 10 && numel(c) > 10
        img = img(r(1):r(end), c(1):c(end), :);
    end
    img = imresize(img, [sz sz]);
end


function s = applyCalibrator(C, s)
    switch C.type
        case 'platt'
            s = 1 ./ (1 + exp(-(C.a * s + C.b)));
        case 'rank'
            % Distribution-free: map each score to its percentile within THIS
            % dataset's own score distribution, then threshold on percentile.
            % Uses only unlabelled target images, so it is legitimate at
            % deployment time - a clinic has its own unlabelled images.
            valid = ~isnan(s);
            r = tiedrank(s(valid)) / nnz(valid);
            out = nan(size(s));
            out(valid) = r;
            s = out;
        otherwise
            error('drishti:badCalibrator', 'Unknown calibrator type: %s', C.type);
    end
end
