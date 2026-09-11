function R = trainHybridGrader(opts)
%TRAINHYBRIDGRADER  Lesion features + CNN score -> referable DR. The Phase 3 item.
%
%   R = TRAINHYBRIDGRADER() extracts Module 2 lesion features for the APTOS
%   split, combines them with the CNN's referable score, fits a gradient-boosted
%   ensemble, and compares it against the CNN alone on identical images.
%
%   THIS IS THE README'S CENTRAL CLAIM
%   ----------------------------------
%   "Integrated pipeline must outperform single-technique baselines." The
%   baseline is the CNN alone; the integrated model is the CNN score plus
%   independently-derived lesion counts and areas.
%
%   EXPECT THIS TO BE HARD, AND SAY SO EITHER WAY
%   ---------------------------------------------
%   The baseline already reaches AUC 0.9891. Module 2's features are measurably
%   weak - hard exudate Dice 0.240, microaneurysm counts of 43-192 where the
%   clinical range is 5-50, soft exudates barely separating. Adding noisy
%   features to a strong CNN commonly does nothing or hurts.
%
%   The experiment is still worth running, because "we tested the central claim
%   and it did not hold" is a real result, whereas asserting the claim without
%   testing it is not. Both outcomes are reported.
%
%   FAIR COMPARISON RULES
%   ---------------------
%   - Same images, same split, same endpoint for both arms.
%   - The CNN score is an INPUT to the hybrid, so the hybrid can always ignore
%     the lesion features and recover the baseline. If it still loses, the
%     features are actively harmful rather than merely uninformative.
%   - The hybrid is fitted with cross-validation on the training split and
%     evaluated on the validation split the CNN never trained on.
%
%   See also EXTRACTLESIONFEATURES, EVALUATEGRADER.

    arguments
        opts.modelFile (1,:) char = ''
        opts.limitTrain (1,1) double = 600
        opts.limitVal (1,1) double = 300
        opts.seed (1,1) double = 0
    end

    cfg = drishti_paths();
    rng(opts.seed);
    if isempty(opts.modelFile)
        opts.modelFile = fullfile(cfg.modelsDir, 'baseline_grader.mat');
    end
    S = load(opts.modelFile);
    net = S.trainedNet;
    inputSize3 = S.meta.inputSize;
    cacheDir = fullfile(cfg.dataRoot, '_cache', sprintf('aptos_%d', inputSize3(1)));

    [trA, valA] = loadAptosSplit();
    nTr = min(height(trA), opts.limitTrain);
    nVa = min(height(valA), opts.limitVal);
    trA = trA(randperm(height(trA), nTr), :);
    valA = valA(randperm(height(valA), nVa), :);

    fprintf('  extracting features: %d train + %d val images\n', nTr, nVa);
    [Xtr, ytr, cnnTr] = buildFeatures(trA, cacheDir, net, inputSize3, cfg);
    [Xva, yva, cnnVa] = buildFeatures(valA, cacheDir, net, inputSize3, cfg);

    okTr = all(isfinite(Xtr), 2);
    okVa = all(isfinite(Xva), 2);
    fprintf('  usable: %d train, %d val (rows with non-finite features dropped)\n', ...
        nnz(okTr), nnz(okVa));

    Xtr = Xtr(okTr,:); ytr = ytr(okTr); cnnTr = cnnTr(okTr);
    Xva = Xva(okVa,:); yva = yva(okVa); cnnVa = cnnVa(okVa);

    % ---- arm A: CNN alone --------------------------------------------------
    [~,~,~,aucBase] = perfcurve(yva, cnnVa, true);

    % ---- arm B: CNN score + lesion features -------------------------------
    mdl = fitcensemble(Xtr, ytr, 'Method', 'LogitBoost', ...
        'NumLearningCycles', 200, 'Learners', templateTree('MaxNumSplits', 8), ...
        'ClassNames', [false true]);
    [~, sc] = predict(mdl, Xva);
    hybridScore = sc(:, 2);
    [~,~,~,aucHybrid] = perfcurve(yva, hybridScore, true);

    % ---- arm C: lesion features WITHOUT the CNN score ---------------------
    % Isolates what Module 2 contributes on its own. If this is near chance the
    % features carry little signal, which explains any null result in arm B.
    mdlLesionOnly = fitcensemble(Xtr(:,2:end), ytr, 'Method', 'LogitBoost', ...
        'NumLearningCycles', 200, 'Learners', templateTree('MaxNumSplits', 8), ...
        'ClassNames', [false true]);
    [~, scL] = predict(mdlLesionOnly, Xva(:,2:end));
    [~,~,~,aucLesion] = perfcurve(yva, scL(:,2), true);

    R = struct();
    R.nTrain = numel(ytr); R.nVal = numel(yva);
    R.aucBaseline = aucBase;
    R.aucHybrid = aucHybrid;
    R.aucLesionOnly = aucLesion;
    R.delta = aucHybrid - aucBase;
    R.featureNames = featureNames();
    R.model = mdl;

    imp = predictorImportance(mdl);
    [~, ord] = sort(imp, 'descend');
    R.importance = table(string(R.featureNames(ord))', imp(ord)', ...
        'VariableNames', {'feature','importance'});

    printHybrid(R);
    save(fullfile(cfg.resultsDir, 'hybrid_grader_result.mat'), 'R');
end


% ------------------------------------------------------------------ helpers

function [X, y, cnnScore] = buildFeatures(T, cacheDir, net, inputSize3, cfg)
    n = height(T);
    nFeat = numel(featureNames());
    X = nan(n, nFeat);
    y = T.diagnosis >= 2;
    cnnScore = nan(n,1);

    origDir = cfg.aptos.trainImages;
    names = T.imageName;

    % CNN scores in batches (GPU), then lesion features in parallel (CPU).
    for i = 1:32:n
        j = min(i+31, n);
        Xb = zeros([inputSize3(1:2) 3 j-i+1], 'single');
        for k = i:j
            im = im2single(imread(fullfile(cacheDir, char(names(k) + ".png"))));
            if size(im,3)==1, im = repmat(im,1,1,3); end
            Xb(:,:,:,k-i+1) = im;
        end
        Y = predict(net, dlarray(Xb,'SSCB'));
        P = double(gather(extractdata(Y)))';
        cnnScore(i:j) = sum(P(:,3:end), 2);
    end

    feats = nan(n, nFeat-1);
    parfor k = 1:n
        try
            F = extractLesionFeatures(imread(fullfile(origDir, char(names(k) + ".png"))), ...
                'runQualityGate', false, 'skipNeovasc', true); %#ok<PFBNS>
            feats(k,:) = flattenFeatures(F);
        catch
            feats(k,:) = nan(1, nFeat-1);
        end
    end

    X(:,1) = cnnScore;
    X(:,2:end) = feats;
end


function v = flattenFeatures(F)
    v = [ F.microaneurysms.count, ...
          F.microaneurysms.countWithin1DD, ...
          F.microaneurysms.densityPerDD2, ...
          F.haemorrhages.count, ...
          F.haemorrhages.areaDD2, ...
          F.haemorrhages.largestAreaDD2, ...
          F.haemorrhages.countByType.dot, ...
          F.haemorrhages.countByType.blot, ...
          F.haemorrhages.countByType.flame, ...
          F.hardExudates.count, ...
          F.hardExudates.areaDD2, ...
          min(F.hardExudates.minDistanceToFoveaDD, 10), ...   % Inf -> capped
          F.hardExudates.areaWithin1DDofFovea, ...
          F.softExudates.count, ...
          F.softExudates.areaDD2, ...
          F.vessels.totalLengthDD, ...
          F.vessels.meanCaliberDD, ...
          F.anatomy.discConfidence ];
end


function nm = featureNames()
    nm = {'cnnScore','maCount','maWithin1DD','maDensity', ...
          'haemCount','haemArea','haemLargest','haemDot','haemBlot','haemFlame', ...
          'hardExCount','hardExArea','hardExFoveaDist','hardExNearFovea', ...
          'softExCount','softExArea','vesselLength','vesselCaliber','discConf'};
end


function printHybrid(R)
    fprintf('\n  ==================================================================\n');
    fprintf('   HYBRID MODEL - the README''s "integrated beats single-technique"\n');
    fprintf('   APTOS, %d train / %d val, identical images both arms\n', R.nTrain, R.nVal);
    fprintf('  ==================================================================\n');
    fprintf('   CNN alone (baseline)          AUC %.4f\n', R.aucBaseline);
    fprintf('   CNN + lesion features         AUC %.4f   (%+.4f)\n', R.aucHybrid, R.delta);
    fprintf('   lesion features ONLY          AUC %.4f\n', R.aucLesionOnly);
    fprintf('  ------------------------------------------------------------------\n');
    if R.delta > 0.002
        fprintf('   -> the integrated model BEATS the baseline.\n');
    elseif R.delta < -0.002
        fprintf('   -> the integrated model is WORSE. Module 2 features are hurting.\n');
    else
        fprintf('   -> no meaningful difference. The lesion features add nothing\n');
        fprintf('      the CNN had not already extracted.\n');
    end
    fprintf('\n   top features by importance:\n');
    top = R.importance(1:min(6, height(R.importance)), :);
    for k = 1:height(top)
        fprintf('     %-20s %.4f\n', top.feature(k), top.importance(k));
    end
    fprintf('  ==================================================================\n');
end
