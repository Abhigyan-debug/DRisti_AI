function tests = test_module5_throughput
%TEST_MODULE5_THROUGHPUT  Unit tests for Module 5 throughput simulation.
%
%   Run with:
%       >> runtests('tests/test_module5_throughput.m')
%
%   See also SCREENING_PARAMS, SIMULATE_DISTRICT_THROUGHPUT.

    tests = functiontests(localfunctions);
end

% -------------------------------------------------------------------------
% Test 1: Parameters Initialization & Sourced Boundaries
% -------------------------------------------------------------------------
function testParamsInitialization(testCase)
    p = screening_params();

    testCase.verifyNotEmpty(p);
    testCase.verifyEqual(p.annualScreeningTarget, 100000);
    testCase.verifyEqual(p.targetPatientsPerDay, 400);
    testCase.verifyTrue(p.totalCameras >= 40, 'Total cameras should cover rural district');
    testCase.verifyTrue(p.meanReviewSeconds < 30.0, 'Average review time must be <30s target');
    testCase.verifyTrue(p.uplinkBandwidthKbps >= 256, 'Bandwidth should match rural uplink range');
end

% -------------------------------------------------------------------------
% Test 2: Parameter Overrides
% -------------------------------------------------------------------------
function testParamsOverrides(testCase)
    custom = struct('uplinkBandwidthKbps', 2048, 'numOphthalmologists', 5);
    p = screening_params(custom);

    testCase.verifyEqual(p.uplinkBandwidthKbps, 2048);
    testCase.verifyEqual(p.numOphthalmologists, 5);
end

% -------------------------------------------------------------------------
% Test 3: Simulation Conservation of Patients & Throughput
% -------------------------------------------------------------------------
function testSimulationExecution(testCase)
    p = screening_params();
    simDays = 2; % Short test run
    res = simulate_district_throughput(p, simDays);

    testCase.verifyNotEmpty(res);
    testCase.verifyTrue(res.totalPatients > 0);

    % Conservation check: screened + permanently rejected = total patients
    testCase.verifyEqual(res.screenedCount + res.permRejectCount, res.totalPatients, ...
        'Patient flow conservation violated: screened + rejected != total');

    % Annualized throughput projection should be close to 100k target (+/- 15%)
    testCase.verifyTrue(res.annualThroughputProj >= 85000 && res.annualThroughputProj <= 120000, ...
        'Annual throughput projection deviates significantly from 100k target');
end

% -------------------------------------------------------------------------
% Test 4: Turnaround Time and SLA Constraints
% -------------------------------------------------------------------------
function testTurnaroundTimes(testCase)
    p = screening_params();
    res = simulate_district_throughput(p, 2);

    testCase.verifyTrue(res.meanTAT > 0, 'Mean TAT must be positive');
    testCase.verifyTrue(res.medianTAT <= res.p90TAT, 'Median TAT must be <= p90 TAT');
    testCase.verifyTrue(res.p90TAT <= res.p95TAT, 'p90 TAT must be <= p95 TAT');
    testCase.verifyTrue(res.p95TAT <= res.maxTAT, 'p95 TAT must be <= max TAT');

    % Under standard staffing, same-day SLA should be substantial
    testCase.verifyTrue(res.slaWithin2HoursPct >= 70.0, ...
        'Expected same-day (<2 hr) turnaround to exceed 70% under baseline staffing');
end

% -------------------------------------------------------------------------
% Test 5: Bottleneck Sensitivity Under Severe Resource Constraint
% -------------------------------------------------------------------------
function testBottleneckDetection(testCase)
    % Constrain ophthalmologist staffing to just 1 clinician for entire district
    pChoked = screening_params(struct('numOphthalmologists', 1));
    resChoked = simulate_district_throughput(pChoked, 2);

    testCase.verifyTrue(resChoked.ophthalmologistUtilization > 0.85, ...
        '1 clinician for 400 pts/day should produce severe clinician saturation');
    testCase.verifyEqual(resChoked.bottleneckStage, 'Tele-Ophthalmologist Review', ...
        'Simulation failed to identify clinician shortage as primary bottleneck');
end
