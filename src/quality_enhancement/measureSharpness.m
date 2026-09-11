function s = measureSharpness(img, fov, canonicalFovPx)
%MEASURESHARPNESS  Focus score that is comparable across cameras.
%
%   s = MEASURESHARPNESS(img, fov) returns a struct:
%       s.normalised  Laplacian variance after rescaling so the FOV spans
%                     canonicalFovPx - THE value to threshold
%       s.raw         Laplacian variance at native resolution, for diagnostics
%       s.band        'small' | 'mid' | 'large', the FOV-diameter band
%       s.scale       the resize factor applied
%
%   s = MEASURESHARPNESS(img, fov, canonicalFovPx) overrides the canonical FOV
%   diameter (default 512, matching config/quality_thresholds.json).
%
%   Why not just use variance of the Laplacian
%   ------------------------------------------
%   Because it silently measures image size. A 3x3 Laplacian is a fixed-size
%   kernel, so it samples a different physical retinal distance depending on
%   resolution. Measured within APTOS (constant content, FOV 551-3617 px,
%   n=220): raw Laplacian variance correlates with FOV diameter at r = -0.75.
%   Median raw score by band was 35.3 / 53.5 / 14.5 for small / mid / large FOV
%   - a sharp large image scores below a blurred small one.
%
%   Rescaling every image to a fixed FOV diameter first drops that to r = -0.43
%   and tightens the band medians to 23.3 / 46.5 / 20.4. Better, but NOT solved:
%   a residual -0.43 means a single global threshold still mis-fires at the
%   extremes, which is why s.band is returned - GATEIMAGE applies a per-band
%   tolerance rather than pretending one number fits all.
%
%   Full analysis: docs/phase1_quality_baseline.md section 1.
%
%   See also DETECTFOV, ASSESSQUALITY, GATEIMAGE.

    arguments
        img (:,:,:) {mustBeNumeric}
        fov struct
        canonicalFovPx (1,1) double {mustBePositive} = 512
    end

    gray = toGray(img);

    % --- raw, native resolution (diagnostic only) ------------------------
    s.raw = laplacianVariance(gray, fov.mask);

    % --- normalised ------------------------------------------------------
    % Only ever downscale. Upsampling a small image invents no detail but does
    % inflate the variance, which would make low-resolution captures look
    % sharper than they are - exactly the wrong bias for a quality gate.
    scale = canonicalFovPx / max(fov.diameter, eps);
    if scale < 1
        smallGray = imresize(gray, scale, 'bilinear');
        smallMask = imresize(fov.mask, scale, 'nearest');
        s.normalised = laplacianVariance(smallGray, smallMask);
    else
        scale = 1;
        s.normalised = s.raw;
    end
    s.scale = scale;

    % --- which tolerance band does this image fall in --------------------
    if fov.diameter < 800
        s.band = 'small';
    elseif fov.diameter < 1600
        s.band = 'mid';
    else
        s.band = 'large';
    end
end


function v = laplacianVariance(gray, mask)
%LAPLACIANVARIANCE  Variance of the 4-neighbour Laplacian inside mask.
%
%   Restricted to the FOV: the black surround is perfectly flat, so including
%   it dilutes the variance in proportion to how much of the frame is black -
%   which reintroduces the camera-crop dependency we are trying to remove.

    lap = imfilter(gray, [0 -1 0; -1 4 -1; 0 -1 0], 'replicate');

    % Erode so the FOV boundary itself - a hard black-to-retina step, the
    % strongest edge in the image - does not dominate the score. Without this
    % the metric partly measures how much black surround the camera left in
    % frame, which is a crop convention, not focus.
    %
    % A 7x7 SQUARE (not disk) is used so tools/profile_image_quality.py can
    % reproduce it exactly in numpy. The two implementations must agree or the
    % thresholds in config/quality_thresholds.json do not transfer -
    % tests/test_quality_metrics.m enforces that.
    inner = imerode(mask, strel('square', 7));
    vals = lap(inner);

    if numel(vals) < 100
        v = 0;
        return
    end

    % Reported on a 0-255 intensity scale, NOT [0,1]. This is not cosmetic:
    % config/quality_thresholds.json was derived by tools/profile_image_quality.py,
    % which measures on 0-255. Computing on [0,1] here makes the value 255^2
    % smaller and every threshold comparison meaningless - the first version of
    % this file did exactly that and rejected 100% of all four corpora.
    % tests/test_quality_metrics.m pins the two implementations together.
    v = var(double(vals) * 255);
end
