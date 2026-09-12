function D = buildCandidateDataset(opts)
%BUILDCANDIDATEDATASET  Labelled candidate patches for a false-positive classifier.
%
%   D = BUILDCANDIDATEDATASET() runs the existing candidate generator over the
%   IDRiD lesion-segmentation set and labels every candidate by overlap with the
%   expert mask. Saves patches to <dataRoot>/_cache/candidates_<lesion>_t<thr>/.
%
%   D = BUILDCANDIDATEDATASET(lesion="microaneurysms"|"haemorrhages", ...
%                             patchPx=48, limit=Inf)
%
%   WHY THIS IS THE RIGHT SHAPE OF FIX
%   ----------------------------------
%   The original pipeline was:
%
%       fundus -> candidate generation -> "microaneurysm"
%
%   i.e. a candidate reported as a diagnosis. The two-stage form separates them:
%
%       fundus -> candidates -> CNN false-positive classifier -> lesion
%
%   This function produces the training data for that second stage. It does NOT
%   change any detector, so nothing downstream shifts until a classifier is
%   actually trained and wired in.
%
%   PATCH GEOMETRY - THE BUG THIS FILE USED TO CARRY
%   ------------------------------------------------
%   Patches were cut here from the FULL-RESOLUTION frame at the full-resolution
%   centroid, while DETECTDARKLESIONS scored them at inference from the
%   WORKING-SCALE frame at the working-scale centroid. On IDRiD that is a ~2.1x
%   difference in how much retina sits behind a 48 px patch, so the classifier
%   was trained on lesions at roughly twice the apparent size it later met -
%   and the discrepancy scaled with image resolution, making it a camera
%   fingerprint rather than a constant offset.
%
%   Both sides now call CUTCANDIDATEPATCHES on the working-scale image that
%   DETECTDARKLESIONS returns via 'returnCandidates'. Read that function's
%   header for the full account, including why edge candidates are clamped
%   rather than skipped - this file used to drop them while the scorer kept
%   them unscored, which let them bypass the filter altogether.
%
%   LABELLING RULE
%   --------------
%   A candidate is POSITIVE if its pixels overlap the expert mask at all. Centre
%   distance was rejected as a rule: these objects are a few pixels across and
%   the generator's centroid can sit a pixel or two off a true lesion it has
%   genuinely found, which would mislabel a correct detection as a false
%   positive and teach the classifier the opposite of the intended lesson.
%
%   The overlap test is applied at WORKING scale against a max-pooled copy of
%   the ground truth. That is not an approximation of the evaluator's test - it
%   is the same test. VALIDATELESIONDETECTORS upsamples the candidate mask with
%   'nearest' and asks whether it touches the full-resolution mask; nearest
%   upsampling maps one working pixel onto a 1/scale square block, so asking
%   whether that block contains a ground-truth pixel answers the same question
%   at the scale the candidate actually lives at. Downsampling the ground truth
%   with 'nearest' instead would silently delete microaneurysms a few pixels
%   across and label real detections as false positives.
%
%   THE CEILING THIS IMPLIES
%   ------------------------
%   A false-positive classifier can only discard candidates - it can never
%   recover a lesion the generator missed. D.generatorRecall is therefore the
%   hard ceiling on final recall no matter how good the classifier is, and it
%   is measured here at full resolution against the untouched ground truth so
%   it stays comparable with VALIDATELESIONDETECTORS. Raising it requires a
%   more sensitive generator (lower threshSD, hence more false positives for
%   the classifier to remove); precision is what this stage can fix.
%
%   Use SWEEPGENERATORRECALL to find a threshSD whose ceiling clears the
%   recall gate BEFORE paying for a build-and-train cycle here.
%
%   See also CUTCANDIDATEPATCHES, DETECTDARKLESIONS, SWEEPGENERATORRECALL,
%   TRAINCANDIDATECLASSIFIER.

    arguments
        opts.lesion (1,:) char {mustBeMember(opts.lesion,{'microaneurysms','haemorrhages'})} = 'microaneurysms'
        opts.patchPx (1,1) double = 48
        opts.limit (1,1) double = Inf
        % Matches TRAINCANDIDATECLASSIFIER's default. These two used to
        % disagree (1.5 here, 0.75 there), so the obvious "run both with no
        % arguments" produced a training call that errored on a missing
        % directory - or worse, silently picked up a stale one from an earlier
        % threshold.
        opts.threshSD (1,1) double = 0.75
        opts.fragmentRejection (1,1) logical = true
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    switch opts.lesion
        case 'microaneurysms', sub = '1. Microaneurysms'; suf = '_MA.tif'; fld = 'maMask'; ch = 'microaneurysms';
        case 'haemorrhages',   sub = '2. Haemorrhages';   suf = '_HE.tif'; fld = 'haemMask'; ch = 'haemorrhages';
    end

    maskDir = fullfile(cfg.idrid.segTrainMasks, sub);
    L = dir(fullfile(maskDir, ['*' suf]));
    n = min(numel(L), opts.limit);

    % Versioned by threshSD. Writing two different threshSD runs into the same
    % folder silently corrupts the dataset: bwconncomp's enumeration order is
    % not stable across runs with different candidate counts, so imwrite's
    % "_%04d" index collides between runs and overwrites a patch from one
    % threshold with an unrelated one from another - sometimes leaving the same
    % filename present in BOTH pos/ and neg/ once relabelled. This happened
    % once during a threshSD 1.5 -> 0.75 rebuild and had to be wiped and redone.
    thrTag = strrep(sprintf('%.2f', opts.threshSD), '.', '');
    outDir = fullfile(cfg.dataRoot, '_cache', sprintf('candidates_%s_t%s', opts.lesion, thrTag));
    for c = ["pos", "neg"]
        dd = fullfile(outDir, c);
        if ~isfolder(dd), mkdir(dd); end
    end

    nPos = 0; nNeg = 0; genRecall = nan(n,1); nEdge = 0;

    for k = 1:n
        base = erase(L(k).name, suf);
        ip = fullfile(cfg.idrid.segTrainImages, [base '.jpg']);
        if ~isfile(ip), continue; end
        img = imread(ip);
        gt = imread(fullfile(maskDir, L(k).name));
        if ndims(gt) == 3, gt = gt(:,:,1); end
        gt = gt > 0;

        fov = detectFOV(img);
        disc = locateOpticDisc(img, 'fov', fov);
        v = segmentVessels(img, 'fov', fov, 'discRadiusPx', disc.radius);
        d = detectDarkLesions(img, struct('fov',fov,'disc',disc,'vesselMask',v.mask), ...
            'threshSD', opts.threshSD, 'fragmentRejection', opts.fragmentRejection, ...
            'returnCandidates', true);

        % --- generator recall, at FULL resolution against untouched GT ------
        % Same masks and same matching VALIDATELESIONDETECTORS uses, so the
        % ceiling this prints is directly comparable to the recall that gets
        % reported. No classifier is loaded on this call, so it is stage 1.
        candFull = d.(fld) & fov.mask;
        ccG = bwconncomp(gt & fov.mask, 8);
        hit = 0;
        for q = 1:ccG.NumObjects
            if any(candFull(ccG.PixelIdxList{q})), hit = hit + 1; end
        end
        genRecall(k) = hit / max(ccG.NumObjects, 1);

        % --- labels and patches, at WORKING scale ---------------------------
        C = d.candidates;
        centroids = C.(ch).centroids;
        if isempty(centroids), continue; end

        % Max-pool the ground truth into working-scale cells: see LABELLING
        % RULE above. r is the side of the block one working pixel covers.
        r = max(1, ceil(1 / max(C.scale, eps)));
        gtWork = imresize(imdilate(gt & fov.mask, strel('square', r)), ...
                          C.workSize, 'nearest');

        ccW = bwconncomp(C.(ch).mask, 8);
        % BWCONNCOMP enumerates by the linear index of a component's first
        % pixel, which is the order DETECTDARKLESIONS collected the centroids
        % in. Assert rather than assume: if these ever diverge, every label is
        % attached to the wrong patch and the classifier trains on noise
        % without anything failing.
        if ccW.NumObjects ~= size(centroids, 1)
            error('drishti:candidateOrderMismatch', ...
                ['%s: %d components in the returned %s mask but %d centroids. ' ...
                 'Patch labels would be misaligned.'], ...
                base, ccW.NumObjects, ch, size(centroids,1));
        end

        patches = cutCandidatePatches(C.workImage, centroids, opts.patchPx);

        for q = 1:ccW.NumObjects
            isPos = any(gtWork(ccW.PixelIdxList{q}));
            % Written as uint8 because the training datastore reads PNGs.
            % TRAINCANDIDATECLASSIFIER's prepPatch runs im2single, recovering
            % the same [0,1] range CUTCANDIDATEPATCHES hands the scorer at
            % inference; the 1/255 quantisation is an order of magnitude below
            % the brightness jitter augPatch applies during training.
            pngPatch = im2uint8(patches(:,:,:,q));
            if isPos
                nPos = nPos + 1;
                imwrite(pngPatch, fullfile(outDir, 'pos', sprintf('%s_%04d.png', base, q)));
            else
                nNeg = nNeg + 1;
                imwrite(pngPatch, fullfile(outDir, 'neg', sprintf('%s_%04d.png', base, q)));
            end
        end
        nEdge = nEdge + countClamped(centroids, C.workSize, opts.patchPx);

        if opts.verbose && mod(k, 10) == 0
            fprintf('    %d/%d images  (%d pos / %d neg so far)\n', k, n, nPos, nNeg);
        end
    end

    D.lesion = opts.lesion;
    D.dir = outDir;
    D.nPositive = nPos;
    D.nNegative = nNeg;
    D.generatorRecall = mean(genRecall, 'omitnan');
    D.patchPx = opts.patchPx;
    D.threshSD = opts.threshSD;
    D.fragmentRejection = opts.fragmentRejection;
    D.nClampedAtEdge = nEdge;
    D.patchGeometry = 'working scale (FOV normalised to 1536 px), via cutCandidatePatches';

    if opts.verbose
        fprintf('\n  candidate dataset: %s\n', opts.lesion);
        fprintf('    %d positive / %d negative  (%.1f%% positive)\n', ...
            nPos, nNeg, 100*nPos/max(nPos+nNeg,1));
        fprintf('    patches cut at WORKING scale (matches inference geometry)\n');
        fprintf('    %d patches clamped at the frame edge (kept, not dropped)\n', nEdge);
        fprintf('    GENERATOR RECALL %.3f  <- hard ceiling on final recall;\n', D.generatorRecall);
        fprintf('      a false-positive classifier can only discard candidates,\n');
        fprintf('      never recover a lesion the generator never proposed.\n');
        fprintf('    -> %s\n', outDir);
    end
end


function c = countClamped(centroids, workSize, patchPx)
%COUNTCLAMPED  How many patches needed replicate padding at the frame edge.
%
%   Reported because it used to be the size of a silent divergence between
%   training (dropped these) and inference (kept them unscored). If this is a
%   large fraction of the candidate set on some dataset, the clamping is worth
%   revisiting; on IDRiD it is the thin band where the FOV meets the top and
%   bottom of the frame.
    half = floor(patchPx/2);
    ctr = round(centroids);
    c = nnz(ctr(:,2)-half < 1 | ctr(:,1)-half < 1 | ...
            ctr(:,2)+half-1 > workSize(1) | ctr(:,1)+half-1 > workSize(2));
end
