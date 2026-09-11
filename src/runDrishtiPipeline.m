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
%   (90.3% sensitivity internally, 31.2% on Messidor-2). For a new site, fit a
%   local operating point with FITSITECALIBRATION on ~200 labelled local images
%   and pass it in via opts.siteCalibration. Running a new camera on the
%   shipped threshold is a known failure mode, not an untested risk.
%
%   See also PROCESSIMAGE, EXTRACTLESIONFEATURES, EXPLAINGRADING,
%   FITSITECALIBRATION.

    arguments
        imagePath
        opts.modelFile (1,:) char = ''
        opts.saveReport (1,1) logical = false
        opts.outputDir (1,:) char = ''
        opts.siteCalibration struct = struct()
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    tAll = tic;

    if ischar(imagePath) || isstring(imagePath)
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
                         'summary', q.summary);

    if ~q.gradable
        out.decision = 'recapture';
        out.reason = q.summary;
        out.timings.total = toc(tAll);
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
    out.overlay = E.overlay;
    out.evidence = E.evidence;
    out.camAgreement = E.agreement;
    out.features = E.features;

    % ---- operating point --------------------------------------------------
    rawScore = E.referableScore;
    if isfield(opts.siteCalibration, 'a')
        S = opts.siteCalibration;
        out.referableProb = 1 ./ (1 + exp(-(S.a * rawScore + S.b)));
        refer = rawScore >= S.thresholdRaw;
        out.confidence = sprintf('site-calibrated on %d local images', S.n);
        out.operatingPoint = 'site';
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
        dir0 = opts.outputDir;
        if isempty(dir0), dir0 = fullfile(cfg.reportsDir, 'demo'); end
        if ~isfolder(dir0), mkdir(dir0); end
        out.reportPath = writeReport(out, dir0);
    end

    if opts.verbose, printResult(out); end
end


% ------------------------------------------------------------------ helpers

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
