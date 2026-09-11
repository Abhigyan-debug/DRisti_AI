function info = trainMultiDomainGrader(opts)
%TRAINMULTIDOMAINGRADER  Train on APTOS + IDRiD to improve domain robustness.
%
%   info = TRAINMULTIDOMAINGRADER() fine-tunes on the union of the APTOS
%   training split and the IDRiD grading TRAINING split.
%
%   WHY
%   ---
%   The measured failure is domain shift, not lost signal: AUC held across
%   datasets (0.989 -> 0.885) while sensitivity collapsed (90.3% -> 31.2%)
%   because the score scale moved. Training on a single corpus lets the network
%   tie its output scale to that corpus's appearance. Two corpora from
%   different centres and cameras is the standard first response, and it is an
%   unchecked item on the README's own Phase 3 list ("train/tune on APTOS +
%   IDRiD").
%
%   WHAT IS HELD OUT, AND WHY IT MATTERS
%   ------------------------------------
%   Only IDRiD's TRAINING split (413) enters training. IDRiD's TEST split (103)
%   is deliberately excluded so it remains a clean cross-domain probe - we have
%   already spent Messidor-2, and training on all of IDRiD would leave us with
%   no honest transfer test at all.
%
%   ⚠️ IDRiD filenames COLLIDE across splits: IDRiD_001.jpg exists in both the
%   training and testing folders as different images. The cache is built from
%   the training folder only, and nothing here resolves an image by name alone.
%   That collision silently corrupted an earlier experiment.
%
%   CLASS BALANCE ACROSS CORPORA
%   ----------------------------
%   APTOS is 40.6% referable, IDRiD 62.7%. Concatenating them shifts the prior
%   toward IDRiD's enriched prevalence. Class weights are recomputed on the
%   COMBINED set so the loss reflects what is actually being trained on.
%
%   See also TRAINBASELINEGRADER, EVALUATEIDRIDTRANSFER.

    arguments
        opts.backbone (1,:) char = 'resnet18'
        opts.inputSize (1,1) double = 640
        opts.maxEpochs (1,1) double = 12
        opts.miniBatchSize (1,1) double = 6
        opts.seed (1,1) double = 0
    end

    cfg = drishti_paths();
    rng(opts.seed);

    % ---- APTOS ------------------------------------------------------------
    aptosCache = fullfile(cfg.dataRoot, '_cache', sprintf('aptos_%d', opts.inputSize));
    [trA, valA] = loadAptosSplit();
    trainPaths = arrayfun(@(nm) string(fullfile(aptosCache, char(nm + ".png"))), trA.imageName);
    trainGrades = trA.diagnosis;
    trainSource = repmat("aptos", height(trA), 1);

    % ---- IDRiD training split --------------------------------------------
    idridCache = fullfile(cfg.dataRoot, '_cache', 'idrid_640');
    T = readtable(fullfile(cfg.idrid.gradeLabels, ...
        'a. IDRiD_Disease Grading_Training Labels.csv'), 'VariableNamingRule', 'preserve');
    nm = string(T{:,1});
    gr = T{:,2};
    if ~isnumeric(gr), gr = str2double(string(gr)); end
    keep = nm ~= "" & ~ismissing(nm) & ~isnan(gr);
    nm = nm(keep); gr = double(gr(keep));

    idridPaths = arrayfun(@(x) string(fullfile(idridCache, char(x + ".png"))), nm);
    exists = arrayfun(@(p) isfile(p), idridPaths);
    idridPaths = idridPaths(exists);
    idridGrades = gr(exists);

    trainPaths = [trainPaths; idridPaths];
    trainGrades = [trainGrades; idridGrades];
    trainSource = [trainSource; repmat("idrid", numel(idridPaths), 1)];

    % Validation stays APTOS-only so the number is comparable to every
    % previous run. Changing the yardstick at the same time as the treatment
    % would make the comparison meaningless.
    valPaths = arrayfun(@(nm2) string(fullfile(aptosCache, char(nm2 + ".png"))), valA.imageName);
    valGrades = valA.diagnosis;

    fprintf('  train: %d APTOS + %d IDRiD = %d | val: %d (APTOS only)\n', ...
        nnz(trainSource=="aptos"), nnz(trainSource=="idrid"), numel(trainPaths), numel(valPaths));
    fprintf('  referable prevalence: APTOS %.1f%% | IDRiD %.1f%% | combined %.1f%%\n', ...
        100*mean(trainGrades(trainSource=="aptos")>=2), ...
        100*mean(trainGrades(trainSource=="idrid")>=2), ...
        100*mean(trainGrades>=2));

    inputSize3 = [opts.inputSize opts.inputSize 3];
    trainDS = makeDS(trainPaths, trainGrades, inputSize3, true);
    valDS   = makeDS(valPaths,   valGrades,   inputSize3, false);

    net = imagePretrainedNetwork(opts.backbone, 'NumClasses', 5);
    net = setInput(net, inputSize3);

    counts = countcats(categorical(trainGrades, 0:4, compose("%d", 0:4)));
    weights = sum(counts) ./ (5 * max(counts, 1));
    fprintf('  class weights (combined): %s\n', mat2str(round(weights(:)', 2)));

    if gpuDeviceCount('available') > 0, env = 'gpu'; else, env = 'cpu'; end

    trainOpts = trainingOptions('adam', ...
        'InitialLearnRate', 1e-4, ...
        'LearnRateSchedule', 'piecewise', ...
        'LearnRateDropFactor', 0.3, ...
        'LearnRateDropPeriod', max(3, floor(opts.maxEpochs/3)), ...
        'MaxEpochs', opts.maxEpochs, ...
        'MiniBatchSize', opts.miniBatchSize, ...
        'ValidationData', valDS, ...
        'ValidationFrequency', max(10, floor(numel(trainPaths)/opts.miniBatchSize)), ...
        'ValidationPatience', 4, ...
        'OutputNetwork', 'best-validation', ...
        'Shuffle', 'every-epoch', ...
        'ExecutionEnvironment', env, ...
        'Verbose', true, 'VerboseFrequency', 40, 'Plots', 'none');

    lossFcn = @(Y,T) crossentropy(Y, T, weights, ...
        'NormalizationFactor', 'all-elements', 'WeightsFormat', 'C');

    t0 = tic;
    [trainedNet, trainInfo] = trainnet(trainDS, net, lossFcn, trainOpts);
    elapsed = toc(t0);

    meta = struct('backbone', opts.backbone, 'inputSize', inputSize3, ...
        'trainedOn', 'APTOS train + IDRiD grading train', ...
        'nAptos', nnz(trainSource=="aptos"), 'nIdrid', nnz(trainSource=="idrid"), ...
        'nVal', numel(valPaths), 'classWeights', weights, ...
        'elapsedSeconds', elapsed, 'trainedAt', string(datetime('now')), ...
        'isBaseline', false, ...
        'note', ['Multi-domain. IDRiD TEST split deliberately excluded so it ' ...
                 'remains a clean cross-domain probe.']);

    outFile = fullfile(cfg.modelsDir, 'multidomain_grader.mat');
    save(outFile, 'trainedNet', 'meta', '-v7.3');
    fprintf('\n  trained in %.1f min -> models/multidomain_grader.mat\n', elapsed/60);

    info = struct('net', trainedNet, 'meta', meta, 'trainInfo', trainInfo, 'file', outFile);
end


% ------------------------------------------------------------------ helpers

function ds = makeDS(paths, grades, inputSize3, doAug)
    imds = imageDatastore(paths);
    lbl = arrayDatastore(categorical(grades, 0:4, compose("%d", 0:4)));
    ds = combine(imds, lbl);
    if doAug
        ds = transform(ds, @(x) augment(x, inputSize3), 'IncludeInfo', false);
    else
        ds = transform(ds, @(x) {prep(x{1}, inputSize3), x{2}}, 'IncludeInfo', false);
    end
end

function out = augment(x, inputSize3)
    img = x{1};
    if rand > 0.5, img = fliplr(img); end
    img = imrotate(img, (rand-0.5)*24, 'bilinear', 'crop');
    img = prep(img, inputSize3);
    % Photometric jitter is deliberately WIDER than the single-domain recipe.
    % Simulating camera-to-camera variation during training is the point of
    % this experiment - the measured failure was exactly a shift in appearance
    % between corpora.
    img = img * (0.75 + 0.5*rand) + (rand-0.5)*0.12;
    out = {min(max(img,0),1), x{2}};
end

function img = prep(img, inputSize3)
    if size(img,3)==1, img = repmat(img,1,1,3); end
    img = im2double(img);
    if ~isequal(size(img,1:2), inputSize3(1:2))
        img = imresize(img, inputSize3(1:2));
    end
end

function net = setInput(net, inputSize3)
    lg = layerGraph(net);
    nm = lg.Layers(1).Name;
    net = dlnetwork(replaceLayer(lg, nm, ...
        imageInputLayer(inputSize3, 'Name', nm, 'Normalization', 'zscore')));
end
