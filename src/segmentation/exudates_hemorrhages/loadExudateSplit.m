function thr = loadExudateSplit()
%LOADEXUDATESPLIT  Fitted hard-vs-soft exudate decision boundary.
%
%   thr = LOADEXUDATESPLIT() reads config/exudate_split.json, falling back to
%   1.0 - the value that was hardcoded in SEGMENTEXUDATES before the boundary
%   was ever fitted to ground truth.
%
%   The fallback is deliberately the OLD behaviour rather than a guess: if the
%   fit has not been run on this machine, the pipeline should do what it always
%   did, not something new and unmeasured.
%
%   See also FITEXUDATESPLIT, SEGMENTEXUDATES.

    persistent cachedThr cachedStamp

    cfg = drishti_paths();
    f = fullfile(cfg.projectRoot, 'config', 'exudate_split.json');

    d = dir(f);
    if isempty(d)
        thr = 1.0;
        return
    end
    stamp = sprintf('%.6f:%d', d.datenum, d.bytes);
    if ~isempty(cachedThr) && strcmp(stamp, cachedStamp)
        thr = cachedThr;
        return
    end

    thr = 1.0;
    try
        J = jsondecode(fileread(f));
        if isfield(J, 'splitThreshold') && isfinite(J.splitThreshold)
            thr = J.splitThreshold;
        end
    catch
        % A malformed config must not change detector behaviour silently.
    end

    cachedThr = thr;
    cachedStamp = stamp;
end
