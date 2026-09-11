function v = segmentVessels(img, opts)
%SEGMENTVESSELS  Retinal vessel segmentation by multi-scale matched filtering.
%
%   v = SEGMENTVESSELS(img) returns:
%       v.mask        logical vessel map, original image size
%       v.density     fraction of FOV that is vessel
%       v.totalLengthDD  skeleton length in disc diameters
%       v.meanCaliberDD  mean vessel width in disc diameters
%       v.response    continuous vesselness, for downstream use
%
%   CLASSICAL, NOT LEARNED - AND THAT IS A DELIBERATE COMPROMISE
%   -----------------------------------------------------------
%   The benchmark (Galdran et al., DRIVE) is Dice 82.8 with a U-Net. This is a
%   Frangi-style multi-scale Hessian filter with no training, and it will land
%   well short of that. It is here because it runs today, needs no labelled
%   data, and unblocks three things that were otherwise stuck: the
%   vessel-convergence cue in LOCATEOPTICDISC, haemorrhage/vessel separation,
%   and neovascularization.
%
%   Report its Dice honestly and do not compare it to U-Net numbers without
%   saying which it is.
%
%   Scales are set in disc diameters so one parameter set covers the 6.7x
%   resolution range across our corpora.
%
%   See also LOCATEOPTICDISC, EXTRACTLESIONFEATURES.

    arguments
        img (:,:,:) {mustBeNumeric}
        opts.fov struct = struct()
        opts.discRadiusPx (1,1) double = 0
        opts.sensitivity (1,1) double = 0.5
    end

    fov = opts.fov;
    if ~isfield(fov, 'mask')
        fov = detectFOV(img);
    end
    discRadiusPx = opts.discRadiusPx;
    if discRadiusPx <= 0
        discRadiusPx = fov.diameter / 6.48 / 2;   % measured IDRiD ratio
    end

    % Work at a canonical scale: vessels are a few pixels wide at 1024px FOV,
    % which is enough to resolve them, and 4288px costs 20x the time for no
    % extra vessel detail.
    WORK_FOV_PX = 1024;
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

    % Green carries by far the best vessel contrast - vessels absorb red
    % strongly so they are nearly invisible there, and blue is noise-dominated.
    green = small(:,:,2);

    % Flatten illumination first, or the vesselness responds to the background
    % gradient. Reuses Module 1's estimator so the two cannot disagree.
    bg = estimateBackground(green, mask, fov.diameter * scale);
    flat = green - bg;
    flat(~mask) = 0;

    % Invert: vessels are DARK, and the Hessian ridge filter looks for bright
    % ridges.
    flat = -flat;

    % Multi-scale: the arcades are several times wider than the capillaries,
    % so a single scale always misses one end. Scales are fractions of the disc
    % radius, which is what makes this camera-independent.
    discR = discRadiusPx * scale;
    sigmas = discR * [0.03, 0.05, 0.08, 0.12];
    sigmas = max(sigmas, 1);

    response = zeros(size(flat));
    for s = sigmas
        response = max(response, frangiResponse(flat, s));
    end
    response(~imerode(mask, strel('disk', 3))) = 0;
    if max(response(:)) > 0
        response = response / max(response(:));
    end

    % Threshold. Adaptive rather than fixed: vessel contrast varies enormously
    % with media clarity, and a fixed cut loses the whole tree on a hazy image.
    inside = response(mask);
    thresh = max(0.02, prctile(inside, 100 * (1 - 0.12 * (opts.sensitivity / 0.5))));
    bw = response > thresh;

    % Clean: drop specks smaller than a plausible vessel fragment, close small
    % gaps where a crossing vessel broke the ridge.
    bw = bwareaopen(bw, max(8, round((discR * 0.08)^2)));
    bw = imclose(bw, strel('disk', max(1, round(discR * 0.02))));
    bw = bw & mask;

    % --- measurements (in disc diameters) ---------------------------------
    skel = bwskel(bw);
    discDiamWork = 2 * discR;
    v.mask = imresize(bw, [size(img,1) size(img,2)], 'nearest');
    v.response = response;
    v.density = nnz(bw) / max(nnz(mask), 1);
    v.totalLengthDD = nnz(skel) / max(discDiamWork, 1);
    if nnz(skel) > 0
        v.meanCaliberDD = (nnz(bw) / nnz(skel)) / max(discDiamWork, 1);
    else
        v.meanCaliberDD = 0;
    end
    v.scale = scale;
end


function r = frangiResponse(I, sigma)
%FRANGIRESPONSE  Single-scale Hessian ridge (vesselness) response.
%
%   A vessel is locally a ridge: one large-magnitude principal curvature across
%   it and near-zero along it. The eigenvalue ratio below tests exactly that,
%   which is why it rejects blobs (haemorrhages, exudates) that a simple
%   top-hat would happily return.

    I = imgaussfilt(I, sigma);
    [gx, gy] = gradient(I);
    [gxx, gxy] = gradient(gx);
    [~, gyy] = gradient(gy);

    % Normalise by sigma^2 so responses are comparable across scales
    gxx = gxx * sigma^2;
    gxy = gxy * sigma^2;
    gyy = gyy * sigma^2;

    tmp = sqrt((gxx - gyy).^2 + 4 * gxy.^2);
    lambda1 = 0.5 * (gxx + gyy + tmp);
    lambda2 = 0.5 * (gxx + gyy - tmp);

    % Order by magnitude: |L1| <= |L2|
    swap = abs(lambda1) > abs(lambda2);
    t = lambda1(swap); lambda1(swap) = lambda2(swap); lambda2(swap) = t;

    Rb = (lambda1 ./ (lambda2 + eps)).^2;       % blobness
    S2 = lambda1.^2 + lambda2.^2;               % structureness

    beta = 0.5;
    c = 0.5 * max(sqrt(S2(:)));
    if c == 0, c = 1; end

    r = exp(-Rb / (2 * beta^2)) .* (1 - exp(-S2 / (2 * c^2)));
    % Vessels are bright ridges in the inverted image => lambda2 < 0
    r(lambda2 > 0) = 0;
end
