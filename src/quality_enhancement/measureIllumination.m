function m = measureIllumination(img, fov)
%MEASUREILLUMINATION  Exposure, evenness, glare and contrast inside the FOV.
%
%   m = MEASUREILLUMINATION(img, fov) returns:
%       m.uniformityCV  coefficient of variation of block means inside the FOV.
%                       0 = perfectly even. Rises with vignetting, shadowing and
%                       the off-axis illumination typical of handheld cameras.
%       m.meanIntensity mean luminance inside the FOV, [0,1]
%       m.glareFraction fraction of FOV pixels saturated in any channel
%       m.darkFraction  fraction of FOV pixels crushed to black
%       m.contrast      p99 - p1 of luminance inside the FOV
%       m.brightSide    'none' | 'left' | 'right' | 'top' | 'bottom' - which
%                       way the illumination gradient leans, used to generate a
%                       specific recapture instruction rather than "bad lighting"
%
%   Everything is computed inside the field of view and on a grid that scales
%   with the FOV, so an 8x8 block means the same physical retinal area whether
%   the image is 640x480 or 4288x2848.
%
%   See also DETECTFOV, ASSESSQUALITY, GATEIMAGE.

    arguments
        img (:,:,:) {mustBeNumeric}
        fov struct
    end

    gray = toGray(img);
    if ~isfloat(img)
        rgb = im2double(img);
    else
        rgb = img;
    end

    mask = fov.mask;
    inside = gray(mask);
    if numel(inside) < 100
        m = struct('uniformityCV', NaN, 'meanIntensity', NaN, ...
                   'glareFraction', NaN, 'darkFraction', NaN, ...
                   'contrast', NaN, 'brightSide', 'none');
        return
    end

    m.meanIntensity = mean(inside);
    m.contrast = prctile(inside, 99) - prctile(inside, 1);
    m.darkFraction = mean(inside <= 15/255);

    % Glare: saturation in ANY channel. Checking luminance alone misses the
    % coloured specular reflections that handheld cameras produce off the
    % cornea, which blow one channel while luminance stays mid-range.
    if size(rgb, 3) == 3
        maxChan = max(rgb, [], 3);
    else
        maxChan = rgb;
    end
    m.glareFraction = mean(maxChan(mask) >= 250/255);

    % --- uniformity ------------------------------------------------------
    [m.uniformityCV, blockMeans, blockValid] = blockUniformity(gray, mask, 8);

    % --- which way does the light lean -----------------------------------
    m.brightSide = dominantGradient(blockMeans, blockValid);
end


function [cv, blockMeans, blockValid] = blockUniformity(gray, mask, nBlocks)
%BLOCKUNIFORMITY  CV of block mean intensity over blocks mostly inside the FOV.

    [h, w] = size(gray);
    bh = max(1, floor(h / nBlocks));
    bw = max(1, floor(w / nBlocks));

    blockMeans = nan(nBlocks, nBlocks);
    blockValid = false(nBlocks, nBlocks);

    for i = 1:nBlocks
        rows = (i-1)*bh + 1 : min(i*bh, h);
        for j = 1:nBlocks
            cols = (j-1)*bw + 1 : min(j*bw, w);
            subMask = mask(rows, cols);
            % Only score blocks that sit mostly inside the FOV. A block
            % straddling the boundary is half black and would register as
            % severe unevenness on a perfectly lit image.
            if mean(subMask(:)) > 0.6
                sub = gray(rows, cols);
                blockMeans(i, j) = mean(sub(subMask));
                blockValid(i, j) = true;
            end
        end
    end

    vals = blockMeans(blockValid);
    if numel(vals) < 4 || mean(vals) <= 0
        cv = NaN;
    else
        cv = std(vals) / mean(vals);
    end
end


function side = dominantGradient(blockMeans, blockValid)
%DOMINANTGRADIENT  Which edge of the FOV is brighter, if any.
%
%   Drives a specific recapture message. "Light is falling off on the left" is
%   actionable for a technician; "illumination non-uniform" is not.

    side = 'none';
    if nnz(blockValid) < 8
        return
    end

    n = size(blockMeans, 1);
    half = floor(n / 2);
    bm = blockMeans;

    leftVals   = bm(:, 1:half);       leftVals   = leftVals(~isnan(leftVals));
    rightVals  = bm(:, end-half+1:end); rightVals = rightVals(~isnan(rightVals));
    topVals    = bm(1:half, :);       topVals    = topVals(~isnan(topVals));
    bottomVals = bm(end-half+1:end, :); bottomVals = bottomVals(~isnan(bottomVals));

    if isempty(leftVals) || isempty(rightVals) || isempty(topVals) || isempty(bottomVals)
        return
    end

    overall = mean(bm(~isnan(bm)));
    if overall <= 0
        return
    end

    hDiff = (mean(leftVals) - mean(rightVals)) / overall;
    vDiff = (mean(topVals) - mean(bottomVals)) / overall;

    % 15% relative difference across the FOV is the point where a gradient is
    % visible enough to be worth telling the operator about.
    tol = 0.15;
    if abs(hDiff) < tol && abs(vDiff) < tol
        return
    end

    if abs(hDiff) >= abs(vDiff)
        if hDiff > 0, side = 'left'; else, side = 'right'; end
    else
        if vDiff > 0, side = 'top'; else, side = 'bottom'; end
    end
end
