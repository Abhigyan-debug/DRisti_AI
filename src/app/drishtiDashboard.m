function drishtiDashboard()
%DRISHTIDASHBOARD  Load a retinal photograph, screen it, read the result in plain words.
%
%   drishtiDashboard
%
%   A single-image front end for the whole five-module system. Pick a fundus
%   photograph, press Screen, and read a report written for the person holding
%   the camera rather than for a retina specialist.
%
%   WHAT IT IS FOR
%   --------------
%   RUN_DEMO screens a folder and prints to the console; GENERATE_CLINICAL_REPORT
%   writes a one-page HTML document in clinical vocabulary. Neither answers the
%   question a PHC technician actually has, which is "I have this one patient in
%   front of me - what do I do now?". This does, and it puts the caveats in the
%   same field of view as the answer instead of in a document nobody opens.
%
%   HOW IT RELATES TO THE REST OF THE SYSTEM
%   ----------------------------------------
%   It is a shell, deliberately. Every decision is made by RUNDRISHTIPIPELINE,
%   every plain-English sentence by PLAINLANGUAGEREPORT, and the formal report by
%   GENERATE_CLINICAL_REPORT. Nothing clinical is decided in this file, so the
%   UI cannot drift away from what the pipeline actually concluded.
%
%   SITE CALIBRATION
%   ----------------
%   The dashboard opens UNCALIBRATED and says so, in red, above the result. That
%   is not decoration: at the frozen threshold on an unseen camera the measured
%   sensitivity was 31.2%. Use "Load site calibration" with a .mat saved from
%   FITSITECALIBRATION before screening anyone for real.
%
%   NOTE: this file has never been executed - no MATLAB on the authoring
%   machine. Expect first-run syntax slips.
%
%   See also RUNDRISHTIPIPELINE, PLAINLANGUAGEREPORT, FITSITECALIBRATION,
%   GENERATE_CLINICAL_REPORT, RUN_DEMO.

    ensureOnPath();

    % ---- shared state -----------------------------------------------------
    S = struct('imgPath', '', 'img', [], 'result', struct(), ...
               'hasResult', false, 'calibration', struct(), 'calibNote', '');

    % This machine's saved site calibration, if it has one. Loading it here
    % means a calibrated site opens calibrated rather than depending on the
    % operator remembering to press a button every session. An absent or
    % malformed artifact returns an empty struct and the dashboard opens in
    % the UNCALIBRATED state, which is the loud default.
    S.calibration = loadSiteCalibration();
    if isCalibrated(S.calibration)
        S.calibNote = autoCalibNote(S.calibration);
    end

    ui = buildUI();
    updateChip();
    showHtml(welcomeHtml());
    setStatus('Ready. Load a retinal photograph to begin.');


    % ================================================================== UI

    function u = buildUI()
        u = struct();
        u.fig = uifigure('Name', 'DRishti-AI  -  retinal screening dashboard', ...
                         'Position', [80 60 1320 840], 'Color', [0.96 0.97 0.98]);

        outer = uigridlayout(u.fig, [3 2]);
        outer.RowHeight    = {92, '1x', 24};
        outer.ColumnWidth  = {'1.05x', '1x'};
        outer.Padding      = [14 14 14 14];
        outer.RowSpacing   = 12;
        outer.ColumnSpacing = 12;

        % ---- header --------------------------------------------------------
        header = uipanel(outer, 'BackgroundColor', [1 1 1], 'BorderType', 'none');
        header.Layout.Row = 1;
        header.Layout.Column = [1 2];

        hg = uigridlayout(header, [2 2]);
        hg.RowHeight   = {'1x', '1x'};
        hg.ColumnWidth = {'1x', 300};
        hg.Padding     = [16 8 16 8];
        hg.RowSpacing  = 2;

        t = uilabel(hg, 'Text', 'DRishti-AI  -  diabetic retinopathy screening', ...
                    'FontSize', 20, 'FontWeight', 'bold', 'FontColor', [0.06 0.09 0.16]);
        t.Layout.Row = 1; t.Layout.Column = 1;

        sub = uilabel(hg, 'FontSize', 12, 'FontColor', [0.42 0.45 0.50], ...
            'Text', ['Screening aid only - an ophthalmologist reviews every result. ' ...
                     'Five modules: quality gate, lesion features, ICDR grade, explanation, throughput.']);
        sub.Layout.Row = 2; sub.Layout.Column = 1;

        % The operating-point chip is the single most important thing on the
        % header bar, so it gets a colour and sits where the eye lands.
        u.chip = uilabel(hg, 'Text', '', 'FontSize', 12, 'FontWeight', 'bold', ...
            'HorizontalAlignment', 'center', 'BackgroundColor', [0.99 0.91 0.91], ...
            'FontColor', [0.55 0.06 0.06]);
        u.chip.Layout.Row = 1; u.chip.Layout.Column = 2;

        u.calibBtn = uibutton(hg, 'Text', 'Load site calibration...', ...
            'ButtonPushedFcn', @(~,~) onLoadCalibration());
        u.calibBtn.Layout.Row = 2; u.calibBtn.Layout.Column = 2;

        % ---- left: the photograph -----------------------------------------
        left = uipanel(outer, 'Title', '  Retinal photograph', 'FontWeight', 'bold', ...
                       'BackgroundColor', [1 1 1]);
        left.Layout.Row = 2; left.Layout.Column = 1;

        lg = uigridlayout(left, [3 1]);
        lg.RowHeight = {36, '1x', 40};
        lg.Padding   = [10 10 10 10];
        lg.RowSpacing = 8;

        toolbar = uigridlayout(lg, [1 4]);
        toolbar.ColumnWidth = {150, 150, 160, '1x'};
        toolbar.Padding = [0 0 0 0];
        toolbar.ColumnSpacing = 8;
        toolbar.Layout.Row = 1;

        u.loadBtn = uibutton(toolbar, 'Text', 'Load photograph...', ...
            'ButtonPushedFcn', @(~,~) onLoadImage());

        u.runBtn = uibutton(toolbar, 'Text', 'Screen this image', 'Enable', 'off', ...
            'FontWeight', 'bold', 'BackgroundColor', [0.15 0.39 0.92], ...
            'FontColor', [1 1 1], 'ButtonPushedFcn', @(~,~) onScreen());

        u.overlayBtn = uibutton(toolbar, 'state', 'Text', 'Show AI attention', ...
            'Enable', 'off', 'ValueChangedFcn', @(~,~) drawImage());

        u.saveBtn = uibutton(toolbar, 'Text', 'Save clinical report', 'Enable', 'off', ...
            'ButtonPushedFcn', @(~,~) onSaveReport());

        u.ax = uiaxes(lg);
        u.ax.Layout.Row = 2;
        u.ax.XTick = []; u.ax.YTick = [];
        u.ax.Box = 'off';
        disableDefaultInteractivity(u.ax);
        u.ax.Toolbar.Visible = 'off';

        u.caption = uilabel(lg, 'Text', 'No image loaded.', 'FontSize', 11, ...
            'FontColor', [0.42 0.45 0.50], 'WordWrap', 'on');
        u.caption.Layout.Row = 3;

        % ---- right: the plain-language report -------------------------------
        right = uipanel(outer, 'Title', '  What this means', 'FontWeight', 'bold', ...
                        'BackgroundColor', [1 1 1]);
        right.Layout.Row = 2; right.Layout.Column = 2;

        rg = uigridlayout(right, [1 1]);
        rg.Padding = [4 4 4 4];
        u.html = uihtml(rg);

        % ---- status --------------------------------------------------------
        u.status = uilabel(outer, 'Text', '', 'FontSize', 11, ...
                           'FontColor', [0.42 0.45 0.50]);
        u.status.Layout.Row = 3;
        u.status.Layout.Column = [1 2];
    end


    % ============================================================ callbacks

    function onLoadImage()
        [f, p] = uigetfile({'*.png;*.jpg;*.jpeg;*.JPG;*.tif;*.tiff', ...
                            'Fundus images (*.png, *.jpg, *.jpeg, *.tif)'}, ...
                           'Select a retinal photograph');
        if isequal(f, 0), return; end
        full = fullfile(p, f);

        % The holdout guard runs HERE, at selection, not at inference - by the
        % time an image has been graded the damage is already done. Two clicks
        % through a file browser is all it would take to reach the Messidor-2
        % folder, which is why this check is not left to the operator.
        try
            assertNotHoldout(full);
        catch ME
            uialert(ui.fig, ME.message, 'Held-out benchmark - refused', 'Icon', 'error');
            return
        end

        try
            img = imread(full);
        catch ME
            uialert(ui.fig, ME.message, 'Could not read that file', 'Icon', 'error');
            return
        end

        S.imgPath   = full;
        S.img       = img;
        S.result    = struct();
        S.hasResult = false;

        ui.overlayBtn.Value  = false;
        ui.overlayBtn.Enable = 'off';
        ui.saveBtn.Enable    = 'off';
        ui.runBtn.Enable     = 'on';

        drawImage();
        showHtml(welcomeHtml());
        setStatus(sprintf('Loaded %s  (%d x %d). Press "Screen this image".', ...
                          f, size(img, 2), size(img, 1)));
    end


    function onScreen()
        if isempty(S.img), return; end

        d = uiprogressdlg(ui.fig, 'Title', 'Screening', 'Indeterminate', 'on', ...
            'Message', ['Quality gate, lesion features, ICDR grade, Grad-CAM. ' ...
                        'The first run also loads a ~42 MB network, so it is the slowest.']);

        % No ONCLEANUP here: CLEAR is not permitted in a function that contains
        % nested functions, so the dialog is closed explicitly on both paths.
        failed = false;
        err = [];
        try
            % verbose off: the console narration belongs to the batch entry
            % points, not to a GUI that already shows everything on screen.
            out = runDrishtiPipeline(S.imgPath, ...
                'siteCalibration', S.calibration, 'verbose', false);
        catch ME
            failed = true;
            err = ME;
        end
        closeDialog(d);

        if failed
            uialert(ui.fig, err.message, 'Screening failed', 'Icon', 'error');
            setStatus('Screening failed. See the dialog for the error.');
            return
        end

        S.result    = out;
        S.hasResult = true;

        hasOverlay = isfield(out, 'overlay') && ~isempty(out.overlay);
        ui.overlayBtn.Enable = onOff(hasOverlay);
        ui.overlayBtn.Value  = hasOverlay;     % the explanation is the point
        ui.saveBtn.Enable    = 'on';

        drawImage();
        showHtml(reportHtml(plainLanguageReport(out, ...
            'calibrated', isCalibrated(S.calibration)), out));

        secs = NaN;
        if isfield(out, 'timings') && isfield(out.timings, 'total')
            secs = out.timings.total;
        end
        setStatus(sprintf('Done in %.1f s  -  decision: %s  -  operating point: %s', ...
            secs, upper(out.decision), operatingPointName()));
    end


    function onLoadCalibration()
        [f, p] = uigetfile({'*.mat', 'Site calibration (*.mat)'}, ...
                           'Select a calibration saved from fitSiteCalibration');
        if isequal(f, 0), return; end

        try
            C = load(fullfile(p, f));
            S.calibration = extractCalibration(C);
        catch ME
            uialert(ui.fig, ME.message, 'Not a usable calibration file', 'Icon', 'error');
            return
        end

        S.calibNote = sprintf('%s (%d local images)', f, calibN(S.calibration));
        updateChip();

        % A calibration loaded after a result was shown does not retroactively
        % apply to it. Stale numbers next to a fresh green chip would be read
        % as calibrated, so the result is cleared rather than left sitting there.
        if S.hasResult
            S.hasResult = false;
            S.result    = struct();
            ui.saveBtn.Enable    = 'off';
            ui.overlayBtn.Enable = 'off';
            ui.overlayBtn.Value  = false;
            drawImage();
            showHtml(welcomeHtml());
            setStatus('Calibration loaded. The previous result was cleared - screen the image again.');
        else
            setStatus(sprintf('Calibration loaded from %s.', f));
        end
    end


    function onSaveReport()
        if ~S.hasResult, return; end
        cfg = drishti_paths();
        outDir = fullfile(cfg.reportsDir, 'dashboard');
        if ~isfolder(outDir), mkdir(outDir); end

        try
            % Reuse the existing report path rather than re-running inference:
            % the result in hand is the one on screen, and a second forward
            % pass could return something subtly different.
            rd = buildReportData(S.result);
            shown = S.result.overlay;
            if isempty(shown), shown = S.img; end
            target = fullfile(outDir, sprintf('%s_report.html', S.result.imageName));
            outPath = generate_clinical_report(rd, shown, [], target);
        catch ME
            uialert(ui.fig, ME.message, 'Could not write the report', 'Icon', 'error');
            return
        end

        setStatus(sprintf('Clinical report written to %s', outPath));
        try
            web(outPath, '-browser');
        catch
            % No browser on a demo machine is not a failure worth a dialog -
            % the file is on disk and the status bar says where.
        end
    end


    % ============================================================== helpers

    function drawImage()
        cla(ui.ax);
        if isempty(S.img)
            ui.caption.Text = 'No image loaded.';
            return
        end

        showOverlay = strcmp(ui.overlayBtn.Enable, 'on') && ui.overlayBtn.Value;
        if showOverlay
            imshow(S.result.overlay, 'Parent', ui.ax);
            ui.caption.Text = ['AI attention (Grad-CAM). Red is where the network looked ' ...
                'hardest. It shows WHERE, never WHY - see the caveat in the report.'];
        else
            imshow(S.img, 'Parent', ui.ax);
            ui.caption.Text = S.imgPath;
        end
    end


    function updateChip()
        if isCalibrated(S.calibration)
            ui.chip.Text            = ['SITE CALIBRATED - ' calibSite(S.calibration)];
            ui.chip.BackgroundColor = [0.88 0.97 0.90];
            ui.chip.FontColor       = [0.05 0.35 0.16];
        else
            ui.chip.Text            = 'NOT CALIBRATED';
            ui.chip.BackgroundColor = [0.99 0.91 0.91];
            ui.chip.FontColor       = [0.55 0.06 0.06];
        end
    end


    function n = operatingPointName()
        if isCalibrated(S.calibration)
            n = 'site-calibrated';
        else
            n = 'frozen APTOS (UNCALIBRATED)';
        end
    end


    function showHtml(src)
        ui.html.HTMLSource = src;
    end


    function setStatus(msg)
        ui.status.Text = msg;
    end


    function s = welcomeHtml()
        parts = {htmlHead(), '<div class="wrap">'};
        parts{end+1} = '<h2>How to use this</h2>';
        parts{end+1} = ['<ol><li>Press <b>Load photograph</b> and choose a retinal image.</li>' ...
                        '<li>Press <b>Screen this image</b>.</li>' ...
                        '<li>Read the result here. It is written to be understood without ' ...
                        'clinical training.</li></ol>'];
        if ~isCalibrated(S.calibration)
            parts{end+1} = ['<div class="alert"><b>This camera has not been calibrated.</b><br>' ...
                'On a camera it had not seen before, this system at the shipped threshold found ' ...
                'only <b>31.2%</b> of the patients who genuinely needed referral - it missed about ' ...
                'two in three. Around 200 locally labelled images can refit the operating point ' ...
                '(<code>buildSiteCalibration</code>). Where that has been measured end to end, on ' ...
                'IDRiD, it moved sensitivity <b>75.0% to 82.8%</b> and specificity ' ...
                '<b>97.4% down to 76.9%</b> - it buys missed cases back by flagging more people ' ...
                'for review, and how much it recovers depends on the camera. Until a calibration ' ...
                'is loaded, treat every "no referral" here as weak evidence.</div>'];
        else
            parts{end+1} = ['<div class="ok"><b>Site calibration loaded</b><br>' ...
                escapeHtml(S.calibNote) calibPerformanceHtml(S.calibration) '</div>'];
        end
        parts{end+1} = ['<div class="note">This is a screening aid, not a diagnosis. ' ...
            'No clinician has been timed using it, and no ophthalmologist has yet rated its ' ...
            'explanations - both are open items, not finished work.</div>'];
        parts{end+1} = '</div></body></html>';
        s = strjoin(parts, newline);
    end


    % ---- main render ------------------------------------------------------

    function s = reportHtml(P, out)
        parts = {htmlHead(), '<div class="wrap">'};

        % 1. the answer, before anything else
        parts{end+1} = ['<div class="headline" style="background:' P.headlineColour '">' ...
                        escapeHtml(P.headline) '<div class="sub">' ...
                        escapeHtml(P.subhead) '</div></div>'];

        % 2. the calibration warning sits ABOVE the detail, not below it
        for k = 1:numel(P.warnings)
            w = P.warnings{k};
            if startsWith(w, 'THIS CAMERA')
                parts{end+1} = ['<div class="alert">' escapeHtml(w) '</div>']; %#ok<AGROW>
            end
        end

        % 3. grade and meaning
        parts{end+1} = '<h2>What the system found</h2>';
        parts{end+1} = ['<div class="grade">' escapeHtml(P.gradeLabel) '</div>'];
        parts{end+1} = ['<p>' escapeHtml(P.meaning) '</p>'];
        if isfield(P, 'gradeVsDecision') && ~isempty(P.gradeVsDecision)
            parts{end+1} = ['<div class="note">' escapeHtml(P.gradeVsDecision) '</div>'];
        end
        parts{end+1} = ['<p class="dim">' escapeHtml(P.confidence) '</p>'];

        % 4. the action
        parts{end+1} = '<h2>What to do next</h2>';
        parts{end+1} = ['<div class="action"><b>' escapeHtml(P.action) '</b>' ...
                        '<div class="when">' escapeHtml(P.when) '</div></div>'];

        % 5. picture quality
        parts{end+1} = '<h2>The photograph itself</h2>';
        parts{end+1} = ['<p>' escapeHtml(P.imageQuality) '</p>'];

        % 6. why
        parts{end+1} = '<h2>Why the system says this</h2>';
        parts{end+1} = htmlList(P.evidence);

        % 7. what is withheld - as prominent as what is shown
        parts{end+1} = '<h2>What this system will not tell you</h2>';
        parts{end+1} = ['<p class="dim">These detectors run, but their results are hidden ' ...
            'on purpose. A number that is wrong most of the time is worse on a clinical ' ...
            'document than no number at all.</p>'];
        parts{end+1} = htmlList(P.withheld);

        % 8. remaining caveats
        parts{end+1} = '<h2>Before you rely on this</h2>';
        rest = P.warnings(~startsWith(P.warnings, 'THIS CAMERA'));
        parts{end+1} = htmlList(rest);

        parts{end+1} = footerHtml(out);
        parts{end+1} = '</div></body></html>';
        s = strjoin(parts, newline);
    end


    function s = footerHtml(out)
        bits = {};
        if isfield(out, 'imageName')
            bits{end+1} = ['image: ' escapeHtml(char(out.imageName))];
        end
        bits{end+1} = ['operating point: ' operatingPointName()];
        if isfield(out, 'model') && isstruct(out.model) && isfield(out.model, 'backbone')
            bits{end+1} = ['model: ' escapeHtml(char(out.model.backbone))];
        end
        if isfield(out, 'timings') && isfield(out.timings, 'total')
            bits{end+1} = sprintf('%.1f s', out.timings.total);
        end
        bits{end+1} = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm'));
        s = ['<div class="foot">' strjoin(bits, '&nbsp; &middot; &nbsp;') '</div>'];
    end

end % drishtiDashboard


% =========================================================== local functions

function ensureOnPath()
%ENSUREONPATH  Make the dashboard runnable from a bare MATLAB session.
%
%   A judge or clinician opening this from the file browser has not run
%   SETUP_DRISHTI, and a dashboard that errors with "undefined function
%   runDrishtiPipeline" on first launch is a demo that does not happen.

    here = fileparts(mfilename('fullpath'));            % src/app
    root = fileparts(fileparts(here));                  % project root
    if exist('runDrishtiPipeline', 'file') ~= 2
        addpath(genpath(fullfile(root, 'src')));
        addpath(fullfile(root, 'config'));
        addpath(fullfile(root, 'simulink'));
    end
end


function s = calibSite(C)
%CALIBSITE  Short site label for the chip, so the operator sees WHICH camera.
    s = 'site not recorded';
    if isstruct(C) && isfield(C, 'meta') && isfield(C.meta, 'site')
        s = char(C.meta.site);
    end
    if numel(s) > 34, s = [s(1:31) '...']; end
end


function s = autoCalibNote(C)
%AUTOCALIBNOTE  Provenance line for a calibration loaded from disk, not picked.
    s = sprintf('%s - %d local images', calibSite(C), calibN(C));
    if isstruct(C) && isfield(C, 'meta') && isfield(C.meta, 'fittedAt')
        s = sprintf('%s, fitted %s', s, char(C.meta.fittedAt));
    end
end


function h = calibPerformanceHtml(C)
%CALIBPERFORMANCEHTML  Sensitivity AND specificity, never one without the other.
%
%   Both numbers or neither. A calibrated operating point buys sensitivity by
%   spending specificity, and a panel that showed only the half that improved
%   would misrepresent the trade the operator is living with.

    h = '';
    if ~isstruct(C) || ~isfield(C, 'evaluation'), return; end
    E = C.evaluation;
    need = {'calibratedSensitivity','calibratedSpecificity', ...
            'uncalibratedSensitivity','uncalibratedSpecificity'};
    if ~all(isfield(E, need)), return; end

    h = sprintf(['<br><span style="font-size:11px">Measured on %s, held back ' ...
        'from the fit (n=%d): sensitivity <b>%.1f%%</b>, specificity <b>%.1f%%</b>. ' ...
        'Uncalibrated on the same images: %.1f%% / %.1f%%. Those are that site''s ' ...
        'numbers, not this patient''s, and not a Messidor-2 result.</span>'], ...
        escapeHtml(E.dataset), E.n, ...
        100*E.calibratedSensitivity, 100*E.calibratedSpecificity, ...
        100*E.uncalibratedSensitivity, 100*E.uncalibratedSpecificity);
end


function tf = isCalibrated(C)
%ISCALIBRATED  A calibration is usable only if it carries the Platt slope.
    tf = isstruct(C) && isfield(C, 'a') && ~isempty(C.a);
end


function n = calibN(C)
    n = 0;
    if isstruct(C) && isfield(C, 'n'), n = C.n; end
end


function S = extractCalibration(C)
%EXTRACTCALIBRATION  Pull a FITSITECALIBRATION struct out of a loaded .mat.
%
%   Accepts either the struct saved under any variable name, or a file whose
%   top level already looks like the calibration itself.

    if isCalibrated(C)
        S = C;
        return
    end
    f = fieldnames(C);
    for k = 1:numel(f)
        v = C.(f{k});
        if isCalibrated(v)
            S = v;
            return
        end
    end
    error('drishti:noCalibrationInFile', ...
        ['That .mat contains no site calibration. Expected a struct with fields ' ...
         'a, b and thresholdRaw, as returned by fitSiteCalibration.']);
end


function s = onOff(tf)
    if tf, s = 'on'; else, s = 'off'; end
end


function closeDialog(d)
    if isvalid(d), close(d); end
end


function s = htmlList(items)
%HTMLLIST  Cellstr to an HTML bullet list, escaped.
    if isempty(items)
        s = '';
        return
    end
    parts = cell(1, numel(items));
    for k = 1:numel(items)
        parts{k} = ['<li>' escapeHtml(items{k}) '</li>'];
    end
    s = ['<ul>' strjoin(parts, '') '</ul>'];
end


function s = escapeHtml(t)
%ESCAPEHTML  Text into HTML without letting a filename become markup.
    s = char(t);
    s = strrep(s, '&', '&amp;');
    s = strrep(s, '<', '&lt;');
    s = strrep(s, '>', '&gt;');
end


function s = htmlHead()
%HTMLHEAD  Stylesheet for the report panel.
%
%   Built by concatenation rather than SPRINTF on purpose - the CSS is full of
%   per-cent signs, and a format string would eat every one of them.

    s = [ ...
'<!DOCTYPE html><html><head><meta charset="utf-8"><style>' ...
'body{font-family:"Segoe UI",Roboto,Helvetica,Arial,sans-serif;margin:0;' ...
'color:#1f2937;background:#ffffff;font-size:13.5px;line-height:1.55;}' ...
'.wrap{padding:4px 18px 28px 18px;}' ...
'h2{font-size:13px;text-transform:uppercase;letter-spacing:.05em;color:#64748b;' ...
'margin:22px 0 6px 0;border-bottom:1px solid #e2e8f0;padding-bottom:4px;}' ...
'p{margin:6px 0;}' ...
'ul{margin:6px 0;padding-left:20px;} li{margin:5px 0;}' ...
'.headline{color:#fff;font-size:19px;font-weight:700;padding:16px 18px;' ...
'border-radius:8px;margin-top:10px;letter-spacing:.01em;}' ...
'.headline .sub{font-size:13px;font-weight:400;opacity:.93;margin-top:6px;}' ...
'.grade{font-size:16px;font-weight:700;color:#0f172a;margin:4px 0 2px 0;}' ...
'.action{background:#eff6ff;border-left:4px solid #2563eb;padding:12px 14px;' ...
'border-radius:0 6px 6px 0;font-size:14.5px;}' ...
'.action .when{font-size:12.5px;color:#475569;margin-top:4px;font-weight:600;}' ...
'.alert{background:#fef2f2;border-left:4px solid #dc2626;color:#7f1d1d;' ...
'padding:12px 14px;margin:12px 0;border-radius:0 6px 6px 0;}' ...
'.ok{background:#f0fdf4;border-left:4px solid #16a34a;color:#14532d;' ...
'padding:12px 14px;margin:12px 0;border-radius:0 6px 6px 0;}' ...
'.note{background:#f8fafc;border-left:4px solid #94a3b8;color:#475569;' ...
'padding:12px 14px;margin:14px 0;border-radius:0 6px 6px 0;font-size:12.5px;}' ...
'.dim{color:#64748b;font-size:12.5px;}' ...
'.foot{margin-top:24px;padding-top:10px;border-top:1px solid #e2e8f0;' ...
'color:#94a3b8;font-size:11px;}' ...
'code{background:#f1f5f9;padding:1px 4px;border-radius:3px;font-size:12px;}' ...
'ol{padding-left:20px;} ol li{margin:5px 0;}' ...
'</style></head><body>'];
end
