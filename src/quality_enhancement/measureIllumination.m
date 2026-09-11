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
    m.darkFraction = mean(inside <= 15/255);

    % Contrast is measured on the DETRENDED image - the luminance with its
    % low-frequency illumination component removed.
    %
    % A plain p99-p1 over the whole FOV conflates contrast with illumination
    % unevenness: a vignetted image scores "high contrast" purely because one
    % side is bright and the other dark. That made illumination correction
    % appear to DESTROY contrast (0.570 -> 0.295 on a real APTOS image) when it
    % had in fact improved the image, and it would have made the enhancement
    % stage look harmful in the Phase 6 baseline comparison.
    %
    % What actually determines gradability is local contrast - can a vessel or
    % a microaneurysm be told apart from the retina immediately around it.
    background = estimateBackground(gray, mask, fov.diameter);
    detrended = gray - background;
    dv = detrended(mask);
    m.contrast = prctile(dv, 99) - prctile(dv, 1);

    % The old global measure, kept as a diagnostic: it is a decent proxy for
    % illumination spread, just not for contrast.
    m.globalRange = prctile(inside, 99) - prctile(inside, 1);

    % Glare: specular reflection is ACHROMATIC - it blows all three channels to
    % white. Requiring min(R,G,B) to saturate is what makes this a glare
    % detector rather than an exposure detector.
    %
    % The first version used max(R,G,B) >= 250 ("any channel"). That was wrong
    % and measured nothing but red-channel clipping: corr(any-channel, red-only)
    % = +1.000 across 140 images, and of 75 images flagged above 1%, ZERO had
    % all-channel saturation. The retina is red, so the red channel clips in
    % ordinary well-exposed fundus photographs - flagging that as glare rejected
    % perfectly good images.
    if size(rgb, 3) == 3
        minChan = min(rgb, [], 3);
        maxChan = max(rgb, [], 3);
    else
        minChan = rgb;
        maxChan = rgb;
    end
    m.glareFraction = mean(minChan(mask) >= 240/255);

    % Kept separately: red clipping is a real overexposure signal, just not a
    % glare signal. Useful for Module 2, where a clipped red channel means lost
    % haemorrhage contrast.
    if size(rgb, 3) == 3
        red = rgb(:,:,1);
        m.redClipFraction = mean(red(mask) >= 250/255);
    else
        m.redClipFraction = mean(maxChan(mask) >= 250/255);
    end

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
