function R = ablateCandidatePatchGeometry(opts)
%ABLATECANDIDATEPATCHGEOMETRY  Does patch resolution or threshSD explain the collapse?
%
%   R = ABLATECANDIDATEPATCHGEOMETRY() runs a 2x2 on the TRAIN/VAL side only:
%
%       A  fullRes      patches, threshSD 1.0
%       B  workingScale patches, threshSD 1.0
%       C  fullRes      patches, threshSD 1.5
%       D  workingScale patches, threshSD 1.5
%
%   and reports patch-level held-out AUC per cell, per channel.
%
%   WHY THIS EXISTS
%   ---------------
%   The rebuilt microaneurysm stage-2 classifier scored AUC 0.5056 - chance -
%   against a historical 0.694 recorded in TRAINCANDIDATECLASSIFIER's help. Two
%   things changed at once between those numbers:
%
%     * patch resolution. Training patches used to be cut from the
%       full-resolution frame and are now cut at working scale (FOV normalised
%       to 1536 px, so ~0.45x on IDRiD). A microaneurysm went from roughly 34 px
%       across inside a 48 px patch to roughly 16 px. MA discrimination lives in
%       fine texture, and that resampling may simply destroy it.
%
%     * candidate threshold. threshSD moved 1.5 -> 1.0, which nearly doubles the
%       candidate pool and fills it with harder, more marginal negatives.
%
%   One number cannot attribute a regression to one of two simultaneous changes.
%   This separates them. Nothing here is a fix; it is the measurement that says
%   which fix is worth making.
%
%   WHAT IS AND IS NOT COMPARABLE
%   -----------------------------
%   Within a threshSD column, the two geometries see the SAME candidates and the
%   same labels, so the AUC difference is attributable to patch resolution alone.
%   That is the clean comparison.
%
%   Across threshSD rows it is murkier and must not be over-read: changing the
%   generator threshold changes the negative distribution itself, so a lower AUC
%   at 1.0 may mean "the classifier got worse" OR "the negatives got harder"
%   while the detector as a whole improved. Generator recall rises from 0.235 to
%   0.382 for microaneurysms over that same move, and recall is half the display
%   gate. AUC alone cannot rank the two thresholds; it can only say whether the
%   classifier is learning anything at all in each.
%
%   THE SPLIT IS HELD FIXED
%   -----------------------
%   Every cell uses seed 0 and the same 54 underlying images, so
%   TRAINCANDIDATECLASSIFIER draws the same 40 train / 14 val image split in all
%   four. The cells differ only in the variables under test.
%
%   THE TEST SPLIT IS NOT TOUCHED
%   -----------------------------
%   Every number here comes from the classifier's own held-out IMAGES inside the
%   IDRiD segmentation TRAIN split. VALIDATELESIONDETECTORS and the IDRiD test
%   split are not involved, and must not be run until one configuration has been
%   frozen on the strength of this table.
%
%   MODELS ARE WRITTEN ASIDE
%   ------------------------
%   Each cell saves to models/ablation/, never to
%   models/candidate_classifier_<lesion>.mat. The shipped models are not
%   disturbed by running this.
%
%   See also BUILDCANDIDATEDATASET, TRAINCANDIDATECLASSIFIER,
%   CUTCANDIDATEPATCHES, REBUILDDARKLESIONDETECTORS.

    arguments
        opts.threshSDs (1,:) double = [1.0 1.5]
        opts.geometries (1,:) cell = {'fullRes', 'workingScale'}
        opts.channels (1,:) cell = {'microaneurysms', 'haemorrhages'}
        opts.patchPx (1,1) double = 48
        opts.limit (1,1) double = Inf
        opts.seed (1,1) double = 0
        opts.rebuildDatasets (1,1) logical = true
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    outDir = fullfile(cfg.modelsDir, 'ablation');
    if ~isfolder(outDir), mkdir(outDir); end

    R = struct();
    R.startedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm'));
    R.protocol = ['Patch-level AUC on the classifier''s own held-out IMAGES ' ...
                  'within the IDRiD segmentation TRAIN split. Seed 0, identical ' ...
                  '40/14 image split in every cell. The IDRiD TEST split is not touched.'];
    R.cells = struct([]);
    tAll = tic;

    % ---- 1. datasets: one per (geometry, threshSD, channel) ----------------
    if opts.rebuildDatasets
        for g = 1:numel(opts.geometries)
            for t = 1:numel(opts.threshSDs)
                for c = 1:numel(opts.channels)
                    banner(opts, sprintf('build  %-12s threshSD %.2f  %s', ...
                        opts.geometries{g}, opts.threshSDs(t), opts.channels{c}));
                    buildCandidateDataset( ...
                        'lesion', opts.channels{c}, ...
                        'threshSD', opts.threshSDs(t), ...
                        'patchGeometry', opts.geometries{g}, ...
                        'patchPx', opts.patchPx, ...
                        'limit', opts.limit, ...
                        'verbose', opts.verbose);
                end
            end
        end
    end

    % ---- 2. train one classifier per cell ----------------------------------
    n = 0;
    for g = 1:numel(opts.geometries)
        for t = 1:numel(opts.threshSDs)
            for c = 1:numel(opts.channels)
                geom = opts.geometries{g};
                thr  = opts.threshSDs(t);
                ch   = opts.channels{c};
                other = opts.channels(~strcmp(opts.channels, ch));

                banner(opts, sprintf('train  %-12s threshSD %.2f  %s', geom, thr, ch));
                tag = sprintf('%s_%s_t%s', ch, geom, ...
                    strrep(sprintf('%.2f', thr), '.', ''));
                outFile = fullfile(outDir, ['candidate_classifier_' tag '.mat']);

                T = trainCandidateClassifier( ...
                    'lesion', ch, 'pool', other, 'threshSD', thr, ...
                    'patchGeometry', geom, 'inputPx', opts.patchPx, ...
                    'seed', opts.seed, 'outFile', outFile);

                n = n + 1;
                R.cells(n).geometry = geom;
                R.cells(n).threshSD = thr;
                R.cells(n).channel = ch;
                R.cells(n).auc = T.auc;
                R.cells(n).nValPatches = T.nValPatches;
                R.cells(n).nValPositives = T.nValPositives;
                R.cells(n).sweep = T.sweep;
                R.cells(n).modelFile = outFile;
            end
        end
    end

    R.elapsedMinutes = toc(tAll) / 60;
    R.table = buildTable(R.cells);

    if ~isfolder(cfg.resultsDir), mkdir(cfg.resultsDir); end
    save(fullfile(cfg.resultsDir, 'patch_geometry_ablation.mat'), 'R');
    R.savedTo = fullfile(cfg.resultsDir, 'patch_geometry_ablation.mat');

    if opts.verbose, printReport(R, opts); end
end


% ------------------------------------------------------------------ helpers

function T = buildTable(cells)
    T = table({cells.geometry}', [cells.threshSD]', {cells.channel}', ...
        [cells.auc]', [cells.nValPatches]', [cells.nValPositives]', ...
        'VariableNames', {'geometry','threshSD','channel','auc', ...
                          'valPatches','valPositives'});
    T = sortrows(T, {'channel','threshSD','geometry'});
end


function printReport(R, opts)
    fprintf('\n  ======================================================\n');
    fprintf('  PATCH GEOMETRY x THRESHSD ABLATION\n');
    fprintf('  %s\n', R.protocol);
    fprintf('  ======================================================\n\n');
    disp(R.table);

    for c = 1:numel(opts.channels)
        ch = opts.channels{c};
        fprintf('\n  %s - AUC grid (rows threshSD, cols geometry)\n', ch);
        fprintf('    %-10s', '');
        for g = 1:numel(opts.geometries), fprintf('%14s', opts.geometries{g}); end
        fprintf('\n');
        for t = 1:numel(opts.threshSDs)
            fprintf('    %-10.2f', opts.threshSDs(t));
            for g = 1:numel(opts.geometries)
                a = pick(R.cells, ch, opts.threshSDs(t), opts.geometries{g});
                if isnan(a), fprintf('%14s', '-'); else, fprintf('%14.4f', a); end
            end
            fprintf('\n');
        end
    end

    fprintf(['\n  Read the GEOMETRY comparison within a threshSD row: same\n' ...
             '  candidates, same labels, so the difference is resolution alone.\n' ...
             '  Do NOT rank thresholds on AUC - a different threshSD is a\n' ...
             '  different negative distribution, and it also moves generator\n' ...
             '  recall, which AUC cannot see.\n']);
    fprintf('\n  0.5 is chance. A cell near 0.5 means that configuration learns nothing.\n');
    fprintf('  %.1f min\n\n', R.elapsedMinutes);
end


function a = pick(cells, ch, thr, geom)
    a = NaN;
    for i = 1:numel(cells)
        if strcmp(cells(i).channel, ch) && abs(cells(i).threshSD - thr) < 1e-9 ...
                && strcmp(cells(i).geometry, geom)
            a = cells(i).auc; return
        end
    end
end


function banner(opts, msg)
    if ~opts.verbose, return; end
    fprintf('\n  ----------------------------------------------------------\n');
    fprintf('  %s\n', msg);
    fprintf('  ----------------------------------------------------------\n');
end
