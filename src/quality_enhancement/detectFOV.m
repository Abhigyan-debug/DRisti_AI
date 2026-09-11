function fov = detectFOV(img)
%DETECTFOV  Locate the circular field of view in a fundus photograph.
%
%   fov = DETECTFOV(img) returns a struct describing the illuminated retinal
%   disc: its mask, centre, radius and how much of the frame it occupies.
%
%   fov.mask      logical, true inside the field of view
%   fov.centre    [x y] centroid of the FOV, in pixels
%   fov.radius    estimated radius in pixels
%   fov.diameter  2*radius - THE reference length for this image
%   fov.coverage  fraction of the frame inside the FOV
%   fov.bbox      [x y w h] tight bounding box of the FOV
%   fov.truncated true if the FOV touches a frame edge (cropped acquisition)
%
%   Why this runs first
%   -------------------
%   Every other Module 1 metric is normalised against fov.diameter. Our corpora
%   span a 6.7x linear resolution range (640x480 to 4288x2848), and a focus
%   measure in raw pixel units tracks image size almost as strongly as it tracks
%   focus - r = -0.75 against FOV diameter within APTOS alone. Measuring against
%   the FOV instead of the frame is what makes a single threshold meaningful
%   across cameras. See docs/phase1_quality_baseline.md.
%
%   Note on fov.coverage: it is reported for diagnostics but must NOT be
%   thresholded as an absolute quality signal. Coverage is a camera/crop
%   fingerprint - IDRiD sits at 0.691 with near-zero variance, Messidor-2 at
%   0.465 - so a cut-off calibrated on one corpus rejects another wholesale.
%
%   See also ASSESSQUALITY, MEASURESHARPNESS.

    arguments
        img (:,:,:) {mustBeNumeric}
    end

    gray = toGray(img);
    [h, w] = size(gray);

    % Fundus images are a bright disc on a near-black surround. Otsu adapts to
    % under-exposed captures better than a fixed cut, but clamp it low: on a
    % dim image Otsu can land mid-retina and carve the disc in half.
    level = graythresh(gray);
    thresh = min(level, 0.12);
    mask = gray > thresh;

    % Keep the largest connected region - drops timestamp burn-in, specular
    % flecks in the black surround, and camera-body reflections.
    mask = imfill(mask, 'holes');
    cc = bwconncomp(mask, 8);
    if cc.NumObjects == 0
        fov = emptyFOV(h, w);
        return
    end
    numPixels = cellfun(@numel, cc.PixelIdxList);
    [~, biggest] = max(numPixels);
    mask = false(h, w);
    mask(cc.PixelIdxList{biggest}) = true;

    % Smooth the boundary: JPEG ringing and vignetting leave a ragged edge that
    % would bias the radius estimate outward.
    radiusGuess = sqrt(nnz(mask) / pi);
    se = strel('disk', max(1, round(radiusGuess * 0.01)));
    mask = imopen(mask, se);
    mask = imfill(mask, 'holes');

    if nnz(mask) < 0.01 * h * w
        fov = emptyFOV(h, w);
        return
    end

    stats = regionprops(mask, 'Centroid', 'BoundingBox', 'Area');
    [~, k] = max([stats.Area]);
    stats = stats(k);

    bbox = stats.BoundingBox;          % [x y w h]
    fovW = bbox(3);
    fovH = bbox(4);

    % Most fundus images crop the disc top and bottom, so width is the honest
    % diameter estimate. When the image is uncropped (square-ish FOV) the two
    % agree anyway. Fall back to an area-equivalent circle if the region is
    % oddly shaped.
    areaDiameter = 2 * sqrt(stats.Area / pi);
    if fovW >= fovH
        diameter = fovW;
    else
        diameter = max(fovH, areaDiameter);
    end

    tol = 2;
    truncated = bbox(1) <= tol || bbox(2) <= tol || ...
                (bbox(1) + fovW) >= (w - tol) || (bbox(2) + fovH) >= (h - tol);

    fov = struct( ...
        'mask',      mask, ...
        'centre',    stats.Centroid, ...
        'radius',    diameter / 2, ...
        'diameter',  diameter, ...
        'coverage',  nnz(mask) / (h * w), ...
        'bbox',      bbox, ...
        'truncated', truncated, ...
        'valid',     true);
end


function fov = emptyFOV(h, w)
%EMPTYFOV  Fallback when no plausible disc is found - treat the whole frame as
%          the FOV so downstream metrics still produce a number, and flag it.
    fov = struct( ...
        'mask',      true(h, w), ...
        'centre',    [w/2, h/2], ...
        'radius',    min(h, w) / 2, ...
        'diameter',  min(h, w), ...
        'coverage',  1, ...
        'bbox',      [0.5, 0.5, w, h], ...
        'truncated', true, ...
        'valid',     false);
end
