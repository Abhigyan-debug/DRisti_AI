function reportData = clinical_report_template()
%CLINICAL_REPORT_TEMPLATE  Default data contract for DRishti-AI clinical reports.
%
%   reportData = CLINICAL_REPORT_TEMPLATE() returns a prototype data struct
%   populating all clinical, technical, and explainability fields required for
%   the one-page annotated screening report.
%
%   Fields are structured to satisfy the <30 second ophthalmologist triage bar.
%
%   See also GENERATE_CLINICAL_REPORT, RECAPTURE_MESSAGES.

    reportData = struct();

    % --- Patient & Screening Metadata ------------------------------------
    reportData.patientId        = 'DR-2026-08412';
    reportData.patientAge       = 58;
    reportData.patientGender    = 'Female';
    reportData.diabetesDuration = '11 years (Type 2)';
    reportData.screeningCenter  = 'PHC Chhatarpur, District Hospital Hub';
    reportData.technicianName   = 'A. Sharma (Opht. Assistant)';
    reportData.screeningDate    = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm'));
    reportData.eyeExamined      = 'OD (Right Eye)';
    reportData.cameraModel      = 'Remidio FOP NM-10 (45° Non-Mydriatic)';

    % --- Module 1: Quality Gate Assessment -------------------------------
    reportData.qualityStatus    = 'PASSED'; % PASSED | ENHANCED | REJECTED
    reportData.focusScore       = 0.88;     % Normalized focus score [0, 1]
    reportData.illuminationScore= 0.91;     % Illumination uniformity [0, 1]
    reportData.fovCoverageScore = 0.86;     % Effective retina FOV coverage [0, 1]
    reportData.enhancementsApplied = {'CLAHE contrast enhancement', 'Homomorphic illumination balance'};
    reportData.recaptureAdvice  = '';       % Empty if passed

    % --- Module 2: Retinal Lesion Quantification -------------------------
    reportData.lesions = struct();
    reportData.lesions.microaneurysmCount  = 14;      % Count of detected MAs
    reportData.lesions.hemorrhageCount     = 6;       % Blot / flame hemorrhages
    reportData.lesions.hardExudateAreaPct  = 1.25;    % % of retinal surface area
    reportData.lesions.hardExudateInMacula = true;    % Located within 1 disc diameter of fovea
    reportData.lesions.softExudateCount    = 2;       % Cotton wool spots
    reportData.lesions.neovascularization  = false;   % New fragile vessels at disc/periphery
    reportData.lesions.opticDiscLocation   = [2048, 1420]; % Center [X, Y]
    reportData.lesions.foveaLocation       = [1410, 1460]; % Center [X, Y]

    % --- Module 3: ICDR Severity Grading & Calibration -------------------
    reportData.predictedGrade   = 2;                  % 0: None, 1: Mild, 2: Moderate, 3: Severe, 4: PDR
    reportData.gradeName        = 'Moderate NPDR';
    reportData.isReferable      = true;               % ICDR Grade >= 2
    reportData.calibratedConfidence = 0.914;          % 91.4% confidence (Platt scaled)
    reportData.gradeProbabilities   = [0.02, 0.05, 0.91, 0.02, 0.00]; % [0, 1, 2, 3, 4]

    % --- Module 4: Explainability & Evidence Table -----------------------
    % Maps Grad-CAM attention hotspots directly to physical segmented lesions:
    reportData.evidenceTable = {
        'Hotspot #1 (Inferior Macula)', 'Hard Exudates', 'Cluster of 5 yellowish lipid deposits <1 DD from fovea (Risk of DME)', 'HIGH'
        'Hotspot #2 (Superior Temporal)', 'Microaneurysms', '7 focal red punctate lesions along vessel bifurcation', 'HIGH'
        'Hotspot #3 (Nasal Mid-periphery)', 'Blot Hemorrhages', '3 intra-retinal hemorrhages in quadrant 2', 'MODERATE'
        'Hotspot #4 (Superior)', 'Soft Exudate', '1 cotton-wool nerve fiber layer infarct', 'LOW'
    };

    % --- Clinical Recommendation & Triage Action -------------------------
    reportData.urgencyLevel     = 'REFERRAL_REQUIRED'; % ROUTINE | REFERRAL_REQUIRED | URGENT_PDR
    reportData.recommendedAction= 'Refer to District Hospital Eye Clinic within 30 days for dilated slit-lamp biomicroscopy and OCT assessment for Diabetic Macular Edema (DME).';
    reportData.followUpInterval = '30 Days';

    % --- Reviewer Sign-off ------------------------------------------------
    reportData.reviewedBy       = 'Pending Review';
    reportData.reviewStatus     = 'AWAITING_SPECIALIST_SIGN_OFF';
    reportData.targetReviewSec  = '< 30 Seconds';
end
