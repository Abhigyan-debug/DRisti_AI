function S = runDrishtiSystem(source, opts)
%RUNDRISHTISYSTEM  All five modules, one entry point. Phase 6 integration.
%
%   S = RUNDRISHTISYSTEM(folder) screens every image in a folder and returns a
%   cohort result plus the district-capacity analysis those images imply.
%
%   S = RUNDRISHTISYSTEM(imagePath) screens one image.
%
%   S = RUNDRISHTISYSTEM(src, siteCalibration=C, saveReports=true, ...
%                        outputDir=..., limit=50)
%
%   WHAT "INTEGRATED" MEANS HERE
%   ----------------------------
%   Modules 1-4 run per image (RUNDRISHTIPIPELINE). Module 5 is not a per-image
%   stage - it is a district-level queuing model - so integration means feeding
%   the cohort's MEASURED service time into it rather than an assumed constant:
%
%       [1] quality gate -> [2] lesion features -> [3] grading -> [4] report
%                                     |
%                                     +--> measured s/image
%                                              |
%                                     [5] district capacity model
%
%   This is the loop Phase 5 could not close on its own: the throughput model
%   previously took AI service time as a parameter, and now takes it from the
%   run that just happened.
%
%   ⚠️ SITE CALIBRATION IS A PRECONDITION, NOT AN OPTION.
%   Run without `siteCalibration`, this uses the frozen APTOS threshold, which
%   measured 31.2% sensitivity on unseen equipment (docs/phase3_results.md
%   section 3) - it misses roughly two thirds of referable patients. The system
%   warns, loudly, once per call. Fit a local operating point with
%   FITSITECALIBRATION on ~200 labelled local images before screening anyone.
%
%   ⚠️ NEVER POINT THIS AT MESSIDOR-2. It is the held-out external benchmark and
%   was spent once, on 2026-09-12. See project rule 1.
%
%   See also RUNDRISHTIPIPELINE, FITSITECALIBRATION, ASSERTNOTHOLDOUT,
%   RECOMMEND_DISTRICT_CONFIGURATION, ANALYSEFAILURECASES.

    arguments
        source
        opts.siteCalibration struct = struct()
        opts.saveReports (1,1) logical = false
        opts.outputDir (1,:) char = ''
        opts.limit (1,1) double = Inf
        opts.patient struct = struct()
        opts.screening struct = struct()
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();

    % ---- resolve the work list -------------------------------------------
    if isfolder(source)
        L = [dir(fullfile(source,'*.jpg')); dir(fullfile(source,'*.png')); ...
             dir(fullfile(source,'*.JPG')); dir(fullfile(source,'*.jpeg'))];
        files = arrayfun(@(f) string(fullfile(f.folder,f.name)), L);
    else
        files = string(source);
    end
    assertNotHoldout(files);
    n = min(numel(files), opts.limit);
    if n == 0
        error('drishti:noImages', 'No images found at %s', string(source));
    end

    % A calibration passed by the caller wins; otherwise use this machine's
    % saved artifact if it has one. Resolved HERE, once, so the cohort summary
    % and the warning below describe the operating point the images actually
    % ran at rather than only what was passed in.
    if ~isfield(opts.siteCalibration, 'a')
        opts.siteCalibration = loadSiteCalibration('verbose', opts.verbose);
    end

    calibrated = isfield(opts.siteCalibration, 'a');
    if calibrated && opts.verbose
        fprintf('  Site calibration: %s\n', siteLabel(opts.siteCalibration));
    end
    if ~calibrated && opts.verbose
        warning('drishti:uncalibratedSite', ...
            ['Running on the FROZEN APTOS operating point with no site ' ...
             'calibration. Measured external sensitivity at this threshold ' ...
             'was 31.2%% - about two thirds of referable patients are missed ' ...
             'on unseen equipment. Fit one with fitSiteCalibration before ' ...
             'clinical use.']);
    end

    % ---- modules 1-4, per image ------------------------------------------
    rows = table();
    perImageSec = nan(n,1);
    for k = 1:n
        t = tic;
        out = runDrishtiPipeline(char(files(k)), ...
            'siteCalibration', opts.siteCalibration, ...
            'saveReport', opts.saveReports, 'outputDir', opts.outputDir, ...
            'patient', opts.patient, 'screening', opts.screening, 'verbose', false);
        perImageSec(k) = toc(t);

        grade = NaN; if ~isempty(out.grade), grade = out.grade; end
        rows = [rows; table(string(out.imageName), string(out.decision), grade, ...
            out.referableProb, perImageSec(k), string(out.quality.decision), ...
            'VariableNames', {'image','decision','grade','referableProb', ...
                              'secondsPerImage','qualityDecision'})]; %#ok<AGROW>
        if opts.verbose
            fprintf('  %3d/%d  %-22s %-10s %5.1f s\n', k, n, out.imageName, ...
                out.decision, perImageSec(k));
        end
    end

    % ---- cohort summary ---------------------------------------------------
    S = struct();
    S.perImage = rows;
    S.n = n;
    S.nRefer     = nnz(rows.decision == "refer");
    S.nNoRefer   = nnz(rows.decision == "no-refer");
    S.nRecapture = nnz(rows.decision == "recapture");
    S.referRate      = S.nRefer / n;
    S.recaptureRate  = S.nRecapture / n;
    S.calibrated     = calibrated;
    S.operatingPoint = ternary(calibrated, ...
        ['site-calibrated - ' siteLabel(opts.siteCalibration)], ...
        'frozen APTOS (UNCALIBRATED)');
    S.siteCalibration = calibrationSummary(opts.siteCalibration);

    % ---- module 5, driven by what we just measured ------------------------
    S.measuredSecondsPerImage = median(perImageSec, 'omitnan');
    S.district = districtCapacity(S.measuredSecondsPerImage);

    if opts.verbose, printSummary(S); end
end


% ------------------------------------------------------------------ helpers

function D = districtCapacity(secPerImage)
%DISTRICTCAPACITY  Module 5, using the service time just measured.

    D = struct('available', false, 'measuredSecondsPerImage', secPerImage);
    if exist('recommend_district_configuration', 'file') ~= 2
        D.note = 'simulink/ not on the path - run addpath(''simulink'') for Module 5.';
        return
    end
    p = screening_params();
    % Module 5 works per PATIENT; this run measured per IMAGE.
    D.imagesPerPatient = p.imagesPerPatient;
    D.measuredSecondsPerPatient = secPerImage * p.imagesPerPatient;
    D.contractSecondsPerImage = p.aiInferenceLatencySec;
    D.rec = recommend_district_configuration('verbose', false);
    D.available = true;
end


function printSummary(S)
    fprintf('\n  ===== DRishti-AI, all five modules =====\n');
    fprintf('  cohort            %d images\n', S.n);
    fprintf('  operating point   %s\n', S.operatingPoint);
    if ~S.calibrated
        fprintf('    ⚠ UNCALIBRATED: 31.2%% measured external sensitivity.\n');
        fprintf('      Not fit for clinical use until buildSiteCalibration is run.\n');
    elseif isfield(S.siteCalibration, 'heldBackSensitivity')
        % Sensitivity and specificity together, always. The uncalibrated pair
        % is printed beside them so the TRADE is visible rather than just the
        % half of it that improved.
        c = S.siteCalibration;
        fprintf('    fitted on      %s\n', c.calibrationSet);
        fprintf('    held-back set  %s\n', c.heldBackSet);
        fprintf('      uncalibrated    sens %5.1f%%  spec %5.1f%%\n', ...
            100*c.heldBackUncalibratedSensitivity, ...
            100*c.heldBackUncalibratedSpecificity);
        fprintf('      calibrated      sens %5.1f%%  spec %5.1f%%\n', ...
            100*c.heldBackSensitivity, 100*c.heldBackSpecificity);
        fprintf('    (measured on that site. NOT a Messidor-2 result.)\n');
    end
    fprintf('  refer             %d (%.1f%%)\n', S.nRefer, 100*S.referRate);
    fprintf('  no-refer          %d\n', S.nNoRefer);
    fprintf('  recapture         %d (%.1f%%)\n', S.nRecapture, 100*S.recaptureRate);
    fprintf('  measured          %.2f s/image\n', S.measuredSecondsPerImage);

    if S.district.available
        d = S.district;
        fprintf('\n  --- Module 5: district capacity at this measured rate ---\n');
        fprintf('  %.2f s/image x %d images/patient = %.1f s/patient\n', ...
            S.measuredSecondsPerImage, d.imagesPerPatient, d.measuredSecondsPerPatient);
        fprintf('  contract currently carries %.2f s/image\n', d.contractSecondsPerImage);
        fprintf('  minimum district: %d cameras, %d uplink, %d compute node(s)\n', ...
            d.rec.cameras, d.rec.uplinks, d.rec.computeNodes);
        fprintf('  binding constraint: %s\n', d.rec.bindingConstraint);
        fprintf('  (throughput figures are ASSUMPTION-DEPENDENT - docs/phase5_results.md section 6)\n');
    end
    fprintf('  =========================================\n');
end


function o = ternary(c, a, b)
    if c, o = a; else, o = b; end
end


function s = siteLabel(C)
%SITELABEL  Which camera this operating point was fitted for.
    s = 'site not recorded';
    if isstruct(C) && isfield(C, 'meta') && isfield(C.meta, 'site')
        s = char(C.meta.site);
    end
end


function M = calibrationSummary(C)
%CALIBRATIONSUMMARY  Provenance of the operating point, for the cohort record.
%
%   Sensitivity is never carried without the specificity it cost, so a caller
%   cannot read one out of this struct and quote it on its own.

    M = struct('loaded', false);
    if ~isstruct(C) || ~isfield(C, 'a'), return; end

    M.loaded = true;
    M.site = siteLabel(C);
    M.thresholdRaw = C.thresholdRaw;
    M.nCalibrationImages = C.n;
    if isfield(C, 'meta')
        if isfield(C.meta, 'fittedAt'),       M.fittedAt = C.meta.fittedAt; end
        if isfield(C.meta, 'graderModel'),    M.graderModel = C.meta.graderModel; end
        if isfield(C.meta, 'calibrationSet'), M.calibrationSet = C.meta.calibrationSet; end
        if isfield(C.meta, 'evaluationSet'),  M.evaluationSet = C.meta.evaluationSet; end
    end
    if isfield(C, 'evaluation')
        E = C.evaluation;
        M.heldBackSet = E.dataset;
        M.heldBackSensitivity = E.calibratedSensitivity;
        M.heldBackSpecificity = E.calibratedSpecificity;
        M.heldBackUncalibratedSensitivity = E.uncalibratedSensitivity;
        M.heldBackUncalibratedSpecificity = E.uncalibratedSpecificity;
    end
end
