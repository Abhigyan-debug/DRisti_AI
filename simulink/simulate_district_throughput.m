function results = simulate_district_throughput(params, numDays)
%SIMULATE_DISTRICT_THROUGHPUT  Discrete-event simulation of district DR screening.
%
%   results = SIMULATE_DISTRICT_THROUGHPUT(params, numDays) simulates the
%   end-to-end patient and data flow across a rural district over numDays
%   operational days (default: 5 days = 1 work week).
%
%   Stages simulated:
%     1. Patient arrival & camera acquisition at rural PHCs and mobile vans (parallel)
%     2. Quality assessment & on-the-spot technician recapture
%     3. Rural network upload queue and transmission to district hub (parallel)
%     4. AI inference server batch processing (chronologically interleaved)
%     5. Tele-ophthalmologist triage queue & review (chronologically interleaved)
%
%   Output results struct contains:
%     - summary metrics (throughput, total patients, screened, rejected)
%     - per-stage queue wait times and processing durations
%     - resource utilization percentages (cameras, network, GPU, clinicians)
%     - end-to-end turnaround time (TAT) percentiles (p50, p90, p95, p99)
%     - bottleneck identification and SLA compliance rates
%
%   See also SCREENING_PARAMS, RUN_DISTRICT_SCENARIO_ANALYSIS.

    if nargin < 1 || isempty(params)
        params = screening_params();
    end
    if nargin < 2 || isempty(numDays)
        numDays = 5; % 1 business week default
    end

    totalCenters = params.totalCameras; % PHCs + mobile vans
    patientsPerCenterPerDay = ceil(params.targetPatientsPerDay / totalCenters);
    simMinutesPerDay = params.operatingHoursPerDay * 60;

    totalExpectedPatients = params.targetPatientsPerDay * numDays * 2;
    
    patientId        = zeros(totalExpectedPatients, 1);
    centerId         = zeros(totalExpectedPatients, 1);
    simDay           = zeros(totalExpectedPatients, 1);
    arrivalTime      = zeros(totalExpectedPatients, 1);
    acqStartTime     = zeros(totalExpectedPatients, 1);
    acqEndTime       = zeros(totalExpectedPatients, 1);
    recaptured       = false(totalExpectedPatients, 1);
    permanentlyReject= false(totalExpectedPatients, 1);
    uploadStartTime  = zeros(totalExpectedPatients, 1);
    uploadEndTime    = zeros(totalExpectedPatients, 1);
    aiStartTime      = zeros(totalExpectedPatients, 1);
    aiEndTime        = zeros(totalExpectedPatients, 1);
    reviewStartTime  = zeros(totalExpectedPatients, 1);
    reviewEndTime    = zeros(totalExpectedPatients, 1);
    icdrGrade        = zeros(totalExpectedPatients, 1);
    totalTATMinutes  = zeros(totalExpectedPatients, 1);

    patientCount = 0;

    for d = 1:numDays
        dayOffset = (d - 1) * simMinutesPerDay;
        clinicArrivalWindow = 6.5 * 60; % 390 minutes

        % Temporary storage for day d patients before central queue sorting
        dayStartIdx = patientCount + 1;

        % --- Parallel Local PHC Processing (Acquisition & Upload) ---------
        for c = 1:totalCenters
            cameraNextFree = dayOffset;
            uploadNextFree = dayOffset;

            nPatients = max(1, round(normrnd(patientsPerCenterPerDay, 1.5)));
            rawArrivals = sort(rand(nPatients, 1) * clinicArrivalWindow) + dayOffset;

            for p = 1:nPatients
                patientCount = patientCount + 1;
                idx = patientCount;

                patientId(idx) = idx;
                centerId(idx) = c;
                simDay(idx) = d;
                arrTime = rawArrivals(p);
                arrivalTime(idx) = arrTime;

                % Stage 1: Acquisition
                acqStart = max(arrTime, cameraNextFree);
                examDur = max(4.0, normrnd(params.meanExamMinutes, params.stdExamMinutes));

                % Stage 2: Quality Gate
                needsRecap = (rand() < params.initialRejectRate);
                isReject = false;
                if needsRecap
                    if rand() < params.immediateRecaptureProb
                        examDur = examDur + params.recaptureMinutes;
                        recaptured(idx) = true;
                    else
                        isReject = true;
                        permanentlyReject(idx) = true;
                    end
                end

                acqEnd = acqStart + examDur;
                acqStartTime(idx) = acqStart;
                acqEndTime(idx) = acqEnd;
                cameraNextFree = acqEnd;

                % Assign Grade
                r = rand();
                if r < params.probGrade0
                    grade = 0;
                elseif r < (params.probGrade0 + params.probGrade1)
                    grade = 1;
                elseif r < (params.probGrade0 + params.probGrade1 + params.probGrade2)
                    grade = 2;
                elseif r < (params.probGrade0 + params.probGrade1 + params.probGrade2 + params.probGrade3)
                    grade = 3;
                else
                    grade = 4;
                end
                icdrGrade(idx) = grade;

                if isReject
                    uploadStartTime(idx) = acqEnd;
                    uploadEndTime(idx) = acqEnd;
                    aiStartTime(idx) = acqEnd;
                    aiEndTime(idx) = acqEnd;
                    reviewStartTime(idx) = acqEnd;
                    reviewEndTime(idx) = acqEnd;
                    totalTATMinutes(idx) = acqEnd - arrTime;
                    continue;
                end

                % Stage 3: Network Upload
                payloadBits = params.totalPayloadMB * 8 * 1024 * 1024;
                effBw = max(params.minBandwidthKbps * 1000, ...
                    normrnd(params.uplinkBandwidthKbps * 1000, 200 * 1000));
                txSec = payloadBits / effBw;
                if rand() < params.networkFailureProb
                    txSec = txSec + (params.meanDropoutMinutes * 60);
                end
                txMin = txSec / 60.0;

                upStart = max(acqEnd, uploadNextFree);
                upEnd = upStart + txMin;
                uploadStartTime(idx) = upStart;
                uploadEndTime(idx) = upEnd;
                uploadNextFree = upEnd;
            end
        end

        dayEndIdx = patientCount;
        dayIndices = dayStartIdx:dayEndIdx;

        % --- Chronological Interleaving for Central Hub Processing --------
        % Filter for valid (non-rejected) patients who uploaded to hub
        validDayIdx = dayIndices(~permanentlyReject(dayIndices));
        
        % Sort valid patients by upload completion timestamp
        [~, sortOrder] = sort(uploadEndTime(validDayIdx));
        sortedPatientIndices = validDayIdx(sortOrder);

        % Central Server Queues for day d
        aiNextFreeTime = zeros(params.numComputeNodes, 1) + dayOffset;
        ophthNextFreeTime = zeros(params.numOphthalmologists, 1) + dayOffset;

        aiDurationMin = params.aiTotalLatencySec / 60.0;

        for k = 1:numel(sortedPatientIndices)
            pIdx = sortedPatientIndices(k);
            upFinish = uploadEndTime(pIdx);

            % Stage 4: Central AI Compute
            [earliestNode, bestNode] = min(aiNextFreeTime);
            aiStart = max(upFinish, earliestNode);
            aiEnd = aiStart + aiDurationMin;
            aiStartTime(pIdx) = aiStart;
            aiEndTime(pIdx) = aiEnd;
            aiNextFreeTime(bestNode) = aiEnd;

            % Stage 5: Tele-Ophthalmologist Review
            grade = icdrGrade(pIdx);
            switch grade
                case 0, revSec = params.reviewSecondsGrade0;
                case 1, revSec = params.reviewSecondsGrade1;
                case 2, revSec = params.reviewSecondsGrade2;
                case 3, revSec = params.reviewSecondsGrade3;
                case 4, revSec = params.reviewSecondsGrade4;
                otherwise, revSec = 30.0;
            end
            revSec = max(5.0, normrnd(revSec, revSec * 0.15));
            revMin = revSec / 60.0;

            [earliestOphth, bestOphth] = min(ophthNextFreeTime);
            revStart = max(aiEnd, earliestOphth);
            revEnd = revStart + revMin;
            reviewStartTime(pIdx) = revStart;
            reviewEndTime(pIdx) = revEnd;
            ophthNextFreeTime(bestOphth) = revEnd;

            totalTATMinutes(pIdx) = revEnd - arrivalTime(pIdx);
        end
    end

    % Trim unused preallocations
    validIdx = (1:patientCount)';
    patientId        = patientId(validIdx);
    centerId         = centerId(validIdx);
    simDay           = simDay(validIdx);
    arrivalTime      = arrivalTime(validIdx);
    acqStartTime     = acqStartTime(validIdx);
    acqEndTime       = acqEndTime(validIdx);
    recaptured       = recaptured(validIdx);
    permanentlyReject= permanentlyReject(validIdx);
    uploadStartTime  = uploadStartTime(validIdx);
    uploadEndTime    = uploadEndTime(validIdx);
    aiStartTime      = aiStartTime(validIdx);
    aiEndTime        = aiEndTime(validIdx);
    reviewStartTime  = reviewStartTime(validIdx);
    reviewEndTime    = reviewEndTime(validIdx);
    icdrGrade        = icdrGrade(validIdx);
    totalTATMinutes  = totalTATMinutes(validIdx);

    % Summary Statistics
    screenedSuccessfully = sum(~permanentlyReject);
    recapturedCount = sum(recaptured);
    permRejectCount = sum(permanentlyReject);
    tatValid = totalTATMinutes(~permanentlyReject);

    results = struct();
    results.numDays              = numDays;
    results.totalPatients        = patientCount;
    results.annualThroughputProj = (patientCount / numDays) * params.operatingDaysPerYear;
    results.screenedCount        = screenedSuccessfully;
    results.recapturedCount      = recapturedCount;
    results.permRejectCount      = permRejectCount;
    results.permRejectRate       = permRejectCount / patientCount;
    results.recaptureRate        = recapturedCount / patientCount;

    % Turnaround times (minutes)
    results.meanTAT              = mean(tatValid);
    results.medianTAT            = median(tatValid);
    results.p90TAT               = prctile(tatValid, 90);
    results.p95TAT               = prctile(tatValid, 95);
    results.p99TAT               = prctile(tatValid, 99);
    results.maxTAT               = max(tatValid);

    % Stage durations
    durationAcq      = acqEndTime - acqStartTime;
    durationUpload   = uploadEndTime - uploadStartTime;
    durationAI       = aiEndTime - aiStartTime;
    durationReview   = reviewEndTime - reviewStartTime;

    results.meanDurationAcq      = mean(durationAcq);
    results.meanDurationUpload   = mean(durationUpload(~permanentlyReject));
    results.meanDurationAI       = mean(durationAI(~permanentlyReject));
    results.meanDurationReview   = mean(durationReview(~permanentlyReject));

    % Resource Utilizations
    totalSimMinutes = numDays * simMinutesPerDay;
    results.cameraUtilization = sum(durationAcq) / (totalCenters * totalSimMinutes);
    results.networkUtilization = sum(durationUpload(~permanentlyReject)) / (totalCenters * totalSimMinutes);
    results.aiGpuUtilization = sum(durationAI(~permanentlyReject)) / (params.numComputeNodes * totalSimMinutes);

    clinicianShiftMinutes = numDays * params.numOphthalmologists * (params.ophthalmologistShiftHrs * 60);
    results.ophthalmologistUtilization = sum(durationReview(~permanentlyReject)) / clinicianShiftMinutes;

    % SLA Compliance:
    results.slaWithin1HourPct   = 100 * mean(tatValid <= 60.0);
    results.slaWithin2HoursPct  = 100 * mean(tatValid <= params.targetSameDayTATMinutes);
    results.slaWithin24HoursPct = 100 * mean(tatValid <= (params.maxAcceptableWaitDays * 24 * 60));

    % Bottleneck Diagnosis:
    utils = [results.cameraUtilization, results.networkUtilization, ...
             results.aiGpuUtilization, results.ophthalmologistUtilization];
    stageNames = {'Camera/Technician Acquisition', 'Rural Network Upload', ...
                  'Central AI Server GPU', 'Tele-Ophthalmologist Review'};
    [maxUtil, maxIdx] = max(utils);
    results.bottleneckStage = stageNames{maxIdx};
    results.bottleneckUtilization = maxUtil;

    results.gradeCounts = [sum(icdrGrade==0), sum(icdrGrade==1), sum(icdrGrade==2), ...
                           sum(icdrGrade==3), sum(icdrGrade==4)];
    results.referableCount = sum(icdrGrade >= 2);
    results.referablePct = 100 * results.referableCount / screenedSuccessfully;

    results.data = struct('patientId', patientId, 'centerId', centerId, ...
                          'arrivalTime', arrivalTime, 'totalTATMinutes', totalTATMinutes, ...
                          'icdrGrade', icdrGrade, 'permanentlyReject', permanentlyReject);
end
