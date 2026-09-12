function e = segmentExudates(img, ctx, opts)
%SEGMENTEXUDATES  Hard and soft exudate segmentation.
%
%   e = SEGMENTEXUDATES(img, ctx) where ctx carries .fov, .disc and optionally
%   .vesselMask and .fovea. Returns:
%       e.hardMask, e.softMask          logical, original image size
%       e.hardAreaDD2, e.softAreaDD2    area in square disc diameters
%       e.hardCount, e.softCount
%       e.minDistanceToFoveaDD          DRIVES THE DME ENDPOINT
%       e.areaWithin1DDofFovea
%
%   Why this detector matters most
%   ------------------------------
%   Two reasons. It has the highest achievable benchmark of any lesion (IDRiD
%   AUPR 0.885 for hard exudates - the only lesion where high numbers are
%   plausible at all). And since R3's DME decision, e.minDistanceToFoveaDD
%   directly drives a reported clinical endpoint: IDRiD grades DME risk by the
%   shortest distance from the macula centre to any hard exudate, with grade 2
%   (referable) at <= 1 disc diameter.
%
%   HARD vs SOFT
%   ------------
%   Hard exudates are lipid deposits: bright yellow, sharp-edged, often
%   clustered. Soft exudates (cotton-wool spots) are nerve-fibre infarcts:
%   paler, fluffy, indistinct margins. They are separated here on edge
%   sharpness and colour saturation, not size - the size ranges overlap.
%
%   THE OPTIC DISC MUST BE EXCLUDED. It is the brightest object in the image
%   and would otherwise be returned as one enormous exudate in every single
%   image, which is the classic failure of any brightness-threshold approach.
%
%   Soft exudate ground truth exists for only 26 of 54 IDRiD training images,
%   so that channel is the least reliable output of this module.
%
%   See also EXTRACTLESIONFEATURES, DETECTHAEMORRHAGES.

    arguments
        img (:,:,:) {mustBeNumeric}
        ctx struct
        % Candidate cutoff: median + thresholdK*std.
        %
        % ⚠️ 2.2 was the shipped default and is documented (phase3_results.md
        % §3e) as scoring precision 0.595 / recall 0.254 - "fit to display".
        % A fresh, reproducible run of EVALUATESEGMENTATION('exudates') does
        % NOT reproduce that: at k=2.2 it measures precision 0.441 / recall
        % 0.270, which does NOT clear the 0.5 display bar. Neither this
        % function nor its dependencies (detectFOV/locateOpticDisc/
        % segmentVessels) changed this session, so this is a genuine
        % discrepancy against the documented number, not a regression
        % introduced here - see docs/phase3_results.md §3e for the full
        % measured sweep and the flag raised about it.
        %
        % k=3.0 is the loosest threshold that clears 0.5 with real margin
        % (measured 0.549, vs 0.500 exactly - borderline - at k=2.6):
        %   k=2.2  recall 0.270  precision 0.441   NOT fit
        %   k=2.6  recall 0.195  precision 0.500   borderline, NOT fit
        %   k=3.0  recall 0.146  precision 0.549   fit            <- new default
        %   k=3.5  recall 0.111  precision 0.598   fit
        %   k=4.0  recall 0.081  precision 0.621   fit
        % Recall at any threshold that clears the bar is substantially below
        % the previously-claimed 0.254. Re-run EVALUATESEGMENTATION('exudates')
        % before trusting a number here - do not restate old figures.
        opts.thresholdK (1,1) double = 3.0
        % Hard-vs-soft decision boundary on the combined sharpness/yellowness
        % score. This was a bare 1.0 in the code and had never been fitted to
        % ground truth - the soft channel it produced scored precision 0.000 on
        % the held-out split (4 detections in 27 images, none correct). NaN
        % means "read the fitted value from config/exudate_split.json"; a
        % number overrides it, which is what FITEXUDATESPLIT sweeps.
        opts.splitThreshold (1,1) double = NaN
        % Per-component pixel lists, needed only by FITEXUDATESPLIT. Retaining
        % them on every call exhausted memory partway through a 27-image
        % validation run on 4288x2848 images: thousands of index vectors held
        % alongside four full-size masks and a 293 MB double conversion.
        opts.returnSplitDiagnostics (1,1) logical = false
    end

    fov = ctx.fov;
    disc = ctx.disc;
    discDiam = 2 * disc.radius;

    WORK_FOV_PX = 1024;
    scale = min(1, WORK_FOV_PX / fov.diameter);
    small = imresize(im2double(img), scale, 'bilinear');
    mask = imresize(fov.mask, scale, 'nearest');
    if size(small,3) ~= 3, small = repmat(small,1,1,3); end

    discR = disc.radius * scale;
    discDiamWork = 2 * discR;

    green = small(:,:,2);

    % Flatten illumination - otherwise a bright quadrant reads as exudate
    bg = estimateBackground(green, mask, fov.diameter * scale);
    flat = green - bg;

    valid = imerode(mask, strel('disk', max(2, round(discR * 0.10))));

    % --- exclude the optic disc -------------------------------------------
    [Y, X] = ndgrid(1:size(green,1), 1:size(green,2));
    dcx = disc.centre(1) * scale; dcy = disc.centre(2) * scale;
    discZone = sqrt((X - dcx).^2 + (Y - dcy).^2) <= discR * 1.25;
    valid = valid & ~discZone;

    % --- candidate bright regions -----------------------------------------
    vals = flat(valid);
    if isempty(vals)
        e = emptyResult(img); return
    end
    thr = median(vals) + opts.thresholdK * std(vals);
    cand = flat > thr & valid;

    % Vessels can produce bright specular reflexes along their centreline;
    % remove anything sitting on a vessel.
    if isfield(ctx, 'vesselMask') && ~isempty(ctx.vesselMask)
        vm = imresize(ctx.vesselMask, size(green), 'nearest');
        cand = cand & ~imdilate(vm, strel('disk', 2));
    end

    cand = bwareaopen(cand, max(4, round((discDiamWork * 0.01)^2)));

    % --- hard vs soft -----------------------------------------------------
    % Hard exudates have sharp margins and higher yellow saturation; soft ones
    % are fluffy and desaturated. Gradient magnitude at the boundary separates
    % them better than any intensity rule.
    gradMag = imgradient(imgaussfilt(green, 1));
    lab = rgb2lab(small);
    bStar = lab(:,:,3);            % yellow-blue axis; exudate lipid is yellow

    splitThr = opts.splitThreshold;
    if isnan(splitThr), splitThr = loadExudateSplit(); end

    cc = bwconncomp(cand, 8);
    hardMask = false(size(cand));
    softMask = false(size(cand));
    splitScores = zeros(cc.NumObjects, 1);
    for k = 1:cc.NumObjects
        px = cc.PixelIdxList{k};
        sharpness = mean(gradMag(px));
        yellowness = mean(bStar(px));

        % Scored, not OR'd. The original rule was
        %     sharpness > p75  OR  yellowness > 25
        % which sent essentially everything to the hard class: measured soft
        % exudate area was exactly 0.0000 on every image tested, because
        % passing EITHER loose condition was enough and almost every candidate
        % passes one. An OR over two permissive tests is not a classifier.
        %
        % Both cues now vote on a normalised scale and the decision is on the
        % combined score, so a region must be sharp-edged AND yellow to be
        % called hard - which is what actually distinguishes a lipid deposit
        % from a cotton-wool spot.
        sharpScore  = sharpness / max(prctile(gradMag(valid), 75), eps);
        yellowScore = yellowness / 25;
        combined = 0.5 * min(sharpScore, 2) + 0.5 * min(yellowScore, 2);

        splitScores(k) = combined;
        if combined >= splitThr
            hardMask(px) = true;
        else
            softMask(px) = true;
        end
    end

    % Diagnostics for FITEXUDATESPLIT: the per-component score and where each
    % component sits, so the boundary can be swept against ground truth without
    % re-running candidate generation once per candidate threshold.
    if opts.returnSplitDiagnostics
        e.split = struct('threshold', splitThr, 'scores', splitScores, ...
                         'pixelIdxList', {cc.PixelIdxList}, 'workSize', size(cand));
    else
        e.split = struct('threshold', splitThr, 'scores', splitScores, ...
                         'pixelIdxList', {{}}, 'workSize', size(cand));
    end

    % --- measure ----------------------------------------------------------
    e.hardMask = imresize(hardMask, [size(img,1) size(img,2)], 'nearest');
    e.softMask = imresize(softMask, [size(img,1) size(img,2)], 'nearest');

    areaScale = discDiamWork^2;
    e.hardAreaDD2 = nnz(hardMask) / max(areaScale, 1);
    e.softAreaDD2 = nnz(softMask) / max(areaScale, 1);
    ccH = bwconncomp(hardMask, 8); e.hardCount = ccH.NumObjects;
    ccS = bwconncomp(softMask, 8); e.softCount = ccS.NumObjects;

    % --- DME driver: distance from fovea to nearest hard exudate ----------
    e.minDistanceToFoveaDD = Inf;
    e.areaWithin1DDofFovea = 0;
    if isfield(ctx, 'fovea') && ~isempty(ctx.fovea) && ctx.fovea.found && any(hardMask(:))
        fx = ctx.fovea.centre(1) * scale;
        fy = ctx.fovea.centre(2) * scale;
        dists = sqrt((X - fx).^2 + (Y - fy).^2);
        e.minDistanceToFoveaDD = min(dists(hardMask)) / max(discDiamWork, 1);
        e.areaWithin1DDofFovea = nnz(hardMask & dists <= discDiamWork) / max(areaScale, 1);
    end
end


function e = emptyResult(img)
    z = false(size(img,1), size(img,2));
    e = struct('hardMask', z, 'softMask', z, 'hardAreaDD2', 0, 'softAreaDD2', 0, ...
        'hardCount', 0, 'softCount', 0, 'minDistanceToFoveaDD', Inf, ...
        'areaWithin1DDofFovea', 0);
end
