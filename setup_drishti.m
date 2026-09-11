function cfg = setup_drishti()
%SETUP_DRISHTI  Initialise the DRishti-AI project in the current MATLAB session.
%
%   Run this once at the start of every session (or let startup.m do it):
%
%       >> cfg = setup_drishti();
%
%   It adds the project source tree to the MATLAB path, resolves where the
%   datasets live on this particular machine, and reports whether the required
%   toolboxes are installed. Returns the project config struct (see
%   CONFIG/DRISHTI_PATHS).
%
%   See also DRISHTI_PATHS, CHECK_ENVIRONMENT.

    projectRoot = fileparts(mfilename('fullpath'));

    % --- MATLAB path -----------------------------------------------------
    addpath(genpath(fullfile(projectRoot, 'src')));
    addpath(fullfile(projectRoot, 'config'));
    addpath(fullfile(projectRoot, 'tests'));

    % --- Paths -----------------------------------------------------------
    cfg = drishti_paths();

    fprintf('\n=== DRishti-AI ===\n');
    fprintf('  project root : %s\n', cfg.projectRoot);
    fprintf('  data root    : %s', cfg.dataRoot);
    if isfolder(cfg.dataRoot)
        fprintf('  [found]\n');
    else
        fprintf('  [MISSING]\n');
        fprintf(['\n  Datasets not found. Either set the DRISHTI_DATA_ROOT environment\n' ...
                 '  variable, or copy config/local_paths.example.json to\n' ...
                 '  config/local_paths.json and edit the dataRoot field.\n']);
    end

    % --- Per-dataset presence -------------------------------------------
    names = fieldnames(cfg.datasets);
    fprintf('\n  Datasets:\n');
    for k = 1:numel(names)
        p = cfg.datasets.(names{k});
        if isfolder(p)
            mark = 'ok     ';
        else
            mark = 'MISSING';
        end
        fprintf('    [%s] %-10s %s\n', mark, names{k}, p);
    end

    % --- Toolboxes -------------------------------------------------------
    fprintf('\n');
    check_environment();
    fprintf('\n');
end
