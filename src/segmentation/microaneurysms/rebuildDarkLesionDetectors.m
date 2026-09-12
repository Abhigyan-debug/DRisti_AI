function R = rebuildDarkLesionDetectors(opts)
%REBUILDDARKLESIONDETECTORS  Full microaneurysm + haemorrhage rebuild, one call.
%
%   R = REBUILDDARKLESIONDETECTORS() runs the whole dark-lesion cycle in a
%   single MATLAB invocation:
%
%       1. sweep generator recall            -> choose ONE shared threshSD
%       2. build candidate datasets          -> both channels, that threshSD
%       3. train stage-2 classifiers         -> both channels, pooled
%       4. fit the stage-2 operating point   -> TRAIN split, writes the config
%       5. print the held-out command        -> you run it, deliberately, once
%       6. save the whole run, sweep included -> results/dark_lesion_rebuild.mat
%
%   R = REBUILDDARKLESIONDETECTORS(limit=6, skipTraining=true)   % smoke run
%
%   ONE CALL BECAUSE STARTUP IS THE TAX
%   -----------------------------------
%   `matlab -batch` costs ~14 s of startup, and every stage here also rebuilds
%   the same per-image FOV / disc / vessel context. Running the five steps as
%   five invocations pays both taxes five times. Develop with `limit`; quote
%   only full-split numbers.
%
%   THE GENERATOR THRESHOLD IS SHARED, AND THAT IS A CONSTRAINT
%   -----------------------------------------------------------
%   Microaneurysms and haemorrhages come out of ONE candidate generator - the
%   two channels are split from the same connected components - so a single
%   threshSD has to serve both. Two classifiers trained at different threshSDs
%   cannot both be applied: DETECTDARKLESIONS detects that case, disables stage
%   2 and warns, because feeding a classifier out-of-distribution candidates is
%   worse than not having one. This function therefore picks one threshold for
%   both channels and builds both datasets at it.
%
%   HOW THE THRESHOLD IS CHOSEN
%   ---------------------------
%   Stage 2 can only DISCARD candidates, so generator recall is a hard ceiling
%   on final recall. The display gate needs recall >= 0.10 on held-out data, so
%   a generator ceiling near 0.10 leaves nothing for the classifier to spend
%   and no margin for the train-to-test gap.
%
%   Rule, stated before the sweep runs: take the LARGEST threshSD at which BOTH
%   channels' TRAIN generator recall reaches `recallCeilingTarget` (default
%   0.25, i.e. 2.5x the gate). Largest, because every step looser multiplies
%   the false positives the classifier then has to remove, and precision is the
%   metric both channels are failing worst. If no tested value reaches the
%   target for both, the loosest tested value is used and the shortfall is
%   reported - the channel then fails the recall gate honestly.
%
%   WHAT THIS DELIBERATELY DOES NOT DO
%   ----------------------------------
%   It does not run VALIDATELESIONDETECTORS on the test split. That is the
%   held-out measurement the display gate reads, and it should be a conscious
%   act rather than the tail of an automated script - the moment it becomes
%   something you re-run after each tweak, the gate is measuring a detector
%   that was tuned against it. Pass validate=true only when you mean it.
%
%   See also SWEEPGENERATORRECALL, BUILDCANDIDATEDATASET,
%   TRAINCANDIDATECLASSIFIER, FITLESIONOPERATINGPOINT, VALIDATELESIONDETECTORS.

    arguments
        opts.threshSDs (1,:) double = [0.5 0.75 1.0 1.25 1.5]
        opts.threshSD (1,1) double = NaN     % skip the sweep, force this value
        opts.recallCeilingTarget (1,1) double = 0.25
        opts.fragmentRejection (1,1) logical = true
        % Which geometry to build and train at. Decide it with
        % ABLATECANDIDATEPATCHGEOMETRY, then rebuild with the winner - do not
        % pick it from a held-out number.
        opts.patchGeometry (1,:) char ...
            {mustBeMember(opts.patchGeometry,{'workingScale','fullRes'})} = 'workingScale'
        opts.patchPx (1,1) double = 48
        opts.limit (1,1) double = Inf
        opts.skipTraining (1,1) logical = false
        opts.validate (1,1) logical = false
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    channels = {'microaneurysms', 'haemorrhages'};
    R = struct();
    R.startedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm'));
    R.recallCeilingTarget = opts.recallCeilingTarget;
    R.fragmentRejection = opts.fragmentRejection;
    R.patchGeometry = opts.patchGeometry;
    tAll = tic;

    % ---- 1. generator recall ceiling -------------------------------------
    if isfinite(opts.threshSD)
        threshSD = opts.threshSD;
        R.sweep = [];
        R.threshSDSource = 'forced by caller';
        banner(opts, sprintf('1/5  generator threshold FORCED to %.2f (sweep skipped)', threshSD));
    else
        banner(opts, '1/5  generator recall sweep - the ceiling stage 2 can never raise');
        R.sweep = struct();
        for ci = 1:numel(channels)
            R.sweep.(channels{ci}) = sweepGeneratorRecall( ...
                'lesion', channels{ci}, 'threshSDs', opts.threshSDs, 'limit', opts.limit);
        end
        [threshSD, R.ceilingReached] = pickThreshSD(R.sweep, channels, ...
            opts.threshSDs, opts.recallCeilingTarget, opts.verbose);
        R.threshSDSource = 'chosen by the rule in this function''s help';
    end
    R.threshSD = threshSD;

    % ---- 2. candidate datasets -------------------------------------------
    banner(opts, sprintf('2/5  building candidate datasets at threshSD %.2f', threshSD));
    R.datasets = struct();
    for ci = 1:numel(channels)
        R.datasets.(channels{ci}) = buildCandidateDataset( ...
            'lesion', channels{ci}, 'threshSD', threshSD, 'patchPx', opts.patchPx, ...
            'patchGeometry', opts.patchGeometry, ...
            'fragmentRejection', opts.fragmentRejection, 'limit', opts.limit, ...
            'verbose', opts.verbose);
    end

    % ---- 3. stage-2 classifiers ------------------------------------------
    if opts.skipTraining
        banner(opts, '3/5  training SKIPPED (skipTraining=true)');
        R.training = 'skipped';
    else
        banner(opts, '3/5  training stage-2 classifiers (pooled across both channels)');
        R.training = struct();
        for ci = 1:numel(channels)
            other = channels(~strcmp(channels, channels{ci}));
            % Pooling is a data multiplier, not an architecture change: an MA
            % and a dot haemorrhage are the same object to a patch classifier,
            % and 519 MA positives from 54 images is not enough on its own.
            % The model is still saved and evaluated per channel.
            R.training.(channels{ci}) = trainCandidateClassifier( ...
                'lesion', channels{ci}, 'pool', other, 'threshSD', threshSD, ...
                'patchGeometry', opts.patchGeometry, 'inputPx', opts.patchPx);
        end
    end

    % ---- 4. operating point, on TRAIN ------------------------------------
    banner(opts, '4/5  fitting the stage-2 operating point on the TRAIN split');
    R.operatingPoint = fitLesionOperatingPoint( ...
        'fragmentRejection', opts.fragmentRejection, 'limit', opts.limit, ...
        'write', true, 'verbose', opts.verbose);

    % ---- 5. held-out -------------------------------------------------------
    if opts.validate
        banner(opts, '5/5  held-out validation on the IDRiD TEST split');
        R.validation = validateLesionDetectors('split', 'test', 'save', true);
    else
        banner(opts, '5/5  held-out validation NOT run');
        fprintf(['  Everything above was chosen on TRAIN. Nothing has been\n' ...
                 '  measured on held-out data yet. When you are ready, run\n' ...
                 '  it ONCE and write the numbers down whatever they say:\n\n' ...
                 '      validateLesionDetectors(''split'', ''test'')\n\n' ...
                 '  If a channel fails, the answer is a better detector or an\n' ...
                 '  honest NOT VALIDATED row - not another pass through this\n' ...
                 '  script with the test numbers in mind.\n']);
        R.validation = 'not run';
    end

    R.elapsedMinutes = toc(tAll) / 60;

    % ---- 6. persist the run ------------------------------------------------
    % The generator-recall sweep in R.sweep is the ONLY record of why this
    % threshSD was chosen, and the run costs ~100 min. Returning it to a
    % variable that dies with the MATLAB process leaves the provenance of a
    % committed operating point in console scrollback - which is how the
    % haemorrhage recall ceilings from the 2026-09-12 rebuild were lost.
    % Save it beside every other measured artefact.
    R.savedTo = fullfile(cfg.resultsDir, 'dark_lesion_rebuild.mat');
    if ~isfolder(cfg.resultsDir), mkdir(cfg.resultsDir); end
    save(R.savedTo, 'R');

    if opts.verbose
        fprintf('\n  saved -> %s\n', R.savedTo);
        fprintf('  total %.1f min\n\n', R.elapsedMinutes);
    end
end


% ------------------------------------------------------------------ helpers

function [threshSD, reached] = pickThreshSD(sweep, channels, grid, target, verbose)
%PICKTHRESHSD  Largest shared threshold whose recall ceiling clears the target.

    ok = true(1, numel(grid));
    for ci = 1:numel(channels)
        T = sweep.(channels{ci});
        for g = 1:numel(grid)
            row = find(abs(T.threshSD - grid(g)) < 1e-9, 1);
            if isempty(row) || ~(T.recall(row) >= target)
                ok(g) = false;
            end
        end
    end

    reached = any(ok);
    if reached
        threshSD = max(grid(ok));
    else
        threshSD = min(grid);   % loosest tested; the ceiling is simply too low
    end

    if verbose
        fprintf('\n  recall ceiling target %.2f (gate is 0.10; this is the margin)\n', target);
        for ci = 1:numel(channels)
            T = sweep.(channels{ci});
            fprintf('    %-15s ceilings: %s\n', channels{ci}, ...
                strjoin(arrayfun(@(a,b) sprintf('%.2f->%.3f', a, b), ...
                    T.threshSD, T.recall, 'UniformOutput', false), '  '));
        end
        if reached
            fprintf('  chose threshSD %.2f - largest value where BOTH channels clear %.2f\n', ...
                threshSD, target);
        else
            fprintf(['  ** NO tested threshSD reaches %.2f on both channels. Using the\n' ...
                     '     loosest tested value %.2f. Final recall is capped below the\n' ...
                     '     target before stage 2 discards anything, so expect the recall\n' ...
                     '     gate to fail. More annotated data or a different generator is\n' ...
                     '     the fix; a lower gate is not. **\n'], target, threshSD);
        end
    end
end


function banner(opts, msg)
    if ~opts.verbose, return; end
    fprintf('\n  ==========================================================\n');
    fprintf('  %s\n', msg);
    fprintf('  ==========================================================\n');
end
