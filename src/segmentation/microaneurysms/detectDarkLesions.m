function d = detectDarkLesions(img, ctx, opts)
%DETECTDARKLESIONS  Microaneurysms and haemorrhages in one pass.
%
%   d = DETECTDARKLESIONS(img, ctx) returns both, because they are the SAME
%   detection problem separated only at the classification step:
%       d.maMask, d.maCount, d.maDensityPerDD2, d.maCountWithin1DD
%       d.haemMask, d.haemCount, d.haemAreaDD2, d.haemLargestAreaDD2
%       d.haemByType  struct(dot, blot, flame)
%
%   Why one function
%   ----------------
%   A microaneurysm and a dot haemorrhage are both small, round, dark, and red.
%   They are the same object to any detector; the clinical distinction is size
%   (MAs < 125 microns by convention) and they are graded differently only
%   because that size threshold approximates capillary versus larger bleed.
%   Detecting them separately would mean running the same candidate extraction
%   twice and then disagreeing with itself about borderline objects.
%
%   ⚠️ THE MICROANEURYSM CHANNEL DOES NOT WORK. MEASURED, NOT ASSUMED.
%
%   Against IDRiD's MA ground-truth masks:
%       per-lesion recall 0.110, precision 0.022, 14.5x over-detection
%
%   i.e. it misses ~89% of real microaneurysms and ~98% of what it reports is
%   not a microaneurysm. A parameter sweep confirms this is not a tuning
%   problem - precision never exceeds 0.022 at ANY threshold, and tightening
%   the threshold to make the count look plausible simply destroys recall:
%
%       threshSD 1.5 -> recall 0.166  precision 0.019   (26x over-detection)
%       threshSD 2.0 -> recall 0.110  precision 0.022   (14.5x)
%       threshSD 3.0 -> recall 0.007  precision 0.003   (1.0x - plausible
%                                      count, detecting essentially nothing)
%
%   That last row is the trap: a count that LOOKS right while being wrong.
%
%   Morphological MA detection without learned false-positive rejection is a
%   known-hard problem; the best result ever recorded on IDRiD is AUPR 0.5017
%   (iFLYTEK-MIG) using a cascaded CNN ensemble. Fixing this needs a trained
%   FP classifier over these candidates, not better morphology.
%
%   CONSEQUENCE: d.maCount must NOT be shown to a clinician as a finding, and
%   is flagged unreliable in the feature contract. The candidates are retained
%   because they are the right input to a future FP classifier, and because
%   Phase 3 measured that lesion features add nothing to the CNN anyway.
%   The haemorrhage channel shares this pipeline and should be treated with
%   the same suspicion until measured separately.
%
%   The dot / blot / flame split follows the shape rule R3 should confirm:
%   dot = small and round, blot = larger and round, flame = elongated
%   (following the nerve fibre layer). Eccentricity separates flame from the
%   other two; area separates dot from blot.
%
%   See also SEGMENTEXUDATES, EXTRACTLESIONFEATURES.

    arguments
        img (:,:,:) {mustBeNumeric}
        ctx struct
        opts.threshSD (1,1) double = 2.0
        % Stage-2 false-positive classifier. When supplied, every MA candidate
        % is scored and low-scoring ones are discarded. This can only REMOVE
        % candidates - it cannot recover a lesion the generator never proposed,
        % so recall stays capped by generator recall.
        opts.candidateClassifier struct = struct()
        opts.classifierThreshold (1,1) double = 0.5
    end

    fov = ctx.fov;
    disc = ctx.disc;

    WORK_FOV_PX = 1536;   % higher than other detectors: MAs are tiny
    scale = min(1, WORK_FOV_PX / fov.diameter);
    small = imresize(im2double(img), scale, 'bilinear');
    mask = imresize(fov.mask, scale, 'nearest');
    if size(small,3) ~= 3, small = repmat(small,1,1,3); end

    discR = disc.radius * scale;
    discDiamWork = 2 * discR;
    green = small(:,:,2);

    % Dark lesions are dark in GREEN. Flatten first so vignetting does not
    % read as a giant haemorrhage.
    bg = estimateBackground(green, mask, fov.diameter * scale);
    flat = bg - green;                     % positive where darker than local bg
    valid = imerode(mask, strel('disk', max(2, round(discR * 0.10))));

    % Exclude the disc: the cup and the vessels emerging from it are dark and
    % would flood the candidate list.
    [Y, X] = ndgrid(1:size(green,1), 1:size(green,2));
    dcx = disc.centre(1) * scale; dcy = disc.centre(2) * scale;
    valid = valid & sqrt((X-dcx).^2 + (Y-dcy).^2) > discR * 1.2;

    % Remove vessels - they are dark and elongated and would otherwise be
    % returned as thousands of flame haemorrhages. This is exactly why the
    % vessel segmenter had to exist first.
    if isfield(ctx, 'vesselMask') && ~isempty(ctx.vesselMask)
        vm = imresize(ctx.vesselMask, size(green), 'nearest');
        valid = valid & ~imdilate(vm, strel('disk', max(1, round(discR*0.03))));
    end

    vals = flat(valid);
    if isempty(vals)
        d = emptyResult(img); return
    end
    thr = median(vals) + opts.threshSD * std(vals);
    cand = flat > thr & valid;
    cand = imopen(cand, strel('disk', 1));

    % Size bounds in disc diameters. An MA is ~1/12 DD across at most; anything
    % bigger than ~0.5 DD is not a discrete lesion.
    minArea = max(3, round((discDiamWork * 0.004)^2 * pi));
    maxArea = round((discDiamWork * 0.5)^2 * pi);
    cand = bwareaopen(cand, minArea);

    cc = bwconncomp(cand, 8);
    stats = regionprops(cc, 'Area', 'Eccentricity', 'Centroid', 'Solidity');

    maMask = false(size(cand));
    haemMask = false(size(cand));
    nDot = 0; nBlot = 0; nFlame = 0;
    maCentroids = zeros(0, 2);
    haemCentroids = zeros(0, 2);

    % MA size cut: 125 microns. A disc is ~1800 microns, so the threshold is
    % about 0.07 disc diameters - this is the conventional clinical boundary
    % expressed in our camera-independent units.
    maAreaMax = pi * (discDiamWork * 0.035)^2;

    for k = 1:cc.NumObjects
        s = stats(k);
        if s.Area > maxArea, continue; end
        px = cc.PixelIdxList{k};
        if s.Area <= maAreaMax && s.Eccentricity < 0.85
            maMask(px) = true;
            maCentroids(end+1, :) = s.Centroid; %#ok<AGROW>
        else
            haemMask(px) = true;
            haemCentroids(end+1, :) = s.Centroid; %#ok<AGROW>
            if s.Eccentricity > 0.88
                nFlame = nFlame + 1;         % elongated, follows nerve fibres
            elseif s.Area > pi * (discDiamWork * 0.08)^2
                nBlot = nBlot + 1;
            else
                nDot = nDot + 1;
            end
        end
    end

    % --- stage 2: false-positive rejection --------------------------------
    % ⚠️ Routed by which channel the supplied classifier was TRAINED for
    % (meta.lesion). A classifier trained on microaneurysm candidates has never
    % seen a haemorrhage-sized patch and should not silently be applied to that
    % channel, or vice versa. This was previously unconditional-on-MA-only:
    % passing a classifier while evaluating haemorrhages filtered nothing at
    % all (haemMask was never touched), and "stage 1 + classifier" silently
    % equalled "stage 1 alone" - caught via EVALUATETWOSTAGEDETECTOR('haemorrhages')
    % showing identical numbers with and without the classifier.
    targetLesion = '';
    if isfield(opts.candidateClassifier, 'meta') && isfield(opts.candidateClassifier.meta, 'lesion')
        targetLesion = char(opts.candidateClassifier.meta.lesion);
    end

    if isfield(opts.candidateClassifier, 'trained') && strcmp(targetLesion, 'microaneurysms') ...
            && ~isempty(maCentroids)
        keep = scoreCandidates(small, maCentroids, opts.candidateClassifier, ...
                               opts.classifierThreshold, scale);
        ccMA = bwconncomp(maMask, 8);
        drop = false(size(maMask));
        for q = 1:ccMA.NumObjects
            if q <= numel(keep) && ~keep(q)
                drop(ccMA.PixelIdxList{q}) = true;
            end
        end
        maMask(drop) = false;
        maCentroids = maCentroids(keep(1:min(numel(keep), size(maCentroids,1))), :);
    elseif isfield(opts.candidateClassifier, 'trained') && strcmp(targetLesion, 'haemorrhages') ...
            && ~isempty(haemCentroids)
        keep = scoreCandidates(small, haemCentroids, opts.candidateClassifier, ...
                               opts.classifierThreshold, scale);
        ccH = bwconncomp(haemMask, 8);
        drop = false(size(haemMask));
        for q = 1:ccH.NumObjects
            if q <= numel(keep) && ~keep(q)
                drop(ccH.PixelIdxList{q}) = true;
            end
        end
        haemMask(drop) = false;
        haemCentroids = haemCentroids(keep(1:min(numel(keep), size(haemCentroids,1))), :);
        % dot/blot/flame counts were tallied before filtering and are not
        % recomputed here - haemByType is a shape breakdown of the RAW
        % candidate set, not a claim about the filtered one.
    end

    % --- measure ----------------------------------------------------------
    areaScale = discDiamWork^2;
    d.maMask = imresize(maMask, [size(img,1) size(img,2)], 'nearest');
    d.haemMask = imresize(haemMask, [size(img,1) size(img,2)], 'nearest');

    d.maCount = size(maCentroids, 1);
    fovArea = nnz(valid) / max(areaScale, 1);
    d.maDensityPerDD2 = d.maCount / max(fovArea, eps);

    d.maCountWithin1DD = 0;
    if isfield(ctx,'fovea') && ~isempty(ctx.fovea) && ctx.fovea.found && d.maCount > 0
        fx = ctx.fovea.centre(1) * scale; fy = ctx.fovea.centre(2) * scale;
        dd = hypot(maCentroids(:,1) - fx, maCentroids(:,2) - fy);
        d.maCountWithin1DD = nnz(dd <= discDiamWork);
    end

    ccH = bwconncomp(haemMask, 8);
    d.haemCount = ccH.NumObjects;
    d.haemAreaDD2 = nnz(haemMask) / max(areaScale, 1);
    if ccH.NumObjects > 0
        areas = cellfun(@numel, ccH.PixelIdxList);
        d.haemLargestAreaDD2 = max(areas) / max(areaScale, 1);
    else
        d.haemLargestAreaDD2 = 0;
    end
    d.haemByType = struct('dot', nDot, 'blot', nBlot, 'flame', nFlame);
end


function keep = scoreCandidates(small, centroids, C, thr, scale)
%SCORECANDIDATES  Run the stage-2 classifier over candidate patches.
%
%   Patches are cut at the SAME size the classifier was trained on, from the
%   working-scale image. A size mismatch here silently degrades the classifier
%   without erroring, which is why the size comes from the saved metadata
%   rather than being hardcoded.
%
%   TEST-TIME AUGMENTATION. A lesion patch has no canonical orientation, so the
%   score is averaged over all 8 dihedral views when the saved model was
%   trained with TTA (meta.tta) - matching how it was validated. Scoring one
%   orientation at inference while validating on 8 would silently under-deliver
%   the measured operating point.

    inSz = C.meta.inputSize;
    half = floor(inSz(1)/2);
    n = size(centroids, 1);
    keep = true(n, 1);
    useTTA = isfield(C.meta, 'tta') && C.meta.tta;
    nViews = 1; if useTTA, nViews = 8; end

    patches = zeros([inSz(1:2) 3 n*nViews], 'single');
    valid = false(n,1);
    for q = 1:n
        ctr = round(centroids(q,:));
        r1 = ctr(2)-half; r2 = ctr(2)+half-1;
        c1 = ctr(1)-half; c2 = ctr(1)+half-1;
        if r1 < 1 || c1 < 1 || r2 > size(small,1) || c2 > size(small,2)
            continue    % keep edge candidates rather than discard unscored
        end
        pch = single(small(r1:r2, c1:c2, :));
        if size(pch,3) == 1, pch = repmat(pch,1,1,3); end
        base = (q-1)*nViews;
        if useTTA
            views = {pch, fliplr(pch), flipud(pch), rot90(pch,1), rot90(pch,2), ...
                     rot90(pch,3), fliplr(rot90(pch,1)), fliplr(rot90(pch,2))};
            for v = 1:8
                patches(:,:,:,base+v) = views{v};
            end
        else
            patches(:,:,:,base+1) = pch;
        end
        valid(q) = true;
    end

    if ~any(valid), return; end
    validCols = false(1, n*nViews);
    for q = find(valid)'
        validCols((q-1)*nViews+1 : q*nViews) = true;
    end
    Y = predict(C.trained, dlarray(patches(:,:,:,validCols), 'SSCB'));
    P = double(gather(extractdata(Y)))';
    scAll = P(:,2);
    sc = mean(reshape(scAll, nViews, nnz(valid)), 1)';
    keep(valid) = sc >= thr;
end


function d = emptyResult(img)
    z = false(size(img,1), size(img,2));
    d = struct('maMask', z, 'haemMask', z, 'maCount', 0, 'maDensityPerDD2', 0, ...
        'maCountWithin1DD', 0, 'haemCount', 0, 'haemAreaDD2', 0, ...
        'haemLargestAreaDD2', 0, ...
        'haemByType', struct('dot',0,'blot',0,'flame',0));
end
