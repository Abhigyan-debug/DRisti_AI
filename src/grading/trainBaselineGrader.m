function info = trainBaselineGrader(opts)
%TRAINBASELINEGRADER  Train the single-technique DR grading baseline on APTOS.
%
%   info = TRAINBASELINEGRADER() fine-tunes a pretrained CNN to predict the
%   ICDR grade (0-4) from a raw fundus image, with no quality gate and no
%   lesion features.
%
%   info = TRAINBASELINEGRADER(backbone="resnet18", inputSize=384, ...
%                              maxEpochs=12, subsetFraction=1.0)
%
%   THIS IS DELIBERATELY THE BASELINE
%   ---------------------------------
%   The README requires the integrated pipeline to beat a "single technique"
%   comparator. This is that comparator: raw image in, grade out. It must NOT
%   use Module 1's gate or Module 2's features - that is the whole point of it.
%   The hybrid model is a separate function.
%
%   SPLIT DISCIPLINE
%   ----------------
%   APTOS ships 3662 labelled training images and 1928 test images whose labels
%   were never released, so the public test set is unusable for evaluation.
%   This does a stratified split of the 3662 and COMMITS the indices to
%   config/aptos_split.json, so every later run - and Phase 6's comparison -
%   uses the identical split. Without that, a "better" model may just be a
%   luckier split.
%
%   Messidor-2 is never touched here.
%
%   CLASS IMBALANCE
%   ---------------
%   Measured: grade 0 49.3%, 1 10.1%, 2 27.3%, 3 5.3%, 4 8.1%. Grade 3 is 193
%   images. Without class weighting the network can score 49% accuracy by
%   predicting "no DR" for everything, which is exactly the failure mode that
%   matters clinically - it misses every referable case. Weighted loss is not
%   optional here.
%
%   See also EVALUATEGRADER, LOADAPTOSSPLIT.

    arguments
        opts.backbone (1,:) char = 'resnet18'
        opts.inputSize (1,1) double = 384
        opts.maxEpochs (1,1) double = 12
        opts.miniBatchSize (1,1) double = 16
        opts.subsetFraction (1,1) double {mustBeInRange(opts.subsetFraction,0.01,1)} = 1.0
        opts.seed (1,1) double = 0
    end

    cfg = drishti_paths();
    rng(opts.seed);

    % ---- data ------------------------------------------------------------
    % Build (or reuse) the pre-resized cache. Without it training is I/O bound
    % at ~0.45 s/image and a 12-epoch run takes 4.4 hours doing identical
    % preprocessing 12 times over.
    cacheDir = buildAptosCache('size', opts.inputSize);

    [trainT, valT] = loadAptosSplit('subsetFraction', opts.subsetFraction, 'seed', opts.seed);
    trainT.imagePath = redirectToCache(trainT.imageName, cacheDir);
    valT.imagePath   = redirectToCache(valT.imageName,   cacheDir);
    fprintf('  train %d | val %d images\n', height(trainT), height(valT));

    inputSize3 = [opts.inputSize opts.inputSize 3];

    trainDS = makeDatastore(trainT, inputSize3, true);
    valDS   = makeDatastore(valT,   inputSize3, false);

    % ---- network ---------------------------------------------------------
    numClasses = 5;
    try
        net = imagePretrainedNetwork(opts.backbone, 'NumClasses', numClasses);
    catch ME
        error('drishti:noPretrainedWeights', ...
            ['Pretrained weights for "%s" are not installed.\n' ...
             'Install via MATLAB Home > Add-Ons > Get Add-Ons, search\n' ...
             '  "Deep Learning Toolbox Model for %s Network"\n' ...
             'Original error: %s'], opts.backbone, upper(opts.backbone), ME.message);
    end

    % Resize the input layer to our working resolution. DR lesions are small -
    % microaneurysms are a few pixels - so 224 throws away the signal the task
    % depends on. 384 is a compromise against an 8 GB card and one night.
    net = setInputSize(net, inputSize3);

    % ---- class weights ---------------------------------------------------
    counts = countcats(categorical(trainT.diagnosis, 0:4, compose("%d", 0:4)));
    weights = sum(counts) ./ (numClasses * max(counts, 1));
    fprintf('  class weights: %s\n', mat2str(round(weights(:)', 2)));

    % ---- training --------------------------------------------------------
    if gpuDeviceCount('available') > 0
        env = 'gpu';
    else
        env = 'cpu';
        warning('drishti:noGPU', 'No GPU - this will be very slow.');
    end

    valFreq = max(10, floor(height(trainT) / opts.miniBatchSize));

    trainOpts = trainingOptions('adam', ...
        'InitialLearnRate', 1e-4, ...
        'LearnRateSchedule', 'piecewise', ...
        'LearnRateDropFactor', 0.3, ...
        'LearnRateDropPeriod', max(3, floor(opts.maxEpochs/3)), ...
        'MaxEpochs', opts.maxEpochs, ...
        'MiniBatchSize', opts.miniBatchSize, ...
        'ValidationData', valDS, ...
        'ValidationFrequency', valFreq, ...
        'ValidationPatience', 4, ...
        'OutputNetwork', 'best-validation', ...
        'Shuffle', 'every-epoch', ...
        'ExecutionEnvironment', env, ...
        'Verbose', true, ...
        'VerboseFrequency', 25, ...
        'Plots', 'none');

    lossFcn = @(Y, T) crossentropy(Y, T, weights, ...
        'NormalizationFactor', 'all-elements', 'WeightsFormat', 'C');

    t0 = tic;
    [trainedNet, trainInfo] = trainnet(trainDS, net, lossFcn, trainOpts);
    elapsed = toc(t0);

    % ---- save ------------------------------------------------------------
    if ~isfolder(cfg.modelsDir), mkdir(cfg.modelsDir); end
    outFile = fullfile(cfg.modelsDir, 'baseline_grader.mat');
    meta = struct('backbone', opts.backbone, 'inputSize', inputSize3, ...
        'trainedOn', 'APTOS 2019 train split', 'nTrain', height(trainT), ...
        'nVal', height(valT), 'classWeights', weights, ...
        'maxEpochs', opts.maxEpochs, 'elapsedSeconds', elapsed, ...
        'trainedAt', string(datetime('now')), ...
        'isBaseline', true, ...
        'note', 'Single-technique comparator: raw image in, grade out. No quality gate, no lesion features.');
    save(outFile, 'trainedNet', 'meta', '-v7.3');

    fprintf('\n  trained in %.1f min -> models/baseline_grader.mat\n', elapsed/60);

    info = struct('net', trainedNet, 'meta', meta, 'trainInfo', trainInfo, ...
                  'file', outFile);
end


% ------------------------------------------------------------------ helpers

function ds = makeDatastore(T, inputSize3, doAugment)
%MAKEDATASTORE  Image datastore with fundus-appropriate augmentation.

    imds = imageDatastore(T.imagePath);
    labels = categorical(T.diagnosis, 0:4, compose("%d", 0:4));
    lblds = arrayDatastore(labels);
    ds = combine(imds, lblds);

    if doAugment
        ds = transform(ds, @(x) augmentFundus(x, inputSize3), 'IncludeInfo', false);
    else
        ds = transform(ds, @(x) {prepFundus(x{1}, inputSize3), x{2}}, 'IncludeInfo', false);
    end
end


function out = augmentFundus(x, inputSize3)
%AUGMENTFUNDUS  Augmentations that are valid for retinal images.
%
%   Horizontal flip is legitimate - it maps a right eye onto a left eye, which
%   is a real thing the camera sees. VERTICAL flip is not: it would put the
%   superior arcade below the macula, an anatomy that does not exist, and the
%   network would waste capacity learning to ignore impossible inputs.
%
%   Rotation is kept small for the same reason. Brightness/contrast jitter is
%   the most valuable augmentation here because it is exactly the variation
%   Module 1 measured across cameras.

    img = x{1};
    if rand > 0.5
        img = fliplr(img);
    end
    ang = (rand - 0.5) * 24;          % +/-12 degrees
    img = imrotate(img, ang, 'bilinear', 'crop');

    img = prepFundus(img, inputSize3);

    % photometric jitter in [0,1] space
    img = img * (0.85 + 0.3 * rand) + (rand - 0.5) * 0.08;
    img = min(max(img, 0), 1);

    out = {img, x{2}};
end


function img = prepFundus(img, inputSize3)
%PREPFUNDUS  Normalise a cached image to the network input.
%
%   The FOV crop and the expensive resize already happened once in
%   BUILDAPTOSCACHE, so this stays cheap - it is on the per-epoch path.

    if size(img, 3) == 1
        img = repmat(img, 1, 1, 3);
    end
    img = im2double(img);
    if ~isequal(size(img, 1:2), inputSize3(1:2))
        img = imresize(img, inputSize3(1:2));
    end
end


function paths = redirectToCache(names, cacheDir)
    paths = strings(numel(names), 1);
    for k = 1:numel(names)
        paths(k) = string(fullfile(cacheDir, char(names(k) + ".png")));
    end
end


function net = setInputSize(net, inputSize3)
%SETINPUTSIZE  Swap the image input layer for one at our working resolution.

    lg = layerGraph(net);
    inLayer = lg.Layers(1);
    newIn = imageInputLayer(inputSize3, 'Name', inLayer.Name, ...
        'Normalization', 'zscore');
    net = replaceLayer(lg, inLayer.Name, newIn);
    net = dlnetwork(net);
end
