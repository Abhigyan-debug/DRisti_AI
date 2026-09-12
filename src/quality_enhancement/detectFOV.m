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
    % PixelIdxList holds one double per foreground pixel - 67 MB on a 4288x2848
    % frame. Release it before the morphology below allocates its own buffers,
    % rather than letting the two peaks overlap.
    clear cc numPixels

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

    % Area / centroid / bounding box of the LARGEST region. This used to be
    % regionprops(mask, 'Centroid', 'BoundingBox', 'Area'), which is a memory
    % trap on full-resolution fundus frames - see LARGESTREGIONSTATS.
    [regionArea, regionCentroid, bbox] = largestRegionStats(mask);
    if isempty(bbox)
        fov = emptyFOV(h, w);
        return
    end

    fovW = bbox(3);                    % bbox is [x y w h]
    fovH = bbox(4);

    % Most fundus images crop the disc top and bottom, so width is the honest
    % diameter estimate. When the image is uncropped (square-ish FOV) the two
    % agree anyway. Fall back to an area-equivalent circle if the region is
    % oddly shaped.
    areaDiameter = 2 * sqrt(regionArea / pi);
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
        'centre',    regionCentroid, ...
        'radius',    diameter / 2, ...
        'diameter',  diameter, ...
        'coverage',  nnz(mask) / (h * w), ...
        'bbox',      bbox, ...
        'truncated', truncated, ...
        'valid',     true);
end


function [area, centroid, bbox] = largestRegionStats(mask)
%LARGESTREGIONSTATS  Area, centroid and bounding box of the biggest region.
%
%   Drop-in replacement for
%
%       stats = regionprops(mask, 'Centroid', 'BoundingBox', 'Area');
%       [~, k] = max([stats.Area]);  stats = stats(k);
%
%   producing bit-identical values with a fraction of the peak memory. Returns
%   an empty bbox when the mask has no foreground.
%
%   WHY REGIONPROPS WAS THE PROBLEM
%   -------------------------------
%   Read from MATLAB's own source, toolbox/images/images/regionprops.m:
%   ComputeCentroid (line 617) and ComputeBoundingBox (line 749) BOTH begin by
%   calling ComputePixelList, and ComputePixelList (line 1048) materialises
%   stats(k).PixelList - an N-by-2 array of DOUBLE subscripts for every pixel
%   in every region - then reorders its columns, `PixelList(:,[2 1 3:end])`,
%   which allocates a second full copy.
%
%   So 'Centroid' and 'BoundingBox' are not the cheap scalars they look like.
%   Measured with MATLAB's memory profiler on a 4288x2848 frame whose field of
%   view is 7.97 M pixels (profile('-memory','on'), PeakMem per function):
%
%       regionprops(mask,'Centroid','BoundingBox','Area')     128 MB
%         regionprops>ComputePixelList                        128 MB   <- all of it
%         regionprops>ComputeCentroid                         128 MB   (inherited)
%         regionprops>ComputeBoundingBox                        0 MB   (PixelList reused)
%         regionprops>ComputeArea                               0 MB
%
%   and the returned PixelList measures 128 MB exactly (7.97e6 * 2 * 8 B).
%   'Area' is free - it is numel of an index list. 'Centroid' is what drags the
%   subscript array in, and 'BoundingBox' then rides along on it for nothing.
%
%   This helper measures 64 MB peak for the same result: bwconncomp's
%   PixelIdxList, one double per foreground pixel, and nothing else. A 64 MB
%   saving per call, on a function called once per image across a 53-image
%   sweep, twice over.
%
%   Honest scope: DETECTFOV as a whole still peaks around 294 MB on that frame,
%   dominated by graythresh/imfill/imopen over 12.2 M pixels. This fixes the
%   gratuitous half, not all of it.
%
%   WHAT THIS DOES INSTEAD
%   ----------------------
%   A linear index into an h-by-w column-major array decomposes arithmetically:
%   col = ceil(i/h), row = i - (col-1)*h. Centroid is the mean of those, and
%   the bounding box is their min and max - all of which are running
%   accumulations that never need the subscripts stored. The index list is
%   walked in chunks, so peak extra memory is the chunk, not the region.
%
%   BoundingBox and Centroid conventions are regionprops': the centroid is
%   [x y] with pixel centres at integers, and the box is
%   [minX-0.5, minY-0.5, width, height].
%
%   The LARGEST region is selected, matching the max([stats.Area]) it replaces.
%   Note that the caller still reports fov.mask and fov.coverage over the WHOLE
%   mask, small extra components included - exactly as before. This function
%   changes how the numbers are computed, never which pixels are the FOV.

    CHUNK = 2^20;                       % 8 MB of doubles per accumulation step

    area = 0;
    centroid = [NaN NaN];
    bbox = [];

    cc = bwconncomp(mask, 8);
    if cc.NumObjects == 0, return; end

    areas = cellfun(@numel, cc.PixelIdxList);
    [area, k] = max(areas);
    idx = cc.PixelIdxList{k};
    clear cc areas                      % free the other regions' index lists

    h = size(mask, 1);
    sumRow = 0; sumCol = 0;
    minRow = Inf; maxRow = -Inf;
    minCol = Inf; maxCol = -Inf;

    for b = 1:CHUNK:numel(idx)
        s = double(idx(b : min(b+CHUNK-1, numel(idx))));
        c = ceil(s / h);
        r = s - (c - 1) * h;
        sumRow = sumRow + sum(r);
        sumCol = sumCol + sum(c);
        minRow = min(minRow, min(r));  maxRow = max(maxRow, max(r));
        minCol = min(minCol, min(c));  maxCol = max(maxCol, max(c));
    end

    centroid = [sumCol / area, sumRow / area];
    bbox = [minCol - 0.5, minRow - 0.5, ...
            maxCol - minCol + 1, maxRow - minRow + 1];
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
