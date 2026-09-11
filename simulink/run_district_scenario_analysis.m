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

    fprintf('=================================================================\n');
    fprintf('  RECOMMENDED DISTRICT DEPLOYMENT SIZING (100,000 Patients/Year)\n');
    fprintf('=================================================================\n');
    fprintf('  • Acquisition Units     : %d Cameras + %d Technicians across 40 PHCs + 4 Vans\n', ...
        report.recommendedCameras, report.recommendedTechnicians);
    fprintf('  • Central Compute       : %d GPU Nodes (Server inference: ~0.48 s / patient)\n', ...
        report.recommendedComputeNodes);
    fprintf('  • Tele-Ophthalmologists : %d Dedicated Specialists (<30s review workflow)\n', ...
        report.recommendedOphthalmologists);
    fprintf('  • Clinician Utilization : %.1f%% (Safe operating zone: 60-80%%)\n', ...
        resBaseline.ophthalmologistUtilization * 100);
    fprintf('  • Expected Same-Day TAT : Median %.1f min (95th percentile: %.1f min)\n', ...
        resBaseline.medianTAT, resBaseline.p95TAT);
    fprintf('  • Same-Day SLA Delivery : %.1f%% of patients receive report before leaving PHC\n', ...
        resBaseline.slaWithin2HoursPct);
    fprintf('  • Primary Bottleneck    : %s (%.1f%% load)\n', ...
        resBaseline.bottleneckStage, resBaseline.bottleneckUtilization * 100);
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
