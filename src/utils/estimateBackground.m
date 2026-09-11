function bg = estimateBackground(chan, mask, fovDiameter)
%ESTIMATEBACKGROUND  Low-frequency illumination field of a fundus channel.
%
%   bg = ESTIMATEBACKGROUND(chan, mask, fovDiameter) returns the smooth
%   illumination component of a single channel, same size as chan.
%
%   Used both to correct illumination (ENHANCEIMAGE) and to detrend before
%   measuring contrast (MEASUREILLUMINATION), so the two cannot disagree about
%   what "the background" is.
%
%   Performance
%   -----------
%   The blur needed here has sigma ~ fovDiameter/12, which is about 357 px on a
%   4288x2848 IDRiD image. Running that at full resolution cost 2.3 s per image
%   and pushed the Module 1 p95 past 10 s - unacceptable for Module 5's
%   throughput model, and pure waste: the result is by construction
%   low-frequency, so it carries no detail that survives full-resolution
%   sampling anyway.
%
%   Estimating on a downscaled copy and resizing back is visually
%   indistinguishable and roughly 50x faster.
%
%   See also ENHANCEIMAGE, MEASUREILLUMINATION.

    arguments
        chan (:,:) {mustBeNumeric}
        mask (:,:) logical
        fovDiameter (1,1) double {mustBePositive}
    end

    % Fill the surround with the FOV mean before blurring. Blurring across a
    % black surround drags the estimate down near the FOV edge and leaves a
    % bright ring after subtraction.
    inside = chan(mask);
    if isempty(inside)
        bg = chan;
        return
    end
    filled = chan;
    filled(~mask) = mean(inside);

    % Work at a resolution where the blur is cheap but still well sampled.
    WORK_FOV_PX = 256;
    scale = min(1, WORK_FOV_PX / fovDiameter);

    if scale < 1
        small = imresize(filled, scale, 'bilinear');
        sigmaSmall = max(2, (fovDiameter / 12) * scale);
        bgSmall = imgaussfilt(small, sigmaSmall, 'Padding', 'replicate');
        bg = imresize(bgSmall, size(chan), 'bilinear');
    else
        bg = imgaussfilt(filled, max(2, fovDiameter / 12), 'Padding', 'replicate');
    end
end
