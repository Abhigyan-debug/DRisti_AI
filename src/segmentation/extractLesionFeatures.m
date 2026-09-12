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
    dk = detectDarkLesions(workImg, ctx);

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

    % Measured against IDRiD ground truth: recall 0.110, precision 0.022.
    % The flag travels WITH the number so no downstream consumer can treat it
    % as a clinical finding by accident.
    F.microaneurysms = struct( ...
        'reliable', false, ...
        'measuredRecall', 0.110, ...
        'measuredPrecision', 0.022, ...
        'count', dk.maCount, ...
        'countWithin1DD', dk.maCountWithin1DD, ...
        'densityPerDD2', dk.maDensityPerDD2, ...
        'meanRadiusDD', 0);

    % Measured against IDRiD: recall 0.040, precision 0.034 - WORSE than the
    % microaneurysm channel it shares a pipeline with. Its 1.9x count ratio
    % looks plausible, which is exactly the trap: a believable number can be
    % almost entirely wrong.
    F.haemorrhages = struct( ...
        'reliable', false, ...
        'measuredRecall', 0.040, ...
        'measuredPrecision', 0.034, ...
        'count', dk.haemCount, ...
        'areaDD2', dk.haemAreaDD2, ...
        'largestAreaDD2', dk.haemLargestAreaDD2, ...
        'countByType', dk.haemByType);

    % ⚠️ CORRECTED. This was documented as recall 0.254 / precision 0.595 -
    % "the one channel fit to display" - but that number does not reproduce.
    % A fresh, re-runnable EVALUATESEGMENTATION('exudates') at the threshold
    % this module actually shipped with (k=2.2) measures precision 0.441,
    % which does NOT clear the 0.5 display bar. SEGMENTEXUDATES's default
    % threshold has been raised to k=3.0 (the loosest value that clears 0.5
    % with real margin), which is what the numbers below now reflect - but
    % note recall fell from the previously-claimed 0.254 to 0.146 to get
    % there. See segmentExudates.m and docs/phase3_results.md §3e for the
    % full sweep and the flag on the original discrepancy.
    F.hardExudates = struct( ...
        'reliable', true, ...
        'measuredRecall', 0.146, ...
        'measuredPrecision', 0.549, ...
        'areaDD2', ex.hardAreaDD2, ...
        'count', ex.hardCount, ...
        'minDistanceToFoveaDD', ex.minDistanceToFoveaDD, ...
        'areaWithin1DDofFovea', ex.areaWithin1DDofFovea);

    % Never validated against ground truth - IDRiD has soft-exudate masks for
    % only 26 of 54 images and no measurement has been run. Unmeasured is not
    % the same as unreliable, but it is equally unfit to display.
    F.softExudates = struct('reliable', false, 'measuredRecall', NaN, ...
        'measuredPrecision', NaN, 'areaDD2', ex.softAreaDD2, 'count', ex.softCount);

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
    F.microaneurysms = struct('reliable', false, 'measuredRecall', 0.110, ...
        'measuredPrecision', 0.022, 'count', NaN, 'countWithin1DD', NaN, ...
        'densityPerDD2', NaN, 'meanRadiusDD', NaN);
    F.haemorrhages = struct('reliable', false, 'measuredRecall', 0.040, ...
        'measuredPrecision', 0.034, 'count', NaN, 'areaDD2', NaN, ...
        'largestAreaDD2', NaN, ...
        'countByType', struct('dot', NaN, 'blot', NaN, 'flame', NaN));
    F.hardExudates = struct('reliable', true, 'measuredRecall', 0.146, ...
        'measuredPrecision', 0.549, 'areaDD2', NaN, 'count', NaN, ...
        'minDistanceToFoveaDD', NaN, 'areaWithin1DDofFovea', NaN);
    F.softExudates = struct('reliable', false, 'measuredRecall', NaN, ...
        'measuredPrecision', NaN, 'areaDD2', NaN, 'count', NaN);
    F.neovascularization = struct('suspectedAtDisc', false, ...
        'suspectedElsewhere', false, 'vesselTortuosityIndex', NaN, ...
        'abnormalVesselDensityDD2', NaN);
    F.vessels = struct('totalLengthDD', NaN, 'meanCaliberDD', NaN, 'arcadeAngleDeg', NaN);
    F.masks = struct();
    F.x_provenance = struct('imageName', opts.imageName, ...
        'sourceDataset', opts.sourceDataset, 'pipelineVersion', 'phase2-classical', ...
        'elapsedSeconds', elapsed);
end
