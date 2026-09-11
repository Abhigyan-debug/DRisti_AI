function n = measureNoise(img, fov)
%MEASURENOISE  Robust sensor-noise estimate inside the field of view.
%
%   n = MEASURENOISE(img, fov) returns an estimated noise standard deviation on
%   a [0,1] luminance scale.
%
%   Why this is a separate gate check
%   ---------------------------------
%   Noise is the one defect the sharpness metric gets BACKWARDS. Laplacian
%   variance measures high-frequency energy, and noise is high-frequency
%   energy - so a noisy image scores as *sharper*. The degradation study
%   measured Spearman rho = +0.67 between injected noise severity and the
%   sharpness score, and noisy images were never rejected at any severity.
%
%   That is a screening hazard in two directions: a noisy capture can mask a
%   microaneurysm, and amplified noise can imitate one.
%
%   Method: median absolute deviation of the Laplacian response. The MAD is
%   used rather than the standard deviation because vessels and lesions are
%   legitimate high-frequency content, and a plain std would count them as
%   noise - penalising exactly the images with the most to see.
%
%   The 1.4826 factor converts MAD to a Gaussian-equivalent sigma; the /4
%   normalises the Laplacian kernel gain so the result reads as an intensity.
%
%   See also ASSESSQUALITY, GATEIMAGE.

    arguments
        img (:,:,:) {mustBeNumeric}
        fov struct
    end

    gray = toGray(img);
    lap = imfilter(gray, [0 -1 0; -1 4 -1; 0 -1 0] / 4, 'replicate');

    % Same 7x7 erosion as the sharpness measure - the FOV boundary is a hard
    % step edge and would swamp the estimate.
    inner = imerode(fov.mask, strel('square', 7));
    vals = lap(inner);
    if numel(vals) < 100
        n = 0;
        return
    end
    n = 1.4826 * median(abs(vals - median(vals)));
end
