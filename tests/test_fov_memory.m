function tests = test_fov_memory()
%TEST_FOV_MEMORY  DETECTFOV stays correct and memory-bounded on full-size frames.
%
%   runtests('tests/test_fov_memory.m')
%
%   DETECTFOV used to derive its centroid and bounding box with
%
%       regionprops(mask, 'Centroid', 'BoundingBox', 'Area')
%
%   which, per MATLAB's own source (toolbox/images/images/regionprops.m), routes
%   both geometric properties through ComputePixelList - an N-by-2 array of
%   DOUBLE subscripts for every foreground pixel. Measured with the memory
%   profiler on a 4288x2848 frame whose field of view is 7.97 M pixels, that is
%   128 MB of PeakMem per call to produce six numbers, all of it attributed to
%   ComputePixelList. SWEEPGENERATORRECALL calls it once per image across the
%   whole split, twice over.
%
%   These tests pin BOTH halves of the fix:
%
%     * EQUIVALENCE - the replacement must return exactly what regionprops
%       returned. The test computes the regionprops answer on DETECTFOV's own
%       returned mask and demands agreement. If someone "optimises" the helper
%       into something subtly different - a bounding box off by the half-pixel
%       convention, a centroid over the wrong component - this fails.
%
%     * COST - the replacement must not quietly regress to the old approach.
%       The guard is PeakMem from profile('-memory','on'), against a regionprops
%       baseline measured in the same run on the same mask, so it adapts to the
%       machine instead of hardcoding a megabyte count that rots. Wall-clock is
%       deliberately NOT used: regionprops does the 128 MB allocation in 0.16 s,
%       so timing cannot see this defect at all.
%
%   Correctness is the point; the memory saving is worthless if the FOV moves,
%   because fov.diameter is the reference length for every Module 1 metric and
%   fov.mask is what every Module 2 evaluation masks against.
%
%   See also DETECTFOV, SWEEPGENERATORRECALL.

    tests = functiontests(localfunctions);
end


function setupOnce(testCase)
    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    addpath(genpath(fullfile(root, 'src')));
    addpath(fullfile(root, 'config'));
end


% ---------------------------------------------------------------- equivalence

function testMatchesRegionpropsOnSyntheticDisc(testCase)
%   A clean off-centre disc: the case the geometry is supposed to nail.
    img = syntheticFundus(1400, 2000, [1100 700], 620);
    fov = detectFOV(img);
    verifyTrue(testCase, fov.valid, 'A plain bright disc must be found.');
    assertRegionpropsAgreement(testCase, fov);

    % Independent analytic check, so the test is not purely self-consistent.
    verifyEqual(testCase, fov.centre, [1100 700], 'AbsTol', 2, ...
        'Centroid should land on the disc centre.');
    verifyEqual(testCase, fov.diameter, 1240, 'RelTol', 0.02, ...
        'Diameter should recover 2r.');
end


function testMatchesRegionpropsWithDistractorBlobs(testCase)
%   Timestamp burn-in and specular flecks: several components, one real FOV.
%   Exercises the max-area selection that replaced max([stats.Area]).
    img = syntheticFundus(1400, 2000, [1000 700], 560);
    img(40:110, 40:400, :) = 255;        % burn-in strip, touches no edge tolerance
    img(1300:1340, 1900:1960, :) = 200;  % specular fleck in the surround
    fov = detectFOV(img);
    verifyTrue(testCase, fov.valid);
    assertRegionpropsAgreement(testCase, fov);
end


function testMatchesRegionpropsOnTruncatedFov(testCase)
%   IDRiD-style crop: the disc runs off the top and bottom of the frame, which
%   is where the bounding-box half-pixel convention actually bites.
    img = syntheticFundus(900, 2000, [1000 450], 700);
    fov = detectFOV(img);
    verifyTrue(testCase, fov.valid);
    verifyTrue(testCase, fov.truncated, 'This crop touches the frame edge.');
    assertRegionpropsAgreement(testCase, fov);
end


function testMatchesRegionpropsOnRealFrame(testCase)
%   The synthetic cases are clean by construction. A real fundus frame has a
%   ragged, JPEG-ringed boundary, which is the shape the half-pixel and
%   largest-component rules were written for.
    cfg = drishti_paths();
    L = dir(fullfile(cfg.idrid.segTrainImages, '*.jpg'));
    testCase.assumeNotEmpty(L, 'IDRiD segmentation images required.');
    img = imread(fullfile(cfg.idrid.segTrainImages, L(1).name));
    fov = detectFOV(img);
    verifyTrue(testCase, fov.valid);
    assertRegionpropsAgreement(testCase, fov);
end


% ----------------------------------------------------------------------- cost

function testGeometryPeakMemoryBeatsRegionprops(testCase)
%   The regression guard, measured in MEMORY - which is what the fix is about.
%
%   An earlier version of this test compared wall-clock and was worthless:
%   regionprops does the 128 MB allocation in 0.16 s, so time does not see the
%   defect at all. MATLAB's memory profiler reports PeakMem per function, which
%   does.
%
%   Both sides are measured in this run on this mask, so the assertion is a
%   ratio rather than a hardcoded megabyte count that would rot.
    img = syntheticFundus(2848, 4288, [2100 1424], 1640);
    fov = detectFOV(img);                % also warms up before profiling
    mask = fov.mask;

    nPix = nnz(mask);
    verifyGreaterThan(testCase, nPix, 5e6, ...
        'This test is meaningless unless the mask is genuinely large.');

    cleanup = onCleanup(@() profile('off')); %#ok<NASGU>

    [helperMB, names, memAvailable] = ...
        profiledPeak(@() detectFOV(img), 'detectFOV>largestRegionStats');
    if ~memAvailable
        testCase.assumeFail('profile(''-memory'') reports no PeakMem in this release.');
    end

    verifyTrue(testCase, any(strcmp(names, 'detectFOV>largestRegionStats')), ...
        ['detectFOV>largestRegionStats did not appear in the profile. If the ' ...
         'geometry helper was removed, the regionprops PixelList path is ' ...
         'probably back - that is the regression this test exists for.']);

    % Direct guard: nothing under detectFOV may call regionprops. Cheap to
    % check, and it is the exact thing being forbidden.
    verifyFalse(testCase, any(contains(names, 'regionprops')), ...
        'detectFOV must not call regionprops - see largestRegionStats.');

    % Baseline: what the replaced call costs on this very mask.
    refMB = profiledPeak(@() regionprops(mask, 'Centroid', 'BoundingBox', 'Area'), ...
                         'regionprops');

    ref = regionprops(mask, 'Centroid', 'BoundingBox', 'Area');
    [~, k] = max([ref.Area]);
    verifyEqual(testCase, fov.centre, ref(k).Centroid, 'AbsTol', 1e-9);
    verifyEqual(testCase, fov.bbox,   ref(k).BoundingBox, 'AbsTol', 1e-9);

    if isnan(refMB)
        testCase.assumeFail('Could not read a regionprops PeakMem baseline.');
    end
    verifyLessThan(testCase, helperMB, 0.75 * refMB, ...
        sprintf(['largestRegionStats peaked at %.0f MB against a regionprops ' ...
                 'baseline of %.0f MB on the same %d-pixel mask. It should be ' ...
                 'well under, because it never materialises PixelList.'], ...
                helperMB, refMB, nPix));

    fprintf(['\n    [fov memory] %.1f M px FOV | largestRegionStats %.0f MB | ' ...
             'regionprops baseline %.0f MB | saved %.0f MB/call\n'], ...
            nPix/1e6, helperMB, refMB, refMB - helperMB);
end


function testToGrayConvertsOneChannelAtATime(testCase)
%   The crash site. DETECTFOV's first statement is toGray(img), which used to
%   run im2double over the whole RGB frame - 4288*2848*3*8 B = 293 MB of double
%   materialised only to collapse it to one channel on the next line. Under a
%   sustained multi-build run that is what actually exhausted host memory:
%
%       Out of memory.
%       Error in toGray (line 27)  gray = 0.299*img(:,:,1) + ...
%       Error in detectFOV (line 35)
%
%   Converting per channel peaks at one channel instead of three. The guard is
%   relative to an im2double baseline measured in the same run.
    img = syntheticFundus(2848, 4288, [2100 1424], 1640);
    toGray(img);                          % warm up

    [grayMB, ~, memAvailable] = profiledPeak(@() toGray(img), 'toGray');
    if ~memAvailable
        testCase.assumeFail('profile(''-memory'') reports no PeakMem in this release.');
    end
    baseMB = profiledPeak(@() im2double(img), 'im2double');
    if isnan(baseMB) || isnan(grayMB)
        testCase.assumeFail('Could not read PeakMem for both sides.');
    end

    verifyLessThan(testCase, grayMB, 0.5 * baseMB, ...
        sprintf(['toGray peaked at %.0f MB against an im2double-the-whole-frame ' ...
                 'baseline of %.0f MB. It should be near one third - if it is ' ...
                 'not, the whole-frame conversion is back.'], grayMB, baseMB));

    fprintf('\n    [toGray memory] %.0f MB vs %.0f MB whole-frame im2double\n', ...
            grayMB, baseMB);
end


function testToGrayIsBitExact(testCase)
%   The memory fix is worthless if it moves a single value: Module 1's quality
%   thresholds were MEASURED against this function's output, and fov.diameter
%   normalises every metric downstream. im2double scales elementwise, so
%   converting per channel must be bit-for-bit identical - not merely close.
    cfg = drishti_paths();
    L = dir(fullfile(cfg.idrid.segTrainImages, '*.jpg'));
    testCase.assumeNotEmpty(L, 'IDRiD segmentation images required.');
    img = imread(fullfile(cfg.idrid.segTrainImages, L(1).name));

    whole = im2double(img);
    expected = 0.299*whole(:,:,1) + 0.587*whole(:,:,2) + 0.114*whole(:,:,3);
    verifyTrue(testCase, isequal(toGray(img), expected), ...
        'toGray must be bit-identical to the whole-frame conversion it replaced.');
end


function testResizeToDoubleIsBitExact(testCase)
%   RESIZETODOUBLE replaced imresize(im2double(img), scale, 'bilinear') in five
%   hot-path functions. Every one of them produces the working-scale frame that
%   Module 2 detects on, so a half-ULP change would move measured detector
%   numbers that were frozen against the old behaviour.
    cfg = drishti_paths();
    L = dir(fullfile(cfg.idrid.segTrainImages, '*.jpg'));
    testCase.assumeNotEmpty(L, 'IDRiD segmentation images required.');
    img = imread(fullfile(cfg.idrid.segTrainImages, L(1).name));

    for scale = [0.4506, 0.25, 1.0]
        expected = imresize(im2double(img), scale, 'bilinear');
        actual = resizeToDouble(img, scale);
        verifyTrue(testCase, isequal(actual, expected), ...
            sprintf(['resizeToDouble must be bit-identical to the whole-frame ' ...
                     'form it replaced (scale %.4f).'], scale));
    end
end


function testResizeToDoublePeaksAtOneChannel(testCase)
%   The point of the helper. Guarded against an im2double baseline measured in
%   the same run rather than a hardcoded megabyte count.
    img = syntheticFundus(2848, 4288, [2100 1424], 1640);
    resizeToDouble(img, 0.45);            % warm up

    [gotMB, ~, memAvailable] = profiledPeak(@() resizeToDouble(img, 0.45), 'resizeToDouble');
    if ~memAvailable
        testCase.assumeFail('profile(''-memory'') reports no PeakMem in this release.');
    end
    baseMB = profiledPeak(@() im2double(img), 'im2double');
    if isnan(baseMB) || isnan(gotMB)
        testCase.assumeFail('Could not read PeakMem for both sides.');
    end

    verifyLessThan(testCase, gotMB, 0.6 * baseMB, ...
        sprintf(['resizeToDouble peaked at %.0f MB against a whole-frame ' ...
                 'im2double baseline of %.0f MB.'], gotMB, baseMB));
    fprintf('\n    [resize memory] %.0f MB vs %.0f MB whole-frame\n', gotMB, baseMB);
end


function testPatchCutterDoesNotConvertWholeFrame(testCase)
%   CUTCANDIDATEPATCHES used to run im2single over the entire image before
%   reading 48 px windows out of it - 146 MB on a full-resolution frame, and
%   SCORELESIONCANDIDATES calls it once per chunk, so a 1200-candidate image
%   churned that allocation ~38 times.
    img = syntheticFundus(2848, 4288, [2100 1424], 1640);
    cents = [2100 1424; 1800 1200; 2400 1600];
    cutCandidatePatches(img, cents, 48);   % warm up

    [cutMB, ~, memAvailable] = profiledPeak( ...
        @() cutCandidatePatches(img, cents, 48), 'cutCandidatePatches');
    if ~memAvailable
        testCase.assumeFail('profile(''-memory'') reports no PeakMem in this release.');
    end

    frameMB = numel(img) * 4 / 1e6;        % what im2single(whole frame) costs
    verifyLessThan(testCase, cutMB, 0.25 * frameMB, ...
        sprintf(['cutCandidatePatches peaked at %.0f MB cutting 3 patches. A ' ...
                 'single-precision copy of this frame is %.0f MB - if the peak ' ...
                 'is near that, the whole-frame conversion is back.'], ...
                cutMB, frameMB));
end


function testNoRetainedAllocation(testCase)
%   Repeated calls must not accumulate. Catches a helper that caches an index
%   list or leaks a persistent, which on a 53-image sweep is the difference
%   between steady state and an out-of-memory abort.
    img = syntheticFundus(2000, 3000, [1500 1000], 900);
    detectFOV(img);                       % warm up, so first-call costs settle

    before = memUsedMB();
    for i = 1:5
        fov = detectFOV(img); %#ok<NASGU>
        clear fov
    end
    after = memUsedMB();

    if isnan(before) || isnan(after)
        testCase.assumeFail('memory() unavailable on this platform.');
    end
    verifyLessThan(testCase, after - before, 250, ...
        sprintf(['Five detectFOV calls grew MATLAB memory by %.0f MB; the ' ...
                 'geometry helper should hold nothing between calls.'], ...
                after - before));
end


% -------------------------------------------------------------------- helpers

function assertRegionpropsAgreement(testCase, fov)
%ASSERTREGIONPROPSAGREEMENT  fov's geometry must equal the regionprops answer.
%
%   fov.mask is the exact mask the replaced code ran on, so this compares the
%   new helper against the old implementation rather than against a
%   re-derivation of it.
    ref = regionprops(fov.mask, 'Centroid', 'BoundingBox', 'Area');
    verifyNotEmpty(testCase, ref, 'A valid FOV must contain a region.');
    [refArea, k] = max([ref.Area]);

    verifyEqual(testCase, fov.centre, ref(k).Centroid, 'AbsTol', 1e-9, ...
        'Centroid must match regionprops exactly.');
    verifyEqual(testCase, fov.bbox, ref(k).BoundingBox, 'AbsTol', 1e-9, ...
        'BoundingBox must match regionprops, half-pixel convention included.');

    % The diameter rule is regionprops-derived too, so re-derive and compare.
    bw = ref(k).BoundingBox(3);
    bh = ref(k).BoundingBox(4);
    if bw >= bh
        expected = bw;
    else
        expected = max(bh, 2 * sqrt(refArea / pi));
    end
    verifyEqual(testCase, fov.diameter, expected, 'AbsTol', 1e-9, ...
        'Diameter is the reference length for every Module 1 metric.');

    % Coverage is over the WHOLE mask, extra components included - unchanged by
    % the fix, and pinned here so nobody "tidies" it into largest-component-only.
    verifyEqual(testCase, fov.coverage, nnz(fov.mask) / numel(fov.mask), ...
        'AbsTol', 1e-12, 'Coverage must stay whole-mask.');
end


function img = syntheticFundus(h, w, centreXY, radius)
%SYNTHETICFUNDUS  A bright disc on a near-black surround, uint8 RGB.
    [X, Y] = meshgrid(1:w, 1:h);
    inside = (X - centreXY(1)).^2 + (Y - centreXY(2)).^2 <= radius^2;
    base = uint8(inside) * 180;
    % A little texture so graythresh has a real distribution to work on rather
    % than a two-valued histogram.
    rng(0);
    tex = uint8(inside) .* uint8(randi([0 40], h, w));
    img = repmat(base + tex, 1, 1, 3);
end


function [mb, names, memAvailable] = profiledPeak(fn, target)
%PROFILEDPEAK  Run fn under the memory profiler; return one function's PeakMem.
%
%   Returns the peak in MB (NaN if `target` was not called), the names of every
%   function recorded, and whether PeakMem was reported at all.
%
%   The call sequence matters. `profile clear` resets the '-memory' option, so
%   enabling memory profiling and THEN clearing silently downgrades to an
%   ordinary time profile whose FunctionTable has no PeakMem field - which
%   looks exactly like "the function was never called". Stop, enable, run,
%   read, stop.
    profile off
    profile('-memory', 'on');
    fn();
    info = profile('info');
    profile off

    names = {};
    mb = NaN;
    memAvailable = false;
    if ~isfield(info, 'FunctionTable'), return; end
    names = {info.FunctionTable.FunctionName};
    memAvailable = ~isempty(info.FunctionTable) && ...
                   isfield(info.FunctionTable(1), 'PeakMem');
    if ~memAvailable, return; end
    hit = strcmp(names, target);
    if any(hit)
        mb = double(info.FunctionTable(find(hit, 1)).PeakMem) / 1e6;
    end
end


function mb = memUsedMB()
%MEMUSEDMB  MATLAB's own footprint, or NaN where `memory` is unsupported.
    mb = NaN;
    try
        m = memory();
        mb = m.MemUsedMATLAB / 1e6;
    catch
        % memory() is Windows-only; the caller treats NaN as "skip".
    end
end
