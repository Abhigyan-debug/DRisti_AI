function R = trainCandidateClassifier(opts)
%TRAINCANDIDATECLASSIFIER  Stage 2: reject false-positive lesion candidates.
%
%   R = TRAINCANDIDATECLASSIFIER() trains a small CNN on the labelled patches
%   from BUILDCANDIDATEDATASET and reports precision/recall on held-out IMAGES.
%
%   R = TRAINCANDIDATECLASSIFIER(lesion=..., maxEpochs=15, valFraction=0.25)
%
%   R = TRAINCANDIDATECLASSIFIER(lesion='microaneurysms', pool={'haemorrhages'})
%   also trains on haemorrhage candidate patches, in addition to the target
%   lesion's own. See POOLING, below - the saved model is still named and
%   evaluated for `lesion` only.
%
%   R = TRAINCANDIDATECLASSIFIER(..., hardNegativeRounds=1) adds a second
%   fine-tuning pass on the hardest false positives from round 1. See HARD
%   NEGATIVE MINING, below.
%
%   THE SPLIT IS BY IMAGE, NOT BY PATCH
%   -----------------------------------
%   Patches from one fundus image share illumination, camera, noise and often
%   the same lesion cluster. A patch-level random split puts near-duplicates on
%   both sides and reports a score that collapses the moment a new image
%   arrives. Every patch from an image goes to exactly one side here - and when
%   POOLING is used, an image never crosses the train/val split under either of
%   its lesion identities (see below).
%
%   POOLING
%   -------
%   IDRiD gives 519 MA positives and comparably few haemorrhage positives from
%   54 images each - not enough for either channel alone (round-1 measured AUC
%   0.694). A microaneurysm and a dot haemorrhage are the same underlying
%   object to a patch classifier - small, dark, round, sitting on a vessel-free
%   background - and the doc's own diagnosis is that the binding constraint is
%   DATA, not architecture. Pooling both channels' candidate patches into one
%   "real lesion vs false candidate" training set is a data-multiplier that
%   costs nothing but a training run: it does not require new ground truth,
%   only combines ground truth that already exists. The model is still
%   evaluated and shipped separately per channel (a dot haemorrhage and an MA
%   are graded differently downstream), but shares one feature extractor.
%
%   HARD NEGATIVE MINING
%   ---------------------
%   Round 1 trains on a random 3:1ish weighted sample of candidates. Most
%   negatives (vessel fragments, background noise) are trivially rejected and
%   contribute almost no gradient after a few epochs - the negatives that
%   matter are the ones round 1 gets WRONG. Round 2 scores every training
%   negative with the round-1 model, keeps the highest-scoring (hardest) third,
%   oversamples them 3x alongside the original data, and fine-tunes from the
%   round-1 weights for a few more epochs. This directly targets the failure
%   mode that limits precision - a near-miss look-alike scored as a lesion -
%   rather than hoping more random epochs stumble onto it.
%
%   TEST-TIME AUGMENTATION
%   -----------------------
%   A lesion patch has no canonical orientation (see AUGPATCH), so the trained
%   classifier's output should not depend on how the patch happened to be cut.
%   Scoring is averaged over the 8 dihedral views (identity, 3 rotations, and
%   their horizontal flip) both when measuring validation AUC and inside
%   DETECTDARKLESIONS at inference. This is free precision/recall - it costs
%   8x the forward passes on a network small enough that this is still fast.
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
%   PATCH GEOMETRY
%   --------------
%   Training patches come from BUILDCANDIDATEDATASET, which cuts them at the
%   WORKING scale (FOV normalised to 1536 px) via CUTCANDIDATEPATCHES - the
%   same geometry DETECTDARKLESIONS scores at. They used to be cut at full
%   resolution here and at working scale there, roughly a 2x difference on
%   IDRiD. The saved model records meta.patchGeometry so a model from before
%   the fix cannot be loaded into the corrected pipeline; retrain instead.
%
%   See also BUILDCANDIDATEDATASET, CUTCANDIDATEPATCHES, DETECTDARKLESIONS,
%   EVALUATETWOSTAGEDETECTOR.

    arguments
        opts.lesion (1,:) char {mustBeMember(opts.lesion,{'microaneurysms','haemorrhages'})} = 'microaneurysms'
        opts.pool (1,:) cell = {}
        % Must match the threshSD BUILDCANDIDATEDATASET was run with - candidate
        % directories are versioned by threshold (see its header note on why).
        opts.threshSD (1,1) double = 0.75
        % A ceiling, not a target - ValidationPatience below stops training once
        % validation loss stops improving, which on the pooled+loosened dataset
        % (2-3x the original candidate volume) happens well before 20 epochs.
        % Running the full ceiling regardless would burn GPU time for no gain,
        % since OutputNetwork='best-validation' already discards the extra
        % epochs' weights - measured during development: validation loss had
        % plateaued by epoch ~3-4 of ~300 iterations each.
        opts.maxEpochs (1,1) double = 20
        opts.validationPatience (1,1) double = 4
        opts.valFraction (1,1) double = 0.25
        opts.inputPx (1,1) double = 48
        opts.seed (1,1) double = 0
        opts.hardNegativeRounds (1,1) double {mustBeInteger, mustBeInRange(opts.hardNegativeRounds,0,3)} = 1
        opts.hardNegativeFrac (1,1) double = 0.33   % fraction of negatives kept as "hard"
        opts.tta (1,1) logical = true
        opts.outFile (1,:) char = ''                % '' = default naming from `lesion`
    end

    cfg = drishti_paths();
    rng(opts.seed);

    channels = [{opts.lesion}, opts.pool];
    files = strings(0,1); labels = false(0,1); imgId = strings(0,1); srcLesion = strings(0,1);

    thrTag = strrep(sprintf('%.2f', opts.threshSD), '.', '');
    for c = channels
        root = fullfile(cfg.dataRoot, '_cache', sprintf('candidates_%s_t%s', c{1}, thrTag));
        if ~isfolder(root)
            error('drishti:noCandidates', ...
                'No candidate dataset at %s. Run buildCandidateDataset(''lesion'',''%s'',''threshSD'',%.2f) first.', ...
                root, c{1}, opts.threshSD);
        end
        posL = dir(fullfile(root, 'pos', '*.png'));
        negL = dir(fullfile(root, 'neg', '*.png'));
        f = [string(fullfile(root,'pos',{posL.name}))'; string(fullfile(root,'neg',{negL.name}))'];
        lb = [true(numel(posL),1); false(numel(negL),1)];
        [~, stems] = arrayfun(@(x) fileparts(x), f, 'UniformOutput', false);
        % Prefix the image id with its channel: an IDRiD_07 candidate from the
        % MA generator and one from the haemorrhage generator are different
        % crops of the same picture and must both land on the same side of the
        % split, but they are tracked distinctly for reporting.
        ii = c{1} + "/" + regexprep(string(stems), '_\d+$', '');
        files = [files; f]; labels = [labels; lb]; imgId = [imgId; ii]; %#ok<AGROW>
        srcLesion = [srcLesion; repmat(string(c{1}), numel(f), 1)]; %#ok<AGROW>
        fprintf('  pooled %-15s %5d pos / %6d neg  (%d images)\n', c{1}, ...
            numel(posL), numel(negL), numel(unique(erase(ii, c{1}+"/"))));
    end

    % Split by the UNDERLYING image, not by the channel-prefixed id: the same
    % fundus photo must not appear in train under one channel and val under
    % another, or its illumination/noise signature leaks across the split.
    baseImg = regexprep(imgId, '^[a-z]+/', '');
    uImgs = unique(baseImg);
    nVal = max(1, round(opts.valFraction * numel(uImgs)));
    valImgs = uImgs(randperm(numel(uImgs), nVal));
    isVal = ismember(baseImg, valImgs);

    fprintf('  %d underlying images -> %d train / %d val (split by IMAGE, shared across pooled channels)\n', ...
        numel(uImgs), numel(uImgs)-nVal, nVal);

    % Report the target channel's own held-out slice, since that is what gets
    % shipped and evaluated - pooled channels only ever add training signal.
    ownVal = isVal & srcLesion == opts.lesion;
    fprintf('  %s: %d train (%d pos) | %d val (%d pos)\n', opts.lesion, ...
        nnz(~isVal & srcLesion==opts.lesion), nnz(~isVal & srcLesion==opts.lesion & labels), ...
        nnz(ownVal), nnz(ownVal & labels));
    if nnz(ownVal & labels) < 5
        warning('drishti:fewValPositives', ...
            'Only %d positive validation patches for %s - the estimate will be very noisy.', ...
            nnz(ownVal & labels), opts.lesion);
    end

    inSz = [opts.inputPx opts.inputPx 3];
    trFiles = files(~isVal); trLabels = labels(~isVal);
    net = buildNet(inSz);

    [net, w] = trainRound(net, trFiles, trLabels, inSz, opts, 'round 1 (all candidates)');

    if opts.hardNegativeRounds > 0
        for r = 1:opts.hardNegativeRounds
            hardIdx = mineHardNegatives(net, trFiles, trLabels, inSz, opts.hardNegativeFrac);
            % Oversample the hardest negatives 3x alongside the untouched
            % original set - this is additive, not a replacement, so round 2
            % cannot forget what round 1 already got right.
            trFiles2 = [trFiles; repmat(trFiles(hardIdx), 3, 1)];
            trLabels2 = [trLabels; repmat(trLabels(hardIdx), 3, 1)];
            [net, w] = trainRound(net, trFiles2, trLabels2, inSz, opts, ...
                sprintf('round %d (hard-negative fine-tune, %d mined)', r+1, numel(hardIdx)));
        end
    end

    % ---- evaluate on the TARGET CHANNEL's held-out images only ------------
    valFiles = files(ownVal);
    yv = labels(ownVal);
    if opts.tta
        scores = predictPatchesTTA(net, valFiles, inSz);
    else
        scores = predictPatches(net, valFiles, inSz);
    end

    [~, ~, ~, auc] = perfcurve(yv, scores, true);
    R = struct();
    R.auc = auc;
    R.nValPatches = numel(yv);
    R.nValPositives = nnz(yv);
    R.valImages = valImgs;
    R.pooled = string(opts.pool);
    R.hardNegativeRounds = opts.hardNegativeRounds;

    R.sweep = table();
    cand = [0.5 0.7 0.9 0.95 0.97 0.99];
    for t = cand
        pred = scores >= t;
        tp = nnz(pred & yv); fp = nnz(pred & ~yv); fn = nnz(~pred & yv);
        R.sweep = [R.sweep; table(t, tp/max(tp+fp,1), tp/max(tp+fn,1), nnz(pred), ...
            'VariableNames', {'threshold','precision','recall','nKept'})];
    end

    outFile = opts.outFile;
    if isempty(outFile)
        outFile = fullfile(cfg.modelsDir, ['candidate_classifier_' opts.lesion '.mat']);
    end
    poolNote = '';
    if ~isempty(opts.pool)
        poolNote = sprintf(' Trained with pooled candidates from: %s.', strjoin(opts.pool, ', '));
    end
    % PATCHGEOMETRY is a compatibility stamp, not documentation. Patches used
    % to be cut from the full-resolution frame here and from the working-scale
    % frame at inference - a ~2x scale mismatch that produced no error and no
    % warning. LOADCANDIDATECLASSIFIERS refuses any model without this stamp,
    % so a classifier trained before the fix cannot be silently loaded into the
    % corrected pipeline and mismatch the other way. Bump the version if the
    % geometry ever changes again.
    meta = struct('lesion', opts.lesion, 'pooled', {cellstr(opts.pool)}, 'inputSize', inSz, ...
        'patchGeometry', 'workingScale/v2', ...
        'threshSD', opts.threshSD, 'valImages', {cellstr(valImgs)}, 'auc', auc, 'tta', opts.tta, ...
        'hardNegativeRounds', opts.hardNegativeRounds, 'trainedAt', string(datetime('now')), ...
        'note', ['Stage-2 false-positive classifier. Split by IMAGE. Final ' ...
                 'recall is capped by generator recall, which this cannot raise. ' ...
                 'Candidates must be generated at the SAME threshSD (meta.threshSD) ' ...
                 'this classifier was trained on, or the operating point mismatches.' poolNote]);
    % scoreCandidates (in detectDarkLesions.m) expects the saved file to
    % contain a variable literally named `trained` - saveTrainedNet's
    % parameter is named that so `save` picks it up from its own scope.
    saveTrainedNet(outFile, net, meta);

    fprintf('\n  patch-level AUC %.4f on %d held-out patches (%d positive)%s\n', ...
        auc, R.nValPatches, R.nValPositives, ternary(opts.tta,' [TTA]',''));
    disp(R.sweep);
    fprintf('  saved -> %s\n', outFile);
end


% ------------------------------------------------------------------ helpers

function net = buildNet(inSz)
    % Same small purpose-built CNN as before. A 48x48 patch of retina is not
    % ImageNet, and upsampling it to 224 to reuse a pretrained backbone spends
    % most of the compute on interpolated pixels.
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
end

function [net, w] = trainRound(net, trFiles, trLabels, inSz, opts, label)
    % The internal early-stopping split must ALSO be by image, not by patch -
    % patches from one photo share illumination and noise, so a patch-level
    % split here would silently reintroduce the exact leakage the outer
    % train/val split exists to prevent, just one level down.
    valFrac = 0.15;
    [~, stems] = arrayfun(@(f) fileparts(f), trFiles, 'UniformOutput', false);
    stemId = regexprep(string(stems), '_\d+$', '');
    rng(opts.seed);
    uStems = unique(stemId);
    nEarlyVal = max(1, round(valFrac * numel(uStems)));
    earlyValStems = uStems(randperm(numel(uStems), nEarlyVal));
    isEarlyVal = ismember(stemId, earlyValStems);

    trainDS = patchDatastore(trFiles(~isEarlyVal), trLabels(~isEarlyVal), inSz, true);
    valDS   = patchDatastore(trFiles(isEarlyVal),  trLabels(isEarlyVal),  inSz, false);

    nPos = nnz(trLabels(~isEarlyVal)); nNeg = nnz(~trLabels(~isEarlyVal));
    w = [1, nNeg/max(nPos,1)];
    w = w / sum(w) * 2;
    fprintf('  [%s] %d patches (%d pos) | class weights [neg pos]: %s\n', ...
        label, numel(trFiles), nnz(trLabels), mat2str(round(w,2)));

    % Validate once per EPOCH, not every 50 iterations. At the finer frequency,
    % validation loss on a small, still-settling (BatchNorm) network is noisy
    % enough that ValidationPatience=4 triggered a stop after under one epoch
    % on the first run here - the network barely left its initial state and
    % AUC came out WORSE than the un-early-stopped original (0.634 vs 0.694).
    % Patience now counts full epochs, matching what "4 epochs with no
    % improvement" is supposed to mean.
    itersPerEpoch = max(1, floor(numel(trFiles(~isEarlyVal)) / 128));

    if gpuDeviceCount('available') > 0, env='gpu'; else, env='cpu'; end
    tOpts = trainingOptions('adam', ...
        'InitialLearnRate', 1e-3, ...
        'MaxEpochs', opts.maxEpochs, ...
        'MiniBatchSize', 128, ...
        'ValidationData', valDS, ...
        'ValidationFrequency', itersPerEpoch, ...
        'ValidationPatience', opts.validationPatience, ...
        'OutputNetwork', 'best-validation', ...
        'Shuffle', 'every-epoch', ...
        'ExecutionEnvironment', env, ...
        'Verbose', true, 'VerboseFrequency', 50, 'Plots', 'none');

    lossFcn = @(Y,T) crossentropy(Y, T, w, 'NormalizationFactor','all-elements','WeightsFormat','C');
    net = trainnet(trainDS, net, lossFcn, tOpts);
end

function hardIdx = mineHardNegatives(net, files, labels, inSz, frac)
%MINEHARDNEGATIVES  The negatives round 1 was most fooled by.
    negIdx = find(~labels);
    scores = predictPatches(net, files(negIdx), inSz);
    [~, ord] = sort(scores, 'descend');
    k = max(1, round(frac * numel(negIdx)));
    hardIdx = negIdx(ord(1:k));
    fprintf('  mined %d hard negatives (mean score %.3f, vs %.3f over all negatives)\n', ...
        k, mean(scores(ord(1:k))), mean(scores));
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

function s = predictPatchesTTA(net, files, inSz)
%PREDICTPATCHESTTA  Average the score over the 8 dihedral views of each patch.
%
%   A lesion patch has no canonical orientation (see AUGPATCH), so a
%   classifier that is even slightly orientation-sensitive is discarding free
%   signal. Averaging over the dihedral group is the standard fix and costs
%   only extra forward passes on a network this small.
    n = numel(files);
    s = nan(n,1);
    for i = 1:64:n
        j = min(i+63, n);
        m = j-i+1;
        X = zeros([inSz(1:2) 3 m*8], 'single');
        col = 0;
        for k = i:j
            p0 = prepPatch(imread(files(k)), inSz);
            views = {p0, fliplr(p0), flipud(p0), rot90(p0,1), rot90(p0,2), rot90(p0,3), ...
                     fliplr(rot90(p0,1)), fliplr(rot90(p0,2))};
            for v = 1:8
                col = col + 1;
                X(:,:,:,col) = views{v};
            end
        end
        Y = predict(net, dlarray(X,'SSCB'));
        P = double(gather(extractdata(Y)))';
        p2 = reshape(P(:,2), 8, m);
        s(i:j) = mean(p2, 1)';
    end
end

function saveTrainedNet(outFile, trained, meta) %#ok<INUSD>
    save(outFile, 'trained', 'meta', '-v7.3');
end

function o = ternary(cond, a, b)
    if cond, o = a; else, o = b; end
end
