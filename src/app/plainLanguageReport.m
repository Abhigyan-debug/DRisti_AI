function P = plainLanguageReport(result, opts)
%PLAINLANGUAGEREPORT  Turn a pipeline result into words a non-specialist can act on.
%
%   P = PLAINLANGUAGEREPORT(result) where result comes from RUNDRISHTIPIPELINE.
%
%   Returns a struct of plain-English blocks:
%
%       P.headline  P.subhead  P.headlineColour    the decision, in one line
%       P.gradeLabel  P.meaning                    what the grade means
%       P.gradeVsDecision                          set when they appear to disagree
%       P.action  P.when                           what to do, and by when
%       P.confidence                               the number, and what it is not
%       P.imageQuality                             what Module 1 did to the photo
%       P.evidence   {cellstr}                     why, from validated channels only
%       P.withheld   {cellstr}                     what we deliberately do not report
%       P.warnings   {cellstr}                     most severe first
%
%   P = PLAINLANGUAGEREPORT(result, calibrated=tf) states the site-calibration
%   status explicitly, for callers that already know it.
%
%   WHO THIS IS WRITTEN FOR
%   -----------------------
%   Not the ophthalmologist - GENERATE_CLINICAL_REPORT already serves them, in
%   their own vocabulary. This is for the person in the room at a rural PHC: a
%   technician, a health worker, and over their shoulder the patient. "Moderate
%   NPDR, referable, 91.4% calibrated confidence" is not a sentence either of
%   them can act on. "Send this patient to an eye doctor within four weeks" is.
%
%   TRANSLATION IS WHERE OVERCLAIMING HAPPENS
%   -----------------------------------------
%   Simplifying language is the easiest place in the whole system to promote a
%   hedged result into a confident one, because the hedges are exactly the
%   clauses that sound like jargon and get cut. So the caveats are structural
%   here, not editorial:
%
%     - A withheld detector renders as "we cannot measure this well enough to
%       tell you", never as zero. Zero is a clinical claim.
%     - An uncalibrated site produces a warning ABOVE the result, not a
%       footnote below it, because at that operating point the measured
%       external sensitivity was 31.2% - for a referable patient the result is
%       likelier wrong than right.
%     - "No referral needed" is phrased as what it is - the absence of a
%       finding in one photograph - never as "this patient is fine".
%
%   See also RUNDRISHTIPIPELINE, DRISHTIDASHBOARD, GENERATE_CLINICAL_REPORT.

    arguments
        result struct
        % RUNDRISHTIPIPELINE records the operating point only on the paths that
        % reach grading - a recaptured image returns before it is set. Inferring
        % calibration from an absent field would label a properly calibrated
        % site "NOT CALIBRATED" on every blurred photograph, and a warning that
        % cries wolf is a warning people learn to click past. A caller that
        % knows the site state says so instead.
        opts.calibrated = []
    end

    P = struct();
    decision = '';
    if isfield(result, 'decision'), decision = char(result.decision); end

    % Resolved up front: the confidence sentence and the calibration warning
    % both depend on it, and they must never disagree about which operating
    % point produced this result.
    calibrated = opts.calibrated;
    if isempty(calibrated)
        op = '';
        if isfield(result, 'operatingPoint'), op = char(result.operatingPoint); end
        calibrated = strcmpi(op, 'site');
    end

    % ---- 1. the decision, in one line -------------------------------------
    switch decision
        case 'refer'
            P.headline       = 'SEND THIS PATIENT TO AN EYE DOCTOR';
            P.subhead        = 'This photograph shows changes that a specialist needs to look at.';
            P.headlineColour = '#b91c1c';
        case 'no-refer'
            P.headline       = 'NO REFERRAL NEEDED FROM THIS PHOTOGRAPH';
            % Deliberately not "this patient is healthy". One photograph of one
            % eye at one moment is the entire evidence base for this sentence.
            P.subhead        = 'Nothing in this photograph reaches the level that needs a specialist today.';
            P.headlineColour = '#15803d';
        otherwise
            P.headline       = 'TAKE THE PHOTOGRAPH AGAIN';
            P.subhead        = 'The image is not clear enough to judge. Do not let the patient leave yet.';
            P.headlineColour = '#b45309';
    end

    % ---- 2. what the grade means ------------------------------------------
    P.gradeLabel = 'Not graded';
    P.meaning    = ['The photograph was rejected before grading, so the system has formed ' ...
                    'no opinion about this eye. An unclear image must never be turned into ' ...
                    'a confident grade - that is the mistake this step exists to prevent.'];
    if isfield(result, 'grade') && ~isempty(result.grade) && isfinite(result.grade)
        [P.gradeLabel, P.meaning] = gradeWords(result.grade);
    end

    % ---- 2b. when the headline and the grade appear to disagree -----------
    % The referral call is made on the TOTAL probability of grade 2 or worse,
    % never on the single most likely grade, and those two can disagree. Seen
    % live on IDRiD_02: best single guess was grade 1 at 0.50, while grades 2-4
    % summed to 0.50 and crossed the referral line. Unexplained, the report
    % reads as a self-contradiction - "mild" sitting under "send this patient to
    % an eye doctor" - which is exactly the kind of thing that destroys trust in
    % a screening tool. So it is named rather than smoothed over.
    P.gradeVsDecision = '';
    if isfield(result, 'grade') && ~isempty(result.grade) && isfinite(result.grade)
        mass = NaN;
        if isfield(result, 'gradeProbs') && numel(result.gradeProbs) == 5
            mass = sum(result.gradeProbs(3:end));
        end
        if strcmp(decision, 'refer') && result.grade < 2
            P.gradeVsDecision = sprintf(['Why refer when the grade says mild? The referral ' ...
                'decision does not use the single most likely grade. It adds up the chance ' ...
                'of grade 2 or worse%s, and that total crossed the referral line. Screening ' ...
                'is deliberately set up this way: missing disease costs far more than one ' ...
                'extra specialist review.'], massText(mass));
        elseif strcmp(decision, 'no-refer') && result.grade >= 2
            P.gradeVsDecision = sprintf(['The most likely single grade is %d, but the ' ...
                'combined chance of grade 2 or worse%s stayed below the referral line, so no ' ...
                'referral was raised. Treat this as borderline rather than a clear negative.'], ...
                result.grade, massText(mass));
        end
    end

    % ---- 3. what to do ----------------------------------------------------
    switch decision
        case 'refer'
            P.action = 'Refer to the district hospital eye clinic for a dilated examination.';
            P.when   = 'Within 4 weeks (project protocol recommendation, not a clinical guideline).';
        case 'no-refer'
            P.action = 'No referral today. Screen this patient again at the next routine round.';
            P.when   = 'In 12 months (project protocol recommendation, not a clinical guideline).';
        otherwise
            why = '';
            if isfield(result, 'reason'), why = strtrim(char(result.reason)); end
            P.action = strtrim(sprintf('Re-take the photograph now, before the patient leaves. %s', why));
            P.when   = 'Same visit.';
    end

    % ---- 4. the number, and what it is not --------------------------------
    % A percentage on a clinical document reads as a calibrated probability for
    % THIS patient on THIS camera. Ours is neither unless a site calibration has
    % been fitted, and "100% for referable disease" was the worst case of it -
    % a number no screening model has earned, printed as if it had. Direction of
    % the score is reportable; a per-cent figure is not, until it is calibrated
    % here. The band words describe the score itself and invent nothing.
    P.confidence = 'No score was produced, because the image was not graded.';
    if isfield(result, 'referableProb') && isfinite(result.referableProb)
        prob = result.referableProb;
        if prob >= 0.80
            lean = 'strongly favors referable disease';
        elseif prob >= 0.50
            lean = 'favors referable disease';
        elseif prob >= 0.20
            lean = 'leans away from referable disease';
        else
            lean = 'strongly favors no referable disease';
        end
        if calibrated
            P.confidence = sprintf(['Model score %s (%.0f%%, calibrated on this site''s own ' ...
                'labelled images).'], lean, 100 * prob);
        else
            P.confidence = sprintf(['Model score %s, but confidence is not calibrated for ' ...
                'this camera.'], lean);
        end
    end

    % ---- 5. what happened to the photograph -------------------------------
    P.imageQuality = 'Image quality was not assessed.';
    if isfield(result, 'quality') && isstruct(result.quality)
        q = result.quality;
        summary = '';
        if isfield(q, 'summary'), summary = strtrim(char(q.summary)); end
        if isfield(q, 'enhanced') && q.enhanced
            P.imageQuality = sprintf(['The photograph was usable but imperfect, so the system ' ...
                'corrected it before grading. %s'], summary);
        elseif strcmp(decision, 'recapture')
            P.imageQuality = sprintf('The photograph failed the quality check. %s', summary);
        else
            P.imageQuality = sprintf('The photograph was good enough to grade as taken. %s', summary);
        end
    end

    % ---- 6. why: validated channels only ----------------------------------
    P.evidence = {};
    if isfield(result, 'evidence') && istable(result.evidence) && height(result.evidence) > 0
        for i = 1:height(result.evidence)
            e = result.evidence(i, :);
            name = char(e.finding);
            if e.count == 0
                % "None found" is not "none present", and the gap between the
                % two is measured: recall 0.146 at the displayed threshold.
                P.evidence{end+1} = sprintf(['%s: none found. This does not mean there are ' ...
                    'none - this detector finds only about 1 in 7 of the ones that are really ' ...
                    'there, so it is believed when it says YES and not when it says NO.'], ...
                    name);
            else
                P.evidence{end+1} = sprintf(['%s: %d area(s) found, and %.0f%% of where the AI ' ...
                    'was looking landed on them.'], name, e.count, 100 * e.camMassFraction);
            end
        end
    end
    if isempty(P.evidence)
        P.evidence = {['No validated lesion evidence is available for this image. The grade ' ...
                       'comes from the network''s overall read of the photograph.']};
    end

    % ---- 7. what we deliberately do not tell you --------------------------
    % Built from the MEASUREMENT, not from constants in this file. These lines
    % used to carry hardcoded figures (0.054, 0.088, "never measured"), which
    % went stale the moment the detectors were re-validated - a report quoting
    % last month's precision is inventing data just as surely as one quoting a
    % number nobody measured.
    P.withheld = {};
    chans = { 'microaneurysms', 'Microaneurysms'; ...
              'haemorrhages',   'Haemorrhages'; ...
              'hardExudates',   'Hard exudates'; ...
              'softExudates',   'Cotton-wool spots (soft exudates)' };
    if isfield(result, 'features') && isstruct(result.features)
        F = result.features;
        for k = 1:size(chans, 1)
            c = chans{k,1};
            if ~isfield(F, c), continue; end
            e = F.(c);
            if isfield(e, 'reliable') && e.reliable
                continue    % this one is displayed, so it is not withheld
            end
            if isfield(e, 'measured') && e.measured
                P.withheld{end+1} = sprintf(['%s - not reported. Measured on held-out ' ...
                    'images: precision %.3f, recall %.3f, F1 %.3f (n=%d). That is below the ' ...
                    'bar set before the test was run, so no count and no locations are ' ...
                    'shown.'], chans{k,2}, e.measuredPrecision, e.measuredRecall, ...
                    e.measuredF1, e.validationN);
            else
                P.withheld{end+1} = sprintf(['%s - not reported. No validation result is ' ...
                    'available on this machine, and an unmeasured detector is treated ' ...
                    'exactly like a failed one.'], chans{k,2});
            end
        end
    end
    if isempty(P.withheld)
        P.withheld = {'Every lesion channel cleared the reporting bar; nothing is withheld.'};
    end

    % ---- 7b. validated lesions, and where they are ------------------------
    % Only channels that passed. A location says "there, look" - a stronger
    % claim than a count - so an unvalidated channel never contributes one.
    P.lesionLocations = {};
    if isfield(result, 'features') && isstruct(result.features)
        F = result.features;
        for k = 1:size(chans, 1)
            c = chans{k,1};
            if ~isfield(F, c), continue; end
            e = F.(c);
            if ~(isfield(e, 'reliable') && e.reliable), continue; end
            if ~isfield(e, 'locations') || isempty(e.locations)
                P.lesionLocations{end+1} = sprintf(['%s: validated (precision %.3f), ' ...
                    'none found in this image.'], chans{k,2}, e.measuredPrecision);
                continue
            end
            for i = 1:numel(e.locations)
                L = e.locations(i);
                if isfinite(L.distanceToFoveaDD)
                    where = sprintf('%s, %.1f disc diameters from the fovea', ...
                        L.quadrant, L.distanceToFoveaDD);
                else
                    where = L.quadrant;
                end
                P.lesionLocations{end+1} = sprintf('%s - %s', chans{k,2}, where);
            end
        end
    end

    % ---- 8. warnings, most severe first -----------------------------------
    P.warnings = {};

    if ~calibrated
        P.warnings{end+1} = ['THIS CAMERA HAS NOT BEEN CALIBRATED. On a camera it had not seen ' ...
            'before, this system at this setting found only 31.2% of the patients who genuinely ' ...
            'needed referral (Messidor-2, n=1744, read once) - it missed about two in three. ' ...
            'Locally labelled images can refit the operating point. Where that has been ' ...
            'measured end to end, on a different camera (IDRiD), it moved sensitivity from ' ...
            '75.0% to 82.8% and specificity from 97.4% down to 76.9% - it recovers missed ' ...
            'cases by flagging more people for review, it does not reach the 90% target, ' ...
            'and how much it recovers depends on the camera. Until then a "no referral" ' ...
            'result here is weak evidence and must not be used to reassure anyone.'];
    end

    if isfield(result, 'camAgreement') && isfinite(result.camAgreement)
        P.warnings{end+1} = sprintf(['The coloured heat map shows WHERE the AI looked, not what ' ...
            'it saw. %.0f%% of its attention fell on lesions our independent detectors also ' ...
            'found. Across the validation set that overlap ran 1.51x better than chance - above ' ...
            'random, but nowhere near proof, and no ophthalmologist has yet rated it.'], ...
            100 * result.camAgreement);
    end

    P.warnings{end+1} = 'Screening aid, not a diagnosis; ophthalmologist review required.';

    P.warnings{end+1} = ['Headline accuracy (90.3% sensitivity, 95.9% specificity) was measured ' ...
        'on APTOS images only, for diabetic retinopathy alone - APTOS carries no macular oedema ' ...
        'labels, so that figure is not comparable to IDx-DR or Gulshan.'];
end


% ------------------------------------------------------------------ helpers

function s = massText(mass)
%MASSTEXT  The combined grade-2-or-worse probability, when the model gave one.
    if isfinite(mass)
        s = sprintf(' (here %.0f%%, uncalibrated model output)', 100 * mass);
    else
        s = '';
    end
end


function [label, meaning] = gradeWords(g)
%GRADEWORDS  ICDR grade to a statement of what the system actually did.
%
%   These sentences used to describe pathology: "several of the tiny blood
%   vessels at the back of the eye are damaged and leaking". The system cannot
%   support that. It emits a five-class score over an ICDR scale; it does not
%   observe leakage, and our own lesion detectors are too weak to corroborate
%   one (microaneurysms 0.028 precision, haemorrhages 0.164, on the IDRiD
%   segmentation TEST split n=27, micro-averaged - both withheld).
%   Describing mechanism the model never measured is the same error as printing
%   a microaneurysm count - it just reads as clinical prose instead of a number.
%
%   So each grade now states the classification and stops there. The ICDR name
%   is kept because it is the label of the class, not a claim about this eye.

    switch g
        case 0
            label   = 'Grade 0 - no diabetic retinopathy';
            meaning = 'The system classified this image as Grade 0 (no diabetic retinopathy).';
        case 1
            label   = 'Grade 1 - mild';
            meaning = 'The system classified this image as Grade 1 (mild DR).';
        case 2
            label   = 'Grade 2 - moderate';
            meaning = 'The system classified this image as Grade 2 (moderate DR).';
        case 3
            label   = 'Grade 3 - severe';
            meaning = 'The system classified this image as Grade 3 (severe DR).';
        case 4
            label   = 'Grade 4 - proliferative';
            meaning = 'The system classified this image as Grade 4 (proliferative DR).';
        otherwise
            label   = 'Grade not recognised';
            meaning = 'The system returned a grade outside the expected 0-4 range.';
    end
end
