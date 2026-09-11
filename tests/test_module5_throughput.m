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

    % Reducing staffing to one clinician must move the bottleneck to review.
    testCase.verifyEqual(resChoked.bottleneckStage, 'Tele-Ophthalmologist Review', ...
        'Simulation failed to identify clinician shortage as primary bottleneck');

    % ...and must raise clinician load well above the 3-clinician baseline.
    resBase = simulate_district_throughput(screening_params(), 2);
    testCase.verifyGreaterThan(resChoked.ophthalmologistUtilization, ...
        resBase.ophthalmologistUtilization * 2, ...
        'Cutting 3 clinicians to 1 should sharply increase utilization');

    % NOTE ON THE ORIGINAL ASSERTION
    % This test previously required utilization > 0.85, and failed at 0.374.
    % The simulation was right and the expectation was wrong:
    %
    %   400 patients/day x 21.6 s mean review = 2.4 h against a 6.5 h shift
    %
    % One clinician really can absorb a 100,000-patient/year district. That is
    % not a modelling artefact - it is the designed consequence of the <30 s
    % AI-assisted report, and it is a headline result for Phase 5: at this
    % scale the constraint is acquisition capacity, not ophthalmologist supply.
    %
    % Asserting >85% saturation would have encoded the assumption the project
    % exists to refute, and "fixing" the simulation to satisfy it would have
    % destroyed the finding. Bounds below are sanity limits, not targets.
    testCase.verifyGreaterThan(resChoked.ophthalmologistUtilization, 0.20, ...
        'Utilization implausibly low - check review-time sampling');
    testCase.verifyLessThan(resChoked.ophthalmologistUtilization, 1.0, ...
        'Utilization cannot exceed 100% of available clinician time');
end
