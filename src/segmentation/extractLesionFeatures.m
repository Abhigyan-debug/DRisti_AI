function F = extractLesionFeatures(img, opts)
%EXTRACTLESIONFEATURES  Module 2 end to end: image -> the feature contract.
%
%   F = EXTRACTLESIONFEATURES(img) runs every detector and returns the struct
%   defined in config/lesion_features.json. This is the ONLY function Module 3
%   should call.
%
%   F = EXTRACTLESIONFEATURES(img, runQualityGate=true, imageName=..., ...
%                             sourceDataset=...)
%
%   Order matters and is not arbitrary
%   ----------------------------------
%     1. quality   - optional Module 1 gate; a rejected image gets no features
%     2. disc      - anchors every spatial measurement
%     3. vessels   - needed to reject vessels from the lesion detectors
%     4. fovea     - needs the disc for anatomy and vessels for the avascular zone
%     5. lesions   - need all of the above
%     6. neovasc   - needs vessels
%
%   Running lesion detection before vessel segmentation returns the entire
%   vascular tree as flame haemorrhages, which is why this order is fixed.
%
%   EVERY SPATIAL VALUE IS IN DISC DIAMETERS. See the contract file for why:
%   a pixel-denominated feature encodes camera model across our 6.7x resolution
%   range, and Phase 3 would learn which dataset an image came from rather than
%   whether the patient has disease.
%
%   HONEST STATUS
%   -------------
%   Every detector here is classical - morphology, matched filtering, shape
%   rules - with no learned component. They were written against a same-day
%   deadline to make the feature vector exist so Phase 3 is unblocked. None is
%   benchmark-competitive, and the microaneurysm channel in particular should
%   be treated as weak (best-ever AUPR on this task is 0.50, and that was a CNN
%   ensemble). Report per-lesion numbers individually rather than implying the
%   whole module performs at the level of its best channel.
%
%   See also LOCATEOPTICDISC, SEGMENTVESSELS, SEGMENTEXUDATES,
%   DETECTDARKLESIONS, DETECTNEOVASCULARIZATION.

    arguments
        img (:,:,:) {mustBeNumeric}
        opts.runQualityGate (1,1) logical = true
        opts.imageName (1,:) char = ''
        opts.sourceDataset (1,:) char = 'unknown'
        opts.skipNeovasc (1,1) logical = false
    end

    t0 = tic;
    F = struct();

    % ---- 1. quality -------------------------------------------------------
    workImg = img;
    if opts.runQualityGate
        r = processImage(img);
        F.quality = struct('decision', r.decision, 'enhanced', r.enhanced, ...
            'sharpnessNormalised', r.before.sharpness.normalised, ...
            'illumUniformityCV', r.before.illum.uniformityCV, ...
            'noise', r.before.noise);
        if ~r.gradable
            % An ungradable image gets NO lesion features. Returning zeros
            % would be indistinguishable from a healthy retina, which is the
            % most dangerous possible confusion in a screening pipeline.
            F = fillUngradable(F, opts, toc(t0));
            return
        end
        workImg = r.image;
        fov = r.before.fov;
    else
        F.quality = struct('decision', 'not_assessed', 'enhanced', false, ...
            'sharpnessNormalised', NaN, 'illumUniformityCV', NaN, 'noise', NaN);
        fov = detectFOV(workImg);
    end

    % ---- 2. optic disc ----------------------------------------------------
    disc = locateOpticDisc(workImg, 'fov', fov);

    % ---- 3. vessels -------------------------------------------------------
    v = segmentVessels(workImg, 'fov', fov, 'discRadiusPx', disc.radius);

    % ---- 4. fovea ---------------------------------------------------------
    fovea = locateFovea(workImg, disc, 'vesselMask', v.mask);

    ctx = struct('fov', fov, 'disc', disc, 'vesselMask', v.mask, 'fovea', fovea);

    % ---- 5. lesions -------------------------------------------------------
    ex = segmentExudates(workImg, ctx);
    % Stage-2 classifiers were trained and measured but never connected to the
    % production path - every report until now ran stage 1 alone. Empty when the
    % models are absent, which leaves the old single-stage behaviour intact.
    dk = detectDarkLesions(workImg, ctx, ...
        'candidateClassifier', loadCandidateClassifiers());

    % ---- 6. neovascularization -------------------------------------------
    if opts.skipNeovasc
        nv = struct('suspectedAtDisc', false, 'suspectedElsewhere', false, ...
                    'vesselTortuosityIndex', 0, 'abnormalVesselDensityDD2', 0);
    else
        nv = detectNeovascularization(workImg, ctx);
    end

    % ---- assemble the contract -------------------------------------------
    F.anatomy = struct( ...
        'discFound', disc.confidence > 0, ...
        'discCentre', disc.centre, ...
        'discRadiusPx', disc.radius, ...
        'discConfidence', disc.confidence, ...
        'foveaFound', fovea.found, ...
        'foveaCentre', fovea.centre, ...
        'discFoveaDistancePx', fovea.discFoveaDistancePx, ...
        'laterality', fovea.laterality);

    % ---- reliability comes from the MEASUREMENT, never from this file -----
    % These four flags used to be literal constants here, which meant a channel
    % stayed "reliable" until somebody remembered to edit a source file after
    % re-measuring. They are now read from results/lesion_validation.mat, which
    % VALIDATELESIONDETECTORS writes by comparing the held-out IDRiD test split
    % against a bar frozen in config/lesion_validation_thresholds.json. With no
    % validation on this machine every channel reads reliable = false.
    V = loadLesionReliability();

    F.microaneurysms = withReliability(V.microaneurysms, struct( ...
        'count', dk.maCount, ...
        'countWithin1DD', dk.maCountWithin1DD, ...
        'densityPerDD2', dk.maDensityPerDD2, ...
        'meanRadiusDD', 0));

    F.haemorrhages = withReliability(V.haemorrhages, struct( ...
        'count', dk.haemCount, ...
        'areaDD2', dk.haemAreaDD2, ...
        'largestAreaDD2', dk.haemLargestAreaDD2, ...
        'countByType', dk.haemByType));

    F.hardExudates = withReliability(V.hardExudates, struct( ...
        'areaDD2', ex.hardAreaDD2, ...
        'count', ex.hardCount, ...
        'minDistanceToFoveaDD', ex.minDistanceToFoveaDD, ...
        'areaWithin1DDofFovea', ex.areaWithin1DDofFovea));

    F.softExudates = withReliability(V.softExudates, struct( ...
        'areaDD2', ex.softAreaDD2, ...
        'count', ex.softCount));

    % ---- locations, for VALIDATED channels only ---------------------------
    % Item 5 of the report contract: show validated lesions and where they are.
    % A location list is a stronger claim than a count - it says "there, look" -
    % so it is built only for channels that cleared the frozen bar. Distances
    % are in DISC DIAMETERS per the Phase 2 spatial contract; the pixel
    % centroid rides along solely so the report can draw a marker.
    masks = struct('microaneurysms', dk.maMask, 'haemorrhages', dk.haemMask, ...
                   'hardExudates', ex.hardMask, 'softExudates', ex.softMask);
    chNames = fieldnames(masks);
    for ci = 1:numel(chNames)
        cn = chNames{ci};
        if F.(cn).reliable
            F.(cn).locations = lesionLocations(masks.(cn), disc, fovea);
        else
            F.(cn).locations = emptyLocations();
        end
    end

    F.neovascularization = nv;

    F.vessels = struct( ...
        'totalLengthDD', v.totalLengthDD, ...
        'meanCaliberDD', v.meanCaliberDD, ...
        'arcadeAngleDeg', 0);

    F.masks = struct('vessels', v.mask, 'hardExudates', ex.hardMask, ...
        'softExudates', ex.softMask, 'microaneurysms', dk.maMask, ...
        'haemorrhages', dk.haemMask);

    F.x_provenance = struct('imageName', opts.imageName, ...
        'sourceDataset', opts.sourceDataset, 'pipelineVersion', 'phase2-classical', ...
        'elapsedSeconds', toc(t0));
end


function F = fillUngradable(F, opts, elapsed)
%FILLUNGRADABLE  Explicit NaNs, never zeros.
%
%   Zero microaneurysms means "a healthy retina". NaN means "we could not
%   look". Phase 3 must be able to tell those apart, and a zero here would
%   silently teach it that ungradable images are healthy.

    F.anatomy = struct('discFound', false, 'discCentre', [NaN NaN], ...
        'discRadiusPx', NaN, 'discConfidence', 0, 'foveaFound', false, ...
        'foveaCentre', [NaN NaN], 'discFoveaDistancePx', NaN, 'laterality', 'unknown');
    % Same field set as the gradable path - a struct whose shape depends on
    % which branch ran will break any consumer that indexes it uniformly.
    U = struct('reliable', false, 'measured', false, 'precision', NaN, ...
        'recall', NaN, 'f1', NaN, 'n', 0, 'verdict', 'image ungradable - not assessed', ...
        'protocol', 'n/a');
    F.microaneurysms = withReliability(U, struct('count', NaN, 'countWithin1DD', NaN, ...
        'densityPerDD2', NaN, 'meanRadiusDD', NaN));
    F.microaneurysms.locations = emptyLocations();
    F.haemorrhages = withReliability(U, struct('count', NaN, 'areaDD2', NaN, ...
        'largestAreaDD2', NaN, ...
        'countByType', struct('dot', NaN, 'blot', NaN, 'flame', NaN)));
    F.haemorrhages.locations = emptyLocations();
    F.hardExudates = withReliability(U, struct('areaDD2', NaN, 'count', NaN, ...
        'minDistanceToFoveaDD', NaN, 'areaWithin1DDofFovea', NaN));
    F.hardExudates.locations = emptyLocations();
    F.softExudates = withReliability(U, struct('areaDD2', NaN, 'count', NaN));
    F.softExudates.locations = emptyLocations();
    F.neovascularization = struct('suspectedAtDisc', false, ...
        'suspectedElsewhere', false, 'vesselTortuosityIndex', NaN, ...
        'abnormalVesselDensityDD2', NaN);
    F.vessels = struct('totalLengthDD', NaN, 'meanCaliberDD', NaN, 'arcadeAngleDeg', NaN);
    F.masks = struct();
    F.x_provenance = struct('imageName', opts.imageName, ...
        'sourceDataset', opts.sourceDataset, 'pipelineVersion', 'phase2-classical', ...
        'elapsedSeconds', elapsed);
end


function s = withReliability(v, fields)
%WITHRELIABILITY  Attach measured reliability to a channel's feature struct.
%
%   The measurement travels WITH the numbers, in the same struct, so no
%   downstream consumer can read a count without also being handed the evidence
%   that says whether the count means anything.

    s = struct();
    s.reliable = v.reliable;
    s.measured = v.measured;
    s.measuredPrecision = v.precision;   % names kept for existing consumers
    s.measuredRecall = v.recall;
    s.measuredF1 = v.f1;
    s.validationN = v.n;
    s.validationVerdict = v.verdict;
    s.validationProtocol = v.protocol;

    f = fieldnames(fields);
    for k = 1:numel(f)
        s.(f{k}) = fields.(f{k});
    end
end


function L = lesionLocations(mask, disc, fovea, maxN)
%LESIONLOCATIONS  Where the validated lesions are, in disc diameters.
%
%   Distances are in DISC DIAMETERS, per the Phase 2 spatial contract: a pixel
%   distance encodes the camera model across our 6.7x resolution range, so a
%   report quoting pixels would say something different on every camera. The
%   pixel centroid is carried too, but only so the report can draw a marker on
%   the image the clinician is looking at.
%
%   Capped at the largest MAXN lesions. A report listing four hundred
%   coordinates is not evidence a human can check, and the largest are the ones
%   a reviewer can actually find on the image.

    if nargin < 4, maxN = 12; end
    L = emptyLocations();
    if isempty(mask) || ~any(mask(:)), return; end

    dd = disc.radius * 2;
    if ~isfinite(dd) || dd <= 0, return; end

    cc = bwconncomp(mask, 8);
    if cc.NumObjects == 0, return; end
    st = regionprops(cc, 'Centroid', 'Area');

    [~, order] = sort([st.Area], 'descend');
    order = order(1:min(maxN, numel(order)));

    for i = 1:numel(order)
        r = st(order(i));
        c = r.Centroid;
        e = struct();
        e.centroidPx = round(c);
        e.areaDD2 = r.Area / (dd^2);
        e.distanceToDiscDD = norm(c - disc.centre) / dd;
        if fovea.found
            e.distanceToFoveaDD = norm(c - fovea.centre) / dd;
        else
            e.distanceToFoveaDD = NaN;
        end
        e.quadrant = quadrantOf(c, disc, fovea);
        L(end+1) = e; %#ok<AGROW>
    end
end


function L = emptyLocations()
%EMPTYLOCATIONS  A 0x1 struct with the right fields, so consumers can index it.
    L = struct('centroidPx', {}, 'areaDD2', {}, 'distanceToDiscDD', {}, ...
               'distanceToFoveaDD', {}, 'quadrant', {});
end


function q = quadrantOf(c, disc, fovea)
%QUADRANTOF  Clinical quadrant, named the way a retina is described.
%
%   Nasal/temporal is defined by which side the disc sits on relative to the
%   fovea - that is what makes the label eye-specific rather than image-specific,
%   and it is the same cue LOCATEFOVEA uses to call laterality.

    q = 'unknown';
    if ~fovea.found || any(~isfinite(disc.centre)), return; end

    vertical = 'superior';
    if c(2) > fovea.centre(2), vertical = 'inferior'; end

    discIsRight = disc.centre(1) > fovea.centre(1);
    towardDisc = (c(1) > fovea.centre(1)) == discIsRight;
    if towardDisc
        horizontal = 'nasal';
    else
        horizontal = 'temporal';
    end
    q = [vertical ' ' horizontal];
end
