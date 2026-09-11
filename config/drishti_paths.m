function cfg = drishti_paths()
%DRISHTI_PATHS  Resolve every path the DRishti-AI pipeline needs.
%
%   cfg = DRISHTI_PATHS() returns a struct with the project root, the dataset
%   root for THIS machine, and a .datasets sub-struct pointing at each corpus.
%
%   The dataset root is resolved in priority order:
%     1. the DRISHTI_DATA_ROOT environment variable
%     2. config/local_paths.json  (git-ignored, one per teammate)
%     3. <projectRoot>/data       (the default, possibly a junction/symlink)
%
%   Datasets are never committed to git, so every teammate points at their own
%   copy without touching tracked files.
%
%   See also SETUP_DRISHTI.

    projectRoot = fileparts(fileparts(mfilename('fullpath')));

    % ---- 1. environment variable ---------------------------------------
    dataRoot = getenv('DRISHTI_DATA_ROOT');
    source   = 'DRISHTI_DATA_ROOT env var';

    % ---- 2. local_paths.json -------------------------------------------
    if isempty(dataRoot)
        localFile = fullfile(projectRoot, 'config', 'local_paths.json');
        if isfile(localFile)
            try
                local = jsondecode(fileread(localFile));
                if isfield(local, 'dataRoot') && ~isempty(local.dataRoot)
                    dataRoot = local.dataRoot;
                    source   = 'config/local_paths.json';
                end
            catch err
                warning('drishti:badLocalPaths', ...
                    'Could not parse %s: %s', localFile, err.message);
            end
        end
    end

    % ---- 3. default ------------------------------------------------------
    if isempty(dataRoot)
        dataRoot = fullfile(projectRoot, 'data');
        source   = 'default <projectRoot>/data';
    end

    cfg = struct();
    cfg.projectRoot   = projectRoot;
    cfg.dataRoot      = dataRoot;
    cfg.dataRootSource = source;

    % ---- project output directories -------------------------------------
    cfg.modelsDir  = fullfile(projectRoot, 'models');
    cfg.resultsDir = fullfile(projectRoot, 'results');
    cfg.reportsDir = fullfile(projectRoot, 'reports');
    cfg.docsDir    = fullfile(projectRoot, 'docs');
    cfg.simulinkDir = fullfile(projectRoot, 'simulink');

    % ---- dataset roots ---------------------------------------------------
    cfg.datasets = struct( ...
        'aptos2019', fullfile(dataRoot, 'aptos2019'), ...
        'idrid',     fullfile(dataRoot, 'idrid'), ...
        'drive',     fullfile(dataRoot, 'drive'), ...
        'messidor2', fullfile(dataRoot, 'messidor2'));

    % ---- frequently-used sub-paths --------------------------------------
    % APTOS 2019 - ICDR grades 0-4, used for grading train/val (Phase 3).
    cfg.aptos = struct( ...
        'trainImages', fullfile(cfg.datasets.aptos2019, 'train_images'), ...
        'testImages',  fullfile(cfg.datasets.aptos2019, 'test_images'), ...
        'trainLabels', fullfile(cfg.datasets.aptos2019, 'train.csv'), ...
        'testList',    fullfile(cfg.datasets.aptos2019, 'test.csv'));

    % IDRiD - lesion masks (A), grades (B), disc/fovea coords (C). Phases 2-3.
    idrid = cfg.datasets.idrid;
    cfg.idrid = struct( ...
        'segTrainImages',  fullfile(idrid, 'segmentation', '1. Original Images', 'a. Training Set'), ...
        'segTestImages',   fullfile(idrid, 'segmentation', '1. Original Images', 'b. Testing Set'), ...
        'segTrainMasks',   fullfile(idrid, 'segmentation', '2. All Segmentation Groundtruths', 'a. Training Set'), ...
        'segTestMasks',    fullfile(idrid, 'segmentation', '2. All Segmentation Groundtruths', 'b. Testing Set'), ...
        'gradeTrainImages', fullfile(idrid, 'grading', '1. Original Images', 'a. Training Set'), ...
        'gradeTestImages',  fullfile(idrid, 'grading', '1. Original Images', 'b. Testing Set'), ...
        'gradeLabels',      fullfile(idrid, 'grading', '2. Groundtruths'), ...
        'locTrainImages',   fullfile(idrid, 'localization', '1. Original Images', 'a. Training Set'), ...
        'locTestImages',    fullfile(idrid, 'localization', '1. Original Images', 'b. Testing Set'), ...
        'locLabels',        fullfile(idrid, 'localization', '2. Groundtruths'));

    % DRIVE - vessel segmentation ground truth. Phase 2.
    cfg.drive = struct( ...
        'trainImages', fullfile(cfg.datasets.drive, 'training', 'images'), ...
        'trainVessels', fullfile(cfg.datasets.drive, 'training', '1st_manual'), ...
        'trainMasks',  fullfile(cfg.datasets.drive, 'training', 'mask'), ...
        'testImages',  fullfile(cfg.datasets.drive, 'test', 'images'), ...
        'testVessels', fullfile(cfg.datasets.drive, 'test', '1st_manual'), ...
        'testMasks',   fullfile(cfg.datasets.drive, 'test', 'mask'));

    % Messidor-2 - held out entirely for final external validation (Phase 6).
    cfg.messidor2 = struct( ...
        'images',   fullfile(cfg.datasets.messidor2, 'IMAGES'), ...
        'pairings', fullfile(cfg.datasets.messidor2, 'messidor-2.csv'));

    % ---- clinical constants ---------------------------------------------
    % ICDR severity scale; referable DR (the screening decision) is grade >= 2.
    cfg.icdr = struct( ...
        'labels', {{'0 - No DR', '1 - Mild NPDR', '2 - Moderate NPDR', ...
                    '3 - Severe NPDR', '4 - Proliferative DR'}}, ...
        'referableThreshold', 2);

    % Phase 0 target operating point (see docs/literature_benchmarks.md).
    cfg.targets = struct('sensitivity', 0.90, 'specificity', 0.85);
end
