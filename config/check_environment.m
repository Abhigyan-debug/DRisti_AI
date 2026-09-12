function [ok, report] = check_environment()
%CHECK_ENVIRONMENT  Verify MATLAB version, toolboxes and datasets for DRishti-AI.
%
%   [ok, report] = CHECK_ENVIRONMENT() prints a readiness report and returns
%   ok = true only if every REQUIRED toolbox is installed and licensed, and
%   every dataset path resolves.
%
%   report is a table with one row per check.
%
%   Run this before starting work on any phase, and after installing toolboxes.
%
%   See also SETUP_DRISHTI, DRISHTI_PATHS.

    % name, licence feature, required/optional, first phase that needs it,
    % and a PROBE: a toolbox folder under matlabroot whose absence proves the
    % product is not actually installed.
    %
    % The probe exists because licence checks are not evidence of installation.
    % SimEvents on this machine reports ver() = 26.1 AND passes both
    % license('test') and license('checkout'), while toolbox/simevents does not
    % exist on disk - so this function printed a green [ok] for a product whose
    % every block path fails to resolve. Phase 5's model builder took the
    % SimEvents branch on the strength of that [ok] and crashed. A readiness
    % check that reports ready for something unusable is worse than no check.
    specs = {
        'Image Processing Toolbox',              'image_toolbox',        true,  'Phase 1', 'images'
        'Computer Vision Toolbox',               'video_and_image_blockset', true,  'Phase 2', 'vision'
        'Deep Learning Toolbox',                 'neural_network_toolbox', true,  'Phase 2', 'nnet'
        'Statistics and Machine Learning Toolbox','statistics_toolbox',  true,  'Phase 3', 'stats'
        'Simulink',                              'simulink',             true,  'Phase 5', 'simulink'
        'Medical Imaging Toolbox',               'medical_imaging_toolbox', false, 'Phase 2 (optional)', 'medical'
        'Parallel Computing Toolbox',            'distrib_computing_toolbox', false, 'Phase 3 (GPU training)', 'parallel'
        'SimEvents',                             'simevents',            false, 'Phase 5 (queuing blocks)', 'simevents'
    };

    name    = strings(0, 1);
    status  = strings(0, 1);
    needed  = strings(0, 1);
    phase   = strings(0, 1);

    fprintf('  Toolboxes:\n');

    allRequiredOk = true;
    for k = 1:size(specs, 1)
        tbName  = specs{k, 1};
        feature = specs{k, 2};
        isReq   = specs{k, 3};
        tbPhase = specs{k, 4};

        probeDir = '';
        if size(specs, 2) >= 5, probeDir = specs{k, 5}; end

        installed = license('test', feature) == 1;
        if installed
            % license('test') can pass for an uninstalled product; confirm we
            % can actually check one out.
            [checkedOut, ~] = license('checkout', feature);
            if checkedOut
                st = "ok";
            else
                st = "no license";
            end
        else
            st = "MISSING";
        end

        % Licensed is not installed. Verify the product is actually on disk.
        if st == "ok" && ~isempty(probeDir) && ...
                ~isfolder(fullfile(matlabroot, 'toolbox', probeDir))
            st = "NOT INSTALLED";
        end

        if isReq && st ~= "ok"
            allRequiredOk = false;
        end

        if isReq
            req = "required";
        else
            req = "optional";
        end

        switch st
            case "ok",         mark = 'ok     ';
            case "no license", mark = 'LICENCE';
            case "NOT INSTALLED", mark = 'NOT INST';
            otherwise,         mark = 'MISSING';
        end
        fprintf('    [%s] %-42s %-8s  %s\n', mark, tbName, req, tbPhase);

        name(end+1, 1)   = string(tbName);   %#ok<AGROW>
        status(end+1, 1) = st;               %#ok<AGROW>
        needed(end+1, 1) = req;              %#ok<AGROW>
        phase(end+1, 1)  = string(tbPhase);  %#ok<AGROW>
    end

    % --- MATLAB release --------------------------------------------------
    rel = version('-release');            % e.g. '2026a'
    relYear = str2double(rel(1:4));
    fprintf('\n  MATLAB release: %s\n', rel);

    % --- GPU -------------------------------------------------------------
    % Compute capability matters, not just "is there an NVIDIA card".
    % MATLAB's supported range is release-dependent:
    %     R2025b and earlier : compute capability 5.0 - 9.x
    %     R2026a and later   : compute capability 5.0 - 12.x
    % An RTX 50-series (Blackwell) card reports 12.0, so on R2025b or older
    % it is simply not usable - training silently falls back to CPU. See
    % docs/matlab_install.md.
    BLACKWELL_MIN_RELEASE = 2026;

    if ~license('test', 'distrib_computing_toolbox')
        fprintf(['  GPU: Parallel Computing Toolbox not available - ' ...
                 'Phase 3 will train on CPU.\n']);
    else
        try
            nGPU = gpuDeviceCount('available');
        catch
            nGPU = 0;
        end

        if nGPU < 1
            % gpuDeviceCount returns 0 both for "no card" and for "card
            % present but unsupported by this release" - distinguish them,
            % because the fix is completely different.
            unsupported = false;
            try
                t = gpuDeviceTable;   % lists devices even when unsupported
                if ~isempty(t)
                    unsupported = true;
                    fprintf('  GPU: %d device(s) present but NOT usable by MATLAB %s:\n', ...
                        height(t), rel);
                    disp(t);
                end
            catch
                % gpuDeviceTable unavailable on older releases; fall through
            end

            if unsupported
                fprintf(['\n  >> Likely cause: this release supports compute capability\n' ...
                         '     5.0-9.x only. RTX 50-series (Blackwell) cards report 12.0\n' ...
                         '     and need R2026a or newer. Upgrading the release fixes this;\n' ...
                         '     a driver update will not. See docs/matlab_install.md.\n']);
            else
                fprintf('  GPU: none detected - Phase 3 training will be slow on CPU.\n');
            end
        else
            g = gpuDevice;
            cc = str2double(g.ComputeCapability);
            fprintf('  GPU: %s (%.1f GB, compute capability %s)\n', ...
                g.Name, g.TotalMemory / 1e9, g.ComputeCapability);

            if cc >= 10 && relYear < BLACKWELL_MIN_RELEASE
                fprintf(['  >> WARNING: compute capability %s on MATLAB %s. ' ...
                         'Expect trouble;\n     R2026a+ is required for 10.x-12.x ' ...
                         'devices.\n'], g.ComputeCapability, rel);
            end
            if g.TotalMemory / 1e9 < 6
                fprintf(['  >> Note: under 6 GB of VRAM. Phase 3 will need small ' ...
                         'batch sizes\n     at 512px+ input, or gradient accumulation.\n']);
            end
        end
    end

    % --- Datasets ---------------------------------------------------------
    cfg = drishti_paths();
    dsNames = fieldnames(cfg.datasets);
    missingData = false;
    for k = 1:numel(dsNames)
        p = cfg.datasets.(dsNames{k});
        present = isfolder(p);
        if ~present
            missingData = true;
        end
        name(end+1, 1)   = "dataset: " + string(dsNames{k}); %#ok<AGROW>
        if present
            status(end+1, 1) = "ok";       %#ok<AGROW>
        else
            status(end+1, 1) = "MISSING";  %#ok<AGROW>
        end
        needed(end+1, 1) = "required";     %#ok<AGROW>
        phase(end+1, 1)  = "Phase 0";      %#ok<AGROW>
    end

    ok = allRequiredOk && ~missingData;
    report = table(name, status, needed, phase);

    fprintf('\n');
    if ok
        fprintf('  READY - all required toolboxes and datasets present.\n');
    else
        fprintf('  NOT READY - see MISSING entries above.\n');
        fprintf('  Toolbox install: Home > Add-Ons > Get Add-Ons.\n');
        fprintf('  Datasets: see docs/datasets.md.\n');
    end
end
