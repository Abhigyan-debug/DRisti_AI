function tests = test_lesion_validation
%TEST_LESION_VALIDATION  The reporting contract for Module 2 lesion channels.
%
%   These tests guard the rule that makes the clinical report honest: a lesion
%   channel may be displayed ONLY if it was measured against ground truth and
%   cleared a bar that was frozen before the measurement ran.
%
%   The failure they exist to catch is not a crash. It is somebody re-enabling a
%   channel by hand - editing `reliable` to true, or lowering a gate after seeing
%   the numbers - which produces a report that looks fine and is not.
%
%   Run: runtests('tests/test_lesion_validation.m')

    tests = functiontests(localfunctions);
end


function setupOnce(tc)
    here = fileparts(fileparts(mfilename('fullpath')));
    addpath(genpath(fullfile(here, 'src')));
    addpath(fullfile(here, 'config'));
    tc.TestData.root = here;
end


function testThresholdFileExistsAndParses(tc)
% The gates must live in a committed file, not in source code.
    f = fullfile(tc.TestData.root, 'config', 'lesion_validation_thresholds.json');
    tc.verifyTrue(isfile(f), 'Pre-registered threshold file is missing.');

    T = jsondecode(fileread(f));
    tc.verifyTrue(isfield(T, 'gates'), 'No gates block.');
    tc.verifyTrue(isfield(T.gates, 'displayPrecisionMin'));
    tc.verifyTrue(isfield(T.gates, 'displayRecallMin'));
    tc.verifyGreaterThanOrEqual(T.gates.displayPrecisionMin, 0.5, ...
        ['The precision gate has been lowered below 0.5. Below one half a ' ...
         'displayed finding misinforms more often than it informs.']);
    tc.verifyGreaterThan(T.gates.displayRecallMin, 0, ...
        'A zero recall gate lets a silent detector pass on precision alone.');
end


function testReliabilityLoaderFailsClosed(tc)
% Every channel must be reported on, and unmeasured must mean not displayed.
    V = loadLesionReliability();
    for c = {'microaneurysms', 'haemorrhages', 'hardExudates', 'softExudates'}
        tc.verifyTrue(isfield(V, c{1}), sprintf('Channel %s absent.', c{1}));
        e = V.(c{1});
        tc.verifyTrue(islogical(e.reliable));
        if ~e.measured
            tc.verifyFalse(e.reliable, ...
                sprintf('%s is unmeasured but marked reliable.', c{1}));
        end
    end
end


function testReliableImpliesGatesWereMet(tc)
% The central invariant: nothing is displayed that did not clear the frozen bar.
    f = fullfile(tc.TestData.root, 'results', 'lesion_validation.mat');
    if ~isfile(f)
        tc.assumeFail('No validation result yet - run validateLesionDetectors.');
    end
    S = load(f, 'R');
    R = S.R;
    T = jsondecode(fileread(fullfile(tc.TestData.root, 'config', ...
        'lesion_validation_thresholds.json')));

    names = fieldnames(R.channels);
    for k = 1:numel(names)
        e = R.channels.(names{k});
        if e.reliable
            tc.verifyGreaterThanOrEqual(e.precision, T.gates.displayPrecisionMin, ...
                sprintf('%s is displayed with precision below the gate.', names{k}));
            tc.verifyGreaterThanOrEqual(e.recall, T.gates.displayRecallMin, ...
                sprintf('%s is displayed with recall below the gate.', names{k}));
        end
        tc.verifyGreaterThanOrEqual(e.precision, 0);
        tc.verifyLessThanOrEqual(e.precision, 1);
        tc.verifyGreaterThanOrEqual(e.recall, 0);
        tc.verifyLessThanOrEqual(e.recall, 1);
    end
end


function testValidationRanOnHeldOutSplit(tc)
% Scoring on the split that chose the threshold is not validation.
    f = fullfile(tc.TestData.root, 'results', 'lesion_validation.mat');
    if ~isfile(f)
        tc.assumeFail('No validation result yet.');
    end
    S = load(f, 'R');
    tc.verifyEqual(S.R.split, 'test', ...
        ['The saved validation is not from the held-out test split. The ' ...
         'exudate threshold was tuned on train, so train numbers are optimistic.']);
    tc.verifyFalse(S.R.optimistic);
end


function testThresholdFileUnchangedSinceMeasurement(tc)
% If the gates were edited after seeing the results, the hash stops matching.
    f = fullfile(tc.TestData.root, 'results', 'lesion_validation.mat');
    if ~isfile(f)
        tc.assumeFail('No validation result yet.');
    end
    S = load(f, 'R');
    thr = fullfile(tc.TestData.root, 'config', 'lesion_validation_thresholds.json');

    fid = fopen(thr, 'r');
    bytes = fread(fid, Inf, '*uint8');
    fclose(fid);
    md = java.security.MessageDigest.getInstance('SHA-256');
    md.update(bytes);
    d = typecast(md.digest(), 'uint8');
    h = lower(reshape(dec2hex(d, 2)', 1, []));

    tc.verifyEqual(h, S.R.thresholdSha256, ...
        ['The threshold file has changed since the validation was run. Either ' ...
         're-run validateLesionDetectors, or explain why the gates moved.']);
end
