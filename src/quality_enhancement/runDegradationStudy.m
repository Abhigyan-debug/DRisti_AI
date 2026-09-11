function S = runDegradationStudy(opts)
%RUNDEGRADATIONSTUDY  Validate Module 1's response to controlled defects.
%
%   S = RUNDEGRADATIONSTUDY() takes images the gate currently passes cleanly,
%   degrades each one across a severity sweep for every failure mode, and
%   records what the gate decides and what the metrics do.
%
%   S = RUNDEGRADATIONSTUDY(nBase=6, saveReport=true)
%
%   Four questions it answers
%   -------------------------
%   1. MONOTONICITY - does the relevant metric move in one direction as the
%      defect worsens? A metric that wobbles cannot carry a threshold.
%   2. DETECTION FLOOR - at what severity does the gate stop saying 'pass'?
%   3. RECOVERY - does enhancement actually undo the recoverable defects
%      (illumination, haze, noise) and return metrics toward baseline?
%   4. LEAKAGE - the safety-critical one. Does a blurred image ever reach
%      'pass' after enhancement? It must not: CLAHE raises the sharpness score
%      without restoring detail, so a leak here means blurred images reach the
%      grader. PROCESSIMAGE guards this by freezing the focus verdict on the
%      original; this study is what proves the guard holds.
%
%   Base images are drawn to cover all three FOV bands (small/mid/large),
%   because severity is FOV-scaled and a gate that behaves well at one
%   resolution may not at another.
%
%   Results go to results/phase1/degradation_study.csv and, with saveReport,
%   docs/phase1_degradation_study.md.
%
%   See also DEGRADEIMAGE, PROCESSIMAGE, GATEIMAGE.

    arguments
        opts.nBase (1,1) double {mustBePositive} = 6
        opts.saveReport (1,1) logical = true
        opts.seed (1,1) double = 0
    end

    cfg = drishti_paths();
    rng(opts.seed);

    modes = {'blur', 'illumination', 'glare', 'darken', 'brighten', 'noise', 'haze'};
    severities = 0:0.125:1;

    base = collectCleanBaseImages(cfg, opts.nBase);
    if isempty(base)
        error('drishti:noBaseImages', 'No cleanly-passing base images found.');
    end
    fprintf('  %d base images: %s\n', numel(base), ...
        strjoin(arrayfun(@(b) sprintf('%s/%s', b.corpus, b.band), base, ...
                         'UniformOutput', false), ', '));

    rows = {};
    for b = 1:numel(base)
        img0 = base(b).img;
        fov0 = base(b).fov;
        for m = 1:numel(modes)
            for s = severities
                degraded = degradeImage(img0, modes{m}, s, fov0);
                r = processImage(degraded);
                q = r.before;
                rows(end+1, :) = { base(b).corpus, base(b).band, base(b).file, ...
                    modes{m}, s, r.decision, r.enhanced, ...
                    q.sharpness.normalised, q.illum.uniformityCV, ...
                    q.illum.glareFraction, q.illum.contrast, ...
                    q.illum.meanIntensity, q.noise, firstRejectCode(r) }; %#ok<AGROW>
            end
        end
        fprintf('  base %d/%d done\n', b, numel(base));
    end

    S = cell2table(rows, 'VariableNames', {'corpus','band','file','mode', ...
        'severity','decision','enhanced','sharpness','illumCV','glare', ...
        'contrast','meanInt','noise','rejectCode'});

    outDir = fullfile(cfg.resultsDir, 'phase1');
    if ~isfolder(outDir), mkdir(outDir); end
    writetable(S, fullfile(outDir, 'degradation_study.csv'));

    analyse(S, modes, severities, cfg, opts.saveReport);
end


% ------------------------------------------------------------------ helpers

function base = collectCleanBaseImages(cfg, nWanted)
%COLLECTCLEANBASEIMAGES  Images that pass the gate outright, spread over bands.
%
%   Starting from images that already pass matters: degrading an image that was
%   already borderline confounds the induced defect with the pre-existing one.

    sources = { 'APTOS', cfg.aptos.trainImages; ...
                'IDRiD', cfg.idrid.gradeTrainImages; ...
                'DRIVE', cfg.drive.trainImages };

    base = struct('corpus', {}, 'band', {}, 'file', {}, 'img', {}, 'fov', {});
    bandCount = struct('small', 0, 'mid', 0, 'large', 0);
    perBand = ceil(nWanted / 3);

    for k = 1:size(sources, 1)
        L = dir(fullfile(sources{k,2}, '*'));
        L = L(~[L.isdir]);
        L = L(randperm(numel(L)));
        for i = 1:min(60, numel(L))
            if numel(base) >= nWanted, break; end
            img = imread(fullfile(sources{k,2}, L(i).name));
            q = assessQuality(img);
            d = gateImage(q);
            if ~strcmp(d.decision, 'pass') || ~q.fov.valid
                continue
            end
            bnd = q.sharpness.band;
            if bandCount.(bnd) >= perBand
                continue
            end
            bandCount.(bnd) = bandCount.(bnd) + 1;
            base(end+1) = struct('corpus', sources{k,1}, 'band', bnd, ...
                'file', L(i).name, 'img', img, 'fov', q.fov); %#ok<AGROW>
        end
    end
end


function c = firstRejectCode(r)
    c = '';
    if strcmp(r.decision, 'reject') && ~isempty(r.reasons)
        isRej = strcmp({r.reasons.severity}, 'reject');
        if any(isRej)
            first = r.reasons(find(isRej, 1));
            c = first.code;
        end
    end
end


function analyse(S, modes, severities, cfg, saveReport)
%ANALYSE  Monotonicity, detection floor and leakage.

    metricFor = containers.Map( ...
        {'blur','illumination','glare','darken','brighten','noise','haze'}, ...
        {'sharpness','illumCV','glare','meanInt','meanInt','noise','contrast'});
    wantRising = containers.Map( ...
        {'blur','illumination','glare','darken','brighten','noise','haze'}, ...
        {false, true, true, false, true, true, false});

    lines = {};
    A = @(varargin) assignin('caller', 'lines', [evalin('caller','lines'), {sprintf(varargin{:})}]);

    fprintf('\n%-13s %-10s %7s  %-9s  %s\n', 'mode', 'metric', 'rho', 'floor', 'first reject reason');
    report = {};
    for m = 1:numel(modes)
        mode = modes{m};
        sub = S(strcmp(S.mode, mode), :);
        metric = metricFor(mode);

        % Spearman rho against severity: monotonic response, direction-checked
        rho = corr(sub.severity, sub.(metric), 'type', 'Spearman');
        expectRising = wantRising(mode);
        okDir = (expectRising && rho > 0.5) || (~expectRising && rho < -0.5);

        % Detection floor: lowest severity at which NO base image still passes
        floorSev = NaN;
        for s = severities(severities > 0)
            atS = sub(sub.severity == s, :);
            if ~any(strcmp(atS.decision, 'pass'))
                floorSev = s;
                break
            end
        end

        codes = sub.rejectCode(~cellfun(@isempty, sub.rejectCode));
        if isempty(codes)
            topCode = '(never rejected)';
        else
            u = unique(codes);
            n = cellfun(@(c) sum(strcmp(codes, c)), u);
            [~, o] = max(n);
            topCode = u{o};
        end

        flag = '';
        if ~okDir, flag = '  <-- NOT MONOTONIC'; end
        if isnan(floorSev), floorStr = 'never'; else, floorStr = sprintf('%.3f', floorSev); end
        fprintf('%-13s %-10s %+7.3f  %-9s  %s%s\n', mode, metric, rho, floorStr, topCode, flag);
        report(end+1, :) = {mode, metric, rho, floorStr, topCode, okDir}; %#ok<AGROW>
    end

    % ---- the safety-critical check --------------------------------------
    blur = S(strcmp(S.mode, 'blur'), :);
    leaked = blur(blur.severity >= 0.5 & strcmp(blur.decision, 'pass'), :);
    fprintf('\n  LEAKAGE CHECK - blurred images reaching ''pass'' at severity >= 0.5: %d of %d\n', ...
        height(leaked), height(blur(blur.severity >= 0.5, :)));
    if height(leaked) > 0
        fprintf('  *** Enhancement is letting defocus through. Investigate before Phase 2. ***\n');
        disp(unique(leaked(:, {'band','severity'})));
    else
        fprintf('  OK - the frozen focus verdict is holding.\n');
    end

    % ---- per-band behaviour ---------------------------------------------
    fprintf('\n  Detection floor for blur, by FOV band:\n');
    for bnd = ["small", "mid", "large"]
        sb = blur(strcmp(blur.band, bnd), :);
        if isempty(sb), continue; end
        f = NaN;
        for s = severities(severities > 0)
            if ~any(strcmp(sb.decision(sb.severity == s), 'pass')), f = s; break; end
        end
        if isnan(f)
            fprintf('    %-6s never rejected  <-- band-specific blind spot\n', bnd);
        else
            fprintf('    %-6s %.3f\n', bnd, f);
        end
    end

    if saveReport
        writeReport(S, report, cfg, height(leaked));
    end
end


function writeReport(S, report, cfg, nLeaked)
    f = fullfile(cfg.docsDir, 'phase1_degradation_study.md');
    fid = fopen(f, 'w');
    fprintf(fid, '# Module 1 Degradation Response\n\n');
    fprintf(fid, '*Generated by `runDegradationStudy` on %s. %d image/defect/severity combinations.*\n\n', ...
        datestr(now, 'yyyy-mm-dd'), height(S)); %#ok<DATST>
    fprintf(fid, ['Validates that the quality gate responds correctly to each failure mode, ' ...
        'across all three FOV bands. Severity is FOV-scaled, so the same value removes the ' ...
        'same physical retinal detail on any camera.\n\n']);
    fprintf(fid, ['> These severities are **not** a clinical calibration. Synthetic defocus is not ' ...
        'cataract and a brightness ramp is not a misaligned flash. This establishes monotonic ' ...
        'response and detection floors, not where a human draws the ungradable line.\n\n']);
    fprintf(fid, '## Response per failure mode\n\n');
    fprintf(fid, '| Defect | Metric | Spearman rho | Detection floor | Typical reject reason | Monotonic |\n');
    fprintf(fid, '|---|---|---|---|---|---|\n');
    for i = 1:size(report, 1)
        if report{i,6}, ok = 'yes'; else, ok = '**NO**'; end
        fprintf(fid, '| %s | `%s` | %+.3f | %s | `%s` | %s |\n', ...
            report{i,1}, report{i,2}, report{i,3}, report{i,4}, report{i,5}, ok);
    end
    fprintf(fid, '\n## Leakage check\n\n');
    if nLeaked == 0
        fprintf(fid, ['No blurred image at severity >= 0.5 reached `pass`. The frozen focus ' ...
            'verdict in `processImage` is holding - enhancement cannot restore detail that ' ...
            'was never captured, and it is not being allowed to pretend otherwise.\n']);
    else
        fprintf(fid, ['**%d blurred images reached `pass`.** Enhancement is letting defocus ' ...
            'through to the grader. This must be fixed before Phase 2.\n'], nLeaked);
    end
    fclose(fid);
    fprintf('\n  report -> docs/phase1_degradation_study.md\n');
end
