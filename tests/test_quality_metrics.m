function tests = test_quality_metrics()
%TEST_QUALITY_METRICS  Module 1 unit tests.
%
%   runtests('tests/test_quality_metrics.m')
%
%   Covers the behaviours that are easy to break silently:
%     - sharpness must respond to blur and NOT to resolution
%     - the intensity scale must stay 0-255 (a [0,1] version rejected 100%
%       of all four corpora)
%     - the FOV boundary must stay excluded from the focus measure
%     - coverage must never become a gate
%
%   See also ASSESSQUALITY, GATEIMAGE, MEASURESHARPNESS.

    tests = functiontests(localfunctions);
end


function setupOnce(testCase)
    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    addpath(genpath(fullfile(root, 'src')));
    addpath(fullfile(root, 'config'));
    cfg = drishti_paths();
    testCase.TestData.cfg = cfg;

    % A real fundus image, not a synthetic disc - synthetic images have none of
    % the texture the focus measure actually keys on.
    L = dir(fullfile(cfg.idrid.gradeTrainImages, '*.jpg'));
    testCase.assumeNotEmpty(L, 'IDRiD images required for these tests.');
    testCase.TestData.img = imread(fullfile(cfg.idrid.gradeTrainImages, L(1).name));
end


function test_fovIsFoundAndPlausible(testCase)
    img = testCase.TestData.img;
    fov = detectFOV(img);

    verifyTrue(testCase, fov.valid, 'FOV detection failed on a clean IDRiD image.');
    verifyGreaterThan(testCase, fov.coverage, 0.2, 'FOV suspiciously small.');
    verifyLessThan(testCase, fov.coverage, 0.95, ...
        'FOV covers nearly the whole frame - the black surround was not excluded.');

    % Centre should be near the middle of the frame for a well-framed capture
    [h, w, ~] = size(img);
    verifyLessThan(testCase, abs(fov.centre(1) - w/2) / w, 0.15);
    verifyLessThan(testCase, abs(fov.centre(2) - h/2) / h, 0.15);
end


function test_sharpnessFallsWithBlur(testCase)
    % The core contract: blurring must lower the score, monotonically.
    img = testCase.TestData.img;
    fov = detectFOV(img);

    sigmas = [0, 2, 5, 10];
    scores = zeros(size(sigmas));
    for k = 1:numel(sigmas)
        if sigmas(k) == 0
            blurred = img;
        else
            blurred = imgaussfilt(img, sigmas(k));
        end
        s = measureSharpness(blurred, fov);
        scores(k) = s.normalised;
    end

    verifyTrue(testCase, all(diff(scores) < 0), ...
        sprintf('Sharpness must decrease monotonically with blur. Got: %s', ...
                mat2str(round(scores, 2))));
    verifyLessThan(testCase, scores(end), scores(1) * 0.5, ...
        'Heavy blur should at least halve the sharpness score.');
end


function test_sharpnessIsResolutionStable(testCase)
    % The whole reason MEASURESHARPNESS rescales to a canonical FOV. Downsizing
    % an image must not change its focus score much - raw Laplacian variance
    % fails this badly (r = -0.75 against FOV diameter within APTOS).
    img = testCase.TestData.img;

    full = measureSharpness(img, detectFOV(img));
    halfImg = imresize(img, 0.5);
    half = measureSharpness(halfImg, detectFOV(halfImg));

    relDiff = abs(full.normalised - half.normalised) / full.normalised;
    verifyLessThan(testCase, relDiff, 0.45, sprintf( ...
        ['Normalised sharpness changed %.0f%% when the image was halved ' ...
         '(%.2f -> %.2f). The FOV normalisation is not working.'], ...
        relDiff*100, full.normalised, half.normalised));

    % And confirm the raw metric really is the unstable one, so this test keeps
    % documenting *why* normalisation exists.
    rawRel = abs(full.raw - half.raw) / full.raw;
    verifyGreaterThan(testCase, rawRel, relDiff, ...
        'Raw sharpness should be MORE resolution-sensitive than normalised.');
end


function test_sharpnessUsesByteScale(testCase)
    % Regression: computing on [0,1] instead of 0-255 makes every value 255^2
    % too small, so every threshold comparison fails and the gate rejects
    % everything. Pin the order of magnitude.
    img = testCase.TestData.img;
    s = measureSharpness(img, detectFOV(img));

    verifyGreaterThan(testCase, s.normalised, 0.5, ...
        ['Sharpness far too small - likely computed on a [0,1] intensity ' ...
         'scale instead of 0-255.']);
    verifyLessThan(testCase, s.normalised, 1e4, 'Sharpness implausibly large.');
end


function test_fovBoundaryExcludedFromSharpness(testCase)
    % The FOV edge is the strongest gradient in the frame. If it leaks into the
    % measure, a wider black surround raises the "focus" score.
    img = testCase.TestData.img;
    fov = detectFOV(img);

    padded = padarray(img, [200 200], 0, 'both');
    padFov = detectFOV(padded);

    a = measureSharpness(img, fov);
    b = measureSharpness(padded, padFov);

    relDiff = abs(a.normalised - b.normalised) / a.normalised;
    verifyLessThan(testCase, relDiff, 0.35, sprintf( ...
        ['Adding black border changed sharpness by %.0f%% (%.2f -> %.2f). ' ...
         'The FOV boundary is contaminating the measure.'], ...
        relDiff*100, a.normalised, b.normalised));
end


function test_gateRejectsSeverelyDegradedImages(testCase)
    % Deliberate degradation, per the Phase 1 checklist.
    img = testCase.TestData.img;

    heavyBlur = imgaussfilt(img, 15);
    d = gateImage(assessQuality(heavyBlur));
    verifyEqual(testCase, d.decision, 'reject', ...
        'A heavily blurred image must be rejected.');
    verifyTrue(testCase, any(strcmp({d.reasons.code}, 'out_of_focus')));

    veryDark = im2uint8(im2double(img) * 0.15);
    d = gateImage(assessQuality(veryDark));
    verifyEqual(testCase, d.decision, 'reject', ...
        'A very dark image must be rejected.');
end


function test_gateAcceptsCleanImages(testCase)
    % The counterpart: a good image must not be rejected. Guards against a
    % recurrence of the 100%-rejection bug.
    cfg = testCase.TestData.cfg;
    L = dir(fullfile(cfg.idrid.gradeTrainImages, '*.jpg'));
    n = min(12, numel(L));

    rejected = 0;
    for k = 1:n
        img = imread(fullfile(cfg.idrid.gradeTrainImages, L(k).name));
        d = gateImage(assessQuality(img));
        if strcmp(d.decision, 'reject')
            rejected = rejected + 1;
        end
    end

    verifyLessThan(testCase, rejected / n, 0.25, sprintf( ...
        ['%d of %d clean IDRiD images were rejected. Thresholds are too ' ...
         'aggressive - recalibrate with calibrateQualityThresholds.'], rejected, n));
end


function test_everyRejectCarriesAnActionableMessage(testCase)
    % Module 1's output is read by a technician at the camera, not a developer.
    img = imgaussfilt(testCase.TestData.img, 15);
    d = gateImage(assessQuality(img));

    verifyNotEmpty(testCase, d.reasons);
    for k = 1:numel(d.reasons)
        r = d.reasons(k);
        verifyNotEmpty(testCase, r.message);
        verifyTrue(testCase, ischar(r.message) || isstring(r.message));
        % An instruction, not a metric dump
        verifyTrue(testCase, ~contains(lower(r.message), {'nan', 'inf', 'struct'}), ...
            sprintf('Reason "%s" leaks internals: %s', r.code, r.message));
    end
    verifyNotEmpty(testCase, d.summary);
end


function test_coverageIsNeverAGate(testCase)
    % Regression guard on a design decision: FOV coverage is a camera
    % fingerprint (IDRiD 0.691 vs Messidor-2 0.465). If someone adds it as a
    % threshold, an entire corpus gets rejected for its crop convention.
    th = loadQualityThresholds();
    verifyFalse(testCase, isfield(th, 'fovCoverage'), ...
        ['FOV coverage must not be a gate threshold - it is a camera ' ...
         'fingerprint, not a quality signal. See calibrateQualityThresholds.']);
end
