function report = run_district_scenario_analysis(savePlots)
%RUN_DISTRICT_SCENARIO_ANALYSIS  Scenario & sensitivity analysis for 100k target.
%
%   report = RUN_DISTRICT_SCENARIO_ANALYSIS() runs 4 district screening
%   scenarios to identify bottlenecks, validate staffing recommendations,
%   and benchmark SLA compliance for 100,000 patients/year.
%
%   report = RUN_DISTRICT_SCENARIO_ANALYSIS(savePlots) if true, saves
%   comparative figure plots.
%
%   Scenarios tested:
%     1. Baseline District Model (44 cameras, 1 Mbps uplink, 3 clinicians)
%     2. Degraded Rural Connectivity (256 Kbps, 15% dropouts)
%     3. Ophthalmologist Staffing Sensitivity (1, 2, 3, 4, 6 clinicians)
%     4. Edge AI vs Centralized Cloud Processing
%
%   See also SCREENING_PARAMS, SIMULATE_DISTRICT_THROUGHPUT.

    if nargin < 1
        savePlots = false;
    end

    fprintf('\n=================================================================\n');
    fprintf('  DRishti-AI: District-Scale Telemedicine Throughput Analysis\n');
    fprintf('  Target: 100,000 Patients / Year (400 Patients / Day)\n');
    fprintf('=================================================================\n\n');

    baseParams = screening_params();
    simDays = 5; % 1 business week simulation

    % ---------------------------------------------------------------------
    % Scenario 1: Baseline Model
    % ---------------------------------------------------------------------
    fprintf('--- Running Scenario 1: Baseline District Model ---\n');
    resBaseline = simulate_district_throughput(baseParams, simDays);
    print_scenario_summary('Baseline (1 Mbps, 3 Clinicians, 2 GPUs)', resBaseline);

    % ---------------------------------------------------------------------
    % Scenario 2: Degraded Rural Network (256 Kbps, 15% dropout)
    % ---------------------------------------------------------------------
    fprintf('--- Running Scenario 2: Degraded Rural Network ---\n');
    pDegraded = baseParams;
    pDegraded.uplinkBandwidthKbps = 256;
    pDegraded.networkFailureProb  = 0.15;
    pDegraded.meanDropoutMinutes  = 30.0;
    resDegraded = simulate_district_throughput(pDegraded, simDays);
    print_scenario_summary('Degraded Network (256 Kbps, 15% dropouts)', resDegraded);

    % ---------------------------------------------------------------------
    % Scenario 3: Ophthalmologist Staffing Sweep
    % ---------------------------------------------------------------------
    fprintf('--- Running Scenario 3: Clinician Staffing Sweep ---\n');
    ophthCounts = [1, 2, 3, 4, 6];
    ophthSweep = cell(numel(ophthCounts), 1);
    for i = 1:numel(ophthCounts)
        pOphth = baseParams;
        pOphth.numOphthalmologists = ophthCounts(i);
        ophthSweep{i} = simulate_district_throughput(pOphth, simDays);
        fprintf('  %d Ophthalmologist(s): Mean TAT = %5.1f min | p95 TAT = %5.1f min | Utilization = %5.1f%% | Same-Day SLA = %5.1f%%\n', ...
            ophthCounts(i), ophthSweep{i}.meanTAT, ophthSweep{i}.p95TAT, ...
            ophthSweep{i}.ophthalmologistUtilization * 100, ophthSweep{i}.slaWithin2HoursPct);
    end
    fprintf('\n');

    % ---------------------------------------------------------------------
    % Scenario 4: Edge AI Processing (Zero upload queue for AI)
    % ---------------------------------------------------------------------
    fprintf('--- Running Scenario 4: Edge Compute vs Central Cloud ---\n');
    pEdge = baseParams;
    pEdge.uplinkBandwidthKbps = 10000; % Local LAN upload speed to on-prem edge node
    resEdge = simulate_district_throughput(pEdge, simDays);
    print_scenario_summary('Edge AI (On-premise inference at CHC Hub)', resEdge);

    % ---------------------------------------------------------------------
    % Compile Final Sizing Recommendations
    % ---------------------------------------------------------------------
    report = struct();
    report.targetAnnualScreenings  = baseParams.annualScreeningTarget;
    report.dailyPatientLoad        = baseParams.targetPatientsPerDay;
    report.recommendedCameras      = baseParams.totalCameras;
    report.recommendedTechnicians  = baseParams.totalCameras;
    report.recommendedComputeNodes = baseParams.numComputeNodes;
    report.recommendedOphthalmologists = 3;
    report.baselineResults         = resBaseline;
    report.degradedNetworkResults  = resDegraded;
    report.edgeResults             = resEdge;
    report.clinicianSweepResults   = ophthSweep;

    % ---- recommendation ---------------------------------------------------
    % This block used to echo the ASSUMED inputs back as if they were findings:
    % it printed 44 cameras / 3 ophthalmologists / 2 GPUs (exactly what was fed
    % in), a hardcoded "~0.48 s/patient" left over from the 0.120 s CNN
    % placeholder, and named a stage sitting at 13.6% utilisation as the
    % "Primary Bottleneck". A resource that is 86% idle is not a bottleneck, and
    % a recommendation that returns its own input is not a recommendation.
    %
    % Sizing now comes from RECOMMEND_DISTRICT_CONFIGURATION, which solves for
    % the SMALLEST configuration meeting the utilisation ceiling.
    rec = recommend_district_configuration('verbose', false);
    report.rightSizing = rec;
    og = rec.ophthalmologists.contract_general;
    od = rec.ophthalmologists.diabetic_cohort;

    fprintf('=================================================================\n');
    fprintf('  RECOMMENDED DISTRICT DEPLOYMENT SIZING (100,000 Patients/Year)\n');
    fprintf('=================================================================\n');
    fprintf('  MINIMUM viable configuration (<=%.0f%% utilisation), NOT the\n', 100*rec.maxUtilisation);
    fprintf('  over-provisioned configuration assumed in the scenarios above:\n');
    fprintf('    Cameras + technicians : %d   (1 technician per camera)\n', rec.cameras);
    fprintf('    PHC uplinks           : %d\n', rec.uplinks);
    fprintf('    AI compute nodes      : %d   (MEASURED %.2f s/image x %d = %.1f s/patient)\n', ...
        rec.computeNodes, rec.assumptions.aiSecondsPerImage, ...
        rec.assumptions.imagesPerPatient, rec.assumptions.aiMinutesPerPatient*60);
    fprintf('    Ophthalmologists      : %d   (site-CALIBRATED operating point)\n', ...
        max(og.calibrated.count, od.calibrated.count));
    fprintf('      specialist load %.0f-%.0f min/day at the only SAFE operating point\n', ...
        og.calibrated.minPerDay, od.calibrated.minPerDay);
    fprintf('      (90.0%%/57.9%%, per-site calibrated), vs %.0f min/day reading every\n', ...
        og.preAiBaselineMinPerDay);
    fprintf('      image: a %.1f-%.1fx reduction. NOT the ~10x that an idealised\n', ...
        od.calibrated.reductionVsBaseline, og.calibrated.reductionVsBaseline);
    fprintf('      classifier (referral = prevalence) would imply.\n');
    fprintf('    BINDING CONSTRAINT    : %s\n', rec.bindingConstraint);
    fprintf('\n  Same-day TAT (baseline run): median %.1f min, p95 %.1f min, SLA<2h %.1f%%\n', ...
        resBaseline.medianTAT, resBaseline.p95TAT, resBaseline.slaWithin2HoursPct);
    fprintf('  PER-SITE CALIBRATION IS A DEPLOYMENT REQUIREMENT. Uncalibrated, the\n');
    fprintf('  same threshold measured 31.2%% sensitivity on Messidor-2 and would\n');
    fprintf('  auto-clear ~%.0f of the %.0f referable patients seen per day.\n', ...
        rec.triageSafetyNote.missedReferablePerDay_external, ...
        rec.patientsPerDay * 0.16);
    fprintf('  ALL THROUGHPUT FIGURES ABOVE ARE ASSUMPTION-DEPENDENT (30 s review\n');
    fprintf('  time is a design target, not a measurement). See docs/phase5_results.md.\n');
    fprintf('=================================================================\n\n');
end

% -------------------------------------------------------------------------
% Helper: Print Scenario Summary Block
% -------------------------------------------------------------------------
function print_scenario_summary(titleStr, res)
    fprintf('  [%s]\n', titleStr);
    fprintf('    - Screened / Week   : %d patients (%d permanent rejects, %.1f%%)\n', ...
        res.screenedCount, res.permRejectCount, res.permRejectRate * 100);
    fprintf('    - Recaptures        : %d images (%.1f%% immediate on-the-spot retakes)\n', ...
        res.recapturedCount, res.recaptureRate * 100);
    fprintf('    - Turnaround Time   : Mean %.1f min | Median %.1f min | p95 %.1f min | Max %.1f min\n', ...
        res.meanTAT, res.medianTAT, res.p95TAT, res.maxTAT);
    fprintf('    - SLA Compliance    : <1 hr: %.1f%% | <2 hrs (Same-day): %.1f%% | <24 hrs: %.1f%%\n', ...
        res.slaWithin1HourPct, res.slaWithin2HoursPct, res.slaWithin24HoursPct);
    fprintf('    - Utilizations      : Camera: %4.1f%% | Uplink: %4.1f%% | GPU: %4.1f%% | Clinician: %4.1f%%\n', ...
        res.cameraUtilization*100, res.networkUtilization*100, ...
        res.aiGpuUtilization*100, res.ophthalmologistUtilization*100);
    fprintf('    - Identified Critical Bottleneck: %s (%.1f%% utilization)\n\n', ...
        res.bottleneckStage, res.bottleneckUtilization * 100);
end
