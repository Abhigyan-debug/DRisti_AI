function d = detectDarkLesions(img, ctx, opts)
%DETECTDARKLESIONS  Microaneurysms and haemorrhages in one pass.
%
%   d = DETECTDARKLESIONS(img, ctx) returns both, because they are the SAME
%   detection problem separated only at the classification step:
%       d.maMask, d.maCount, d.maDensityPerDD2, d.maCountWithin1DD
%       d.haemMask, d.haemCount, d.haemAreaDD2, d.haemLargestAreaDD2
%       d.haemByType  struct(dot, blot, flame)
%
%   d = DETECTDARKLESIONS(..., 'returnCandidates', true) additionally returns
%   d.candidates - the PRE-filter candidate set in working-scale coordinates,
%   which is what BUILDCANDIDATEDATASET needs in order to cut training patches
%   with the same geometry inference uses. See CUTCANDIDATEPATCHES.
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
%   NEITHER DARK-LESION CHANNEL IS VALIDATED FOR DISPLAY.
%
%   Last held-out measurement (IDRiD segmentation TEST split, n=27, FOV-masked,
%   per-lesion component matching, micro-averaged - VALIDATELESIONDETECTORS):
%
%       microaneurysms  precision 0.028  recall 0.409
%       haemorrhages    precision 0.164  recall 0.311
%
%   against a display gate of precision >= 0.50 AND recall >= 0.10 frozen in
%   config/lesion_validation_thresholds.json. Both fail. Neither count reaches
%   a clinician: EXTRACTLESIONFEATURES reads the verdict from
%   results/lesion_validation.mat and fails closed.
%
%   Re-measured 2026-09-13 after the five defects listed below were fixed - the
%   fifth being a hardcoded stage-2 threshold of 0.5 nobody had chosen, now
%   selected on TRAIN by FITLESIONOPERATINGPOINT. REBUILDDARKLESIONDETECTORS
%   retrained both classifiers under the current patchGeometry stamp; stage 1
%   alone won on both channels, so applyClassifier = false is what ships.
%
%   What the fixes bought: recall. Both channels now CLEAR the recall gate and
%   fail on precision alone (MA recall 0.077 -> 0.409, HE recall 0.054 ->
%   0.311, HE F1 0.077 -> 0.215). MA precision moved the wrong way, 0.046 ->
%   0.028, because stage 2 is off and the candidate pool roughly tripled - the
%   old figure was bought by a classifier discarding candidates on a
%   train/serve geometry mismatch. The verdict is unchanged: not displayed.
%   Superseded figures, do not restate: MA 0.046/0.077, HE 0.130/0.054.
%
%   Morphological MA detection without learned false-positive rejection is a
%   known-hard problem; the best result ever recorded on IDRiD is AUPR 0.5017
%   (iFLYTEK-MIG) using a cascaded CNN ensemble. The binding constraint is
%   annotated data - 519 MA positives from 54 images - not architecture.
%
%   THE FOUR DEFECTS
%   ----------------
%   1. PATCH SCALE. Training patches were cut from the full-resolution frame,
%      inference patches from the working-scale frame. On IDRiD that is a 2.1x
%      difference in the retinal area behind a 48 px patch. Both paths now go
%      through CUTCANDIDATEPATCHES, whose header carries the full account.
%
%   2. EDGE CANDIDATES. The builder dropped candidates too close to the frame
%      to cut; the scorer kept them UNSCORED, so they bypassed the
%      false-positive filter entirely. IDRiD's FOV is flush with the top and
%      bottom of the frame, so this leaked unfiltered candidates on every
%      image. Now clamped identically on both sides.
%
%   3. GENERATOR THRESHOLD. The classifiers were trained on candidates
%      generated at meta.threshSD, but the production path -
%      EXTRACTLESIONFEATURES and VALIDATELESIONDETECTORS - called this function
%      with no threshSD at all and got the 2.0 default. A classifier trained to
%      sort a dense, permissive candidate set was applied to a sparse, strict
%      one. EVALUATETWOSTAGEDETECTOR had honoured meta.threshSD since it was
%      written, which is why its numbers and the validated numbers disagreed
%      and nobody could reconcile them. threshSD now defaults to NaN meaning
%      "adopt the classifier's own", so the two can no longer drift.
%
%   4. FRAGMENT MISROUTING. The MA/haemorrhage split was
%          area <= maAreaMax && eccentricity < 0.85  ->  MA,  else -> haemorrhage
%      so a five-pixel elongated vessel remnant - far too small to be any kind
%      of haemorrhage - was booked as a FLAME HAEMORRHAGE. Eccentricity was
%      acting as a router when it should have been acting as a reject. Size is
%      the clinical discriminator; small-and-elongated is now discarded as a
%      fragment. Set 'fragmentRejection', false to reproduce the old routing.
%
%   The dot / blot / flame split follows the shape rule R3 should confirm:
%   dot = small and round, blot = larger and round, flame = elongated
%   (following the nerve fibre layer). Eccentricity separates flame from the
%   other two; area separates dot from blot. The tally is taken AFTER stage-2
%   filtering - it used to describe the raw candidate set, so haemByType could
%   sum to more objects than haemCount reported.
%
%   See also CUTCANDIDATEPATCHES, LOADLESIONOPERATINGPOINTS, SEGMENTEXUDATES,
%   EXTRACTLESIONFEATURES.

    arguments
        img (:,:,:) {mustBeNumeric}
        ctx struct
        % NaN = adopt the supplied classifier's meta.threshSD, falling back to
        % 2.0 when no classifier is supplied. An explicit value always wins,
        % and disables any classifier that was trained at a different one -
        % see resolveGenerator.
        opts.threshSD (1,1) double = NaN
        % Stage-2 false-positive classifier. When supplied, every candidate is
        % scored and low-scoring ones are discarded. This can only REMOVE
        % candidates - it cannot recover a lesion the generator never proposed,
        % so recall stays capped by generator recall.
        % One classifier, or several. Each is routed to the channel it was
        % TRAINED for (meta.lesion). Untyped so a cell array of classifiers is
        % accepted alongside the original single-struct form.
        opts.candidateClassifier = struct()
        % NaN = read the frozen per-channel operating point from
        % config/lesion_operating_points.json. The old hardcoded 0.5 was the
        % loosest point on the score sweep and nobody had chosen it.
        opts.classifierThreshold (1,1) double = NaN
        opts.fragmentRejection (1,1) logical = true
        opts.returnCandidates (1,1) logical = false
    end

    fov = ctx.fov;
    disc = ctx.disc;

    CC = normaliseClassifiers(opts.candidateClassifier);
    [threshSD, CC] = resolveGenerator(opts.threshSD, CC);
    OP = loadLesionOperatingPoints();

    WORK_FOV_PX = 1536;   % higher than other detectors: MAs are tiny
    scale = min(1, WORK_FOV_PX / fov.diameter);
    small = resizeToDouble(img, scale);
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
        d = emptyResult(img, opts.returnCandidates); return
    end
    thr = median(vals) + threshSD * std(vals);
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
    maCentroids = zeros(0, 2);
    haemCentroids = zeros(0, 2);
    haemArea = zeros(0, 1);
    haemEcc = zeros(0, 1);

    % MA size cut: 125 microns. A disc is ~1800 microns, so the threshold is
    % about 0.07 disc diameters - this is the conventional clinical boundary
    % expressed in our camera-independent units.
    maAreaMax = pi * (discDiamWork * 0.035)^2;

    for k = 1:cc.NumObjects
        s = stats(k);
        if s.Area > maxArea, continue; end
        px = cc.PixelIdxList{k};
        if s.Area <= maAreaMax
            % Small. Round enough to be a microaneurysm, or a fragment.
            if s.Eccentricity < 0.85
                maMask(px) = true;
                maCentroids(end+1, :) = s.Centroid; %#ok<AGROW>
            elseif ~opts.fragmentRejection
                % Defect 4, preserved behind a flag so the change can be
                % measured against the old routing on the TRAIN split rather
                % than asserted.
                haemMask(px) = true;
                haemCentroids(end+1, :) = s.Centroid; %#ok<AGROW>
                haemArea(end+1, 1) = s.Area;          %#ok<AGROW>
                haemEcc(end+1, 1) = s.Eccentricity;   %#ok<AGROW>
            end
            % else: small and elongated -> a vessel remnant or a noise streak.
            % Too small to be any grade of haemorrhage, too elongated to be an
            % MA. Belongs to neither channel.
        else
            haemMask(px) = true;
            haemCentroids(end+1, :) = s.Centroid; %#ok<AGROW>
            haemArea(end+1, 1) = s.Area;          %#ok<AGROW>
            haemEcc(end+1, 1) = s.Eccentricity;   %#ok<AGROW>
        end
    end

    if opts.returnCandidates
        d.candidates = struct( ...
            'workImage', small, ...
            'scale', scale, ...
            'workSize', size(green), ...
            'discDiamWork', discDiamWork, ...
            'threshSD', threshSD, ...
            'microaneurysms', struct('centroids', maCentroids, 'mask', maMask), ...
            'haemorrhages',   struct('centroids', haemCentroids, 'mask', haemMask), ...
            'note', ['PRE-filter candidates in WORKING-SCALE coordinates. ' ...
                     'Cut patches with CUTCANDIDATEPATCHES so training and ' ...
                     'inference share one geometry.']);
    end

    % --- stage 2: false-positive rejection --------------------------------
    % Routed by which channel the supplied classifier was TRAINED for
    % (meta.lesion). A classifier trained on microaneurysm candidates has never
    % seen a haemorrhage-sized patch and should not silently be applied to that
    % channel, or vice versa. This was previously unconditional-on-MA-only:
    % passing a classifier while evaluating haemorrhages filtered nothing at
    % all (haemMask was never touched), and "stage 1 + classifier" silently
    % equalled "stage 1 alone" - caught via EVALUATETWOSTAGEDETECTOR('haemorrhages')
    % showing identical numbers with and without the classifier. It was then a
    % single classifier behind an if/elseif, so supplying both an MA and a
    % haemorrhage model filtered only whichever was checked first and left the
    % other channel raw. It now loops.
    for ci = 1:numel(CC)
        C = CC{ci};
        chan = char(C.meta.lesion);
        if ~isfield(OP, chan) || ~OP.(chan).applyClassifier
            % The frozen operating point says run stage 1 alone on this
            % channel. That is how the "the haemorrhage classifier makes
            % things worse" question gets settled by a committed decision
            % instead of by whoever last edited a source file.
            continue
        end

        thrC = opts.classifierThreshold;
        if ~isfinite(thrC), thrC = OP.(chan).classifierThreshold; end

        switch chan
            case 'microaneurysms'
                if isempty(maCentroids), continue; end
                [srcImg, cScale] = resolvePatchSource(C, img, small, scale);
                keep = scoreLesionCandidates(srcImg, maCentroids, C, ...
                    'centroidScale', cScale) >= thrC;
                maMask = dropRejected(maMask, keep);
                maCentroids = maCentroids(keep, :);

            case 'haemorrhages'
                if isempty(haemCentroids), continue; end
                [srcImg, cScale] = resolvePatchSource(C, img, small, scale);
                keep = scoreLesionCandidates(srcImg, haemCentroids, C, ...
                    'centroidScale', cScale) >= thrC;
                haemMask = dropRejected(haemMask, keep);
                haemCentroids = haemCentroids(keep, :);
                haemArea = haemArea(keep);
                haemEcc = haemEcc(keep);
        end
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

    % Tallied from the SURVIVING haemorrhages, not the raw candidate set.
    blotAreaMin = pi * (discDiamWork * 0.08)^2;
    isFlame = haemEcc > 0.88;
    isBlot  = ~isFlame & haemArea > blotAreaMin;
    d.haemByType = struct('dot', nnz(~isFlame & ~isBlot), ...
                          'blot', nnz(isBlot), 'flame', nnz(isFlame));
end


% ------------------------------------------------------------------ helpers

function CC = normaliseClassifiers(CC)
%NORMALISECLASSIFIERS  Accept a struct, a cell array, or nothing; return a cell array.
    if isstruct(CC)
        if isempty(fieldnames(CC)), CC = {}; else, CC = num2cell(CC); end
    elseif ~iscell(CC)
        CC = {};
    end
    keep = false(1, numel(CC));
    for k = 1:numel(CC)
        C = CC{k};
        keep(k) = isstruct(C) && isfield(C, 'trained') && isfield(C, 'meta') ...
                  && isfield(C.meta, 'lesion');
    end
    CC = CC(keep);
end


function [threshSD, CC] = resolveGenerator(requested, CC)
%RESOLVEGENERATOR  Reconcile the generator threshold with what the classifiers expect.
%
%   Defect 3. A stage-2 classifier is a function of the candidate distribution
%   it was trained on, and that distribution is set by threshSD. Applying it to
%   candidates from a different threshold is a silent domain shift: no error,
%   no warning, just a worse detector. The production path did exactly this for
%   as long as the classifiers existed.
%
%   Rules, in order:
%     * caller gave an explicit threshSD -> honour it, and DISABLE any
%       classifier trained at a different one (loudly). The caller is usually
%       BUILDCANDIDATEDATASET or SWEEPGENERATORRECALL, which are deliberately
%       probing the generator and must not have a classifier interfering.
%     * no explicit value, classifiers agree -> adopt theirs.
%     * no explicit value, classifiers DISAGREE -> the generator is shared, so
%       no single run can satisfy both. Disable stage 2 and fall back to 2.0.
%       Degrading to a noisier stage-1 pipeline is recoverable; shipping a
%       classifier fed out-of-distribution candidates is the bug being fixed.
%     * no classifiers -> 2.0, the long-standing default.

    DEFAULT_THRESH_SD = 2.0;

    metaThr = nan(1, numel(CC));
    for k = 1:numel(CC)
        if isfield(CC{k}.meta, 'threshSD') && isscalar(CC{k}.meta.threshSD)
            metaThr(k) = double(CC{k}.meta.threshSD);
        end
    end

    if isfinite(requested)
        threshSD = requested;
        bad = isfinite(metaThr) & abs(metaThr - threshSD) > 1e-9;
        if any(bad)
            warnOnce('drishti:generatorThresholdOverridden', ...
                ['detectDarkLesions: threshSD %.2f was requested explicitly, but ' ...
                 '%d classifier(s) were trained on candidates from a different ' ...
                 'threshold (%s). Those classifiers are DISABLED for this call - ' ...
                 'scoring them on an out-of-distribution candidate set would ' ...
                 'measure the mismatch, not the classifier.'], ...
                threshSD, nnz(bad), mat2str(metaThr(bad), 3));
            CC = CC(~bad);
        end
        return
    end

    known = metaThr(isfinite(metaThr));
    if isempty(known)
        threshSD = DEFAULT_THRESH_SD;
        return
    end
    if max(known) - min(known) > 1e-9
        warnOnce('drishti:generatorThresholdConflict', ...
            ['detectDarkLesions: the loaded stage-2 classifiers were trained on ' ...
             'candidates from DIFFERENT generator thresholds (%s). One generator ' ...
             'run cannot serve both, so stage 2 is disabled and the detector ' ...
             'falls back to threshSD %.2f. Retrain both channels at one threshold.'], ...
            mat2str(known, 3), DEFAULT_THRESH_SD);
        threshSD = DEFAULT_THRESH_SD;
        CC = {};
        return
    end
    threshSD = known(1);
end


function warnOnce(id, fmt, varargin)
%WARNONCE  Emit a warning at most once per session; these run inside 27-image loops.
    persistent seen
    if isempty(seen), seen = {}; end
    if any(strcmp(seen, id)), return; end
    seen{end+1} = id; %#ok<AGROW>
    warning(id, fmt, varargin{:});
end


function m = dropRejected(m, keep)
%DROPREJECTED  Remove the components of `m` whose `keep` flag is false.
%
%   `keep` is indexed by the enumeration order of BWCONNCOMP over `m`. That is
%   the same order the centroids were collected in: components are enumerated
%   by the linear index of their first pixel, `m` is a subset of the components
%   of the candidate mask with every kept component's pixels intact, and taking
%   a subset preserves relative order.
    cc = bwconncomp(m, 8);
    for q = 1:cc.NumObjects
        if q <= numel(keep) && ~keep(q)
            m(cc.PixelIdxList{q}) = false;
        end
    end
end


function d = emptyResult(img, withCandidates)
    z = false(size(img,1), size(img,2));
    d = struct('maMask', z, 'haemMask', z, 'maCount', 0, 'maDensityPerDD2', 0, ...
        'maCountWithin1DD', 0, 'haemCount', 0, 'haemAreaDD2', 0, ...
        'haemLargestAreaDD2', 0, ...
        'haemByType', struct('dot',0,'blot',0,'flame',0));
    if withCandidates
        e = struct('centroids', zeros(0,2), 'mask', false(0,0));
        d.candidates = struct('workImage', [], 'scale', 1, 'workSize', [0 0], ...
            'discDiamWork', 0, 'threshSD', NaN, ...
            'microaneurysms', e, 'haemorrhages', e, 'note', 'empty');
    end
end
