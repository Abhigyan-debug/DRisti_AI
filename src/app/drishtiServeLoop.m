function drishtiServeLoop(opts)
%DRISHTISERVELOOP  Keep MATLAB warm and screen images dropped into a job folder.
%
%   drishtiServeLoop                        % poll webapp/jobs, run forever
%   drishtiServeLoop(jobDir=...)
%   drishtiServeLoop(siteCalibration=S)     % operating point from FITSITECALIBRATION
%   drishtiServeLoop(maxJobs=1)             % process one job, then return (tests)
%
%   This is the inference half of the browser dashboard. WEBAPP/SERVER.PY writes
%   an uploaded image plus a <id>.request marker into the job folder; this loop
%   notices it, runs the full pipeline, and writes <id>.result.json back.
%
%   WHY A POLLING LOOP AND NOT `matlab -batch` PER IMAGE
%   ----------------------------------------------------
%   Measured on this machine: a cold `matlab -batch` run costs ~39 s end to end,
%   of which ~14 s is MATLAB startup and most of the rest is first-call GPU and
%   cuDNN initialisation. The same pipeline in an already-warm session costs
%   ~8 s. Spawning a process per upload would therefore make every drop feel
%   broken, so the process is started once and kept alive instead.
%
%   WHY FILES AND NOT A SOCKET
%   --------------------------
%   MATLAB has no stdlib HTTP server, and piping over stdin to a -nodesktop
%   process deadlocks in ways that are miserable to debug on Windows. A job
%   folder is boring, inspectable with `dir`, and survives either side being
%   restarted independently - which matters when the Python half will be
%   restarted far more often than this one.
%
%   The write ordering is the protocol, and it is load-bearing at both ends:
%   the server writes the IMAGE first and the .request marker LAST, and this
%   loop writes the result to a .tmp and renames it into place. Neither side
%   can then observe a half-written file.
%
%   ⚠️ Holdout protection still applies here - see ASSERTNOTHOLDOUT. An upload
%   form is a new way to feed the system an image, so it gets the same guard as
%   every other entry point.
%
%   See also RUNDRISHTIPIPELINE, PLAINLANGUAGEREPORT, ASSERTNOTHOLDOUT.

    arguments
        opts.jobDir (1,:) char = ''
        opts.pollSeconds (1,1) double = 0.25
        opts.siteCalibration struct = struct()
        opts.maxJobs (1,1) double = Inf
    end

    cfg = drishti_paths();
    jobDir = opts.jobDir;
    if isempty(jobDir)
        jobDir = fullfile(cfg.projectRoot, 'webapp', 'jobs');
    end
    if ~isfolder(jobDir), mkdir(jobDir); end

    % Same resolution order as the pipeline: caller first, then this machine's
    % saved artifact. Resolved once here so the banner and every job in this
    % session report the operating point the images actually ran at.
    if ~isfield(opts.siteCalibration, 'a')
        opts.siteCalibration = loadSiteCalibration();
    end
    calibrated = isfield(opts.siteCalibration, 'a');

    banner(jobDir, calibrated, opts.siteCalibration);

    % Warm the network and the GPU before announcing readiness. Without this the
    % first person to drop an image pays the ~30 s initialisation cost and
    % concludes the dashboard is broken.
    warmUp(cfg);

    heartbeatFile = fullfile(jobDir, 'worker.alive');
    writeHeartbeat(heartbeatFile, calibrated, opts.siteCalibration);
    fprintf('  READY - waiting for uploads. Ctrl-C to stop.\n\n');

    done = 0;
    lastBeat = tic;
    while done < opts.maxJobs
        reqs = dir(fullfile(jobDir, '*.request'));
        if isempty(reqs)
            % The heartbeat lets the browser say "inference engine offline"
            % instead of hanging for 90 s when this process is not running.
            if toc(lastBeat) > 2
                writeHeartbeat(heartbeatFile, calibrated, opts.siteCalibration);
                lastBeat = tic;
            end
            pause(opts.pollSeconds);
            continue
        end

        [~, order] = sort([reqs.datenum]);          % oldest first
        for k = order(:)'
            handleJob(fullfile(jobDir, reqs(k).name), jobDir, opts.siteCalibration, calibrated);
            done = done + 1;
            writeHeartbeat(heartbeatFile, calibrated, opts.siteCalibration);
            if done >= opts.maxJobs, break; end
        end
    end
end


% ------------------------------------------------------------------ helpers

function handleJob(reqPath, jobDir, siteCal, calibrated)
%HANDLEJOB  One upload: screen it, write the result, remove the request.

    [~, id] = fileparts(reqPath);
    t0 = tic;
    fprintf('  [%s] job %s ... ', char(datetime('now','Format','HH:mm:ss')), id);

    % CLAIM THE JOB BEFORE DOING ANY WORK.
    %
    % MATLAB is single-threaded, so nothing can refresh the heartbeat during
    % RUNDRISHTIPIPELINE - and a large photograph can take 30 s. The server used
    % to read that silence as "the worker died" and gave up on a job that was
    % running perfectly well. A claim marker is the fix: it is written here, in
    % the microseconds before the expensive call, so the server can distinguish
    % "busy" from "gone" without needing a heartbeat it is never going to get.
    claimPath = fullfile(jobDir, [id '.started']);
    fid = fopen(claimPath, 'w');
    if fid >= 0
        fprintf(fid, '%s', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
        fclose(fid);
    end

    R = struct('ok', false, 'id', id, 'error', '');
    try
        req = jsondecode(fileread(reqPath));

        % Patient context, if the operator filled it in. It travels with the
        % referral and prints on the report; it is NOT an input to the model,
        % which reads the photograph and nothing else.
        %
        % Missing fields are left missing rather than defaulted. BUILDREPORTDATA
        % renders anything absent as "not recorded", and its header explains why
        % that matters: a plausible-looking age on a clinical document is
        % indistinguishable from a real one.
        pat = struct(); scr = struct();
        if isfield(req, 'patient')   && isstruct(req.patient),   pat = req.patient; end
        if isfield(req, 'screening') && isstruct(req.screening), scr = req.screening; end

        imgPath = fullfile(jobDir, req.image);
        if ~isfile(imgPath)
            error('drishti:missingUpload', 'Uploaded file not found: %s', req.image);
        end

        % Same guard as every other entry point. An upload form is exactly the
        % kind of new door through which the holdout gets read by accident.
        assertNotHoldout(string(req.image));

        out = runDrishtiPipeline(imgPath, 'siteCalibration', siteCal, 'verbose', false);
        P   = plainLanguageReport(out, 'calibrated', calibrated);

        R.ok            = true;
        % Echoed so the results page shows what actually reached the report,
        % not the browser's own copy of the form.
        R.patient       = pat;
        R.screening     = scr;
        R.decision      = out.decision;
        R.referableProb = out.referableProb;
        R.confidence    = out.confidence;
        R.seconds       = out.timings.total;
        R.calibrated    = calibrated;
        R.plain         = P;

        if isempty(out.grade)
            R.grade = [];
        else
            R.grade = out.grade;
        end

        % Five-bar distribution only when the model actually produced one -
        % drawing five bars from nothing is the template bug BUILDREPORTDATA
        % exists to prevent, and it would be just as wrong in a browser.
        R.gradeProbs = [];
        if isfield(out, 'gradeProbs') && numel(out.gradeProbs) == 5
            R.gradeProbs = out.gradeProbs(:)';
        end

        % The overlay is the explanation; write it next to the result so the
        % server can inline it. A rejected image has none, and that is correct -
        % there is no attention map for an image that was never graded.
        R.overlay = '';
        if ~isempty(out.overlay)
            ovName = [id '_overlay.png'];
            imwrite(out.overlay, fullfile(jobDir, ovName));
            R.overlay = ovName;
        end

        % Formal clinical report, written to reports/dashboard so the browser can
        % offer it for download as a PDF. GENERATE_CLINICAL_REPORT is reused rather
        % than re-implemented: the downloadable document and the one RUN_DEMO
        % produces must not be allowed to drift apart.
        R.report = '';
        try
            rcfg = drishti_paths();
            repDir = fullfile(rcfg.reportsDir, 'dashboard');
            if ~isfolder(repDir), mkdir(repDir); end
            rd = buildReportData(out, 'patient', pat, 'screening', scr);
            shown = out.overlay;
            if isempty(shown), shown = imread(imgPath); end
            repName = [id '_report.html'];
            generate_clinical_report(rd, shown, [], fullfile(repDir, repName));
            R.report = repName;
        catch ME2
            % A failed report is not a failed screening - the decision on screen is
            % still valid, only the download is unavailable.
            fprintf('(report failed: %s) ', ME2.message);
        end

        fprintf('%s (%.1f s)\n', upper(out.decision), toc(t0));

    catch ME
        R.ok = false;
        R.error = ME.message;
        fprintf('FAILED: %s\n', ME.message);
    end

    writeJsonAtomic(fullfile(jobDir, [id '.result.json']), R);

    % The server deletes these if it gave up waiting, so their absence is
    % normal rather than an error worth warning about.
    if isfile(reqPath),   delete(reqPath);   end
    if isfile(claimPath), delete(claimPath); end
end


function warmUp(cfg)
%WARMUP  Pay the first-inference cost before anyone is waiting on it.
%
%   Measured cold-vs-warm on this machine was ~39 s against ~8 s. Nearly all of
%   that gap is one-off GPU and cuDNN setup, so it is spent here, at startup,
%   rather than by whoever happens to drop the first image.

    fprintf('  Warming up the network (one-off GPU init, ~30 s)...\n');
    t = tic;
    try
        f = fullfile(cfg.idrid.segTrainImages, 'IDRiD_01.jpg');
        if isfile(f)
            runDrishtiPipeline(f, 'verbose', false);
        else
            % No dataset on this machine: a synthetic frame still triggers the
            % expensive initialisation, even though the grade is meaningless.
            runDrishtiPipeline(uint8(40 + zeros(512, 512, 3)), 'verbose', false);
        end
        fprintf('  Warm in %.1f s.\n', toc(t));
    catch ME
        % A failed warm-up is not fatal - it only means the first real upload
        % pays the cost. Worth saying out loud, not worth refusing to serve.
        fprintf('  Warm-up skipped (%s).\n', ME.message);
    end
end


function writeHeartbeat(p, calibrated, siteCal)
%WRITEHEARTBEAT  Liveness plus the operating point the worker is actually on.
%
%   The dashboard chip used to be a bare boolean. "SITE CALIBRATED" without
%   naming the site is not much better than no chip: a calibration belongs to
%   one camera, and only the operator can tell whether it is the camera in
%   front of them. So the site label and the held-back sensitivity/specificity
%   travel with the heartbeat.

    S = struct('t', posixtime(datetime('now', 'TimeZone', 'UTC')), ...
               'calibrated', calibrated);
    if nargin >= 3 && isstruct(siteCal) && isfield(siteCal, 'a')
        S.site = calibSiteLabel(siteCal);
        if isfield(siteCal, 'evaluation')
            E = siteCal.evaluation;
            % Both, or neither. Never sensitivity on its own.
            S.calSensitivity   = E.calibratedSensitivity;
            S.calSpecificity   = E.calibratedSpecificity;
            S.uncalSensitivity = E.uncalibratedSensitivity;
            S.uncalSpecificity = E.uncalibratedSpecificity;
            S.calEvalSet       = E.dataset;
            S.calEvalN         = E.n;
        end
    end
    writeJsonAtomic(p, S);
end


function s = calibSiteLabel(C)
    s = 'site not recorded';
    if isfield(C, 'meta') && isfield(C.meta, 'site')
        s = char(C.meta.site);
    end
end


function writeJsonAtomic(p, S)
%WRITEJSONATOMIC  Write via .tmp + rename so a reader never sees a partial file.

    tmp = [p '.tmp'];
    fid = fopen(tmp, 'w');
    if fid < 0
        warning('drishti:cannotWrite', 'Could not write %s', tmp);
        return
    end
    fprintf(fid, '%s', jsonencode(S));
    fclose(fid);
    movefile(tmp, p, 'f');
end


function banner(jobDir, calibrated, siteCal)
    fprintf('\n  ==========================================================\n');
    fprintf('   DRishti-AI  -  inference worker for the browser dashboard\n');
    fprintf('  ==========================================================\n');
    fprintf('  job folder : %s\n', jobDir);
    if calibrated
        fprintf('  operating point : SITE-CALIBRATED (%s)\n', calibSiteLabel(siteCal));
    else
        fprintf('  operating point : frozen APTOS - NOT CALIBRATED\n');
        fprintf('    Measured 31.2%% sensitivity on unseen equipment. Fit a local\n');
        fprintf('    operating point with buildSiteCalibration before clinical use.\n');
    end
end
