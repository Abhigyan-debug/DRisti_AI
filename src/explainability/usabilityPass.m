function R = usabilityPass(opts)
%USABILITYPASS  Build a timed-review set and audit every report in it.
%
%   R = USABILITYPASS() generates a mixed set of reports into
%   reports/usability/, audits each against the decision-critical checklist,
%   and writes index.html - the running order for a stopwatch review.
%
%   R = USABILITYPASS(n=8, outDir=..., includeRecapture=true)
%
%   WHAT THIS MEASURES, AND WHAT IT DOES NOT
%   ----------------------------------------
%   The <30s review target is a claim about a HUMAN. Nothing in this function
%   times a human, and no ophthalmologist has reviewed these reports. What it
%   measures is the part that can be measured without one:
%
%     - machine latency: pipeline seconds per image
%     - structural completeness: is every item a reviewer must read actually on
%       the page
%     - critical-path length: the words on the banner -> grade -> confidence ->
%       evidence -> action chain, which bounds how fast the page CAN be read
%     - fabrication guard: whether any template placeholder leaked into a
%       rendered report
%
%   The critical-path word count is converted to seconds at 200 wpm, a normal
%   silent-reading rate for technical prose. That is a FLOOR on review time,
%   not an estimate of it: it assumes the reviewer reads each word once, looks
%   at no image and makes no judgement. A real review includes inspecting the
%   Grad-CAM overlay against the stated evidence, which is the slow part and is
%   not modelled here. Do not quote the floor as the review time.
%
%   TO ACTUALLY CLOSE THIS ITEM, someone must sit a clinician in front of
%   index.html with a stopwatch. This function produces the set they review.
%
%   See also RUNDRISHTIPIPELINE, GENERATE_CLINICAL_REPORT, BUILDREPORTDATA.

    arguments
        opts.n (1,1) double = 8
        opts.outDir (1,:) char = ''
        opts.includeRecapture (1,1) logical = true
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    outDir = opts.outDir;
    if isempty(outDir), outDir = fullfile(cfg.reportsDir, 'usability'); end
    if ~isfolder(outDir), mkdir(outDir); end

    L = dir(fullfile(cfg.idrid.segTrainImages, '*.jpg'));
    n = min(opts.n, numel(L));
    rows = table();

    for k = 1:n
        ip = fullfile(L(k).folder, L(k).name);
        t = tic;
        out = runDrishtiPipeline(ip, 'saveReport', true, 'outputDir', outDir, ...
            'verbose', false, 'patient', struct('id', sprintf('DEMO-%03d', k)), ...
            'screening', struct('centre', 'PHC Demo', 'technician', 'Demo operator'));
        el = toc(t);
        rows = [rows; auditOne(out, el)]; %#ok<AGROW>
        if opts.verbose
            fprintf('  %2d/%d  %-14s %-10s %5.1fs\n', k, n+1, L(k).name, out.decision, el);
        end
    end

    if opts.includeRecapture
        % A deliberately degraded frame. The recapture report is the one a
        % technician sees most often in the field and the one most likely to go
        % untested, because it never appears in a happy-path demo.
        img = imgaussfilt(imread(fullfile(L(1).folder, L(1).name)), 25);
        t = tic;
        out = runDrishtiPipeline(img, 'saveReport', true, 'outputDir', outDir, ...
            'verbose', false, 'patient', struct('id', 'DEMO-BLUR'), ...
            'screening', struct('centre', 'PHC Demo'));
        el = toc(t);
        rows = [rows; auditOne(out, el)];
        if opts.verbose
            fprintf('  %2d/%d  %-14s %-10s %5.1fs\n', n+1, n+1, 'blurred', out.decision, el);
        end
    end

    R = struct();
    R.reports = rows;
    R.outDir = outDir;
    R.nReports = height(rows);
    R.medianPipelineSec = median(rows.pipelineSec);
    R.medianReadFloorSec = median(rows.readFloorSec);
    R.allChecksPassed = all(rows.checksPassed == rows.checksTotal);
    R.failures = rows(rows.checksPassed < rows.checksTotal, :);

    writeIndex(rows, outDir);

    if opts.verbose
        fprintf('\n  USABILITY PASS  (%d reports -> %s)\n', R.nReports, outDir);
        fprintf('  ------------------------------------------------------------\n');
        fprintf('  median pipeline time      %.1f s/image\n', R.medianPipelineSec);
        fprintf('  median read-time FLOOR    %.0f s  (%.0f words at 200 wpm)\n', ...
            R.medianReadFloorSec, median(rows.criticalPathWords));
        fprintf('    ^ a lower bound on reading alone. It excludes looking at the\n');
        fprintf('      image, which is the slow part of a real review.\n');
        fprintf('  structural checks         %d/%d reports fully complete\n', ...
            nnz(rows.checksPassed == rows.checksTotal), height(rows));
        if ~R.allChecksPassed
            fprintf('\n  INCOMPLETE REPORTS:\n');
            for i = 1:height(R.failures)
                fprintf('    %-14s %s\n', R.failures.image(i), R.failures.notes(i));
            end
        end
        fprintf('\n  HUMAN TIMING NOT DONE. The <30s target is unvalidated until a\n');
        fprintf('  clinician is timed against %s\n', fullfile(outDir, 'index.html'));
        fprintf('  ------------------------------------------------------------\n');
    end
end


% ------------------------------------------------------------------ helpers

function row = auditOne(out, pipelineSec)
%AUDITONE  Check one rendered report against the decision-critical checklist.

    h = '';
    if isfield(out, 'reportPath') && isfile(out.reportPath)
        h = fileread(out.reportPath);
    end
    txt = strtrim(regexprep(regexprep(h, '<[^>]*>', ' '), '\s+', ' '));

    % Scan for placeholders with the base64 payload removed. A ~350 KB blob of
    % random-looking base64 contains almost any short string by chance - '58Y'
    % matched four reports on its first run, none of which had leaked anything.
    hScan = regexprep(h, 'data:image/png;base64,[A-Za-z0-9+/=]+', 'IMAGE');

    chk = {};
    chk(end+1,:) = {'report written',      ~isempty(h)};
    chk(end+1,:) = {'triage banner',       ~isempty(regexp(h, 'triage-banner">\s*\S', 'once'))};
    chk(end+1,:) = {'image embedded',      contains(h, 'data:image/png;base64')};
    chk(end+1,:) = {'confidence basis',    contains(h, 'Confidence:') && ...
                       (contains(h, 'calibrated') || contains(h, 'no grade produced'))};
    chk(end+1,:) = {'evidence table row',  ~isempty(regexp(h, '<tbody>\s*<tr', 'once'))};
    chk(end+1,:) = {'recommended action',  contains(h, 'Triage Action')};
    chk(end+1,:) = {'follow-up window',    contains(h, 'Follow-up Window')};

    % A bare 0 in a lesion card is a clinical assertion an unvalidated detector
    % cannot support. It must render as "not validated" instead.
    chk(end+1,:) = {'lesion channels qualified', ~contains(h, 'stat-val">0<')};

    % Fabrication guard. Each of these strings exists ONLY in the layout
    % template, so any of them in a rendered report means a placeholder survived
    % into a clinical document.
    leaks = {'Remidio FOP NM-10', '11 years (Type 2)', '58Y', ...
             'inferior macular exudate', 'Score: 0.88', 'Platt Scaled'};
    leaked = leaks(cellfun(@(s) contains(hScan, s), leaks));
    chk(end+1,:) = {'no template placeholders', isempty(leaked)};

    passed = cellfun(@logical, chk(:,2));
    notes = "";
    if ~all(passed)
        notes = strjoin(string(chk(~passed,1)), '; ');
    end
    if ~isempty(leaked)
        notes = notes + " [leaked: " + strjoin(string(leaked), ', ') + "]";
    end

    cp = extractCriticalPath(txt);
    words = numel(strsplit(strtrim(cp), ' '));

    row = table(string(out.imageName), string(out.decision), pipelineSec, ...
        words, words / 200 * 60, nnz(passed), numel(passed), notes, ...
        'VariableNames', {'image','decision','pipelineSec','criticalPathWords', ...
                          'readFloorSec','checksPassed','checksTotal','notes'});
end


function cp = extractCriticalPath(txt)
%EXTRACTCRITICALPATH  The text a reviewer must read to reach a decision.
%
%   Runs from the grade banner to the follow-up window. Excludes the page
%   header, the sign-off bar and the styling - a reviewer does not read the
%   product name to decide whether to refer.

    a = regexp(txt, 'GRADE|UNGRADEABLE', 'once');
    b = regexp(txt, 'Follow-up Window', 'once');
    if isempty(a) || isempty(b) || b <= a
        cp = txt;
    else
        cp = txt(a:min(b+40, numel(txt)));
    end
end


function writeIndex(rows, outDir)
%WRITEINDEX  The running order for a stopwatch review.
%
%   Deliberately gives the reviewer no grade and no decision before they open a
%   report. Showing the answer in the index would let them confirm rather than
%   read, which times the wrong thing.

    fid = fopen(fullfile(outDir, 'index.html'), 'w', 'native', 'UTF-8');
    fprintf(fid, ['<!DOCTYPE html><meta charset="UTF-8">' ...
        '<title>DRishti-AI usability review set</title>' ...
        '<style>body{font-family:system-ui,sans-serif;max-width:760px;margin:40px auto;' ...
        'padding:0 16px;color:#111827;line-height:1.5}' ...
        'li{margin:6px 0}code{background:#f3f4f6;padding:1px 5px;border-radius:3px}' ...
        '.note{background:#fffbeb;border-left:4px solid #f59e0b;padding:12px 16px;' ...
        'margin:20px 0;font-size:14px}</style>']);
    fprintf(fid, '<h1>Review set (%d reports)</h1>', height(rows));
    fprintf(fid, ['<div class="note"><b>Protocol.</b> Start a stopwatch, open one ' ...
        'report, and stop the clock when you could sign it off - you have a grade, ' ...
        'you have decided whether you agree with it, and you know the action. ' ...
        'Do not read ahead: the grades are deliberately not listed here.</div>']);
    fprintf(fid, ['<div class="note"><b>Record per report:</b> seconds to sign-off &middot; ' ...
        'agree / disagree with the grade &middot; whether the Grad-CAM overlay landed on ' ...
        'the lesions named in the evidence table &middot; anything you had to hunt for.</div>']);
    fprintf(fid, '<ol>');
    for i = 1:height(rows)
        fprintf(fid, '<li><a href="%s_report.html">%s</a></li>', rows.image(i), rows.image(i));
    end
    fprintf(fid, '</ol>');
    fprintf(fid, ['<p style="color:#6b7280;font-size:13px">Generated by ' ...
        '<code>usabilityPass</code>. Machine timings are in the returned struct; ' ...
        'the human timing is what this page exists to collect.</p>']);
    fclose(fid);
end
