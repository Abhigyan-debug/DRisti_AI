function out = degradeImage(img, mode, severity, fov)
%DEGRADEIMAGE  Apply a controlled, physically-motivated defect to a fundus image.
%
%   out = DEGRADEIMAGE(img, mode, severity) degrades img by a known amount.
%   out = DEGRADEIMAGE(img, mode, severity, fov) reuses a DETECTFOV result.
%
%   severity runs 0 (untouched) to 1 (severe). The mapping is chosen so that
%   ~0.5 sits near the boundary a human grader would call borderline, but that
%   is an assumption to be checked, not a calibration - see the warning below.
%
%   Modes
%     'blur'         optical defocus (disk PSF, not Gaussian - see below)
%     'illumination' off-axis lighting falloff across the retina
%     'glare'        specular reflection: achromatic blown-out patches
%     'darken'       underexposure (multiplicative)
%     'brighten'     overexposure toward saturation
%     'noise'        sensor noise at low light (signal-dependent)
%     'haze'         media opacity / cataract - veiling glare, contrast loss
%
%   EVERY severity is scaled to the FOV diameter
%   -------------------------------------------
%   A fixed 5-pixel blur is catastrophic on a 640x480 capture and invisible on
%   a 4288x2848 one. Scaling by FOV diameter means severity 0.5 removes the
%   same *physical retinal detail* regardless of camera, which is what makes a
%   degradation study comparable across our three resolution bands - and that
%   band coverage is the reason to build this rather than rely on a
%   single-camera labelled set.
%
%   WHAT THIS CAN AND CANNOT TELL YOU
%   ---------------------------------
%   It establishes that the gate responds monotonically to each failure mode
%   and where its detection floor sits. It does NOT establish where a human
%   would draw the ungradable line: synthetic defocus is not cataract, and a
%   linear brightness ramp is not a misaligned flash. Do not calibrate reject
%   thresholds against these severities and claim clinical validity.
%
%   See also RUNDEGRADATIONSTUDY, PROCESSIMAGE.

    arguments
        img (:,:,:) {mustBeNumeric}
        mode (1,:) char {mustBeMember(mode, {'blur','illumination','glare', ...
            'darken','brighten','noise','haze'})}
        severity (1,1) double {mustBeInRange(severity, 0, 1)}
        fov struct = struct()
    end

    if severity == 0
        out = img;
        return
    end
    if ~isfield(fov, 'mask')
        fov = detectFOV(img);
    end

    rgb = im2double(img);
    if size(rgb, 3) ~= 3
        rgb = repmat(rgb, 1, 1, 3);
    end
    d = fov.diameter;

    switch mode
        case 'blur'
            out = applyDefocus(rgb, severity, d);
        case 'illumination'
            out = applyIlluminationFalloff(rgb, severity, fov);
        case 'glare'
            out = applyGlare(rgb, severity, fov);
        case 'darken'
            out = rgb * (1 - 0.85 * severity);
        case 'brighten'
            out = 1 - (1 - rgb) * (1 - 0.80 * severity);
        case 'noise'
            out = applySensorNoise(rgb, severity);
        case 'haze'
            out = applyHaze(rgb, severity, fov);
    end

    out = min(max(out, 0), 1);
    % The surround stays black - a degradation that lights up the background
    % would break DETECTFOV and confound the very thing being measured.
    out = out .* repmat(double(fov.mask), 1, 1, 3);

    if isinteger(img)
        out = cast(out * double(intmax(class(img))), class(img));
    end
end


% ------------------------------------------------------------------ modes

function out = applyDefocus(rgb, severity, fovDiameter)
%APPLYDEFOCUS  Optical defocus via a disk point-spread function.
%
%   A defocused lens convolves the scene with a DISK, not a Gaussian. The
%   difference matters here: a disk PSF preserves more mid-frequency energy and
%   produces the characteristic doubled-edge look of real defocus, whereas a
%   Gaussian rolls off smoothly and is easier for a variance-of-Laplacian
%   measure to detect. Testing against Gaussian blur would flatter the gate.

    radius = max(1, severity * fovDiameter / 90);
    psf = fspecial('disk', radius);
    out = imfilter(rgb, psf, 'replicate');
end


function out = applyIlluminationFalloff(rgb, severity, fov)
%APPLYILLUMINATIONFALLOFF  Off-axis lighting: brightness ramp across the retina.
%
%   Models the commonest handheld failure - the illumination beam not centred
%   on the pupil, so one side of the retina is lit and the other falls away.

    [h, w, ~] = size(rgb);
    [X, Y] = meshgrid(1:w, 1:h);

    % Ramp along a fixed diagonal, normalised over the FOV so severity means
    % the same fractional falloff on any camera.
    cx = fov.centre(1); cy = fov.centre(2);
    dirX = 0.85; dirY = 0.53;
    proj = ((X - cx) * dirX + (Y - cy) * dirY) / max(fov.diameter/2, 1);

    % severity 1 -> the dark edge retains 15% of the bright edge
    gain = 1 - severity * 0.85 * (0.5 + 0.5 * max(min(proj, 1), -1));
    out = rgb .* gain;
end


function out = applyGlare(rgb, severity, fov)
%APPLYGLARE  Specular reflection - achromatic blow-out, not a colour cast.
%
%   Real glare saturates all three channels toward white. Modelling it as a
%   bright red patch would be trivially separable from retina and would not
%   exercise the min(R,G,B) glare detector at all.

    [h, w, ~] = size(rgb);
    [X, Y] = meshgrid(1:w, 1:h);

    % One dominant patch plus a smaller satellite, both inside the FOV.
    r = fov.radius;
    patchR = severity * r * 0.42;
    spots = [fov.centre(1) + 0.30*r, fov.centre(2) - 0.22*r, patchR; ...
             fov.centre(1) - 0.38*r, fov.centre(2) + 0.30*r, patchR * 0.55];

    % FLAT-TOPPED core, not a Gaussian peak. A specular highlight is fully
    % blown across its whole extent with a narrow soft rim - severity controls
    % the AREA of the reflection, not its brightness. That is the physical
    % truth and it matters for the measurement: a Gaussian profile saturates
    % only a pinpoint centre (~0.5% of the FOV even at severity 1.0, under the
    % 0.8% reject threshold), which made the study report glare as undetectable
    % when the metric was fine and the degradation model was the problem.
    glow = zeros(h, w);
    for k = 1:size(spots, 1)
        dist = sqrt((X - spots(k,1)).^2 + (Y - spots(k,2)).^2);
        R = max(spots(k,3), 1);
        % 1.0 inside 0.6R, linear rim out to R
        core = max(0, min(1, (1 - dist / R) / 0.4));
        glow = max(glow, core);
    end

    % Alpha-blend toward white: specular reflection replaces the retinal
    % signal rather than brightening it.
    alpha = repmat(glow, 1, 1, 3);
    out = rgb .* (1 - alpha) + alpha;
end


function out = applySensorNoise(rgb, severity)
%APPLYSENSORNOISE  Signal-dependent (shot) noise, as seen in low-light capture.
%
%   Noise in a real sensor scales with the square root of signal, so dark
%   regions are noisiest. Additive uniform Gaussian noise would be unrealistic
%   and would sit mostly where the retina is brightest.

    sigma = severity * 0.11;
    shot = sqrt(max(rgb, 0.01));
    out = rgb + randn(size(rgb)) .* sigma .* shot;
end


function out = applyHaze(rgb, severity, fov)
%APPLYHAZE  Media opacity - cataract, vitreous haze, a dirty lens.
%
%   Veiling glare: a fraction of the light is scattered into a uniform wash,
%   lifting the black level and compressing contrast WITHOUT blurring edges.
%   This is the most diagnostically interesting mode, because it is the one
%   real-world failure that a focus metric may wrongly flag as defocus - the
%   image is sharp but low-contrast. Worth knowing which way our gate calls it.

    t = 1 - 0.75 * severity;                 % transmission
    veil = mean(rgb(repmat(fov.mask,1,1,3)), 'all');
    out = rgb * t + veil * (1 - t);
end
