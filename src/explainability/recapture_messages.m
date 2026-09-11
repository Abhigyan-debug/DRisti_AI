function msg = recapture_messages(reasonCode, details)
%RECAPTURE_MESSAGES  Actionable field instructions for rural PHC technicians.
%
%   msg = RECAPTURE_MESSAGES(reasonCode, details) translates automated
%   Module 1 quality failure codes into plain, technician-friendly instructions
%   in English (with clinical context) designed to guide immediate on-the-spot
%   recapture before the patient leaves the clinic.
%
%   reasonCode options:
%     'DEFOCUS'         - Blur / out of focus (Laplacian variance fail)
%     'UNDER_EXPOSED'   - Image too dark / flash intensity insufficient
%     'OVER_EXPOSED'    - Glare / saturation artifact
%     'OFF_CENTER'      - Field-of-view misaligned (fovea or disc clipped)
%     'EYELASH_MEDIA'   - Partial eyelid/eyelash obscuration or cataract
%     'PUPIL_CONSTRICT' - Pupil too small / excessive ambient room light
%     'MOTION_ARTIFACT' - Patient movement or eye saccade during capture
%
%   See also CLINICAL_REPORT_TEMPLATE, GENERATE_CLINICAL_REPORT.

    if nargin < 2
        details = struct();
    end

    switch upper(string(reasonCode))
        case "DEFOCUS"
            msg.title = "Image Out of Focus (Blur Detected)";
            msg.action = "Adjust diopter knob on camera. Ask patient to keep their gaze steady on the internal green fixation target.";
            msg.technicianTip = "Ensure forehead and chin are pressed firmly against the rests before triggering capture.";
            msg.severity = "RECAPTURE_REQUIRED";

        case "UNDER_EXPOSED"
            msg.title = "Insufficient Illumination (Under-exposed)";
            msg.action = "Increase flash intensity by 1-2 steps on camera console. Check that ambient examination room lights are dimmed.";
            msg.technicianTip = "Dark retinas or small pupils require higher flash power or 2-3 minutes of dark adaptation.";
            msg.severity = "RECAPTURE_REQUIRED";

        case "OVER_EXPOSED"
            msg.title = "Excessive Glare / Corneal Reflection";
            msg.action = "Reduce flash intensity by 1 step. Ensure the objective lens is clean and adjust working distance slightly forward/back.";
            msg.technicianTip = "Align the corneal reflection dots until they vanish or center within the pupil aperture.";
            msg.severity = "RECAPTURE_REQUIRED";

        case "OFF_CENTER"
            msg.title = "Incorrect Centering (Macula / Disc Clipped)";
            msg.action = "Re-center the camera aiming beam. For Field 1, center on macula (fovea); for Field 2, center on optic disc.";
            msg.technicianTip = "Switch the internal fixation LED target to guide the patient's eye position.";
            msg.severity = "RECAPTURE_REQUIRED";

        case "EYELASH_MEDIA"
            msg.title = "Lid / Eyelash Artifact or Media Opacity";
            msg.action = "Gently instruct patient to open eyes wide. If necessary, have assistant hold the upper eyelid.";
            msg.technicianTip = "If pupil shows persistent grey/white opacity (dense cataract), mark as 'Clinically Ungradeable' and refer for slit-lamp.";
            msg.severity = "CONDITIONAL_RECAPTURE";

        case "PUPIL_CONSTRICT"
            msg.title = "Pupil Constriction (< 3.0 mm)";
            msg.action = "Allow patient 3 minutes of dark adaptation in a fully darkened room before attempting recapture.";
            msg.technicianTip = "Confirm non-mydriatic camera small-pupil aperture mode is active if available.";
            msg.severity = "RECAPTURE_REQUIRED";

        case "MOTION_ARTIFACT"
            msg.title = "Motion Blur Detected";
            msg.action = "Patient blinked or moved during exposure. Remind patient not to blink when they hear the camera click.";
            msg.technicianTip = "Count down '3-2-1' so the patient anticipates the flash without flinching.";
            msg.severity = "RECAPTURE_REQUIRED";

        otherwise
            msg.title = "Quality Check Failed";
            msg.action = "Retake the image ensuring proper patient alignment, steady fixation, and clean camera optics.";
            msg.technicianTip = "Refer patient to medical officer if 2 recapture attempts fail.";
            msg.severity = "RECAPTURE_REQUIRED";
    end

    msg.code = char(reasonCode);
    msg.timestamp = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
end
