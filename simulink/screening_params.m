function params = screening_params(overrides)
%SCREENING_PARAMS  Default operational parameters for rural DR screening.
%
%   params = SCREENING_PARAMS() returns a struct of operational, clinical,
%   and infrastructure parameters calibrated for district-level diabetic
%   retinopathy screening in rural India (target: 100,000 patients/year).
%
%   params = SCREENING_PARAMS(overrides) overrides specific default fields.
%
%   Sources & literature grounding:
%     1. Aravind Tele-ophthalmology Network (Raman et al., Ophthalmology 2016;
%        Prathiba et al., Community Eye Health 2018):
%        - 6-8 minute bilateral acquisition time per patient.
%        - Rural bandwidth constraints and store-and-forward triage workflows.
%     2. Sankara Nethralaya Rural Tele-screening Model (Rani et al., Eye 2021):
%        - PHC non-mydriatic screening; ungradeable image rate ~8-12%.
%        - Triage review time: <30s for normal/mild, 60-90s for referable.
%     3. Ayushman Bharat Health & Wellness Centres (HWC) District Model:
%        - Typical district population: 1.5 - 2.0 million.
%        - Target diabetic population: ~150,000 (ICMR-INDIAB study: ~10% prevalence).
%        - Annual screening target: 100,000 diabetic patients (~67% coverage).
%
%   See also SIMULATE_DISTRICT_THROUGHPUT, RUN_DISTRICT_SCENARIO_ANALYSIS.

    if nargin < 1 || isempty(overrides)
        overrides = struct();
    end

    params = struct();

    % --- District Scale & Target -----------------------------------------
    params.districtPopulation      = 1.8e6;    % Average rural district population
    params.annualScreeningTarget   = 100000;   % Target patients screened per year
    params.operatingDaysPerYear    = 250;      % 5 days/week * 50 weeks
    params.operatingHoursPerDay    = 8;        % 09:00 - 17:00 PHC working hours

    % --- PHC / Hub-and-Spoke Topology ------------------------------------
    params.numPHCs                 = 40;       % Number of Primary Health Centres
    params.numVans                 = 4;        % Mobile screening vans for remote hamlets
    params.camerasPerCenter        = 1;        % Non-mydriatic fundus camera per center
    params.techniciansPerCamera    = 1;        % Trained rural ophthalmic assistant per camera

    % --- Stage 1: Acquisition (Patient Registration + Imaging) -----------
    % Bilateral 2-field photography (macula-centred + disc-centred, 2 images/eye = 4 images)
    params.meanExamMinutes         = 7.5;      % Mean exam duration per patient (minutes)
    params.stdExamMinutes          = 1.5;      % Standard deviation (log-normal distribution)
    params.imagesPerPatient        = 4;        % 2 fields * 2 eyes
    params.rawImageMegabytes       = 3.5;      % High-resolution uncompressed/JPEG fundus image

    % --- Stage 2: Quality Assessment Gate (Module 1 Integration) ---------
    % Sourced from Module 1 measured baseline (docs/phase1_quality_baseline.md)
    params.initialRejectRate       = 0.12;     % 12% initial ungradeable / recapture needed
    params.immediateRecaptureProb  = 0.85;     % 85% successfully recaptured on-the-spot
    params.recaptureMinutes        = 2.5;      % Additional technician time for recapture
    params.permanentRejectRate     = 0.02;     % 2% persistently ungradeable (dense cataract, etc.)

    % --- Stage 3: Network Upload (Rural Connectivity) --------------------
    % Asymmetrical rural broadband / cellular 4G uplink
    params.uplinkBandwidthKbps     = 1024;     % Nominal 1 Mbps uplink per PHC
    params.minBandwidthKbps        = 256;      % Bad cellular link / congestion floor
    params.networkFailureProb      = 0.05;     % 5% chance of intermittent link blackout
    params.meanDropoutMinutes      = 20.0;     % Mean link reconnection time

    % --- Stage 4: AI Processing (Edge vs. Central Inference) -------------
    params.aiInferenceLatencySec   = 0.120;    % 120 ms per image on server GPU (RTX 5050 / T4)
    params.numComputeNodes         = 2;        % Redundant server compute nodes at district hub

    % --- Stage 5: Tele-Ophthalmologist Review (Triage & Grading) ---------
    % Sourced from clinical review target (<30 second constraint):
    params.reviewSecondsGrade0     = 15.0;     % Normal fundus / clear negative (<15 sec)
    params.reviewSecondsGrade1     = 25.0;     % Mild NPDR (check microaneurysms, <25 sec)
    params.reviewSecondsGrade2     = 30.0;     % Moderate NPDR (referable threshold, ~30 sec)
    params.reviewSecondsGrade3     = 60.0;     % Severe NPDR (quadrant rule check, 60 sec)
    params.reviewSecondsGrade4     = 90.0;     % Proliferative DR / DME (urgent referral, 90 sec)
    params.reviewSecondsUngradeable= 20.0;     % Permanent ungradeable review (<20 sec)

    % Disease Prevalence in Screened Diabetic Population (ICMR / India-specific):
    params.probGrade0              = 0.72;     % No DR (72%)
    params.probGrade1              = 0.12;     % Mild NPDR (12%)
    params.probGrade2              = 0.09;     % Moderate NPDR (9% - referable)
    params.probGrade3              = 0.04;     % Severe NPDR (4% - referable)
    params.probGrade4              = 0.03;     % Proliferative DR (3% - referable)

    % Staffing Configuration:
    params.numOphthalmologists     = 3;        % Dedicated reviewing tele-ophthalmologists at hub
    params.ophthalmologistShiftHrs = 6.5;      % Effective daily tele-screening reading hours

    % --- SLA / Target Turnaround Constraints -----------------------------
    params.targetSameDayTATMinutes = 120.0;    % Patient stays at PHC for report (<2 hours target)
    params.maxAcceptableWaitDays   = 1.0;      % Max store-and-forward batch delay (24 hours)

    % --- Apply Overrides -------------------------------------------------
    fields = fieldnames(overrides);
    for i = 1:numel(fields)
        params.(fields{i}) = overrides.(fields{i});
    end

    % --- Derived values --------------------------------------------------
    % ALL derived quantities are computed here, AFTER overrides are applied.
    %
    % They were previously computed inline next to their inputs, above the
    % override block, which meant screening_params(struct('numPHCs', 80))
    % returned the new numPHCs alongside a totalCameras still derived from 40 -
    % silently wrong, with no error. Phase 5's stated goal is recommending how
    % many cameras a district needs, so sweeping numPHCs is exactly the use
    % this file exists for.
    %
    % If you add a parameter that is computed from another, add it HERE.
    params.targetPatientsPerDay = params.annualScreeningTarget / params.operatingDaysPerYear;
    params.totalCameras         = params.numPHCs + params.numVans;
    params.totalPayloadMB       = params.imagesPerPatient * params.rawImageMegabytes;
    params.aiTotalLatencySec    = params.imagesPerPatient * params.aiInferenceLatencySec;

    params.meanReviewSeconds = ...
        params.probGrade0 * params.reviewSecondsGrade0 + ...
        params.probGrade1 * params.reviewSecondsGrade1 + ...
        params.probGrade2 * params.reviewSecondsGrade2 + ...
        params.probGrade3 * params.reviewSecondsGrade3 + ...
        params.probGrade4 * params.reviewSecondsGrade4;
    % Expected average review time across the modelled population is 21.6 s,
    % comfortably inside the <30 s review target the report is designed for.
end
