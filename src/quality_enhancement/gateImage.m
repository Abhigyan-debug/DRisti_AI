function d = gateImage(q, th)
%GATEIMAGE  Decide pass / enhance / reject, with an actionable recapture reason.
%
%   d = GATEIMAGE(q) takes an ASSESSQUALITY struct and returns:
%       d.decision  'pass' | 'enhance' | 'reject'
%       d.reasons   struct array: .code, .severity, .message, .value, .threshold
%       d.summary   one-line human summary
%       d.gradable  logical - false only for 'reject'
%
%   d = GATEIMAGE(q, th) supplies thresholds explicitly (for sweeps/testing).
%
%   Decision policy
%   ---------------
%     reject   at least one metric past its reject threshold. Unrecoverable -
%              no amount of enhancement puts back detail that was never
%              captured. Returns a recapture instruction.
%     enhance  at least one metric in the borderline band. ENHANCEIMAGE runs,
%              then the image is re-assessed and re-gated.
%     pass     everything inside tolerance.
%
%   Screening asymmetry
%   -------------------
%   A false reject costs one retake. A false accept sends an ungradeable image
%   into grading, where it produces a confident-looking wrong answer - the
%   failure mode this whole module exists to prevent. So borderline resolves
%   toward 'enhance', never toward 'pass'.
%
%   The messages are written for a rural PHC technician standing at the camera,
%   per the README's Module 1 spec. They name the fix, not the metric.
%
%   See also ASSESSQUALITY, ENHANCEIMAGE.

    arguments
        q struct
        th struct = loadQualityThresholds()
    end

    reasons = emptyReason();

    % ---- FOV detection failed -------------------------------------------
    if ~q.fov.valid
        reasons(end+1) = mkReason('fov_not_found', 'reject', ...
            'No retina detected. Check the camera is aligned to the eye and the lens cap is off.', ...
            q.fov.coverage, NaN);
    end

    % ---- sharpness -------------------------------------------------------
    % Per-band thresholds, measured by CALIBRATEQUALITYTHRESHOLDS. One flat
    % cut-off does not survive a 6.7x resolution range even after FOV
    % normalisation. See MEASURESHARPNESS.
    bandTh       = th.sharpness.byBand.(q.sharpness.band);
    rejectAt     = bandTh.reject;
    borderlineAt = bandTh.borderline;

    if q.sharpness.normalised < rejectAt
        reasons(end+1) = mkReason('out_of_focus', 'reject', ...
            'Image is out of focus. Refocus on the vessels at the optic disc and retake.', ...
            q.sharpness.normalised, rejectAt);
    elseif q.sharpness.normalised < borderlineAt
        reasons(end+1) = mkReason('soft_focus', 'borderline', ...
            'Focus is soft. Retake if convenient.', ...
            q.sharpness.normalised, borderlineAt);
    end

    % ---- exposure --------------------------------------------------------
    if q.illum.meanIntensity < th.exposure.darkReject
        reasons(end+1) = mkReason('underexposed', 'reject', ...
            'Image is too dark. Increase illumination and retake.', ...
            q.illum.meanIntensity, th.exposure.darkReject);
    elseif q.illum.meanIntensity > th.exposure.brightReject
        reasons(end+1) = mkReason('overexposed', 'reject', ...
            'Image is washed out. Reduce flash intensity and retake.', ...
            q.illum.meanIntensity, th.exposure.brightReject);
    end

    if q.illum.darkFraction > th.exposure.darkFractionReject
        reasons(end+1) = mkReason('large_dark_region', 'reject', ...
            'A large part of the retina is in shadow. Re-centre the camera and retake.', ...
            q.illum.darkFraction, th.exposure.darkFractionReject);
    end

    % ---- illumination uniformity ----------------------------------------
    % Uneven illumination is NEVER a hard reject on its own. Correcting it is
    % precisely what Module 1's enhancement stage exists to do, so routing it
    % straight to reject throws away images the pipeline is designed to fix.
    % Native-resolution inspection confirmed the images rejected on this code
    % had clearly visible discs and vessels - they were gradable.
    %
    % Catastrophic cases are still caught: a half-black frame trips
    % 'large_dark_region', and an unusable exposure trips under/overexposed.
    % The real decision is made when the enhanced image is re-gated.
    if q.illum.uniformityCV > th.illumination.reject
        reasons(end+1) = mkReason('severe_uneven_illumination', 'borderline', ...
            gradientMessage(q.illum.brightSide, true), ...
            q.illum.uniformityCV, th.illumination.reject);
    elseif q.illum.uniformityCV > th.illumination.borderline
        reasons(end+1) = mkReason('mild_uneven_illumination', 'borderline', ...
            gradientMessage(q.illum.brightSide, false), ...
            q.illum.uniformityCV, th.illumination.borderline);
    end

    % ---- glare -----------------------------------------------------------
    if q.illum.glareFraction > th.glare.reject
        reasons(end+1) = mkReason('glare', 'reject', ...
            'Strong reflection blocking the retina. Adjust the angle slightly and retake.', ...
            q.illum.glareFraction, th.glare.reject);
    elseif q.illum.glareFraction > th.glare.borderline
        reasons(end+1) = mkReason('mild_glare', 'borderline', ...
            'Some reflection present.', ...
            q.illum.glareFraction, th.glare.borderline);
    end

    % ---- contrast --------------------------------------------------------
    if q.illum.contrast < th.contrast.reject
        reasons(end+1) = mkReason('low_contrast', 'borderline', ...
            'Low contrast - attempting enhancement.', ...
            q.illum.contrast, th.contrast.reject);
    end

    % ---- framing ---------------------------------------------------------
    % Deliberately NOT thresholded on fov.coverage: coverage is a camera
    % fingerprint, not a quality signal (IDRiD 0.691 vs Messidor-2 0.465), so an
    % absolute cut-off would reject an entire corpus for its crop convention.
    % Truncation on more than one edge is a real framing fault though.
    if q.fov.valid && q.fov.truncated
        edges = countTruncatedEdges(q.fov, q.sizePx);
        if edges >= 3
            reasons(end+1) = mkReason('fov_clipped', 'borderline', ...
                'Retina is cut off at the edges. Move back slightly and re-centre.', ...
                edges, 3);
        end
    end

    % ---- noise -----------------------------------------------------------
    % Checked explicitly because the sharpness metric gets noise BACKWARDS:
    % noise is high-frequency energy, so a noisy image scores as sharper
    % (measured Spearman rho = +0.67 against injected noise). Without this
    % check, heavy sensor noise passes the gate at every severity.
    if isfield(q, 'noise')
        if q.noise > th.noise.reject
            reasons(end+1) = mkReason('excessive_noise', 'reject', ...
                'Image is too grainy to read. Increase illumination so the camera can use a lower gain, then retake.', ...
                q.noise, th.noise.reject);
        elseif q.noise > th.noise.borderline
            reasons(end+1) = mkReason('noisy', 'borderline', ...
                'Image is grainy - attempting correction.', ...
                q.noise, th.noise.borderline);
        end
    end

    % ---- suppress misleading focus advice --------------------------------
    % The sharpness metric depends on gradient magnitude, so ANY defect that
    % flattens the image - underexposure, overexposure, veiling haze - drives
    % it down and trips 'out_of_focus'. The degradation study found darken,
    % brighten and haze all reporting focus as the reject reason.
    %
    % That is not a harmless mislabel. "Refocus on the vessels at the optic
    % disc and retake" sends a technician to do the one thing that will not
    % help; they retake and get the same dark frame. The message a technician
    % acts on has to name the real fault.
    %
    % When exposure, contrast or noise is out of range the focus reading is not
    % trustworthy, so the focus reason is dropped in favour of the root cause.
    % The root cause must itself be a REJECT before it displaces the focus
    % reason. Allowing a borderline cause to do it silently downgrades the
    % verdict: darkening lowers contrast, which raised a borderline
    % 'low_contrast', which cancelled the 'out_of_focus' reject and let heavily
    % underexposed images through. The degradation study caught this as
    % darken and haze regressing from a 0.625 detection floor to never.
    rootCauseCodes = {'underexposed', 'overexposed', 'large_dark_region', ...
                      'excessive_noise'};
    isRootCause = ismember({reasons.code}, rootCauseCodes) & ...
                  strcmp({reasons.severity}, 'reject');
    if any(isRootCause)
        keep = ~ismember({reasons.code}, {'out_of_focus', 'soft_focus'});
        reasons = reasons(keep);
    end

    % ---- resolve ---------------------------------------------------------
    if isempty(reasons)
        d.decision = 'pass';
    elseif any(strcmp({reasons.severity}, 'reject'))
        d.decision = 'reject';
    else
        d.decision = 'enhance';
    end

    d.reasons  = reasons;
    d.gradable = ~strcmp(d.decision, 'reject');
    d.summary  = summarise(d);
end


% ------------------------------------------------------------------ helpers

function r = emptyReason()
    r = struct('code', {}, 'severity', {}, 'message', {}, ...
               'value', {}, 'threshold', {});
end

function r = mkReason(code, severity, message, value, threshold)
    r = struct('code', code, 'severity', severity, 'message', message, ...
               'value', value, 'threshold', threshold);
end

function msg = gradientMessage(side, severe)
%GRADIENTMESSAGE  Turn a gradient direction into a camera instruction.
    switch side
        case 'left',   where = 'Light is falling off on the right.';
        case 'right',  where = 'Light is falling off on the left.';
        case 'top',    where = 'Light is falling off at the bottom.';
        case 'bottom', where = 'Light is falling off at the top.';
        otherwise,     where = 'Illumination is uneven across the retina.';
    end
    if severe
        msg = [where ' Re-centre the camera on the pupil and retake.'];
    else
        msg = [where ' Minor - attempting correction.'];
    end
end

function n = countTruncatedEdges(fov, sizePx)
    tol = 2;
    b = fov.bbox;
    n = (b(1) <= tol) + (b(2) <= tol) + ...
        ((b(1) + b(3)) >= sizePx(2) - tol) + ...
        ((b(2) + b(4)) >= sizePx(1) - tol);
end

function s = summarise(d)
    switch d.decision
        case 'pass'
            s = 'Gradable.';
        case 'enhance'
            s = sprintf('Borderline (%s) - enhancing.', ...
                strjoin({d.reasons.code}, ', '));
        case 'reject'
            isReject = strcmp({d.reasons.severity}, 'reject');
            firstMsg = d.reasons(find(isReject, 1)).message;
            s = sprintf('Ungradable: %s', firstMsg);
    end
end
