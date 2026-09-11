function [trainT, valT] = loadAptosSplit(opts)
%LOADAPTOSSPLIT  Stratified, COMMITTED train/validation split of APTOS 2019.
%
%   [trainT, valT] = LOADAPTOSSPLIT() returns tables with imageName,
%   imagePath and diagnosis (0-4).
%
%   [trainT, valT] = LOADAPTOSSPLIT(valFraction=0.2, subsetFraction=1.0, ...
%                                   seed=0, rebuild=false)
%
%   Why the split is written to disk
%   --------------------------------
%   config/aptos_split.json is generated once and then REUSED. Every later
%   run - every model, every ablation, and Phase 6's integrated-vs-baseline
%   comparison - reads the same file. Without that, two models are scored on
%   different validation sets and a "better" result may just be a luckier
%   split. The comparison the project is judged on requires them to be
%   identical, so the split is data, not a runtime decision.
%
%   Stratified by grade, because grade 3 is only 5.3% of the set (193 images)
%   and a naive random split can leave the validation set with too few to
%   estimate anything.
%
%   APTOS's own 1928-image test set has no public labels and is never used.
%   Messidor-2 is never touched.
%
%   See also TRAINBASELINEGRADER.

    arguments
        opts.valFraction (1,1) double {mustBeInRange(opts.valFraction,0.05,0.5)} = 0.2
        opts.subsetFraction (1,1) double {mustBeInRange(opts.subsetFraction,0.01,1)} = 1.0
        opts.seed (1,1) double = 0
        opts.rebuild (1,1) logical = false
    end

    cfg = drishti_paths();
    splitFile = fullfile(cfg.projectRoot, 'config', 'aptos_split.json');

    labels = readtable(cfg.aptos.trainLabels);
    allNames = string(labels.id_code);
    allGrades = double(labels.diagnosis);

    if isfile(splitFile) && ~opts.rebuild
        S = jsondecode(fileread(splitFile));
        trainNames = string(S.train);
        valNames = string(S.val);
    else
        rng(opts.seed);
        trainNames = strings(0,1);
        valNames = strings(0,1);
        for g = 0:4
            idx = find(allGrades == g);
            idx = idx(randperm(numel(idx)));
            nVal = max(1, round(opts.valFraction * numel(idx)));
            valNames = [valNames; allNames(idx(1:nVal))];        %#ok<AGROW>
            trainNames = [trainNames; allNames(idx(nVal+1:end))]; %#ok<AGROW>
        end
        S = struct();
        S.x_comment = ['Committed stratified split of the 3662 labelled APTOS ' ...
            'training images. Reused by every run so models are comparable. ' ...
            'Do not regenerate without a very good reason - it invalidates ' ...
            'comparison against any result produced before the change.'];
        S.x_created = string(datetime('now'));
        S.x_seed = opts.seed;
        S.x_valFraction = opts.valFraction;
        S.train = cellstr(trainNames);
        S.val = cellstr(valNames);
        fid = fopen(splitFile, 'w');
        fprintf(fid, '%s', jsonencode(S, 'PrettyPrint', true));
        fclose(fid);
        fprintf('  committed new split -> config/aptos_split.json\n');
    end

    trainT = buildTable(trainNames, allNames, allGrades, cfg);
    valT   = buildTable(valNames,   allNames, allGrades, cfg);

    % Subsetting is for smoke tests only - it keeps the stratification but
    % shrinks both sides, so a fast run exercises the same code path.
    if opts.subsetFraction < 1
        trainT = stratifiedSubset(trainT, opts.subsetFraction, opts.seed);
        valT   = stratifiedSubset(valT,   opts.subsetFraction, opts.seed);
    end
end


function T = buildTable(names, allNames, allGrades, cfg)
    [tf, loc] = ismember(names, allNames);
    names = names(tf);
    grades = allGrades(loc(tf));
    paths = strings(numel(names), 1);
    for k = 1:numel(names)
        paths(k) = string(fullfile(cfg.aptos.trainImages, char(names(k) + ".png")));
    end
    T = table(names, paths, grades, ...
        'VariableNames', {'imageName', 'imagePath', 'diagnosis'});
end


function T = stratifiedSubset(T, frac, seed)
    rng(seed);
    keep = false(height(T), 1);
    for g = 0:4
        idx = find(T.diagnosis == g);
        n = max(1, round(frac * numel(idx)));
        sel = idx(randperm(numel(idx), min(n, numel(idx))));
        keep(sel) = true;
    end
    T = T(keep, :);
end
