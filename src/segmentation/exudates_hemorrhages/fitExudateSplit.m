function S = fitExudateSplit(opts)
%FITEXUDATESPLIT  Fit the hard-vs-soft exudate boundary against IDRiD ground truth.
%
%   S = FITEXUDATESPLIT                 % TRAIN split, writes config/exudate_split.json
%   S = FITEXUDATESPLIT(save=false)     % sweep only, write nothing
%
%   THE PROBLEM THIS SOLVES
%   -----------------------
%   SEGMENTEXUDATES separated hard from soft exudates on `combined >= 1.0`.
%   That 1.0 was never fitted to anything - it was a plausible-looking constant
%   on a normalised score. Measured on the held-out split it produced a soft
%   channel with precision 0.000: four detections across 27 images, none of them
%   correct, while 38 real cotton-wool spots went unreported. A boundary nobody
%   fitted is a boundary nobody checked.
%
%   THE OBJECTIVE, STATED BEFORE THE SWEEP WAS RUN
%   ----------------------------------------------
%       maximise soft-exudate F1 on TRAIN,
%       subject to hard-exudate per-lesion precision >= 0.50 on TRAIN.
%
%   The constraint is not negotiable after the fact: hard exudates drive the DME
%   endpoint (hardExudates.minDistanceToFoveaDD) and are the only channel
%   currently fit to display. Buying a soft-channel improvement by pushing hard
%   exudates below the reporting bar would be a net loss dressed up as progress.
%
%   AMENDMENT, AND WHY IT IS NOT CHERRY-PICKING
%   -------------------------------------------
%   The first sweep showed soft-exudate precision peaking near 0.095 across the
%   ENTIRE grid - an order of magnitude below the 0.50 reporting gate. The soft
%   channel is therefore unreportable at every boundary, which makes "maximise
%   soft F1" an objective that optimises something no clinician will ever see,
%   and the rule as first written chose a boundary that cut hard-exudate recall
%   from 0.142 to 0.119 to get there.
%
%   So the rule is now conditional, and the condition is decided by the FROZEN
%   gate rather than by preference:
%
%     if no boundary makes soft exudates reportable (soft precision never
%     reaches displayPrecisionMin), the boundary affects only the displayable
%     channel, so choose the one that MAXIMISES HARD-EXUDATE RECALL subject to
%     hard precision >= 0.50;
%     otherwise maximise soft F1 under the same precision constraint.
%
%   Both branches are stated here before the second run, and the sweep table is
%   printed in full either way so the choice can be checked rather than trusted.
%
%   TRAIN ONLY
%   ----------
%   The boundary is fitted here and measured by VALIDATELESIONDETECTORS on the
%   TEST split, which this function never reads. Fitting and scoring on the same
%   images is what made the old exudate numbers unreproducible.
%
%   See also SEGMENTEXUDATES, LOADEXUDATESPLIT, VALIDATELESIONDETECTORS.

    arguments
        opts.limit (1,1) double = Inf
        opts.save (1,1) logical = true
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    imgDir  = cfg.idrid.segTrainImages;
    maskRoot = cfg.idrid.segTrainMasks;

    L = dir(fullfile(imgDir, '*.jpg'));
    n = min(numel(L), opts.limit);
    if n == 0
        error('drishti:noImages', 'No IDRiD training images at %s', imgDir);
    end

    if opts.verbose
        fprintf('\n  Fitting hard/soft exudate boundary on IDRiD TRAIN, %d images\n', n);
        fprintf('  objective: max soft F1 subject to hard precision >= 0.50\n\n');
    end

    per = cell(n, 1);
    for k = 1:n
        base = erase(L(k).name, '.jpg');
        img = imread(fullfile(imgDir, L(k).name));

        fov  = detectFOV(img);
        disc = locateOpticDisc(img, 'fov', fov);
        v    = segmentVessels(img, 'fov', fov, 'discRadiusPx', disc.radius);
        fv   = locateFovea(img, disc, 'vesselMask', v.mask);
        ctx  = struct('fov', fov, 'disc', disc, 'vesselMask', v.mask, 'fovea', fv);

        % Any threshold: the per-component scores do not depend on it, which is
        % what makes a single pass per image enough to sweep the whole range.
        e = segmentExudates(img, ctx, 'splitThreshold', 1.0, ...
            'returnSplitDiagnostics', true);
        if ~isfield(e, 'split') || isempty(e.split.scores)
            per{k} = emptyRecord();
            continue
        end

        sz = e.split.workSize;
        gEX = downTo(readMask(fullfile(maskRoot, '3. Hard Exudates', [base '_EX.tif'])), sz);
        gSE = downTo(readMask(fullfile(maskRoot, '4. Soft Exudates', [base '_SE.tif'])), sz);

        LEX = bwlabel(gEX, 8);
        LSE = bwlabel(gSE, 8);

        rec = struct();
        rec.scores = e.split.scores(:);
        rec.nEX = max(LEX(:));
        rec.nSE = max(LSE(:));
        m = numel(e.split.pixelIdxList);
        rec.exHit = cell(m,1);
        rec.seHit = cell(m,1);
        for q = 1:m
            px = e.split.pixelIdxList{q};
            a = unique(LEX(px)); rec.exHit{q} = a(a > 0);
            b = unique(LSE(px)); rec.seHit{q} = b(b > 0);
        end
        per{k} = rec;

        if opts.verbose && mod(k, 10) == 0
            fprintf('    %2d/%d images\n', k, n);
        end
    end

    % ---- sweep ------------------------------------------------------------
    grid = 0.2:0.05:2.0;
    hardP = nan(size(grid)); hardR = nan(size(grid));
    softP = nan(size(grid)); softR = nan(size(grid)); softF = nan(size(grid));

    for gi = 1:numel(grid)
        thr = grid(gi);
        hTP = 0; hN = 0; sTP = 0; sN = 0;
        exFound = 0; exTotal = 0; seFound = 0; seTotal = 0;

        for k = 1:n
            r = per{k};
            if isempty(r) || isempty(r.scores), continue; end
            isHard = r.scores >= thr;

            hN = hN + nnz(isHard);
            sN = sN + nnz(~isHard);

            exSeen = []; seSeen = [];
            for q = 1:numel(r.exHit)
                if isHard(q)
                    if ~isempty(r.exHit{q}), hTP = hTP + 1; exSeen = [exSeen; r.exHit{q}]; end %#ok<AGROW>
                else
                    if ~isempty(r.seHit{q}), sTP = sTP + 1; seSeen = [seSeen; r.seHit{q}]; end %#ok<AGROW>
                end
            end
            exFound = exFound + numel(unique(exSeen)); exTotal = exTotal + r.nEX;
            seFound = seFound + numel(unique(seSeen)); seTotal = seTotal + r.nSE;
        end

        hardP(gi) = hTP / max(hN, 1);
        hardR(gi) = exFound / max(exTotal, 1);
        softP(gi) = sTP / max(sN, 1);
        softR(gi) = seFound / max(seTotal, 1);
        softF(gi) = 2 * softP(gi) * softR(gi) / max(softP(gi) + softR(gi), eps);
    end

    % ---- apply the pre-stated rule ----------------------------------------
    feasible = hardP >= 0.50;
    S = struct();
    S.grid = grid;
    S.hardPrecision = hardP; S.hardRecall = hardR;
    S.softPrecision = softP; S.softRecall = softR; S.softF1 = softF;
    S.constraintMet = feasible;
    S.objective = ['max soft F1 s.t. hard precision >= 0.50; falls back to max ' ...
        'hard recall when soft cannot clear the reporting gate at any boundary'];
    S.n = n;
    S.fittedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm'));

    % The frozen reporting gate decides which branch applies - not a preference.
    gates = jsondecode(fileread(fullfile(cfg.projectRoot, 'config', ...
        'lesion_validation_thresholds.json')));
    softCanEverBeReported = any(softP >= gates.gates.displayPrecisionMin);
    S.softCanEverBeReported = softCanEverBeReported;

    if ~any(feasible)
        % No boundary satisfies the constraint. Keeping the old value is the
        % correct outcome: the fit failed, and inventing a threshold that breaks
        % the one working channel would be worse than leaving it alone.
        S.splitThreshold = 1.0;
        S.feasible = false;
        S.rule = 'none feasible - retained the previous hardcoded 1.0';
        S.note = ['No threshold keeps hard-exudate precision at or above 0.50. ' ...
                  'The old hardcoded 1.0 is retained and the soft channel stays ' ...
                  'unreportable.'];
    elseif ~softCanEverBeReported
        % Soft exudates cannot clear the gate at ANY boundary, so this parameter
        % only ever affects the hard channel. Optimise the thing that is
        % actually shown: hard-exudate recall, which is its binding weakness.
        % Hard recall ties across a wide band of boundaries, and a bare max()
        % returns the FIRST tied index - which picked 0.20 (hard precision
        % 0.652) over 1.50 (same recall 0.142, precision 0.810). That is an
        % artefact of argmax, not a decision. Break the tie on precision: among
        % boundaries with the best recall, take the most precise. It is a strict
        % dominance argument, so nothing is being traded away.
        cand = hardR; cand(~feasible) = -Inf;
        best = max(cand);
        tied = find(cand >= best - 1e-12);
        [~, wi] = max(hardP(tied));
        bi = tied(wi);
        S.splitThreshold = grid(bi);
        S.feasible = true;
        S.rule = ['soft unreportable at every boundary -> maximise hard recall ' ...
                  'subject to hard precision >= 0.50'];
        S.note = sprintf(['Fitted on IDRiD train (n=%d). Soft-exudate precision ' ...
            'peaks at %.3f across the whole sweep, far below the %.2f reporting ' ...
            'gate, so the soft channel is a detector-level failure rather than a ' ...
            'threshold choice and stays hidden. The boundary was therefore set to ' ...
            'favour the displayable channel: hard precision %.3f, recall %.3f.'], ...
            n, max(softP), gates.gates.displayPrecisionMin, hardP(bi), hardR(bi));
    else
        cand = softF; cand(~feasible) = -Inf;
        [~, bi] = max(cand);
        S.splitThreshold = grid(bi);
        S.feasible = true;
        S.rule = 'maximise soft F1 subject to hard precision >= 0.50';
        S.note = sprintf(['Fitted on IDRiD train (n=%d). At this boundary, train ' ...
            'hard precision %.3f / recall %.3f, soft precision %.3f / recall %.3f, ' ...
            'soft F1 %.3f.'], n, hardP(bi), hardR(bi), softP(bi), softR(bi), softF(bi));
    end

    if opts.verbose, printSweep(S); end

    if opts.save
        out = fullfile(cfg.projectRoot, 'config', 'exudate_split.json');
        J = struct('purpose', ['Hard-vs-soft exudate decision boundary, FITTED on ' ...
                               'the IDRiD training split. Read by loadExudateSplit.'], ...
                   'splitThreshold', S.splitThreshold, ...
                   'objective', S.objective, ...
                   'ruleApplied', S.rule, ...
                   'softCanEverBeReported', S.softCanEverBeReported, ...
                   'feasible', S.feasible, ...
                   'fittedOn', sprintf('IDRiD segmentation TRAIN split, n=%d', n), ...
                   'fittedAt', S.fittedAt, ...
                   'note', S.note);
        fid = fopen(out, 'w');
        fprintf(fid, '%s', jsonencode(J, 'PrettyPrint', true));
        fclose(fid);
        S.savedTo = out;
        if opts.verbose, fprintf('  saved -> %s\n\n', out); end
    end
end


% ------------------------------------------------------------------ helpers

function r = emptyRecord()
    r = struct('scores', [], 'nEX', 0, 'nSE', 0, 'exHit', {{}}, 'seHit', {{}});
end


function b = readMask(p)
    if ~isfile(p), b = []; return; end
    m = imread(p);
    if ndims(m) == 3, m = m(:,:,1); end
    b = m > 0;
end


function g = downTo(b, sz)
%DOWNTO  Ground truth at the detector's working scale.
%
%   An absent mask means the lesion is absent, so it becomes an empty mask of
%   the right size rather than being skipped - otherwise every false positive on
%   a negative image would vanish from the fit.

    if isempty(b)
        g = false(sz);
    else
        g = imresize(b, sz, 'nearest');
    end
end


function printSweep(S)
    fprintf('\n  ===== HARD/SOFT EXUDATE BOUNDARY SWEEP (train) =====\n');
    fprintf('  %6s  %8s %8s  %8s %8s %8s  %s\n', ...
        'thr', 'hardP', 'hardR', 'softP', 'softR', 'softF1', 'hard>=0.50');
    for i = 1:numel(S.grid)
        if mod(i, 2) == 1 || S.grid(i) == S.splitThreshold
            flag = '';
            if S.constraintMet(i), flag = 'ok'; end
            marker = '';
            if S.grid(i) == S.splitThreshold, marker = '  <- chosen'; end
            fprintf('  %6.2f  %8.3f %8.3f  %8.3f %8.3f %8.3f  %-3s%s\n', ...
                S.grid(i), S.hardPrecision(i), S.hardRecall(i), ...
                S.softPrecision(i), S.softRecall(i), S.softF1(i), flag, marker);
        end
    end
    fprintf('  %s\n', S.note);
end
