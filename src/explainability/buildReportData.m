function reportData = buildReportData(result, opts)
%BUILDREPORTDATA  Map a real pipeline result onto the clinical report contract.
%
%   reportData = BUILDREPORTDATA(result) where result comes from
%   RUNDRISHTIPIPELINE. Feeds GENERATE_CLINICAL_REPORT.
%
%   reportData = BUILDREPORTDATA(result, patient=struct(...)) supplies the
%   clinical metadata the image cannot contain.
%
%   TWO RULES THIS ENFORCES
%   -----------------------
%   1. NEVER INVENT WHAT THE IMAGE CANNOT TELL US. Patient age, sex, diabetes
%      duration, camera model and screening centre are not recoverable from
%      pixels. The template ships plausible-looking defaults ("58, Female,
%      11 years (Type 2), Remidio FOP NM-10") which are fine as a layout
%      prototype and dangerous the moment a real image flows through: a
%      fabricated age on a clinical document is indistinguishable from a real
%      one. Anything not supplied renders as "not recorded".
%
%   2. NEVER REPORT AN UNVALIDATED DETECTOR AS A FINDING. The lesion channels
%      carry measured reliability (per-lesion precision against IDRiD):
%
%          hard exudates   0.549  -> reported (was 0.595; corrected - see
%                                   segmentExudates.m and phase3_results.md §3e)
%          haemorrhages    0.034  -> withheld
%          microaneurysms  0.021  -> withheld
%          soft exudates   never measured -> withheld
%
%      A withheld channel renders as "detector not validated - not reported",
%      not as a zero. Zero means "we looked and found none", which is a
%      clinical claim we cannot support.
%
%   The evidence table is built from actual Grad-CAM/lesion overlap, not from
%   the template's illustrative rows.
%
%   See also RUNDRISHTIPIPELINE, GENERATE_CLINICAL_REPORT.

    arguments
        result struct
        opts.patient struct = struct()
        opts.screening struct = struct()
    end

    reportData = clinical_report_template();

    % ---- metadata: supplied or explicitly absent --------------------------
    reportData.patientId        = getOr(opts.patient, 'id',        'not recorded');
    reportData.patientAge       = getOr(opts.patient, 'age',       'not recorded');
    reportData.patientGender    = getOr(opts.patient, 'gender',    'not recorded');
    reportData.diabetesDuration = getOr(opts.patient, 'diabetesDuration', 'not recorded');
    reportData.screeningCenter  = getOr(opts.screening, 'centre',  'not recorded');
    reportData.technicianName   = getOr(opts.screening, 'technician', 'not recorded');
    reportData.cameraModel      = getOr(opts.screening, 'camera',  'not recorded');
    reportData.screeningDate    = char(datetime('now','Format','yyyy-MM-dd HH:mm'));

    % Laterality IS derivable from the image - the disc sits nasally - so it is
    % reported when Module 2 determined it, and left blank when it did not.
    lat = 'not determined';
    if isfield(result,'features') && isfield(result.features,'anatomy')
        switch result.features.anatomy.laterality
            case 'OD', lat = 'OD (Right Eye)';
            case 'OS', lat = 'OS (Left Eye)';
        end
    end
    reportData.eyeExamined = lat;

    % ---- Module 1 ---------------------------------------------------------
    if isfield(result,'quality')
        switch result.quality.decision
            case 'pass',   reportData.qualityStatus = 'PASSED';
            case 'reject', reportData.qualityStatus = 'REJECTED';
            otherwise,     reportData.qualityStatus = 'ENHANCED';
        end
        if result.quality.enhanced
            reportData.qualityStatus = 'ENHANCED';
        end
    end
    % The template ships focusScore = 0.88, a layout placeholder. Carry the
    % real sharpness measurement instead, under its own name - it is a Laplacian
    % variance, not a normalised score, and the report labels it as such.
    reportData.sharpness = NaN;
    reportData.sharpnessBand = '';
    if isfield(result,'quality') && isfield(result.quality,'sharpness')
        reportData.sharpness = result.quality.sharpness;
        reportData.sharpnessBand = result.quality.sharpnessBand;
    end

    reportData.recaptureAdvice = '';
    if strcmp(result.decision, 'recapture')
        reportData.qualityStatus = 'REJECTED';
        reportData.recaptureAdvice = result.reason;
    end

    % ---- Module 2: only validated channels --------------------------------
    F = struct();
    if isfield(result,'features'), F = result.features; end
    L = struct();

    L.microaneurysmCount = withheld(F, 'microaneurysms', 'count');
    L.hemorrhageCount    = withheld(F, 'haemorrhages',   'count');
    L.softExudateCount   = withheld(F, 'softExudates',   'count');

    % Hard exudates remain special-cased for the DME endpoint (area near the
    % fovea), but the gate is the measured flag, not the channel's name.
    if isfield(F,'hardExudates') && isfield(F.hardExudates,'reliable') && F.hardExudates.reliable
        % Area in DD^2 converted to a percentage of a nominal 45-degree field.
        % Expressed as an area fraction rather than a raw count because the
        % count is far noisier than the area for a confluent lesion type.
        L.hardExudateAreaPct = 100 * F.hardExudates.areaDD2 / 30;
        L.hardExudateInMacula = isfinite(F.hardExudates.minDistanceToFoveaDD) && ...
                                F.hardExudates.minDistanceToFoveaDD <= 1;
    else
        L.hardExudateAreaPct = NaN;
        L.hardExudateInMacula = false;
    end

    % ---- validated lesions: what passed, and where it is ------------------
    % Item 5 of the reporting contract. A location list asserts more than a
    % count does - it says "there, look" - so it is emitted ONLY for channels
    % that cleared the frozen bar in config/lesion_validation_thresholds.json.
    % Item 6 is the same rule seen from the other side: everything that failed
    % or was never measured is listed as not validated, with its numbers, and
    % never as a zero.
    [reportData.detectorValidation, reportData.lesionLocations] = validationBlocks(F);

    L.neovascularization = false;
    if isfield(F,'neovascularization')
        L.neovascularization = F.neovascularization.suspectedAtDisc || ...
                               F.neovascularization.suspectedElsewhere;
    end

    L.opticDiscLocation = [NaN NaN];
    L.foveaLocation = [NaN NaN];
    if isfield(F,'anatomy')
        if F.anatomy.discFound,  L.opticDiscLocation = round(F.anatomy.discCentre); end
        if F.anatomy.foveaFound, L.foveaLocation = round(F.anatomy.foveaCentre); end
    end
    reportData.lesions = L;

    % ---- Module 3 ---------------------------------------------------------
    if ~isempty(result.grade)
        reportData.predictedGrade = result.grade;
        names = {'No DR','Mild NPDR','Moderate NPDR','Severe NPDR','Proliferative DR'};
        reportData.gradeName = names{result.grade+1};
        reportData.isReferable = strcmp(result.decision,'refer');
        reportData.calibratedConfidence = result.referableProb;
        reportData.calibrationApplied = contains(lower(result.confidence), 'calibrated') && ...
                                        ~contains(lower(result.confidence), 'uncalibrated');
    else
        % No grade was produced. The template defaults - grade 2, 'Moderate
        % NPDR', referable, 91.4% confident - would otherwise render an
        % UNGRADABLE image as a confident referable diagnosis. NaN routes the
        % badge to its 'UNGRADEABLE - RECAPTURE REQUIRED' branch.
        reportData.predictedGrade = NaN;
        reportData.gradeName = 'Ungradable';
        reportData.isReferable = false;
        reportData.calibratedConfidence = NaN;
        reportData.calibrationApplied = false;
    end

    % The template ships [0.02 0.05 0.91 0.02 0.00] as an illustrative bar
    % chart. Those are the softmax outputs of no model at all. A five-bar
    % distribution on a clinical document reads as the model's own uncertainty,
    % so it must come from the model or not be drawn.
    if isfield(result,'gradeProbs') && numel(result.gradeProbs) == 5
        reportData.gradeProbabilities = result.gradeProbs(:)';
    else
        reportData.gradeProbabilities = nan(1,5);
    end

    % ---- Module 4: evidence from real overlap ------------------------------
    rows = {};
    if isfield(result,'evidence') && istable(result.evidence) && height(result.evidence) > 0
        for i = 1:height(result.evidence)
            e = result.evidence(i,:);
            if e.count == 0, continue; end
            if e.camMassFraction >= 0.10
                strength = 'HIGH';
            elseif e.camMassFraction >= 0.03
                strength = 'MODERATE';
            else
                strength = 'LOW';
            end
            rows(end+1,:) = { sprintf('Grad-CAM overlap'), char(e.finding), ...
                sprintf('%d region(s); %.0f%% of heatmap attention', ...
                        e.count, 100*e.camMassFraction), strength }; %#ok<AGROW>
        end
    end
    if isempty(rows)
        rows = {'-', 'No validated lesion evidence', ...
                'Withheld channels are not reported; see reliability notes', 'N/A'};
    end
    reportData.evidenceTable = rows;

    % ---- recommendation ----------------------------------------------------
    switch result.decision
        case 'recapture'
            reportData.recommendedAction = ['Repeat image capture before grading. ' ...
                                            result.reason];
            reportData.followUpInterval  = 'Same visit';
        case 'refer'
            reportData.recommendedAction = 'Refer to ophthalmologist';
            reportData.followUpInterval  = 'Within 4 weeks (project protocol)';
        otherwise
            reportData.recommendedAction = 'Routine rescreening';
            reportData.followUpInterval  = '12 months (project protocol)';
    end
    % Name the model that actually produced this grade. The template footer read
    % "DRishti-AI v1.0 (Ensemble + ResNet)"; the pipeline loads a single
    % ResNet-18 and no ensemble is involved, so that string overstated the
    % system on every report it rendered.
    reportData.modelDescription = 'model not identified';
    if isfield(result,'model') && isstruct(result.model)
        m = result.model;
        d = '';
        if isfield(m,'backbone'), d = upper(strrep(char(m.backbone),'resnet','ResNet-')); end
        if isfield(m,'trainedOn'), d = [d ', trained on ' char(m.trainedOn)]; end
        if isfield(m,'isBaseline') && m.isBaseline
            d = [d ' (baseline comparator: no quality gate, no lesion features)'];
        end
        if ~isempty(d), reportData.modelDescription = d; end
    end

    reportData.reviewStatus = 'Awaiting ophthalmologist review';
end


function v = getOr(s, f, dflt)
    if isfield(s, f) && ~isempty(s.(f))
        v = s.(f);
    else
        v = dflt;
    end
end


function v = withheld(F, channel, field)
%WITHHELD  NaN for an unvalidated channel - never a zero.
%
%   Zero is a clinical assertion ("we looked, there were none"). NaN is an
%   admission ("this detector is not trustworthy"). The report renders them
%   differently and they must not be conflated.

    v = NaN;
    if ~isfield(F, channel), return; end
    c = F.(channel);
    if isfield(c, 'reliable') && c.reliable && isfield(c, field)
        v = c.(field);
    end
end


function [rows, locs] = validationBlocks(F)
%VALIDATIONBLOCKS  Per-channel validation table, and locations for the passers.
%
%   rows: {channel, precision, recall, F1, verdict} for ALL four channels, so a
%   reader can see what was measured and what was rejected. Hiding the failures
%   would make the one surviving channel look like the whole story.
%
%   locs: {channel, quadrant, distance-to-fovea DD, area DD^2, centroid px} for
%   validated channels only.

    names  = {'microaneurysms', 'haemorrhages', 'hardExudates', 'softExudates'};
    labels = {'Microaneurysms', 'Haemorrhages', 'Hard exudates', 'Soft exudates'};

    rows = {};
    locs = {};
    for k = 1:numel(names)
        c = names{k};
        if ~isfield(F, c), continue; end
        e = F.(c);

        p = getNum(e, 'measuredPrecision');
        r = getNum(e, 'measuredRecall');
        f1 = getNum(e, 'measuredF1');
        verdict = 'not validated';
        if isfield(e, 'validationVerdict') && ~isempty(e.validationVerdict)
            verdict = char(e.validationVerdict);
        end
        rows(end+1, :) = {labels{k}, p, r, f1, verdict}; %#ok<AGROW>

        if ~(isfield(e, 'reliable') && e.reliable), continue; end
        if ~isfield(e, 'locations'), continue; end
        for i = 1:numel(e.locations)
            L = e.locations(i);
            locs(end+1, :) = { labels{k}, L.quadrant, ...
                L.distanceToFoveaDD, L.areaDD2, L.centroidPx }; %#ok<AGROW>
        end
    end
end


function v = getNum(s, f)
    v = NaN;
    if isfield(s, f), v = s.(f); end
end
