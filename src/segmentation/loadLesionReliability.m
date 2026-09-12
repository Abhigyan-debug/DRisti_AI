function V = loadLesionReliability()
%LOADLESIONRELIABILITY  Measured reliability for each lesion channel.
%
%   V = LOADLESIONRELIABILITY() returns one struct per channel:
%
%       V.<channel>.reliable    logical - may this be displayed?
%       V.<channel>.precision   .recall  .f1
%       V.<channel>.n           images scored
%       V.<channel>.verdict     human-readable pass/fail reason
%       V.<channel>.protocol    how it was measured
%       V.<channel>.measured    false if no validation has been run
%
%   Reads RESULTS/LESION_VALIDATION.MAT, written by VALIDATELESIONDETECTORS.
%
%   IT FAILS CLOSED, ON PURPOSE
%   ---------------------------
%   If the validation has never been run on this machine, every channel comes
%   back reliable = false and measured = false, and the clinical report shows
%   "not validated" for all four. The alternative - defaulting to the last
%   numbers somebody wrote into a source file - is how a hardcoded `reliable =
%   true` outlives the measurement that justified it. These flags were literal
%   constants in EXTRACTLESIONFEATURES until this change, which meant the
%   report's honesty depended on somebody remembering to edit them.
%
%   A channel is displayed only when a measurement exists AND clears the bar
%   frozen in CONFIG/LESION_VALIDATION_THRESHOLDS.JSON. Silence is the safe
%   default, because an unmeasured detector and a bad one are equally unfit to
%   put a finding in front of a clinician.
%
%   The result is cached and re-read when the .mat changes, since this is called
%   once per image.
%
%   See also VALIDATELESIONDETECTORS, EXTRACTLESIONFEATURES.

    persistent cached cachedStamp

    channels = {'microaneurysms', 'haemorrhages', 'hardExudates', 'softExudates'};

    cfg = drishti_paths();
    f = fullfile(cfg.resultsDir, 'lesion_validation.mat');

    if ~isfile(f)
        V = unmeasured(channels, ['no validation result found - run ' ...
            'validateLesionDetectors']);
        return
    end

    d = dir(f);
    stamp = [d.datenum d.bytes];
    if ~isempty(cached) && isequal(stamp, cachedStamp)
        V = cached;
        return
    end

    try
        S = load(f, 'R');
        R = S.R;
    catch ME
        V = unmeasured(channels, sprintf('validation result unreadable (%s)', ME.message));
        return
    end

    V = struct();
    for k = 1:numel(channels)
        c = channels{k};
        if ~isfield(R, 'channels') || ~isfield(R.channels, c)
            V.(c) = oneUnmeasured('channel absent from the validation result');
            continue
        end
        e = R.channels.(c);
        V.(c) = struct( ...
            'reliable',  logical(e.reliable), ...
            'measured',  true, ...
            'precision', e.precision, ...
            'recall',    e.recall, ...
            'f1',        e.f1, ...
            'n',         e.n, ...
            'verdict',   e.verdict, ...
            'protocol',  e.protocol);
    end

    cached = V;
    cachedStamp = stamp;
end


function V = unmeasured(channels, why)
    V = struct();
    for k = 1:numel(channels)
        V.(channels{k}) = oneUnmeasured(why);
    end
end


function e = oneUnmeasured(why)
    e = struct('reliable', false, 'measured', false, ...
               'precision', NaN, 'recall', NaN, 'f1', NaN, 'n', 0, ...
               'verdict', ['not validated - ' why], ...
               'protocol', 'no measurement on this machine');
end
