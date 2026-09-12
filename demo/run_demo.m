function D = run_demo(opts)
%RUN_DEMO  One-command prototype demo: sample images in, clinical reports out.
%
%   run_demo                      % 6 images, writes reports/demo/
%   run_demo(n=12)                % more images
%   run_demo(openReport=true)     % open the first report in a browser
%
%   Phase 7 deliverable. Runs the full five-module system on sample fundus
%   images and prints a summary a judge or clinician can read in a minute.
%
%   WHAT THIS DEMO DELIBERATELY DOES NOT DO
%   ---------------------------------------
%   It does not present the system as ready. Every number that would be
%   misleading on its own is printed with the caveat that qualifies it:
%
%     - the headline 90.3% sensitivity is APTOS-INTERNAL; the held-out
%       external result at the same frozen threshold was 31.2%
%     - the microaneurysm and haemorrhage counts exist internally but are
%       NEVER displayed, because their measured precision (0.028 and 0.164 on
%       the IDRiD test split, 2026-09-13) is far below the 0.50 bar for
%       showing a clinician a number
%     - per-site calibration is a precondition, not a nice-to-have
%
%   A demo that hides these is a demo that fails the first hard question.
%
%   See also RUNDRISHTISYSTEM, RUNDRISHTIPIPELINE, RECOMMEND_DISTRICT_CONFIGURATION.

    arguments
        opts.n (1,1) double = 6
        opts.outputDir (1,:) char = ''
        opts.openReport (1,1) logical = false
        opts.source (1,:) char = ''
    end

    here = fileparts(mfilename('fullpath'));
    addpath(genpath(fullfile(here, '..', 'src')));
    addpath(fullfile(here, '..', 'config'));
    addpath(fullfile(here, '..', 'simulink'));

    cfg = drishti_paths();
    src = opts.source;
    if isempty(src), src = cfg.idrid.segTrainImages; end

    outDir = opts.outputDir;
    if isempty(outDir), outDir = fullfile(cfg.reportsDir, 'demo'); end
    if ~isfolder(outDir), mkdir(outDir); end

    banner();

    % ---- run the system ---------------------------------------------------
    fprintf('  Running %d images through all five modules...\n\n', opts.n);
    S = runDrishtiSystem(src, 'limit', opts.n, 'saveReports', true, ...
        'outputDir', outDir, 'verbose', true, ...
        'screening', struct('centre', 'DEMO PHC', 'technician', 'Demo operator'));

    % ---- what the clinician sees -----------------------------------------
    fprintf('\n  ---------------- WHAT THE CLINICIAN SEES ----------------\n');
    fprintf('  %d one-page HTML reports in %s\n', S.n, outDir);
    fprintf('  Each contains: fundus image + Grad-CAM overlay, ICDR grade,\n');
    fprintf('  calibrated confidence with its basis stated, an evidence table,\n');
    fprintf('  and a recommended action with a follow-up window.\n');

    rep = dir(fullfile(outDir, '*_report.html'));
    D = struct('system', S, 'reportDir', outDir, ...
               'reports', string({rep.name}'), 'outputDir', outDir);

    % ---- the honest part --------------------------------------------------
    limitations();

    if opts.openReport && ~isempty(rep)
        web(fullfile(outDir, rep(1).name), '-browser');
    end
    fprintf('\n  Reports: %s\n', outDir);
    fprintf('  Full results: docs/phase3_results.md, phase5_results.md, phase6_results.md\n\n');
end


function banner()
    fprintf('\n');
    fprintf('  ================================================================\n');
    fprintf('   DRishti-AI - Explainable DR Screening for Rural India\n');
    fprintf('   SIH 2026 - SIH26038 - Team 111 Neural Cyphers - MathWorks track\n');
    fprintf('  ================================================================\n\n');
    fprintf('   [1] quality gate  ->  [2] lesion features  ->  [3] ICDR grading\n');
    fprintf('        -> [4] explainable report  -> [5] district throughput model\n\n');
end


function limitations()
%LIMITATIONS  The numbers a judge will ask about, with their caveats attached.
%
%   Every figure here is measured and traceable to a results document. They are
%   printed by the demo itself so the honest version is the default version, not
%   an appendix someone has to go looking for.

    fprintf('\n  ------------- MEASURED PERFORMANCE, HONESTLY -------------\n');
    fprintf('  Referable DR, APTOS validation (in-domain, n=733):\n');
    fprintf('      Sensitivity 90.3%%  Specificity 95.9%%  AUC 0.9891\n');
    fprintf('  Referable DR, Messidor-2 (HELD OUT, read once, n=1744):\n');
    fprintf('      Sensitivity 31.2%%  Specificity 99.5%%  AUC 0.8848\n');
    fprintf('      -> the model RANKS well but the frozen threshold sits 4.1x\n');
    fprintf('         above the median referable case on this camera.\n');
    fprintf('      -> per-site calibration recovers PART of that gap. Measured\n');
    fprintf('         end to end on IDRiD (fit TRAIN n=413 -> held-back TEST\n');
    fprintf('         n=103): sensitivity 75.0%% -> 82.8%%, specificity\n');
    fprintf('         97.4%% -> 76.9%%. It does NOT reach the 90%% target, and it\n');
    fprintf('         is NOT a Messidor-2 result.\n');
    fprintf('         CALIBRATION IS MANDATORY BEFORE DEPLOYING AT A NEW SITE.\n');

    fprintf('\n  Lesion detectors (per-lesion precision vs IDRiD ground truth):\n');
    fprintf('      hard exudates   P 0.817 / R 0.133  -> DISPLAYED\n');
    fprintf('      haemorrhages    P 0.164 / R 0.311  -> withheld (precision)\n');
    fprintf('      microaneurysms  P 0.028 / R 0.409  -> withheld (precision)\n');
    fprintf('      soft exudates   P 0.038 / R 0.026  -> withheld (precision)\n');
    fprintf('      (IDRiD test split n=27, micro-averaged, re-measured 2026-09-13)\n');
    fprintf('      -> counts exist internally but are NEVER shown. A count at 5%%\n');
    fprintf('         precision on a clinical document is a fabricated finding.\n');

    fprintf('\n  Known limits:\n');
    fprintf('      - No clinician has been timed. The <30s review target is a\n');
    fprintf('        DESIGN TARGET; a ~38s read-time floor was measured.\n');
    fprintf('      - Grad-CAM lesion enrichment 1.51x: above chance, NOT\n');
    fprintf('        validated explainability. No ophthalmologist has rated it.\n');
    fprintf('      - The quality gate does NOT improve grading accuracy\n');
    fprintf('        (measured: -9.2pp specificity). Its value is clinical:\n');
    fprintf('        an ungradable image gets a retake, never a confident grade.\n');
end
