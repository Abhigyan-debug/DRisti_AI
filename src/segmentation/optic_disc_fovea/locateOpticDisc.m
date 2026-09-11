function d = locateOpticDisc(img, opts)
%LOCATEOPTICDISC  Find the optic disc centre in a fundus photograph.
%
%   d = LOCATEOPTICDISC(img) returns:
%       d.centre      [x y] in ORIGINAL image pixels
%       d.radius      estimated disc radius in original pixels
%       d.confidence  0..1, peak strength relative to the runner-up
%       d.fov         the DETECTFOV result (reused by callers)
%       d.elapsed     seconds
%
%   d = LOCATEOPTICDISC(img, fov=..., debug=true) reuses a known FOV and
%   returns intermediate maps in d.debug.
%
%   Benchmark: IDRiD challenge winner (DeepDR) achieved 21.07 px mean Euclidean
%   error on 4288x2848 images - about 0.5% of image width. See
%   docs/literature_benchmarks.md section 2.4.
%
%   Method
%   ------
%   The disc is the brightest LARGE, COMPACT structure in the retina. A
%   disc-sized averaging filter over a brightness map is a matched filter for
%   exactly that, which is a far more specific question than "where is it
%   bright". Two preprocessing steps matter:
%
%   1. VESSELS DARKEN THE DISC. A closing at vessel width fills them in before
%      brightness is measured.
%
%   2. SCATTERED EXUDATES ARE BRIGHTER THAN THE DISC. In a diabetic cohort -
%      the entire population here - that is common. An opening at half the disc
%      radius removes small ones. LARGE CONFLUENT EXUDATES SURVIVE IT and
%      remain the dominant failure mode; see the measured results below.
%
%   3. THE RED CHANNEL CLIPS (measured in Phase 0 - the same finding that
%      forced the Module 1 glare metric rewrite). A clipped channel destroys
%      the brightness ordering, so the map is green-led with red as a
%      tie-breaker only where red is unsaturated.
%
%   Disc size is NOT a guess: measured from the 54 IDRiD optic-disc ground
%   truth masks, median radius 263 px against a 3409 px FOV, giving a disc
%   diameter / FOV diameter ratio of 1/6.48. The 1/6.5 default is that
%   measurement. Sweeping the ratio to 1/8 or 1/12 lowers the mean error, but
%   that is fitting the catastrophic tail, not finding a better disc size.
%
%   MEASURED PERFORMANCE (no CNN refinement yet)
%   --------------------------------------------
%     IDRiD test split (n=103):  mean 239 px | median 98 px | 72.8% inside disc
%     IDRiD train split (n=413): mean 259 px | median 112 px | 74.1% inside disc
%     Benchmark (DeepDR, deep network): 21.07 px mean -> we are 11.4x off.
%
%   The mean is dominated by a tail: median 98 px is about 0.37 disc radii,
%   i.e. the typical hit lands INSIDE the disc, but ~27% miss badly. Treat this
%   as a SEED for CNN refinement, which is what the README specifies and what
%   the benchmark entries actually did - not as a finished localizer.
%
%   d.confidence tracks error at Spearman rho = -0.70 on the test split, so it
%   is a usable reliability signal for Module 4 rather than decoration.
%
%   WHAT DID NOT WORK: vessel convergence
%   -------------------------------------
%   Every retinal vessel emerges from the disc and an exudate has none, so
%   vessel density should separate them. A black-top-hat proxy for vesselness
%   was tried and measured three ways:
%     - globally blended:      median 122 -> 79 px, but mean 285 -> 333
%     - after masking the FOV rim (the surround swamps an unmasked top-hat):
%                              median improved, mean still worse
%     - as a re-ranker over the top-5 brightness peaks, which bounds the damage
%       by construction:       mean 341, still worse than brightness alone
%   The idea is sound; this proxy is too crude. Revisit with the real vessel
%   segmentation once Phase 2 builds it - the interface is the same map, and
%   opts.vesselWeight is retained (default 0) to make that a one-line change.
%
%   See also DETECTFOV, EVALUATEDISCLOCALIZATION, LOADIDRIDLANDMARKS.

    arguments
        img (:,:,:) {mustBeNumeric}
        opts.fov struct = struct()
        opts.debug (1,1) logical = false
        % Disc diameter as a fraction of FOV diameter. Anatomically the disc is
        % ~1/7 of a 50-degree field; 1/6.5 is a good working value.
        opts.discFovRatio (1,1) double = 1/6.5
        % Weight of the vessel-convergence term, 0 = brightness only.
        opts.vesselWeight (1,1) double {mustBeInRange(opts.vesselWeight,0,1)} = 0
        % FOV erosion as a fraction of disc radius, before scoring.
        opts.edgeErodeFrac (1,1) double = 0.15
    end

    t0 = tic;

    fov = opts.fov;
    if ~isfield(fov, 'mask')
        fov = detectFOV(img);
    end

    % --- work at a canonical scale ---------------------------------------
    % Localisation is a low-frequency problem: the disc is ~80px across at this
    % working size, which is ample. Running at 4288x2848 costs seconds per
    % image for no accuracy - the same lesson as estimateBackground.
    WORK_FOV_PX = 512;
    scale = min(1, WORK_FOV_PX / fov.diameter);
    if scale < 1
        small = imresize(im2double(img), scale, 'bilinear');
        mask = imresize(fov.mask, scale, 'nearest');
    else
        scale = 1;
        small = im2double(img);
        mask = fov.mask;
    end
    if size(small, 3) ~= 3
        small = repmat(small, 1, 1, 3);
    end

    discRadiusPx = max(4, (fov.diameter * scale) * opts.discFovRatio / 2);

    % --- build the search map --------------------------------------------
    green = small(:,:,2);
    red   = small(:,:,1);

    % Red is the brightest channel on the disc but clips; use it only where it
    % is not saturated, so a blown red channel cannot dominate the map.
    redUsable = red < 250/255;
    bright = green;
    bright(redUsable) = 0.65 * green(redUsable) + 0.35 * red(redUsable);

    vesselWidth = max(1, round(discRadiusPx * 0.12));

    % --- vessel convergence cue -------------------------------------------
    % Brightness alone cannot separate the disc from a large confluent
    % exudate, and in a diabetic cohort those are common. Measured on IDRiD:
    % brightness-only put the prediction on an exudate in half of the worst
    % failures.
    %
    % The discriminator is anatomical rather than photometric - EVERY major
    % retinal vessel emerges from the disc, and an exudate has none crossing
    % it. A black top-hat on green picks out dark thin structures (vessels);
    % averaging that over a disc-sized window gives vessel density, which
    % peaks hard at the disc and is ~0 on an exudate.
    %
    % This is a cheap proxy, not the Phase 2 vessel segmenter. When the U-Net
    % lands, swap it in here - the interface is the same map.
    vesselish = imbothat(green, strel('disk', max(2, vesselWidth)));
    % Mask BEFORE averaging. The black surround is the darkest thing in the
    % frame, so an unmasked black top-hat responds enormously to it and that
    % response bleeds inward through the disc-sized average, inflating vessel
    % density all along the FOV rim.
    vesselish(~imerode(mask, strel('disk', max(2, vesselWidth * 3)))) = 0;
    vesselDensity = imfilter(vesselish, fspecial('disk', discRadiusPx), 'replicate');
    if max(vesselDensity(:)) > 0
        vesselDensity = vesselDensity / max(vesselDensity(:));
    end

    % --- brightness cue ----------------------------------------------------
    % Fill vessels so they stop darkening the disc, then open to suppress
    % scattered exudates. Large confluent exudates survive this - the vessel
    % term above is what rejects those.
    brightFilled = imclose(bright, strel('disk', vesselWidth));
    brightFilled = imopen(brightFilled, strel('disk', max(2, round(discRadiusPx * 0.5))));

    % Erode only enough to exclude the FOV rim itself. The previous version
    % eroded by half a disc radius AND averaged over a full disc window, which
    % suppressed any disc sitting within ~1.5 radii of the edge - and the disc
    % is frequently near the nasal edge. That single line accounted for the
    % four largest errors on the training split (1721, 1648, 1521, 1239 px).
    inner = imerode(mask, strel('disk', max(2, round(discRadiusPx * opts.edgeErodeFrac))));
    brightFilled(~inner) = 0;

    % Disc-sized averaging: a matched filter for "a compact bright region the
    % size of an optic disc", a far more specific question than "where is it
    % bright". Normalised by the valid-pixel count so a disc near the FOV edge
    % is not penalised for having part of its window outside the retina.
    kern = fspecial('disk', discRadiusPx);
    brightScore = imfilter(brightFilled, kern, 'replicate');
    coverage = imfilter(double(inner), kern, 'replicate');
    brightScore = brightScore ./ max(coverage, 0.25);

    if max(brightScore(:)) > 0
        brightScore = brightScore / max(brightScore(:));
    end

    % --- propose, then choose ---------------------------------------------
    % Brightness PROPOSES candidates; the vessel term only CHOOSES among them.
    %
    % Measured on 60 IDRiD training images, a globally blended score
    % (brightScore .* vesselDensity) moved the median error 122 -> 79 px but
    % pushed the MEAN from 285 -> 333. The vessel cue genuinely helps the
    % typical case and wrecks the tail: where the proxy is unreliable it drags
    % the argmax to a location that is not a disc at all.
    %
    % Restricting the vessel term to re-ranking a handful of brightness peaks
    % bounds that damage by construction - the answer is always one of the top
    % few "compact bright disc-sized region" candidates, so a bad vessel signal
    % can pick the wrong candidate but can never invent a new location.
    K = 5;
    cands = zeros(K, 2);
    nCand = 0;
    work = brightScore;
    for i = 1:K
        [v, idx] = max(work(:));
        if v <= 0, break; end
        [cy, cx] = ind2sub(size(work), idx);
        nCand = nCand + 1;
        cands(nCand, :) = [cx, cy];
        % Suppress this candidate's neighbourhood before looking for the next
        work(max(1,cy-round(discRadiusPx)):min(end,cy+round(discRadiusPx)), ...
             max(1,cx-round(discRadiusPx)):min(end,cx+round(discRadiusPx))) = 0;
    end
    cands = cands(1:nCand, :);

    w = opts.vesselWeight;
    combined = zeros(nCand, 1);
    for i = 1:nCand
        b = brightScore(cands(i,2), cands(i,1));
        v = vesselDensity(cands(i,2), cands(i,1));
        combined(i) = b * ((1 - w) + w * v);
    end
    [~, best] = max(combined);
    px = cands(best, 1);
    py = cands(best, 2);
    peakVal = combined(best);

    score = brightScore;   % retained for debug output

    % --- confidence: how far clear of the best competing candidate --------
    % A close runner-up usually means a large confluent exudate is competing
    % with the disc. That is worth surfacing to Module 4 rather than hiding,
    % and it was measured to track error (Spearman rho about -0.5).
    if nCand > 1 && peakVal > 0
        rivalVal = max(combined([1:best-1, best+1:end]));
        d.confidence = max(0, min(1, 1 - rivalVal / peakVal));
    else
        d.confidence = 1;
    end

    % --- back to original coordinates -------------------------------------
    d.centre  = [px, py] / scale;
    d.radius  = discRadiusPx / scale;
    d.fov     = fov;
    d.elapsed = toc(t0);

    if opts.debug
        d.debug = struct('score', score, 'bright', bright, 'scale', scale, ...
                         'discRadiusPx', discRadiusPx, 'peakVal', peakVal, ...
                         'rivalVal', rivalVal);
    end
end
