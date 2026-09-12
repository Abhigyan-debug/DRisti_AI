function out = runDrishtiPipeline(imagePath, opts)
%RUNDRISHTIPIPELINE  Image in, screening decision out. The whole system.
%
%   out = RUNDRISHTIPIPELINE(imagePath) runs every module in order and returns
%   a single result struct.
%
%   out = RUNDRISHTIPIPELINE(img, ...) also accepts an image array.
%
%   out = RUNDRISHTIPIPELINE(path, saveReport=true, outputDir=...)
%
%   THE FIVE MODULES, IN ORDER
%   --------------------------
%     1  quality gate      reject -> recapture instruction, STOP
%     2  lesion features   disc, fovea, vessels, MA, haemorrhage, exudates
%     3  DR grading        ICDR 0-4 + calibrated referable probability
%     4  explainability    Grad-CAM + lesion evidence table
%     5  throughput        per-image timing feeds the district model
%
%   A rejected image stops at stage 1. That is the design: an ungradable image
%   must produce a retake instruction, never a confident grade. Most published
%   pipelines grade everything and report accuracy only on the images that
%   happened to be gradable.
%
%   WHAT out CONTAINS
%     out.decision        'refer' | 'no-refer' | 'recapture'
%     out.grade           ICDR 0-4 ([] if recapture)
%     out.referableProb   calibrated probability
%     out.confidence      qualifier string - states whether calibrated, and
%                         that calibration is domain-specific
%     out.reason          recapture instruction, if applicable
%     out.evidence        lesion findings supporting the decision
%     out.overlay         Grad-CAM composite for the report
%     out.timings         per-stage seconds, for Module 5
%
%   ⚠️ OPERATING POINT. The threshold is read from the frozen validation file.
%   Measured external validation shows it does NOT transfer across cameras
%   (90.3% sensitivity internally, 31.2% on Messidor-2). Running a new camera
%   on the shipped threshold is a known failure mode, not an untested risk.
%
%   The operating point is resolved in this order:
%     1. opts.siteCalibration, if a caller passed one
%     2. this machine's saved artifact, via LOADSITECALIBRATION
%     3. the shipped APTOS threshold - UNCALIBRATED, and said so loudly
%
%   Build (2) for a new camera with BUILDSITECALIBRATION. An absent artifact
%   is not an error: it leaves the system in the uncalibrated state, which is
%   the honest default and is announced in every report.
%
%   See also PROCESSIMAGE, EXTRACTLESIONFEATURES, EXPLAINGRADING,
%   BUILDSITECALIBRATION, LOADSITECALIBRATION, FITSITECALIBRATION.

    arguments
        imagePath
        opts.modelFile (1,:) char = ''
        opts.saveReport (1,1) logical = false
        opts.outputDir (1,:) char = ''
        opts.siteCalibration struct = struct()
        opts.patient struct = struct()
        opts.screening struct = struct()
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    tAll = tic;

    if ischar(imagePath) || isstring(imagePath)
        % Guard BEFORE the read, not after. RUNDRISHTISYSTEM already checks the
        % batch it is about to process, but this function is a public entry
        % point in its own right - "image in, screening decision out" - and a
        % direct call with a Messidor-2 path reached IMREAD with nothing in the
        % way. The holdout is destroyed silently: no error, no failing test,
        % just a headline claim that quietly stops being true. Re-checking here
        % costs one string comparison and closes the last unguarded path.
        assertNotHoldout(imagePath);
        img = imread(imagePath);
        [~, nameOnly] = fileparts(char(imagePath));
    else
        img = imagePath;
        nameOnly = 'image';
    end

    out = struct('imageName', nameOnly, 'decision', '', 'grade', [], ...
                 'referableProb', NaN, 'confidence', '', 'reason', '', ...
                 'evidence', table(), 'overlay', [], 'timings', struct());

    % ---- 1. quality gate --------------------------------------------------
    t = tic;
    q = processImage(img);
    out.timings.qualityGate = toc(t);
    out.quality = struct('decision', q.decision, 'enhanced', q.enhanced, ...
                         'summary', q.summary, ...
                         'sharpness', q.before.sharpness.normalised, ...
                         'sharpnessBand', q.before.sharpness.band);

    if ~q.gradable
        out.decision = 'recapture';
        out.reason = q.summary;
        out.timings.total = toc(tAll);
        % A rejected image still gets a report. The recapture instruction is the
        % only output the technician can act on, and it has to reach them at the
        % camera - returning silently here leaves the operator with nothing.
        if opts.saveReport
            out = emitReport(out, opts, cfg, img);
        end
        if opts.verbose, printResult(out); end
        return
    end

    % ---- 2 + 3 + 4: grade and explain -------------------------------------
    % explainGrading already runs the grader and Module 2, so calling it once
    % avoids paying for lesion extraction twice.
    t = tic;
    E = explainGrading(img, 'modelFile', opts.modelFile, 'runModule2', true);
    out.timings.gradeAndExplain = toc(t);

    out.grade = E.grade;
    out.gradeProbs = E.gradeProbs;
    out.model = E.model;
    out.overlay = E.overlay;
    out.evidence = E.evidence;
    out.camAgreement = E.agreement;
    out.features = E.features;

    % ---- operating point --------------------------------------------------
    rawScore = E.referableScore;

    % A caller-supplied calibration wins; otherwise fall back to this
    % machine's saved artifact, so a calibrated site stays calibrated even
    % when a caller forgets to pass it. Absent artifact -> empty struct ->
    % the uncalibrated branch below, which is the loud default.
    if ~isfield(opts.siteCalibration, 'a')
        opts.siteCalibration = loadSiteCalibration('verbose', opts.verbose);
    end

    if isfield(opts.siteCalibration, 'a')
        S = opts.siteCalibration;
        out.referableProb = 1 ./ (1 + exp(-(S.a * rawScore + S.b)));
        refer = rawScore >= S.thresholdRaw;
        out.confidence = sprintf('site-calibrated on %d local images (%s)', ...
            S.n, siteOf(S));
        out.operatingPoint = 'site';
        out.siteCalibration = S;
    else
        calFile = fullfile(cfg.modelsDir, 'calibrator.mat');
        if isfile(calFile)
            C = load(calFile);
            out.referableProb = applyCalibration(C.C, rawScore);
            out.confidence = ['Platt-calibrated on APTOS; NOT validated on ' ...
                              'other cameras - see site calibration'];
        else
            out.referableProb = rawScore;
            out.confidence = 'uncalibrated model output - not a probability';
        end
        refer = rawScore >= E.threshold;
        out.operatingPoint = 'shipped (APTOS-derived)';
    end

    if refer
        out.decision = 'refer';
    else
        out.decision = 'no-refer';
    end

    out.timings.total = toc(tAll);

    % ---- 5. report --------------------------------------------------------
    if opts.saveReport
        out = emitReport(out, opts, cfg, img);
    end

    if opts.verbose, printResult(out); end
end


% ------------------------------------------------------------------ helpers

function s = siteOf(C)
%SITEOF  The camera an operating point was fitted for, or an honest blank.
    s = 'site not recorded';
    if isstruct(C) && isfield(C, 'meta') && isfield(C.meta, 'site')
        s = char(C.meta.site);
    end
end


function out = emitReport(out, opts, cfg, img)
%EMITREPORT  Write the HTML report, with a PNG fallback.
%
%   Natik's HTML generator is the real report - structured, styled and built for
%   the <30s triage bar. The PNG is a fallback for when a browser is not
%   available (a live demo on a projector, say); it is skipped when there is no
%   overlay, which is the case for a rejected image.

    dir0 = opts.outputDir;
    if isempty(dir0), dir0 = fullfile(cfg.reportsDir, 'demo'); end
    if ~isfolder(dir0), mkdir(dir0); end
    try
        rd = buildReportData(out, 'patient', opts.patient, 'screening', opts.screening);
        % out.overlay is already the Grad-CAM composite, so it is passed as the
        % image with no separate heatmap - compositing it twice would wash the
        % retina out and exaggerate the attention region.
        % A rejected image has no overlay, but the technician still needs to
        % SEE the frame that failed - "out of focus" is far easier to act on
        % next to the blurred picture that produced it.
        shown = out.overlay;
        if isempty(shown), shown = img; end
        out.reportPath = generate_clinical_report(rd, shown, [], ...
            fullfile(dir0, sprintf('%s_report.html', out.imageName)));
    catch ME
        warning('drishti:htmlReportFailed', ...
            'HTML report failed (%s); falling back to PNG.', ME.message);
    end
    out.overlayPath = writeReport(out, dir0);
end



function p = writeReport(out, dir0)
%WRITEREPORT  One-page annotated summary, designed for <30s review.
%
%   Ordered by what a clinician decides first: the action, then the grade, then
%   the evidence, then the caveats. Burying the recommendation under metrics is
%   what makes reports slow to read.

    p = fullfile(dir0, sprintf('%s_report.png', out.imageName));
    if isempty(out.overlay), return; end

    ov = im2double(out.overlay);
    ov = imresize(ov, [700 700]);

    switch out.decision
        case 'refer',      banner = [0.85 0.20 0.20];  txt = 'REFER';
        case 'no-refer',   banner = [0.15 0.55 0.25];  txt = 'NO REFERRAL';
        otherwise,         banner = [0.90 0.60 0.10];  txt = 'RECAPTURE';
    end

    canvas = ones(860, 700, 3);
    canvas(1:60, :, 1) = banner(1);
    canvas(1:60, :, 2) = banner(2);
    canvas(1:60, :, 3) = banner(3);
    canvas(80:779, :, :) = ov;

    lines = { sprintf('%s   |   ICDR grade %d', txt, out.grade), ...
              sprintf('Referable probability: %.1f%%', 100*out.referableProb), ...
              sprintf('Confidence basis: %s', out.confidence) };
    if height(out.evidence) > 0 && out.evidence.count(1) > 0
        lines{end+1} = sprintf('Top finding: %s (n=%d)', ...
            out.evidence.finding(1), out.evidence.count(1));
    end

    canvas = insertText(canvas, [12 14], lines{1}, 'FontSize', 26, ...
        'BoxOpacity', 0, 'TextColor', 'white');
    y = 790;
    for k = 2:numel(lines)
        canvas = insertText(canvas, [12 y], lines{k}, 'FontSize', 15, ...
            'BoxOpacity', 0, 'TextColor', 'black');
        y = y + 24;
    end
    imwrite(canvas, p);
end


function printResult(out)
    fprintf('\n  ---------------------------------------------------------\n');
    fprintf('   %s\n', out.imageName);
    switch out.decision
        case 'recapture'
            fprintf('   DECISION : RECAPTURE\n');
            fprintf('   Reason   : %s\n', out.reason);
        otherwise
            fprintf('   DECISION : %s   (ICDR grade %d)\n', upper(out.decision), out.grade);
            fprintf('   Referable: %.1f%%   [%s]\n', 100*out.referableProb, out.confidence);
            if height(out.evidence) > 0
                fprintf('   Evidence :\n');
                for k = 1:min(3, height(out.evidence))
                    fprintf('     %-16s n=%-5d %.0f%% of heatmap attention\n', ...
                        out.evidence.finding(k), out.evidence.count(k), ...
                        100*out.evidence.camMassFraction(k));
                end
            end
            fprintf('   Operating point: %s\n', out.operatingPoint);
    end
    fprintf('   %.2f s total\n', out.timings.total);
    fprintf('  ---------------------------------------------------------\n');
end
