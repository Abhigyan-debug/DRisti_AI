function tests = test_project_setup()
%TEST_PROJECT_SETUP  Phase 0 smoke tests - is this machine ready to work?
%
%   Run with:   runtests('tests/test_project_setup.m')
%   or:         results = runtests('test_project_setup'); disp(results);
%
%   Verifies the dataset layout against config/dataset_layout.json - the same
%   contract tools/verify_setup.py checks, so the MATLAB and Python sides of the
%   project cannot drift apart.
%
%   See also SETUP_DRISHTI, CHECK_ENVIRONMENT, DRISHTI_PATHS.

    tests = functiontests(localfunctions);
end


function setupOnce(testCase)
    here = fileparts(mfilename('fullpath'));
    projectRoot = fileparts(here);
    addpath(fullfile(projectRoot, 'config'));

    cfg = drishti_paths();
    testCase.TestData.cfg = cfg;

    layoutFile = fullfile(projectRoot, 'config', 'dataset_layout.json');
    testCase.TestData.layout = jsondecode(fileread(layoutFile));
end


function test_dataRootExists(testCase)
    cfg = testCase.TestData.cfg;
    verifyTrue(testCase, isfolder(cfg.dataRoot), ...
        sprintf(['Data root not found: %s\n' ...
                 'Resolved from: %s\n' ...
                 'Set DRISHTI_DATA_ROOT or edit config/local_paths.json. ' ...
                 'See docs/datasets.md.'], cfg.dataRoot, cfg.dataRootSource));
end


function test_datasetDirectoryCounts(testCase)
    % Every directory in the shared layout contract must exist with the
    % expected number of files.
    cfg    = testCase.TestData.cfg;
    dirs   = testCase.TestData.layout.directories;
    failures = strings(0, 1);

    for k = 1:numel(dirs)
        spec = dirs(k);
        if iscell(dirs), spec = dirs{k}; end
        p = fullfile(cfg.dataRoot, spec.path);

        if ~isfolder(p)
            failures(end+1, 1) = "MISSING  " + string(spec.path); %#ok<AGROW>
            continue
        end

        listing = dir(p);
        n = sum(~[listing.isdir]);
        if isfield(spec, 'count') && n ~= spec.count
            failures(end+1, 1) = sprintf("COUNT    %s: %d files, expected %d", ...
                spec.path, n, spec.count); %#ok<AGROW>
        end
    end

    verifyEmpty(testCase, failures, ...
        sprintf('Dataset layout problems:\n  %s\n\nRe-run: python tools/organize_datasets.py', ...
                strjoin(cellstr(failures), sprintf('\n  '))));
end


function test_labelFilesReadable(testCase)
    % The label files must not merely exist - they must parse, with the
    % columns the pipeline depends on.
    cfg = testCase.TestData.cfg;

    % APTOS: id_code + diagnosis in 0..4
    aptos = readtable(cfg.aptos.trainLabels);
    verifyTrue(testCase, all(ismember({'id_code', 'diagnosis'}, aptos.Properties.VariableNames)), ...
        'APTOS train.csv is missing id_code/diagnosis columns.');
    verifyEqual(testCase, height(aptos), 3662, 'APTOS train.csv should have 3662 rows.');
    verifyTrue(testCase, all(aptos.diagnosis >= 0 & aptos.diagnosis <= 4), ...
        'APTOS diagnosis values must lie on the ICDR 0-4 scale.');

    % IDRiD grading: 413 train rows, grades on the same scale
    idridFile = fullfile(cfg.idrid.gradeLabels, ...
        'a. IDRiD_Disease Grading_Training Labels.csv');
    idrid = readtable(idridFile);
    idrid = idrid(~ismissing(idrid{:, 2}), :);   % trailing blank rows
    verifyEqual(testCase, height(idrid), 413, 'IDRiD grading train should have 413 rows.');
end


function test_imageLoadsFromEachDataset(testCase)
    % One real image read per corpus - catches a truncated extraction that
    % file counts alone would miss.
    cfg = testCase.TestData.cfg;

    sources = { ...
        'APTOS',     cfg.aptos.trainImages; ...
        'IDRiD',     cfg.idrid.gradeTrainImages; ...
        'DRIVE',     cfg.drive.trainImages; ...
        'Messidor2', cfg.messidor2.images};

    for k = 1:size(sources, 1)
        name = sources{k, 1};
        folder = sources{k, 2};
        listing = dir(folder);
        listing = listing(~[listing.isdir]);
        verifyNotEmpty(testCase, listing, sprintf('%s: no images found in %s', name, folder));

        img = imread(fullfile(folder, listing(1).name));
        verifyGreaterThan(testCase, size(img, 1), 100, ...
            sprintf('%s: image looks too small to be a fundus photo.', name));
        verifyEqual(testCase, ndims(img), 3, ...
            sprintf('%s: expected an RGB fundus image.', name));
    end
end


function test_knownGapsStillDocumented(testCase)
    % If a known gap has been filled, this test fails on purpose - so that
    % config/dataset_layout.json and docs/datasets.md get updated.
    cfg  = testCase.TestData.cfg;
    gaps = testCase.TestData.layout.known_missing;

    for k = 1:numel(gaps)
        gap = gaps(k);
        if iscell(gaps), gap = gaps{k}; end
        p = fullfile(cfg.dataRoot, gap.path);
        verifyFalse(testCase, isfolder(p) || isfile(p), ...
            sprintf(['"%s" now exists - the gap is resolved.\n' ...
                     'Remove it from config/dataset_layout.json known_missing ' ...
                     'and update docs/datasets.md.'], gap.path));
    end
end
