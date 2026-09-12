function OP = loadLesionOperatingPoints()
%LOADLESIONOPERATINGPOINTS  Stage-2 classifier operating point, per dark-lesion channel.
%
%   OP = LOADLESIONOPERATINGPOINTS() reads
%   config/lesion_operating_points.json and returns
%
%       OP.<channel>.classifierThreshold   score above which a candidate is kept
%       OP.<channel>.applyClassifier       false = run stage 1 alone
%
%   for channel in {microaneurysms, haemorrhages}.
%
%   FALLBACK IS THE OLD BEHAVIOUR, NOT A GUESS
%   ------------------------------------------
%   A missing or malformed file yields threshold 0.5 with the classifier
%   applied - exactly what DETECTDARKLESIONS hardcoded before this file
%   existed. A teammate who has not run FITLESIONOPERATINGPOINT gets the
%   pipeline the project has always had, not a new and unmeasured one. Same
%   reasoning as LOADEXUDATESPLIT.
%
%   THIS IS NOT A DISPLAY GATE. Whether a channel may be shown to a clinician
%   is decided only by LOADLESIONRELIABILITY, from the held-out measurement.
%
%   See also FITLESIONOPERATINGPOINT, DETECTDARKLESIONS, LOADEXUDATESPLIT,
%   LOADLESIONRELIABILITY.

    persistent cachedOP cachedStamp

    channels = {'microaneurysms', 'haemorrhages'};
    OP = struct();
    for k = 1:numel(channels)
        OP.(channels{k}) = struct('classifierThreshold', 0.5, 'applyClassifier', true);
    end

    cfg = drishti_paths();
    f = fullfile(cfg.projectRoot, 'config', 'lesion_operating_points.json');

    d = dir(f);
    if isempty(d), return; end

    stamp = sprintf('%.6f:%d', d.datenum, d.bytes);
    if ~isempty(cachedOP) && strcmp(stamp, cachedStamp)
        OP = cachedOP;
        return
    end

    try
        J = jsondecode(fileread(f));
        for k = 1:numel(channels)
            c = channels{k};
            if ~isfield(J, 'channels') || ~isfield(J.channels, c), continue; end
            E = J.channels.(c);
            if isfield(E, 'classifierThreshold') && isscalar(E.classifierThreshold) ...
                    && isfinite(E.classifierThreshold)
                OP.(c).classifierThreshold = double(E.classifierThreshold);
            end
            if isfield(E, 'applyClassifier') && isscalar(E.applyClassifier)
                OP.(c).applyClassifier = logical(E.applyClassifier);
            end
        end
    catch
        % A malformed config must not silently change detector behaviour.
        return
    end

    cachedOP = OP;
    cachedStamp = stamp;
end
