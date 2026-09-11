function tests = test_segmentation()
%TEST_SEGMENTATION  Module 2 invariants.
%
%   runtests('tests/test_segmentation.m')
%
%   Phase 2 shipped with ZERO tests while Module 1 had nine, so nothing caught
%   a regression in any detector. These cover the contracts that matter rather
%   than the accuracy numbers, which live in evaluateSegmentation: a detector
%   can be weak and still be correct about its units, its ordering and its
%   handling of ungradable input. Those are the things that silently corrupt
%   Phase 3 if they break.
%
%   See also EVALUATESEGMENTATION, EXTRACTLESIONFEATURES.

    tests = functiontests(localfunctions);
end


function setupOnce(testCase)
    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    addpath(genpath(fullfile(root, 'src')));
    addpath(fullfile(root, 'config'));
    cfg = drishti_paths();
    testCase.TestData.cfg = cfg;

    L = dir(fullfile(cfg.idrid.segTrainImages, '*.jpg'));
    testCase.assumeNotEmpty(L, 'IDRiD segmentation images required.');
    testCase.TestData.img = imread(fullfile(cfg.idrid.segTrainImages, L(1).name));
end


function test_featureContractShape(testCase)
    % Module 3 reads this struct and nothing else. A missing or renamed field
    % breaks the hand-off silently, because MATLAB structs do not complain
    % until the field is dereferenced.
    F = extractLesionFeatures(testCase.TestData.img, 'runQualityGate', false);

    required = {'anatomy','microaneurysms','haemorrhages','hardExudates', ...
                'softExudates','neovascularization','vessels','quality'};
    for k = 1:numel(required)
        verifyTrue(testCase, isfield(F, required{k}), ...
            sprintf('Feature contract is missing "%s" - Phase 3 reads this.', required{k}));
    end

    verifyTrue(testCase, isfield(F.hardExudates, 'minDistanceToFoveaDD'), ...
        'minDistanceToFoveaDD drives the DME endpoint and must be present.');
    verifyTrue(testCase, isfield(F.anatomy, 'laterality'), ...
        'laterality is needed because lesion position is side-dependent.');
end


function test_spatialUnitsAreDiscDiameters(testCase)
    % THE contract rule. A pixel-denominated feature encodes camera model
    % across a 6.7x resolution range, and Phase 3 would learn the dataset
    % rather than the disease. Halving the image must not change a DD-scaled
    % feature much, whereas a pixel-scaled one would change ~4x by area.
    img = testCase.TestData.img;

    Ffull = extractLesionFeatures(img, 'runQualityGate', false);
    Fhalf = extractLesionFeatures(imresize(img, 0.5), 'runQualityGate', false);

    a = Ffull.hardExudates.areaDD2;
    b = Fhalf.hardExudates.areaDD2;
    testCase.assumeGreaterThan(a, 0, 'Need a non-zero area to test scaling.');

    ratio = b / a;
    verifyGreaterThan(testCase, ratio, 0.25, sprintf( ...
        ['Hard exudate area changed %.2fx when the image was halved (%.4f -> ' ...
         '%.4f). A disc-diameter-normalised feature should be roughly stable; ' ...
         'this looks pixel-denominated.'], ratio, a, b));
    verifyLessThan(testCase, ratio, 4.0, sprintf( ...
        'Hard exudate area changed %.2fx when the image was halved.', ratio));
end


function test_ungradableGivesNaNNotZero(testCase)
    % Zero microaneurysms means "a healthy retina". NaN means "we could not
    % look". If an ungradable image returned zeros, Phase 3 would be taught
    % that unreadable images are healthy - the most dangerous confusion
    % available in a screening pipeline.
    black = zeros(800, 800, 3, 'uint8');
    F = extractLesionFeatures(black, 'runQualityGate', true);

    verifyTrue(testCase, isnan(F.microaneurysms.count), ...
        'Ungradable image returned a numeric MA count instead of NaN.');
    verifyTrue(testCase, isnan(F.hardExudates.areaDD2), ...
        'Ungradable image returned a numeric exudate area instead of NaN.');
    verifyFalse(testCase, F.anatomy.discFound);
end


function test_discIsExcludedFromLesions(testCase)
    % The optic disc is the brightest object in the image. If it is not
    % excluded it is returned as one enormous hard exudate in EVERY image,
    % which is the classic failure of any brightness-threshold detector.
    img = testCase.TestData.img;
    fov = detectFOV(img);
    disc = locateOpticDisc(img, 'fov', fov);
    v = segmentVessels(img, 'fov', fov, 'discRadiusPx', disc.radius);
    e = segmentExudates(img, struct('fov',fov,'disc',disc,'vesselMask',v.mask));

    [Y, X] = ndgrid(1:size(img,1), 1:size(img,2));
    inDisc = sqrt((X-disc.centre(1)).^2 + (Y-disc.centre(2)).^2) <= disc.radius;
    overlap = nnz(e.hardMask & inDisc) / max(nnz(inDisc), 1);

    verifyLessThan(testCase, overlap, 0.10, sprintf( ...
        ['%.0f%% of the optic disc was labelled hard exudate. The disc must be ' ...
         'excluded before bright-lesion detection.'], 100*overlap));
end


function test_vesselsRemovedFromDarkLesions(testCase)
    % Vessels are dark and elongated. Without subtracting them, the detector
    % returns the whole vascular tree as flame haemorrhages - which is why the
    % pipeline order (vessels BEFORE lesions) is fixed.
    img = testCase.TestData.img;
    fov = detectFOV(img);
    disc = locateOpticDisc(img, 'fov', fov);
    v = segmentVessels(img, 'fov', fov, 'discRadiusPx', disc.radius);

    withVessels = detectDarkLesions(img, struct('fov',fov,'disc',disc,'vesselMask',v.mask));
    without     = detectDarkLesions(img, struct('fov',fov,'disc',disc));

    verifyLessThanOrEqual(testCase, withVessels.haemCount, without.haemCount, ...
        ['Supplying a vessel mask should reduce (or not increase) the ' ...
         'haemorrhage count. If it does not, the mask is not being applied.']);
end


function test_evaluatorRunsAndIsReproducible(testCase)
    % The vessel/exudate numbers were originally produced by throwaway scripts
    % that no longer exist. This pins that they are regenerable.
    R = evaluateSegmentation('vessels', 'limit', 3, 'verbose', false);
    verifyTrue(testCase, isfield(R, 'vessels'));
    verifyGreaterThan(testCase, R.vessels.diceMean, 0.3, ...
        'Vessel Dice collapsed - check segmentVessels or the FOV masking.');
    verifyLessThan(testCase, R.vessels.diceMean, 0.95, ...
        'Vessel Dice implausibly high - suspect the FOV mask is inflating it.');
    verifyNotEmpty(testCase, R.vessels.protocol, ...
        'The evaluation protocol must be recorded alongside the number.');
end
