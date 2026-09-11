function [out, applied] = enhanceImage(img, q, opts)
%ENHANCEIMAGE  Adaptive correction of recoverable fundus image defects.
%
%   [out, applied] = ENHANCEIMAGE(img, q) corrects the image using only the
%   steps its measured defects call for. q is an ASSESSQUALITY struct.
%
%   applied is a struct of logicals recording which steps ran, so the report
%   (Module 4) can state what was done to an image before it was graded.
%
%   Options
%     'force'      run every step regardless of measured need (for comparison)
%     'thresholds' explicit threshold struct
%
%   What can and cannot be recovered
%   --------------------------------
%   Illumination gradients, low contrast and sensor noise are *recoverable* -
%   the retinal detail is present in the capture, just poorly rendered.
%
%   Focus is NOT recoverable. Detail that was never resolved cannot be
%   restored, and sharpening only amplifies noise into lesion-shaped artifacts.
%   GATEIMAGE therefore rejects out-of-focus images outright rather than
%   sending them here, and PROCESSIMAGE carries the original focus verdict
%   forward instead of re-deriving it from the enhanced image. See the note in
%   PROCESSIMAGE about why re-scoring focus after CLAHE is unsafe.
%
%   Clinical safety
%   ---------------
%   Every step is bounded to avoid fabricating structures that look like
%   pathology. CLAHE in particular will manufacture bright speckle that mimics
%   microaneurysms and hard exudates if its clip limit is set aggressively, and
%   Module 2 would then dutifully detect them. The clip limit here is
%   deliberately conservative; do not raise it to make images "look better".
%
%   All operations are confined to the field of view. The surround stays black.
%
%   See also ASSESSQUALITY, GATEIMAGE, PROCESSIMAGE.

    arguments
        img (:,:,:) {mustBeNumeric}
        q struct
        opts.force (1,1) logical = false
        opts.thresholds struct = loadQualityThresholds()
    end

    th = opts.thresholds;
    applied = struct('illumination', false, 'clahe', false, 'denoise', false);

    rgb = im2double(img);
    if size(rgb, 3) ~= 3
        rgb = repmat(rgb, 1, 1, 3);
    end
    mask = q.fov.mask;

    % Work in L*a*b* and touch only L. Enhancing R, G and B independently
    % shifts hue, and in fundus imaging hue is diagnostic - exudates are
    % yellow-white, haemorrhages red. Colour must survive enhancement intact.
    lab = rgb2lab(rgb);
    L = lab(:,:,1) / 100;              % adapthisteq wants [0,1]

    % ---- 1. illumination normalisation ----------------------------------
    needIllum = opts.force || ...
        (~isnan(q.illum.uniformityCV) && q.illum.uniformityCV > th.illumination.borderline);
    if needIllum
        L = normaliseIllumination(L, mask, q.fov.diameter);
        applied.illumination = true;
    end

    % ---- 2. denoise ------------------------------------------------------
    % BEFORE contrast enhancement, not after. CLAHE multiplies whatever
    % high-frequency content it finds, so noise left in place at this point
    % gets amplified into bright speckle in the dark paramacular region -
    % speckle that is the size and shape of a microaneurysm, which Module 2
    % would then detect as pathology in a healthy eye. Denoising afterwards is
    % worse than useless: it smooths away the very structure CLAHE recovered.
    %
    % Verified visually - an APTOS image enhanced with CLAHE and no prior
    % denoise showed clear background grain that was absent in the original.
    needClahe = opts.force || q.illum.contrast < th.contrast.reject * 1.5;
    noiseLevel = estimateNoise(L, mask);

    % Denoise whenever the image is measurably noisy, OR whenever CLAHE is
    % about to run - amplification makes even modest noise consequential.
    if opts.force || noiseLevel > 0.004 || needClahe
        L = denoiseChannel(L, q.fov.diameter);
        applied.denoise = true;
    end

    % ---- 3. contrast (CLAHE) --------------------------------------------
    if needClahe
        L = applyCLAHE(L, mask, q.fov.diameter);
        applied.clahe = true;
    end

    % ---- reassemble ------------------------------------------------------
    lab(:,:,1) = min(max(L, 0), 1) * 100;
    out = lab2rgb(lab);
    out = min(max(out, 0), 1);

    % Keep the surround black - a grey halo outside the FOV would confuse
    % DETECTFOV on the re-assessment pass.
    out = out .* repmat(double(mask), 1, 1, 3);

    if isinteger(img)
        out = cast(out * double(intmax(class(img))), class(img));
    end
end


% ------------------------------------------------------------------ steps

function L = normaliseIllumination(L, mask, fovDiameter)
%NORMALISEILLUMINATION  Remove the low-frequency illumination gradient.
%
%   Estimates the background as a heavily blurred copy and subtracts it,
%   restoring the original mean so overall exposure is unchanged.

    % Shared with MEASUREILLUMINATION so the correction and the contrast
    % measurement cannot disagree about what the background is. Sigma scales
    % with the FOV, so the same physical retinal distance is smoothed whether
    % the image is 640x480 or 4288x2848.
    if ~any(mask(:))
        return
    end
    background = estimateBackground(L, mask, fovDiameter);

    corrected = L - background + mean(background(mask));
    L(mask) = corrected(mask);
    L = min(max(L, 0), 1);
end


function L = applyCLAHE(L, mask, fovDiameter)
%APPLYCLAHE  Contrast-limited adaptive histogram equalisation on L*.

    % Tiles sized so each covers a comparable patch of retina across cameras.
    % ~1/8 of the FOV per tile is the usual choice for fundus work.
    tilesAcross = max(4, min(16, round(size(L, 2) / max(fovDiameter/8, 1))));
    nTiles = [max(4, round(tilesAcross * size(L,1) / size(L,2))), tilesAcross];

    % ClipLimit 0.01 is deliberate restraint. At 0.02+ CLAHE starts producing
    % bright speckle in the dark paramacular region that is indistinguishable
    % from microaneurysms to Module 2's detector. A false lesion is worse than
    % a dull image.
    equalised = adapthisteq(L, 'NumTiles', nTiles, 'ClipLimit', 0.01, ...
                            'Distribution', 'rayleigh');

    % Only inside the FOV; the black surround must not be stretched to grey.
    L(mask) = equalised(mask);
end


function L = denoiseChannel(L, fovDiameter)
%DENOISECHANNEL  Edge-preserving denoise.
%
%   Non-local means is the quality choice but is punishingly slow at 4288x2848
%   (tens of seconds per image), which Module 5's throughput model cannot
%   absorb. A guided filter gives most of the edge preservation at a fraction
%   of the cost, and vessel edges are what must survive.

    radius = max(2, round(fovDiameter / 400));
    L = imguidedfilter(L, 'NeighborhoodSize', [radius radius], ...
                       'DegreeOfSmoothing', 0.002);
end


function n = estimateNoise(L, mask)
%ESTIMATENOISE  Robust noise estimate from high-frequency residual.
%
%   Median absolute deviation of the Laplacian response, scaled to a standard
%   deviation. The MAD is used rather than the standard deviation because
%   vessels and lesions are legitimate high-frequency content and would
%   otherwise be counted as noise.

    lap = imfilter(L, [0 -1 0; -1 4 -1; 0 -1 0] / 4, 'replicate');
    inner = imerode(mask, strel('square', 7));
    vals = lap(inner);
    if numel(vals) < 100
        n = 0;
        return
    end
    n = 1.4826 * median(abs(vals - median(vals)));
end
