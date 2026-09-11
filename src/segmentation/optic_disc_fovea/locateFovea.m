function f = locateFovea(img, disc, opts)
%LOCATEFOVEA  Find the fovea centre using the optic disc as anchor.
%
%   f = LOCATEFOVEA(img, disc) where disc comes from LOCATEOPTICDISC returns:
%       f.centre      [x y] in original image pixels
%       f.found       logical
%       f.laterality  'OD' | 'OS' | 'unknown' - which eye
%       f.discFoveaDistancePx
%       f.confidence  0..1
%
%   Anatomy does most of the work
%   -----------------------------
%   The fovea is not found by searching the whole image. It sits at a
%   stereotyped position relative to the disc: roughly 2.5 disc diameters
%   temporal, on a line a few degrees below horizontal, in an avascular zone.
%   So the search is restricted to an annulus around that predicted location,
%   and within it the fovea is the darkest vessel-free spot.
%
%   Restricting the search is not just speed - the macula is not the only dark
%   region in a fundus image (haemorrhages, shadowing, vignetting all qualify),
%   and an unrestricted darkest-region search finds them instead.
%
%   LATERALITY
%   ----------
%   "Temporal" is left for a right eye and right for a left eye, so the side
%   must be decided first. With a single image and no metadata the usable cue
%   is that the disc sits nasally: it is on the right half of a left eye and
%   the left half of a right eye. That is inferred from the disc's offset from
%   the FOV centre. Both lateralities are present in IDRiD, so this cannot be
%   hardcoded. The feature contract carries the result because lesion position
%   relative to the macula is side-dependent.
%
%   See also LOCATEOPTICDISC, SEGMENTVESSELS.

    arguments
        img (:,:,:) {mustBeNumeric}
        disc struct
        opts.vesselMask = []
    end

    fov = disc.fov;
    discDiam = 2 * disc.radius;

    % --- which eye --------------------------------------------------------
    % Disc right of FOV centre => disc is nasal on a LEFT eye (OS).
    offset = disc.centre(1) - fov.centre(1);
    if abs(offset) < 0.05 * fov.diameter
        f.laterality = 'unknown';
        temporalSign = -sign(offset);
        if temporalSign == 0, temporalSign = -1; end
    elseif offset > 0
        f.laterality = 'OS';      % left eye, fovea temporal = to the LEFT
        temporalSign = -1;
    else
        f.laterality = 'OD';      % right eye, fovea temporal = to the RIGHT
        temporalSign = +1;
    end

    % --- predicted fovea location ----------------------------------------
    % 2.5 disc diameters temporal, ~0.1 DD below the disc centre.
    predicted = [disc.centre(1) + temporalSign * 2.5 * discDiam, ...
                 disc.centre(2) + 0.10 * discDiam];

    % --- refine within a search window -----------------------------------
    searchR = round(1.1 * discDiam);
    [h, w, ~] = size(img);
    r1 = max(1, round(predicted(2) - searchR)); r2 = min(h, round(predicted(2) + searchR));
    c1 = max(1, round(predicted(1) - searchR)); c2 = min(w, round(predicted(1) + searchR));

    if r2 <= r1 + 4 || c2 <= c1 + 4
        % Predicted point falls outside the image - the disc estimate is
        % probably wrong. Report the prediction and flag low confidence rather
        % than inventing a refinement.
        f.centre = predicted;
        f.found = false;
        f.confidence = 0;
        f.discFoveaDistancePx = 2.5 * discDiam;
        return
    end

    patch = im2double(img(r1:r2, c1:c2, :));
    if size(patch,3) == 3
        g = patch(:,:,2);
    else
        g = patch;
    end

    % The fovea is a broad shallow depression in intensity, not a small dark
    % spot. Smoothing at ~1/3 disc diameter suppresses haemorrhages and vessel
    % segments, which are the main false attractors.
    gs = imgaussfilt(g, max(2, discDiam * 0.33 / 3));

    % Penalise vessels: the foveal avascular zone is by definition vessel-free,
    % so this is a strong and cheap discriminator when a vessel map exists.
    if ~isempty(opts.vesselMask)
        vm = double(opts.vesselMask(r1:r2, c1:c2));
        vesselNear = imgaussfilt(vm, max(2, discDiam * 0.25 / 2));
        gs = gs + 0.5 * vesselNear;   % push candidates away from vessels
    end

    % Prefer points near the anatomical prediction: without this the darkest
    % point drifts to the window corner on images with heavy vignetting.
    [Y, X] = ndgrid(r1:r2, c1:c2);
    dist = sqrt((X - predicted(1)).^2 + (Y - predicted(2)).^2) / max(searchR, 1);
    cost = gs + 0.25 * dist.^2;

    [~, idx] = min(cost(:));
    [py, px] = ind2sub(size(cost), idx);
    f.centre = [c1 + px - 1, r1 + py - 1];
    f.found = true;

    % Confidence: how much darker the chosen spot is than the window median.
    % A real fovea is distinctly darker; a flat window means we guessed.
    med = median(gs(:));
    contrast = (med - gs(py, px)) / max(med, eps);
    f.confidence = max(0, min(1, contrast * 6)) * disc.confidence;

    f.discFoveaDistancePx = hypot(f.centre(1) - disc.centre(1), ...
                                  f.centre(2) - disc.centre(2));
end
