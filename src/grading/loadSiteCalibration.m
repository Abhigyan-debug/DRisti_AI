function C = loadSiteCalibration(opts)
%LOADSITECALIBRATION  The saved site operating point, if this machine has one.
%
%   C = LOADSITECALIBRATION() returns the site-calibration artifact saved by
%   BUILDSITECALIBRATION, or an EMPTY STRUCT when this machine has none.
%
%   C = LOADSITECALIBRATION(file='models/site_calibration_mathura.mat')
%
%   Resolution order, first hit wins:
%     1. an explicit `file`
%     2. $DRISHTI_SITE_CALIBRATION
%     3. models/site_calibration.mat
%
%   WHY AN ABSENT FILE IS NOT AN ERROR
%   ----------------------------------
%   No calibration is the DEFAULT state, not a broken one, and it is already
%   loud: RUNDRISHTISYSTEM warns, the dashboard shows a red UNCALIBRATED chip,
%   and the report carries the uncalibrated caveat above the result. A missing
%   artifact must therefore leave the system in that state rather than stop it
%   - a rural site with no local labels still needs to be able to screen.
%
%   A MALFORMED ARTIFACT IS REFUSED, NOT PATCHED
%   --------------------------------------------
%   The failure that matters is not an absent file, it is a file that loads,
%   looks plausible, and silently shifts the operating point. So an artifact
%   is used only if it carries `meta.artifactVersion` in ACCEPTED_VERSION and
%   every field the pipeline actually reads. Anything else warns by name and
%   drops to uncalibrated - the same fail-closed discipline as
%   LOADCANDIDATECLASSIFIERS and LOADLESIONRELIABILITY.
%
%   In particular a bare struct from FITSITECALIBRATION is REFUSED here: it
%   has a, b and thresholdRaw, so it would work, but it carries no record of
%   which site or which grader it belongs to. An operating point with no
%   provenance is exactly what the 31.2%% failure was made of.
%
%   THE ARTIFACT IS SITE-SPECIFIC AND SAYS SO
%   -----------------------------------------
%   C.meta.site names the camera the threshold was fitted for. It is surfaced
%   to the operator rather than checked in code, because nothing here can tell
%   which camera took the photograph on screen - only the person running it
%   can. Screening camera B through camera A's calibration is not calibrated,
%   it is miscalibrated with a green chip on it.
%
%   See also BUILDSITECALIBRATION, FITSITECALIBRATION, RUNDRISHTIPIPELINE.

    arguments
        opts.file (1,:) char = ''
        opts.verbose (1,1) logical = true
    end

    persistent cached cachedStamp

    % Bump when the artifact's shape changes; every older artifact is then
    % refused instead of being read with fields that no longer mean the same.
    ACCEPTED_VERSION = {'siteCalibration/v1'};

    f = resolveFile(opts.file);
    C = struct();
    if isempty(f) || ~isfile(f)
        return
    end

    d = dir(f);
    stamp = sprintf('%s|%.6f|%d', f, d.datenum, d.bytes);
    if ~isempty(cachedStamp) && strcmp(stamp, cachedStamp)
        C = cached;
        return
    end

    try
        L = load(f);
    catch ME
        warnRefused(opts, f, sprintf('it could not be read (%s)', ME.message));
        return
    end

    A = pickArtifact(L);
    if isempty(fieldnames(A))
        warnRefused(opts, f, 'it contains no site-calibration struct');
        return
    end

    missing = setdiff({'a','b','thresholdRaw','n'}, fieldnames(A));
    if ~isempty(missing)
        warnRefused(opts, f, sprintf('it is missing required field(s): %s', ...
            strjoin(missing, ', ')));
        return
    end

    if ~isfield(A, 'meta') || ~isfield(A.meta, 'artifactVersion') || ...
            ~any(strcmp(char(A.meta.artifactVersion), ACCEPTED_VERSION))
        warnRefused(opts, f, ['it carries no recognised meta.artifactVersion ' ...
            'stamp, so there is no record of which site or which grader its ' ...
            'operating point belongs to']);
        return
    end

    C = A;
    cached = C;
    cachedStamp = stamp;
end


% ------------------------------------------------------------------ helpers

function f = resolveFile(explicit)
    if ~isempty(explicit)
        f = explicit;
        return
    end
    env = getenv('DRISHTI_SITE_CALIBRATION');
    if ~isempty(env)
        f = env;
        return
    end
    cfg = drishti_paths();
    f = fullfile(cfg.modelsDir, 'site_calibration.mat');
end


function A = pickArtifact(L)
%PICKARTIFACT  The artifact, whether it was saved bare or under a variable.
    A = struct();
    if isfield(L, 'A') && isstruct(L.A)
        A = L.A;
        return
    end
    v = fieldnames(L);
    for k = 1:numel(v)
        c = L.(v{k});
        if isstruct(c) && isfield(c, 'a') && isfield(c, 'thresholdRaw')
            A = c;
            return
        end
    end
end


function warnRefused(opts, f, why)
    if ~opts.verbose, return; end
    warning('drishti:unusableSiteCalibration', ...
        ['Refusing the site calibration at %s because %s.\n' ...
         'Running UNCALIBRATED on the frozen APTOS operating point instead. ' ...
         'Rebuild it with buildSiteCalibration.'], f, why);
end
