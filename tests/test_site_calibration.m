function tests = test_site_calibration
%TEST_SITE_CALIBRATION  Calibrated vs uncalibrated behaviour, and its provenance.
%
%   The failure these guard against is not a crash. It is a system that reports
%   itself CALIBRATED while running on an operating point nobody can trace - to
%   which camera, fitted on which images, evaluated against what. That is the
%   shape of the original 31.2%% failure: a threshold applied far outside the
%   domain it was chosen in, with nothing in the output saying so.
%
%   So these tests check three things:
%     1. FITSITECALIBRATION fits what it claims to fit.
%     2. An artifact without provenance is REFUSED, not used.
%     3. Calibrating moves sensitivity and specificity in OPPOSITE directions,
%        and both are recorded - never sensitivity alone.
%
%   Run: runtests('tests/test_site_calibration.m')

    tests = functiontests(localfunctions);
end


function setupOnce(tc)
    here = fileparts(fileparts(mfilename('fullpath')));
    addpath(genpath(fullfile(here, 'src')));
    addpath(fullfile(here, 'config'));
    tc.TestData.root = here;
    tc.TestData.artifact = fullfile(here, 'models', 'site_calibration.mat');

    % A deterministic two-class score set standing in for a target camera:
    % separable enough to be calibratable, overlapping enough that a threshold
    % choice actually costs something.
    rng(0);
    nPos = 120; nNeg = 180;
    tc.TestData.scores = [0.10 + 0.08*randn(nPos,1); 0.02 + 0.05*randn(nNeg,1)];
    tc.TestData.truth  = [true(nPos,1); false(nNeg,1)];
end


% ----------------------------------------------------------- what it fits

function testFitReachesTargetSensitivityOnItsOwnSample(tc)
% The selection rule is "lowest threshold reaching targetSensitivity". On the
% sample it was fitted to, it must actually reach it - otherwise the rule is
% not implemented, whatever the help says.
    S = fitSiteCalibration(tc.TestData.scores, tc.TestData.truth, ...
        'targetSensitivity', 0.90);
    tc.verifyGreaterThanOrEqual(S.calibrationSensitivity, 0.90, ...
        'Fit did not reach its own target sensitivity on the calibration set.');
    tc.verifyGreaterThanOrEqual(S.calibrationSpecificity, 0, ...
        'Specificity must be recorded alongside sensitivity.');
end


function testFitReturnsBothThresholdScales(tc)
% thresholdRaw is the one the pipeline compares E.referableScore against.
% Returning only the Platt-scale threshold would be a silent scale mismatch.
    S = fitSiteCalibration(tc.TestData.scores, tc.TestData.truth);
    tc.verifyTrue(isfield(S, 'threshold'), 'No calibrated-scale threshold.');
    tc.verifyTrue(isfield(S, 'thresholdRaw'), 'No raw-scale threshold.');
    tc.verifyTrue(isfinite(S.thresholdRaw), 'thresholdRaw is not finite.');
end


function testPlattMapIsMonotoneIncreasing(tc)
% A calibration may relabel the scale; it must never reorder patients. If the
% map is decreasing, a higher score would report a lower risk.
    S = fitSiteCalibration(tc.TestData.scores, tc.TestData.truth);
    x = linspace(min(tc.TestData.scores), max(tc.TestData.scores), 50)';
    p = 1 ./ (1 + exp(-(S.a * x + S.b)));
    tc.verifyGreaterThan(S.a, 0, 'Platt slope is not positive.');
    tc.verifyTrue(all(diff(p) >= -1e-12), 'Calibration map is not monotone.');
end


function testSingleClassSampleIsRejected(tc)
% A calibration set with no negatives cannot locate an operating point. It must
% fail loudly rather than return a threshold fitted to nothing.
    tc.verifyError(@() fitSiteCalibration([0.2;0.3;0.4], true(3,1)), ...
        'drishti:degenerateCalibrationSet');
end


function testSmallSampleCarriesANoiseWarning(tc)
% A 20-image fit is a noisy estimate. The struct has to say so, because the
% caller cannot tell from the threshold itself.
    idx = [1:10, 121:130];
    S = fitSiteCalibration(tc.TestData.scores(idx), tc.TestData.truth(idx));
    tc.verifyNotEmpty(S.warning, ...
        'A sub-50-image calibration returned no noise warning.');
end


% ------------------------------------------------- calibrated vs uncalibrated

function testCalibrationTradesSpecificityForSensitivity(tc)
% THE central behavioural claim. On a domain whose scores sit below the shipped
% threshold, calibrating must recover sensitivity AND give up specificity. A
% change that improved both would mean the comparison is not measuring what it
% claims to.
    scores = tc.TestData.scores;
    truth  = tc.TestData.truth;

    shippedThr = 0.4032960;      % the frozen APTOS high-sensitivity threshold
    S = fitSiteCalibration(scores, truth, 'targetSensitivity', 0.90);

    base = predictSensSpec(scores >= shippedThr, truth);
    cal  = predictSensSpec(scores >= S.thresholdRaw, truth);

    tc.verifyGreaterThan(cal.sens, base.sens, ...
        'Calibration did not raise sensitivity on a shifted domain.');
    tc.verifyLessThan(cal.spec, base.spec, ...
        'Calibration raised sensitivity without costing specificity - suspicious.');
end


function testUncalibratedIsTheDefaultWhenNoArtifactExists(tc)
% No calibration must leave the system in the uncalibrated state, not stop it.
% A rural site with no local labels still has to be able to screen.
    missing = fullfile(tempdir, 'drishti_no_such_calibration.mat');
    if isfile(missing), delete(missing); end
    C = loadSiteCalibration('file', missing);
    tc.verifyEmpty(fieldnames(C), ...
        'A missing artifact must return an empty struct, not a partial one.');
    tc.verifyFalse(isfield(C, 'a'), ...
        'Callers gate on isfield(C,''a''); it must be absent when uncalibrated.');
end


% -------------------------------------------------------------- provenance

function testArtifactWithoutProvenanceIsRefused(tc)
% A bare FITSITECALIBRATION struct has a, b and thresholdRaw, so it would work.
% It must still be refused: it records no site and no grader, and an operating
% point with no provenance is what the 31.2% failure was made of.
    A = fitSiteCalibration(tc.TestData.scores, tc.TestData.truth); %#ok<NASGU>
    f = fullfile(tempdir, 'drishti_bare_calibration.mat');
    save(f, 'A');
    c = onCleanup(@() delete(f));

    C = tc.verifyWarning(@() loadSiteCalibration('file', f), ...
        'drishti:unusableSiteCalibration');
    tc.verifyEmpty(fieldnames(C), ...
        'An unstamped artifact must fall back to uncalibrated.');
end


function testArtifactMissingRequiredFieldIsRefused(tc)
    A = struct('a', 1, 'b', 0, 'n', 100);     % no thresholdRaw
    A.meta.artifactVersion = 'siteCalibration/v1';
    f = fullfile(tempdir, 'drishti_incomplete_calibration.mat');
    save(f, 'A');
    c = onCleanup(@() delete(f));

    C = tc.verifyWarning(@() loadSiteCalibration('file', f), ...
        'drishti:unusableSiteCalibration');
    tc.verifyEmpty(fieldnames(C));
end


function testSavedArtifactCarriesItsProvenanceAndBothMetrics(tc)
% The real artifact, if this machine has one.
    if ~isfile(tc.TestData.artifact)
        tc.assumeFail('No site_calibration.mat on this machine - run buildSiteCalibration.');
    end
    C = loadSiteCalibration('file', tc.TestData.artifact);
    tc.verifyTrue(isfield(C, 'a'), 'A valid artifact was refused.');

    tc.verifyTrue(isfield(C.meta, 'site'), 'Artifact does not name its site.');
    tc.verifyTrue(isfield(C.meta, 'graderModel'), 'Artifact does not name its grader.');
    tc.verifyTrue(isfield(C.meta, 'calibrationSet'), 'No calibration set recorded.');
    tc.verifyTrue(isfield(C.meta, 'evaluationSet'), 'No evaluation set recorded.');

    % Sensitivity is never carried without the specificity it cost.
    E = C.evaluation;
    for f = {'calibratedSensitivity','calibratedSpecificity', ...
             'uncalibratedSensitivity','uncalibratedSpecificity'}
        tc.verifyTrue(isfield(E, f{1}), sprintf('Artifact lacks %s.', f{1}));
    end
end


function testArtifactWasNotFittedOnTheHeldOutBenchmark(tc)
% Messidor-2 is spent. An operating point fitted or selected on it would make
% the one honest external number meaningless, and no test elsewhere would
% notice - the artifact would look perfectly well-formed.
    if ~isfile(tc.TestData.artifact)
        tc.assumeFail('No site_calibration.mat on this machine.');
    end
    C = loadSiteCalibration('file', tc.TestData.artifact);

    prov = lower(strjoin({char(C.meta.site), char(C.meta.calibrationSet), ...
                          char(C.meta.evaluationSet)}, ' '));
    tc.verifyEmpty(strfind(prov, 'messidor'), ...
        'The site calibration names Messidor-2 in its provenance. It is the held-out benchmark.');
    tc.verifyTrue(isfield(C.meta, 'heldOutBenchmarkUsed'), ...
        'Artifact does not record whether a held-out set was used.');
end


function testCalibrationAndEvaluationSetsAreDisjoint(tc)
% Fit and evaluation on the same images is indistinguishable from tuning on
% test. The artifact must record that they were separated.
    if ~isfile(tc.TestData.artifact)
        tc.assumeFail('No site_calibration.mat on this machine.');
    end
    C = loadSiteCalibration('file', tc.TestData.artifact);
    tc.verifyTrue(isfield(C.meta, 'disjoint') && C.meta.disjoint, ...
        'Artifact does not assert calibration/evaluation disjointness.');
    tc.verifyNotEqual(char(C.meta.calibrationSet), char(C.meta.evaluationSet), ...
        'Calibration and evaluation sets are the same.');
end


function testHeldBackNumbersAreNotTheOptimisticOnes(tc)
% The fit hits its target on the images it saw. What may be QUOTED is the
% held-back pair. If the two are identical, something is reporting the
% calibration set as though it were held out.
    if ~isfile(tc.TestData.artifact)
        tc.assumeFail('No site_calibration.mat on this machine.');
    end
    C = loadSiteCalibration('file', tc.TestData.artifact);
    tc.verifyNotEqual(C.evaluation.calibratedSensitivity, C.calibrationSensitivity, ...
        'Held-back sensitivity equals the calibration-set value exactly.');
end


% ------------------------------------------------------------------ helpers

function E = predictSensSpec(pred, truth)
    E.sens = nnz(pred & truth) / max(nnz(truth), 1);
    E.spec = nnz(~pred & ~truth) / max(nnz(~truth), 1);
end
