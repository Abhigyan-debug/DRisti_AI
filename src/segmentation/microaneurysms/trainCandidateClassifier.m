function R = trainCandidateClassifier(opts)
%TRAINCANDIDATECLASSIFIER  Stage 2: reject false-positive lesion candidates.
%
%   R = TRAINCANDIDATECLASSIFIER() trains a small CNN on the labelled patches
%   from BUILDCANDIDATEDATASET and reports precision/recall on held-out IMAGES.
%
%   R = TRAINCANDIDATECLASSIFIER(lesion=..., maxEpochs=15, valFraction=0.25)
%
%   THE SPLIT IS BY IMAGE, NOT BY PATCH
%   -----------------------------------
%   Patches from one fundus image share illumination, camera, noise and often
%   the same lesion cluster. A patch-level random split puts near-duplicates on
%   both sides and reports a score that collapses the moment a new image
%   arrives. Every patch from an image goes to exactly one side here.
%
%   WHAT THIS CAN AND CANNOT ACHIEVE
%   --------------------------------
%   A false-positive classifier only ever DISCARDS candidates. It cannot
%   recover a lesion the generator never proposed, so final recall is capped by
%   generator recall - measured at 0.235 for microaneurysms at threshSD 1.5.
%   The target here is PRECISION: baseline 0.021 means 98% of reported
%   microaneurysms are false, and that is what makes the count unfit to show a
%   clinician.
%
%   Success is not "high accuracy". At 2.7% positives, predicting "false" for
%   everything scores 97.3% accuracy and discards every lesion. The metrics
%   that matter are precision and recall on the positive class.
%
%   See also BUILDCANDIDATEDATASET, DETECTDARKLESIONS.

    arguments
        opts.lesion (1,:) char = 'microaneurysms'
        opts.maxEpochs (1,1) double = 15
        opts.valFraction (1,1) double = 0.25
        opts.inputPx (1,1) double = 48
        opts.seed (1,1) double = 0
    end

    cfg = drishti_paths();
    rng(opts.seed);
    root = fullfile(cfg.dataRoot, '_cache', ['candidates_' opts.lesion]);
    if ~isfolder(root)
        error('drishti:noCandidates', ...
            'No candidate dataset at %s. Run buildCandidateDataset first.', root);
    end

    posL = dir(fullfile(root, 'pos', '*.png'));
    negL = dir(fullfile(root, 'neg', '*.png'));
    files = [string(fullfile(root,'pos',{posL.name}))'; string(fullfile(root,'neg',{negL.name}))'];
    labels = [true(numel(posL),1); false(numel(negL),1)];

    % Image id is everything before the trailing _NNNN
    [~, stems] = arrayfun(@(f) fileparts(f), files, 'UniformOutput', false);
    imgId = regexprep(string(stems), '_\d+$', '');

    uImgs = unique(imgId);
    nVal = max(1, round(opts.valFraction * numel(uImgs)));
    valImgs = uImgs(randperm(numel(uImgs), nVal));
    isVal = ismember(imgId, valImgs);

    fprintf('  %d images -> %d train / %d val (split by IMAGE)\n', ...
        numel(uImgs), numel(uImgs)-nVal, nVal);
    fprintf('  patches: %d train (%d pos) | %d val (%d pos)\n', ...
        nnz(~isVal), nnz(~isVal & labels), nnz(isVal), nnz(isVal & labels));

    if nnz(isVal & labels) < 5
        warning('drishti:fewValPositives', ...
            'Only %d positive validation patches - the estimate will be very noisy.', ...
            nnz(isVal & labels));
    end

    inSz = [opts.inputPx opts.inputPx 3];
    trainDS = patchDatastore(files(~isVal), labels(~isVal), inSz, true);
    valDS   = patchDatastore(files(isVal),  labels(isVal),  inSz, false);

    % Small purpose-built CNN. A 48x48 patch of retina is not ImageNet, and
    % upsampling it to 224 to reuse a pretrained backbone spends most of the
    % compute on interpolated pixels.
    % One layer per line: inside [ ], a comma is horizontal concatenation and a
    % newline is vertical, so mixing them makes the dimensions inconsistent.
    layers = [
        imageInputLayer(inSz, 'Normalization', 'zscore')
        convolution2dLayer(3, 32, 'Padding', 'same')
        batchNormalizationLayer
        reluLayer
        convolution2dLayer(3, 32, 'Padding', 'same')
        batchNormalizationLayer
        reluLayer
        maxPooling2dLayer(2, 'Stride', 2)
        convolution2dLayer(3, 64, 'Padding', 'same')
        batchNormalizationLayer
        reluLayer
        convolution2dLayer(3, 64, 'Padding', 'same')
        batchNormalizationLayer
        reluLayer
        maxPooling2dLayer(2, 'Stride', 2)
        convolution2dLayer(3, 128, 'Padding', 'same')
        batchNormalizationLayer
        reluLayer
        globalAveragePooling2dLayer
        dropoutLayer(0.4)
        fullyConnectedLayer(2)
        softmaxLayer ];
    net = dlnetwork(layerGraph(layers));

    % Class weights: 2.7% positives. Without this the net learns "always false",
    % which is 97.3% accurate and useless.
    nPos = nnz(~isVal & labels); nNeg = nnz(~isVal & ~labels);
    w = [1, nNeg/max(nPos,1)];
    w = w / sum(w) * 2;
    fprintf('  class weights [neg pos]: %s\n', mat2str(round(w,2)));

    if gpuDeviceCount('available') > 0, env='gpu'; else, env='cpu'; end
    tOpts = trainingOptions('adam', ...
        'InitialLearnRate', 1e-3, ...
        'MaxEpochs', opts.maxEpochs, ...
        'MiniBatchSize', 128, ...
        'ValidationData', valDS, ...
        'ValidationFrequency', 50, ...
        'OutputNetwork', 'best-validation', ...
        'Shuffle', 'every-epoch', ...
        'ExecutionEnvironment', env, ...
        'Verbose', true, 'VerboseFrequency', 50, 'Plots', 'none');

    lossFcn = @(Y,T) crossentropy(Y, T, w, 'NormalizationFactor','all-elements','WeightsFormat','C');
    trained = trainnet(trainDS, net, lossFcn, tOpts);

    % ---- evaluate on held-out images --------------------------------------
    scores = predictPatches(trained, files(isVal), inSz);
    yv = labels(isVal);

    [X, Y, Thr, auc] = perfcurve(yv, scores, true);
    R = struct();
    R.auc = auc;
    R.nValPatches = numel(yv);
    R.nValPositives = nnz(yv);
    R.valImages = valImgs;

    % Sweep the operating point: what precision is reachable, and at what cost
    % in recall? Baseline precision is 0.021, so the bar to clear is low.
    R.sweep = table();
    cand = [0.5 0.7 0.9 0.95 0.99];
    for t = cand
        pred = scores >= t;
        tp = nnz(pred & yv); fp = nnz(pred & ~yv); fn = nnz(~pred & yv);
        R.sweep = [R.sweep; table(t, tp/max(tp+fp,1), tp/max(tp+fn,1), nnz(pred), ...
            'VariableNames', {'threshold','precision','recall','nKept'})];
    end

    outFile = fullfile(cfg.modelsDir, ['candidate_classifier_' opts.lesion '.mat']);
    meta = struct('lesion', opts.lesion, 'inputSize', inSz, 'valImages', {cellstr(valImgs)}, ...
        'auc', auc, 'trainedAt', string(datetime('now')), ...
        'note', ['Stage-2 false-positive classifier. Split by IMAGE. Final ' ...
                 'recall is capped by generator recall (0.235), which this ' ...
                 'cannot raise.']);
    save(outFile, 'trained', 'meta', '-v7.3');

    fprintf('\n  patch-level AUC %.4f on %d held-out patches (%d positive)\n', ...
        auc, R.nValPatches, R.nValPositives);
    disp(R.sweep);
    fprintf('  baseline (no classifier): precision 0.021\n');
    fprintf('  saved -> models/candidate_classifier_%s.mat\n', opts.lesion);
end


function ds = patchDatastore(files, labels, inSz, doAug)
    imds = imageDatastore(files);
    lbl = arrayDatastore(categorical(labels, [false true], {'neg','pos'}));
    ds = combine(imds, lbl);
    if doAug
        ds = transform(ds, @(x) {augPatch(x{1}, inSz), x{2}}, 'IncludeInfo', false);
    else
        ds = transform(ds, @(x) {prepPatch(x{1}, inSz), x{2}}, 'IncludeInfo', false);
    end
end

function p = augPatch(p, inSz)
    % A lesion patch has no canonical orientation, so all eight dihedral
    % transforms are valid here - unlike a whole fundus image, where a vertical
    % flip would invent an anatomy that does not exist.
    if rand > 0.5, p = fliplr(p); end
    if rand > 0.5, p = flipud(p); end
    k = randi(4) - 1;
    if k > 0, p = rot90(p, k); end
    p = prepPatch(p, inSz);
    p = p * (0.85 + 0.3*rand);
    p = min(max(p, 0), 1);
end

function p = prepPatch(p, inSz)
    if size(p,3) == 1, p = repmat(p,1,1,3); end
    p = im2single(p);
    if ~isequal(size(p,1:2), inSz(1:2)), p = imresize(p, inSz(1:2)); end
end

function s = predictPatches(net, files, inSz)
    n = numel(files);
    s = nan(n,1);
    for i = 1:256:n
        j = min(i+255, n);
        X = zeros([inSz(1:2) 3 j-i+1], 'single');
        for k = i:j
            X(:,:,:,k-i+1) = prepPatch(imread(files(k)), inSz);
        end
        Y = predict(net, dlarray(X,'SSCB'));
        P = double(gather(extractdata(Y)))';
        s(i:j) = P(:,2);
    end
end
