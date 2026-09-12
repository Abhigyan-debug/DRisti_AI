function R = recommend_district_configuration(opts)
%RECOMMEND_DISTRICT_CONFIGURATION  Minimum staffing/compute to hit the target.
%
%   R = RECOMMEND_DISTRICT_CONFIGURATION() answers the Phase 5 question the
%   README actually asks - "recommended camera/technician/compute/
%   ophthalmologist ratios and bottleneck report" - by sizing each resource
%   DOWN to the smallest count that still meets the utilisation ceiling.
%
%   R = RECOMMEND_DISTRICT_CONFIGURATION(maxUtilisation=0.85, verbose=true)
%
%   WHY SIZING DOWN, NOT SIMULATING UP
%   ----------------------------------
%   Run as configured (44 cameras, 3 ophthalmologists, 2 compute nodes) every
%   stage sits near 12% utilisation, nothing queues, and the simulator dutifully
%   reports a "bottleneck" at 13.6% - a number with no operational meaning. That
%   is not a finding about the pipeline, it is a statement that the assumed
%   district is over-provisioned by roughly 8x. The useful question is the
%   inverse: what is the LEAST a district needs?
%
%   THE UTILISATION CEILING IS NOT 100%
%   -----------------------------------
%   Sizing to 100% utilisation is sizing for a system with an unbounded queue:
%   at rho = 1 waiting time diverges, and a single sick day or a bad-network
%   morning turns into a backlog that never clears. 0.85 is the default ceiling
%   - a standard planning headroom, and ASSUMED, not sourced.
%
%   THE REFERRAL RATE IS REPORTED AS A RANGE, DELIBERATELY
%   ------------------------------------------------------
%   Ophthalmologist load scales directly with how many screens get referred, and
%   the project holds two defensible, non-contradictory figures:
%
%       4.54%  config/telemedicine_parameters.json (DERIVED, Dey et al. 2025),
%              a GENERAL screened population, and its own note calls it a floor
%              because DME-only referrals are excluded.
%       16%    the grade mix in SCREENING_PARAMS, a DIABETIC-ONLY cohort.
%
%   They differ by 3.5x and have different denominators. Collapsing them to one
%   number would manufacture a precision the evidence does not support, so both
%   are carried and the recommendation is an interval.
%
%   See also SCREENING_PARAMS, SIMULATE_DISTRICT_THROUGHPUT.

    arguments
        opts.maxUtilisation (1,1) double = 0.85
        opts.verbose (1,1) logical = true
    end

    p = screening_params();
    U = opts.maxUtilisation;

    minutesPerDay = p.operatingHoursPerDay * 60;
    patientsPerDay = p.targetPatientsPerDay;

    % Recapture inflates acquisition work: a rejected image sends the patient
    % back to the camera, it does not remove them from the system. The contract
    % calls this out explicitly as a modelling requirement.
    acqMinutesPerPatient = p.meanExamMinutes + ...
        p.initialRejectRate * p.immediateRecaptureProb * p.recaptureMinutes;

    uploadMinutesPerPatient = (p.totalPayloadMB * 8 * 1024) / p.uplinkBandwidthKbps / 60;
    aiMinutesPerPatient     = p.aiTotalLatencySec / 60;

    % --- demand per stage, in resource-minutes per day ---------------------
    demand = struct();
    demand.cameras         = patientsPerDay * acqMinutesPerPatient;
    demand.uplinks         = patientsPerDay * uploadMinutesPerPatient;
    demand.computeNodes    = patientsPerDay * aiMinutesPerPatient;

    % Review load at both cohort definitions.
    refRates = struct('contract_general', p.contractReferralRate, ...
                      'diabetic_cohort',  p.derivedReferableRate);

    R = struct();
    R.maxUtilisation = U;
    R.patientsPerDay = patientsPerDay;
    R.assumptions = struct( ...
        'acqMinutesPerPatient', acqMinutesPerPatient, ...
        'uploadMinutesPerPatient', uploadMinutesPerPatient, ...
        'aiMinutesPerPatient', aiMinutesPerPatient, ...
        'aiSecondsPerImage', p.aiInferenceLatencySec, ...
        'imagesPerPatient', p.imagesPerPatient);

    % --- size each non-review resource -------------------------------------
    R.cameras      = ceilUnits(demand.cameras,      minutesPerDay, U);
    R.uplinks      = ceilUnits(demand.uplinks,      minutesPerDay, U);
    R.computeNodes = ceilUnits(demand.computeNodes, minutesPerDay, U);

    % Technicians follow cameras 1:1 by the staffing model in the contract
    % (one vision technician per centre), so this is a restatement, not an
    % independent estimate - say so rather than presenting two numbers.
    R.technicians  = R.cameras;

    % --- review load: WHAT THE SPECIALIST ACTUALLY SEES ---------------------
    %
    % ⚠️ The specialist reviews what the classifier FLAGS, not what is diseased.
    % An earlier version of this function set the reviewed fraction equal to the
    % disease prevalence, which silently assumed a PERFECT classifier and
    % understated specialist load by ~10x. The flagged fraction is:
    %
    %     flagged = prevalence*sensitivity + (1-prevalence)*(1-specificity)
    %
    % and the false-positive term dominates whenever specificity is not near 1.
    %
    % Three operating points, all MEASURED (docs/phase3_results.md sections 3, 3b),
    % kept separate because they are not interchangeable:
    %
    %   idealised     referral = prevalence. NOT achievable; retained only to
    %                 show what the optimistic assumption was worth.
    %   uncalibrated  31.2% sens / 99.5% spec on Messidor-2 at the frozen APTOS
    %                 threshold. Low specialist load, because it MISSES most
    %                 disease - the light load is a symptom of the failure.
    %   calibrated    90.0% sens / 57.9% spec after per-site calibration on ~200
    %                 local images. This is the only SAFE operating point, and
    %                 it is the expensive one.
    shiftMinutes = p.ophthalmologistShiftHrs * 60;
    reviewSec = p.reviewSecondsGrade2;   % contract's 30 s - ASSUMED, see header

    opPoints = struct( ...
        'idealised',    struct('sens', 1.000, 'spec', 1.000), ...
        'uncalibrated', struct('sens', 0.312, 'spec', 0.995), ...
        'calibrated',   struct('sens', 0.900, 'spec', 0.579));

    R.ophthalmologists = struct();
    names = fieldnames(refRates);
    opNames = fieldnames(opPoints);
    for i = 1:numel(names)
        prev = refRates.(names{i});
        baselineMin = patientsPerDay * reviewSec / 60;   % read everything

        entry = struct('prevalence', prev, ...
                       'preAiBaselineMinPerDay', baselineMin, ...
                       'preAiBaselineCount', ceilUnits(baselineMin, shiftMinutes, U));
        for j = 1:numel(opNames)
            op = opPoints.(opNames{j});
            flagged = prev * op.sens + (1 - prev) * (1 - op.spec);
            mins = patientsPerDay * flagged * reviewSec / 60;
            entry.(opNames{j}) = struct( ...
                'sensitivity', op.sens, 'specificity', op.spec, ...
                'flaggedFraction', flagged, ...
                'minPerDay', mins, ...
                'count', ceilUnits(mins, shiftMinutes, U), ...
                'reductionVsBaseline', baselineMin / max(mins, eps));
        end
        R.ophthalmologists.(names{i}) = entry;
    end

    % The cost of the triage policy, stated next to its benefit. Auto-clearing
    % everything the AI calls negative means the AI's false negatives are never
    % seen by a human.
    %
    % ⚠️ TWO SENSITIVITIES, KEPT SEPARATE. 90.3% is APTOS-INTERNAL and is NOT a
    % universal property of the model. The SAME frozen threshold measured 31.2%
    % sensitivity on Messidor-2 (docs/phase3_results.md section 3). Quoting the
    % internal figure alone would understate missed patients by ~7x. Both are
    % carried; neither is presented as "the" sensitivity.
    missedAt = @(sens) patientsPerDay * refRates.diabetic_cohort * (1 - sens);
    R.triageSafetyNote = struct( ...
        'internalSensitivity',        0.903, ...
        'internalSource',             'APTOS validation split, n=733 (in-domain)', ...
        'missedReferablePerDay_internal', missedAt(0.903), ...
        'externalSensitivity',        0.312, ...
        'externalSource',             'Messidor-2, same frozen threshold, NO per-site calibration', ...
        'missedReferablePerDay_external', missedAt(0.312), ...
        'calibratedSensitivity',      0.900, ...
        'calibratedSource',           'Messidor-2 after per-site calibration on ~200 local images', ...
        'missedReferablePerDay_calibrated', missedAt(0.900), ...
        'deploymentRequirement', ['PER-SITE CALIBRATION IS A PRECONDITION, NOT AN ' ...
            'OPTIMISATION. Without it an unseen camera sits nearer the 31.2% ' ...
            'figure, and an AI-triage policy would auto-clear the majority of ' ...
            'referable patients at that site. See FITSITECALIBRATION and ' ...
            'docs/phase3_results.md section 3b.']);

    % --- what actually binds ------------------------------------------------
    % Compare each stage's demand against ONE unit of that resource, so the
    % ranking is "which resource do you run out of first", not an artefact of
    % how many were assumed available.
    perUnitLoad = [ demand.cameras      / minutesPerDay
                    demand.uplinks      / minutesPerDay
                    demand.computeNodes / minutesPerDay
                    R.ophthalmologists.diabetic_cohort.calibrated.minPerDay / ...
                        (p.ophthalmologistShiftHrs * 60) ];
    stageNames = {'Acquisition (camera+technician)', 'Network uplink', ...
                  'AI compute node', 'Ophthalmologist review'};
    [~, worst] = max(perUnitLoad);
    R.bindingConstraint = stageNames{worst};
    R.unitsRequiredPerStage = table(string(stageNames)', perUnitLoad, ...
        'VariableNames', {'stage', 'unitsRequiredAtFullUtilisation'});

    if opts.verbose
        fprintf('\n  ===== DISTRICT RIGHT-SIZING =====\n');
        fprintf('  target %g patients/day (%g/year over %d operating days)\n', ...
            patientsPerDay, p.annualScreeningTarget, p.operatingDaysPerYear);
        fprintf('  utilisation ceiling %.0f%% (ASSUMED planning headroom)\n\n', 100*U);

        fprintf('  ⚠ ASSUMPTION-DEPENDENT RESULT. Load-bearing assumptions:\n');
        fprintf('      review time 30 s/image   ASSUMED (Module 4 design target,\n');
        fprintf('                               NOT measured - no clinician timed)\n');
        fprintf('      technician time %.1f min  ASSUMED\n', p.meanExamMinutes);
        fprintf('      rural uplink %.1f Mbps    ASSUMED\n', p.uplinkBandwidthKbps/1024);
        fprintf('      operating days %d/yr     ASSUMED\n', p.operatingDaysPerYear);
        fprintf('      utilisation ceiling %.0f%%  ASSUMED\n', 100*U);
        fprintf('    Change any of these and the configuration below changes.\n');
        fprintf('    MEASURED inputs: AI %.2f s/image, %d images/patient, %.1f%% reject rate.\n', ...
            p.aiInferenceLatencySec, p.imagesPerPatient, 100*p.initialRejectRate);


        fprintf('  per-patient service times actually used:\n');
        fprintf('    acquisition incl. recapture  %5.2f min\n', acqMinutesPerPatient);
        fprintf('    upload (%d images, %.1f MB)   %5.2f min\n', ...
            p.imagesPerPatient, p.totalPayloadMB, uploadMinutesPerPatient);
        fprintf('    AI  %5.2f min  (MEASURED %.2f s/image x %d)\n\n', ...
            aiMinutesPerPatient, p.aiInferenceLatencySec, p.imagesPerPatient);

        fprintf('  MINIMUM VIABLE CONFIGURATION\n');
        fprintf('    cameras (+1 technician each)   %3d\n', R.cameras);
        fprintf('    PHC uplinks                    %3d\n', R.uplinks);
        fprintf('    AI compute nodes               %3d\n', R.computeNodes);
        fprintf('\n    OPHTHALMOLOGIST LOAD - the specialist reviews what the\n');
        fprintf('    classifier FLAGS, not what is diseased:\n');
        for i = 1:numel(names)
            o = R.ophthalmologists.(names{i});
            fprintf('      [%s cohort, prevalence %.1f%%]\n', names{i}, 100*o.prevalence);
            fprintf('        pre-AI baseline (read everything)        %5.1f min/day  (%d specialist)\n', ...
                o.preAiBaselineMinPerDay, o.preAiBaselineCount);
            fprintf('        AI, idealised (referral=prevalence)      %5.1f min/day  NOT ACHIEVABLE\n', ...
                o.idealised.minPerDay);
            fprintf('        AI, UNCALIBRATED site (31.2%%/99.5%%)      %5.1f min/day  UNSAFE - misses disease\n', ...
                o.uncalibrated.minPerDay);
            fprintf('        AI, site-CALIBRATED  (90.0%%/57.9%%)       %5.1f min/day  (%d specialist)  %.1fx vs baseline\n', ...
                o.calibrated.minPerDay, o.calibrated.count, o.calibrated.reductionVsBaseline);
        end
        fprintf('\n    The only SAFE operating point is the calibrated one, and it is\n');
        fprintf('    the expensive one: specificity 57.9%% means ~%.0f%%-%.0f%% of ALL screens\n', ...
            100*R.ophthalmologists.contract_general.calibrated.flaggedFraction, ...
            100*R.ophthalmologists.diabetic_cohort.calibrated.flaggedFraction);
        fprintf('    get flagged, mostly false positives. Real reduction vs reading\n');
        fprintf('    everything is ~2x, NOT the ~10x an idealised classifier implies.\n');

        fprintf('      => PER-SITE CALIBRATION IS A DEPLOYMENT REQUIREMENT, not a tuning step.\n');
        fprintf('\n  BINDING CONSTRAINT: %s\n', R.bindingConstraint);
        fprintf('  (units of each resource needed at 100%% utilisation:');
        fprintf(' %.2f', perUnitLoad); fprintf(')\n');
    end
end


function n = ceilUnits(demandMinutes, capacityMinutesPerUnit, maxUtil)
%CEILUNITS  Smallest whole number of units that keeps utilisation <= maxUtil.
    n = max(1, ceil(demandMinutes / (capacityMinutesPerUnit * maxUtil)));
end
