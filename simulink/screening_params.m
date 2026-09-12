function [params, provenance] = screening_params(overrides)
%SCREENING_PARAMS  Operational parameters for rural DR screening, from the contract.
%
%   params = SCREENING_PARAMS() returns a struct of operational, clinical,
%   and infrastructure parameters calibrated for district-level diabetic
%   retinopathy screening in rural India (target: 100,000 patients/year).
%
%   params = SCREENING_PARAMS(overrides) overrides specific default fields.
%
%   [params, provenance] = SCREENING_PARAMS(...) also returns, per field, where
%   the number came from: SOURCED / DERIVED / MEASURED / ASSUMED / R4-LOCAL.
%
%   ⚠️ THE CONTRACT IS config/telemedicine_parameters.json, NOT THIS FILE.
%   That file is R3-owned and tags every value SOURCED / DERIVED / ASSUMED so
%   the Phase 5 write-up can separate findings from guesses - its own header
%   says "ASSUMED values must appear as assumptions in the Phase 5 write-up,
%   never as findings". This file previously hardcoded its own copy of those
%   numbers, and the two had drifted apart:
%
%       parameter              contract          this file (before)
%       images_per_patient     2  (SOURCED)      4
%       technician time        5.0 min (ASSUMED) 7.5 min
%       PHC uplink             5.0 Mbps(ASSUMED) 1.024 Mbps
%       quality reject rate    0.109 (SOURCED)   0.12
%       AI time per image      null  (PENDING)   0.120 s
%
%   Duplicated constants that disagree are worse than either value alone,
%   because the Phase 5 output then rests on numbers that bypassed R3's
%   provenance tagging entirely. Contract-backed fields are now LOADED from the
%   JSON; anything the contract does not cover keeps a local default and is
%   tagged R4-LOCAL so the write-up can say which is which.
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
    provenance = struct();

    % ---- load the contract ------------------------------------------------
    % Resolved relative to this file so it works from any working directory.
    thisDir = fileparts(mfilename('fullpath'));
    contractFile = fullfile(thisDir, '..', 'config', 'telemedicine_parameters.json');
    C = struct(); haveContract = false;
    if isfile(contractFile)
        C = jsondecode(fileread(contractFile));
        haveContract = true;
    else
        warning('drishti:noParamContract', ...
            ['config/telemedicine_parameters.json not found - falling back to ' ...
             'this file''s local defaults. Every parameter will be tagged ' ...
             'R4-LOCAL and NONE of it should be quoted as sourced.']);
    end

    % --- District Scale & Target -----------------------------------------
    params.districtPopulation      = 1.8e6;    % Average rural district population
    [params.annualScreeningTarget, provenance.annualScreeningTarget] = ...
        fromContract(C, haveContract, {'demand','target_patients_per_year'}, 100000);
    [params.operatingDaysPerYear, provenance.operatingDaysPerYear] = ...
        fromContract(C, haveContract, {'demand','operating_days_per_year'}, 250);
    params.operatingHoursPerDay    = 8;        % 09:00 - 17:00 PHC working hours

    % --- PHC / Hub-and-Spoke Topology ------------------------------------
    params.numPHCs                 = 40;       % Number of Primary Health Centres
    params.numVans                 = 4;        % Mobile screening vans for remote hamlets
    params.camerasPerCenter        = 1;        % Non-mydriatic fundus camera per center
    params.techniciansPerCamera    = 1;        % Trained rural ophthalmic assistant per camera

    % --- Stage 1: Acquisition (Patient Registration + Imaging) -----------
    % Bilateral 2-field photography (macula-centred + disc-centred, 2 images/eye = 4 images)
    % Contract says 5.0 min (ASSUMED); this file said 7.5. Contract wins. The
    % 7.5 figure traced to Aravind's 6-8 min BILATERAL acquisition window, which
    % is a different quantity from the contract's technician time per patient -
    % scenario analysis sweeps it rather than pretending either is settled.
    [params.meanExamMinutes, provenance.meanExamMinutes] = ...
        fromContract(C, haveContract, {'acquisition','technician_time_per_patient_min'}, 7.5);
    params.stdExamMinutes          = 1.5;      % Standard deviation (log-normal distribution)
    % Contract says 2 images/patient (SOURCED, Dey et al. 2025 - one macula-
    % centred field per eye). This file assumed 4 (two fields per eye), which
    % doubles both upload payload and AI compute. Contract wins.
    [params.imagesPerPatient, provenance.imagesPerPatient] = ...
        fromContract(C, haveContract, {'demand','images_per_patient'}, 4);
    [params.rawImageMegabytes, provenance.rawImageMegabytes] = ...
        fromContract(C, haveContract, {'upload','image_size_mb'}, 3.5);

    % --- Stage 2: Quality Assessment Gate (Module 1 Integration) ---------
    % Sourced from Module 1 measured baseline (docs/phase1_quality_baseline.md)
    [params.initialRejectRate, provenance.initialRejectRate] = ...
        fromContract(C, haveContract, {'ai_processing','quality_reject_rate'}, 0.12);
    params.immediateRecaptureProb  = 0.85;     % 85% successfully recaptured on-the-spot
    params.recaptureMinutes        = 2.5;      % Additional technician time for recapture
    params.permanentRejectRate     = 0.02;     % 2% persistently ungradeable (dense cataract, etc.)

    % --- Stage 3: Network Upload (Rural Connectivity) --------------------
    % Asymmetrical rural broadband / cellular 4G uplink
    % Contract carries Mbps; this model works in kbps.
    [upMbps, provenance.uplinkBandwidthKbps] = ...
        fromContract(C, haveContract, {'upload','assumed_rural_phc_upload_mbps'}, 1.0);
    params.uplinkBandwidthKbps     = upMbps * 1024;
    params.minBandwidthKbps        = 256;      % Bad cellular link / congestion floor
    params.networkFailureProb      = 0.05;     % 5% chance of intermittent link blackout
    params.meanDropoutMinutes      = 20.0;     % Mean link reconnection time

    % --- Stage 4: AI Processing (Edge vs. Central Inference) -------------
    % ⚠️ 0.120 s was a placeholder for a CNN forward pass. The DEPLOYED pipeline
    % also runs the quality gate, Module 2's classical detectors and Grad-CAM on
    % every image, and those dominate: BENCHMARKINFERENCETIME measures the full
    % pipeline at ~8 s/image on the dev GPU, ~65x the placeholder. Sizing compute
    % from the forward pass alone understates the requirement by two orders of
    % magnitude, which is the difference between "AI is free" and "AI needs a
    % staffed compute node".
    %
    % The contract slot (ai_processing.inference_time_per_image_s) was left
    % null/PENDING by R3 precisely so it would be measured rather than guessed.
    % It is read here when populated; the local fallback is the measured GPU
    % figure, NOT the old placeholder.
    [params.aiInferenceLatencySec, provenance.aiInferenceLatencySec] = ...
        fromContract(C, haveContract, {'ai_processing','inference_time_per_image_s'}, 8.0);
    params.numComputeNodes         = 2;        % Redundant server compute nodes at district hub
    provenance.numComputeNodes     = 'R4-LOCAL';

    % --- Stage 5: Tele-Ophthalmologist Review (Triage & Grading) ---------
    % Sourced from clinical review target (<30 second constraint):
    params.reviewSecondsGrade0     = 15.0;     % Normal fundus / clear negative (<15 sec)
    params.reviewSecondsGrade1     = 25.0;     % Mild NPDR (check microaneurysms, <25 sec)
    params.reviewSecondsGrade2     = 30.0;     % Moderate NPDR (referable threshold, ~30 sec)
    params.reviewSecondsGrade3     = 60.0;     % Severe NPDR (quadrant rule check, 60 sec)
    params.reviewSecondsGrade4     = 90.0;     % Proliferative DR / DME (urgent referral, 90 sec)
    params.reviewSecondsUngradeable= 20.0;     % Permanent ungradeable review (<20 sec)

    % ⚠️ COHORT CONFLICT, DELIBERATELY LEFT VISIBLE.
    % This grade mix implies referable (ICDR >= 2) = 16% and describes a
    % DIABETIC-ONLY screened cohort. The contract's review.referral_rate is
    % 0.0454 (DERIVED, Dey et al. 2025) and describes a GENERAL screened
    % population - and its own note calls it a FLOOR, since DME-only referrals
    % are excluded. 16% vs 4.5% is a 3.5x swing in ophthalmologist load, which
    % is the single most consequential number Phase 5 produces.
    %
    % These are not contradictory - they have different denominators - so
    % neither is silently picked. Both are carried, and
    % RUN_DISTRICT_SCENARIO_ANALYSIS reports staffing as a RANGE across the two
    % cohort definitions rather than a false point estimate.
    [params.contractReferralRate, provenance.contractReferralRate] = ...
        fromContract(C, haveContract, {'review','referral_rate'}, 0.0454);

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
    % Expected average review time across the modelled population is ~21.6 s.
    % NOTE this is conditional on Module 4 hitting its <30 s design target: the
    % contract tags review time ASSUMED and says so explicitly. Phase 4 built
    % the timing instrument (USABILITYPASS) but no clinician has been timed, so
    % this remains an assumption, not an observation.
    params.derivedReferableRate = params.probGrade2 + params.probGrade3 + params.probGrade4;

    % Every field not explicitly tagged above is this file's own default.
    f = fieldnames(params);
    for i = 1:numel(f)
        if ~isfield(provenance, f{i})
            provenance.(f{i}) = 'R4-LOCAL';
        end
    end
end


% ------------------------------------------------------------------ helpers

function [v, prov] = fromContract(C, haveContract, path, fallback)
%FROMCONTRACT  Read one value from the parameter contract, carrying its tag.
%
%   Returns the fallback (tagged R4-LOCAL) when the contract is missing, when
%   the key is absent, or when the key exists but its value is null - the last
%   case being how R3 marks a parameter as PENDING measurement rather than
%   guessed. A null must NOT silently become zero.

    v = fallback;
    prov = 'R4-LOCAL';
    if ~haveContract, return; end

    node = C;
    for k = 1:numel(path)
        if ~isstruct(node) || ~isfield(node, path{k}), return; end
        node = node.(path{k});
    end
    if ~isstruct(node) || ~isfield(node, 'value'), return; end
    if isempty(node.value), return; end          % null => PENDING, keep fallback

    v = node.value;
    if isfield(node, 'confidence')
        prov = char(node.confidence);
    else
        prov = 'SOURCED';
    end
end
