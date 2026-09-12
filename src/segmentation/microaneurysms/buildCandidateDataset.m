function D = buildCandidateDataset(opts)
%BUILDCANDIDATEDATASET  Labelled candidate patches for a false-positive classifier.
%
%   D = BUILDCANDIDATEDATASET() runs the existing candidate generator over the
%   IDRiD lesion-segmentation set and labels every candidate by overlap with the
%   expert mask. Saves patches to <dataRoot>/_cache/ma_candidates/.
%
%   D = BUILDCANDIDATEDATASET(lesion="microaneurysms"|"haemorrhages", ...
%                             patchPx=48, limit=Inf)
%
%   WHY THIS IS THE RIGHT SHAPE OF FIX
%   ----------------------------------
%   The current pipeline is:
%
%       fundus -> candidate generation -> "microaneurysm"
%
%   Measured, that yields recall 0.089 / precision 0.021, and a threshold sweep
%   showed no operating point rescues it. The generator is not the problem in
%   isolation - it is that a candidate is being reported as a diagnosis.
%
%   The two-stage form separates them:
%
%       fundus -> candidates -> CNN false-positive classifier -> lesion
%
%   This function produces the training data for that second stage. It does NOT
%   change any detector, so nothing downstream shifts until a classifier is
%   actually trained and wired in.
%
%   LABELLING RULE
%   --------------
%   A candidate is POSITIVE if its pixels overlap the expert mask at all. Centre
%   distance was rejected as a rule: these objects are a few pixels across and
%   the generator's centroid can sit a pixel or two off a true lesion it has
%   genuinely found, which would mislabel a correct detection as a false
%   positive and teach the classifier the opposite of the intended lesson.
%
%   THE CEILING THIS IMPLIES
%   ------------------------
%   A false-positive classifier can only discard candidates - it can never
%   recover a lesion the generator missed. Measured generator recall is 0.089
%   for microaneurysms, so **0.089 is the hard ceiling** on final recall no
%   matter how good the classifier is. Improving recall requires a more
%   sensitive generator (and hence more false positives for the classifier to
%   remove), which is the natural next experiment. Precision is what this stage
%   can realistically fix.
%
%   See also DETECTDARKLESIONS, EVALUATESEGMENTATION.

    arguments
        opts.lesion (1,:) char {mustBeMember(opts.lesion,{'microaneurysms','haemorrhages'})} = 'microaneurysms'
        opts.patchPx (1,1) double = 48
        opts.limit (1,1) double = Inf
        opts.threshSD (1,1) double = 1.5   % generous: recall ceiling matters more
                                           % than precision at this stage
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    switch opts.lesion
        case 'microaneurysms', sub = '1. Microaneurysms'; suf = '_MA.tif'; fld = 'maMask';
        case 'haemorrhages',   sub = '2. Haemorrhages';   suf = '_HE.tif'; fld = 'haemMask';
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
        d = fullfile(outDir, c);
        if ~isfolder(d), mkdir(d); end
    end

    nPos = 0; nNeg = 0; genRecall = nan(n,1);
    half = floor(opts.patchPx/2);

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
            'threshSD', opts.threshSD);

        cand = d.(fld) & fov.mask;
        cc = bwconncomp(cand, 8);
        stats = regionprops(cc, 'Centroid');

        % How many TRUE lesions did the generator touch? This is the ceiling.
        ccG = bwconncomp(gt & fov.mask, 8);
        hit = 0;
        for q = 1:ccG.NumObjects
            if any(cand(ccG.PixelIdxList{q})), hit = hit + 1; end
        end
        genRecall(k) = hit / max(ccG.NumObjects, 1);

        for q = 1:cc.NumObjects
            isPos = any(gt(cc.PixelIdxList{q}));
            ctr = round(stats(q).Centroid);
            r1 = ctr(2)-half; r2 = ctr(2)+half-1;
            c1 = ctr(1)-half; c2 = ctr(1)+half-1;
            if r1 < 1 || c1 < 1 || r2 > size(img,1) || c2 > size(img,2)
                continue    % patch would need padding; skip rather than invent pixels
            end
            patch = img(r1:r2, c1:c2, :);

            if isPos
                nPos = nPos + 1;
                imwrite(patch, fullfile(outDir, 'pos', sprintf('%s_%04d.png', base, q)));
            else
                nNeg = nNeg + 1;
                imwrite(patch, fullfile(outDir, 'neg', sprintf('%s_%04d.png', base, q)));
            end
        end

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

    if opts.verbose
        fprintf('\n  candidate dataset: %s\n', opts.lesion);
        fprintf('    %d positive / %d negative  (%.1f%% positive)\n', ...
            nPos, nNeg, 100*nPos/max(nPos+nNeg,1));
        fprintf('    GENERATOR RECALL %.3f  <- hard ceiling on final recall;\n', D.generatorRecall);
        fprintf('      a false-positive classifier can only discard candidates,\n');
        fprintf('      never recover a lesion the generator never proposed.\n');
        fprintf('    -> %s\n', outDir);
    end
end
