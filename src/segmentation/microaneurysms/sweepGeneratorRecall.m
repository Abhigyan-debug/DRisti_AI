function R = sweepGeneratorRecall(opts)
%SWEEPGENERATORRECALL  How far can threshSD be pushed before rebuilding candidates?
%
%   R = SWEEPGENERATORRECALL() runs the MA/haemorrhage candidate generator at
%   several threshSD values over the IDRiD segmentation-train set and reports
%   recall (the ceiling a stage-2 classifier could ever reach) and candidate
%   volume (the classifier's workload), WITHOUT writing any patches to disk.
%
%   Exists to answer one question cheaply before paying for a full
%   BUILDCANDIDATEDATASET + TRAINCANDIDATECLASSIFIER cycle at a new threshold.
%
%   ONE IMAGE IN MEMORY AT A TIME
%   -----------------------------
%   This used to pre-compute every image's context up front and hold all of
%   them for the duration of the sweep:
%
%       ctxs = cell(n,1); imgs = cell(n,1); gts = cell(n,1);
%
%   On IDRiD that is 53 frames at 4288x2848x3 uint8 (36 MB each) plus, per
%   frame, an FOV mask, a vessel mask and a ground-truth mask (12 MB each as
%   logicals) - about 4 GB resident before a single candidate is generated, on
%   a machine with 15.7 GB total. REBUILDDARKLESIONDETECTORS then calls this
%   twice in a row, once per channel, so the second call started while the
%   first call's arrays were still being reclaimed.
%
%   The loops are now image-outer / threshold-inner. Every image still has its
%   context computed exactly once and reused across all thresholds, so the
%   arithmetic and the number of DETECTDARKLESIONS calls are unchanged - only
%   the lifetime of the buffers is. Peak memory is now one image's worth
%   instead of the whole split's.
%
%   The reported numbers are identical: DETECTDARKLESIONS is deterministic and
%   holds no state across calls, so visiting (image, threshold) pairs in a
%   different order cannot change any of them.
%
%   See also BUILDCANDIDATEDATASET, DETECTDARKLESIONS, REBUILDDARKLESIONDETECTORS.

    arguments
        opts.lesion (1,:) char {mustBeMember(opts.lesion,{'microaneurysms','haemorrhages'})} = 'microaneurysms'
        opts.threshSDs (1,:) double = [0.75 1.0 1.25 1.5 2.0]
        opts.limit (1,1) double = Inf
        % Passed through so the sweep measures the ceiling of the SAME
        % generator configuration the rebuild will then build patches from.
        opts.fragmentRejection (1,1) logical = true
    end

    cfg = drishti_paths();
    switch opts.lesion
        case 'microaneurysms', sub = '1. Microaneurysms'; suf = '_MA.tif'; fld = 'maMask';
        case 'haemorrhages',   sub = '2. Haemorrhages';   suf = '_HE.tif'; fld = 'haemMask';
    end
    maskDir = fullfile(cfg.idrid.segTrainMasks, sub);
    L = dir(fullfile(maskDir, ['*' suf]));
    n = min(numel(L), opts.limit);

    thresholds = opts.threshSDs;
    nT = numel(thresholds);

    % Rows are thresholds, columns are images. NaN means "this image was
    % skipped", which keeps it out of the means rather than scoring it zero.
    recall = nan(nT, n);
    nCand  = nan(nT, n);
    nTrue  = nan(1, n);

    for k = 1:n
        base = erase(L(k).name, suf);
        ip = fullfile(cfg.idrid.segTrainImages, [base '.jpg']);
        if ~isfile(ip), continue; end

        img = imread(ip);
        gt = imread(fullfile(maskDir, L(k).name));
        if ndims(gt) == 3, gt = gt(:,:,1); end

        % Context depends only on the image, not on threshSD, so it is built
        % once here and reused by every threshold below.
        fov = detectFOV(img);
        disc = locateOpticDisc(img, 'fov', fov);
        v = segmentVessels(img, 'fov', fov, 'discRadiusPx', disc.radius);
        ctx = struct('fov', fov, 'disc', disc, 'vesselMask', v.mask);
        clear v

        gtMask = (gt > 0) & fov.mask;
        clear gt
        ccG = bwconncomp(gtMask, 8);
        nTrue(k) = ccG.NumObjects;

        for ti = 1:nT
            d = detectDarkLesions(img, ctx, 'threshSD', thresholds(ti), ...
                'fragmentRejection', opts.fragmentRejection);
            cand = d.(fld) & ctx.fov.mask;

            hit = 0;
            for q = 1:ccG.NumObjects
                if any(cand(ccG.PixelIdxList{q})), hit = hit + 1; end
            end
            recall(ti, k) = hit / max(ccG.NumObjects, 1);

            ccC = bwconncomp(cand, 8);
            nCand(ti, k) = ccC.NumObjects;
            clear d cand ccC
        end

        clear img ctx fov disc gtMask ccG
        fprintf('  image %d/%d\n', k, n);
    end

    R = table();
    for ti = 1:nT
        R = [R; table(thresholds(ti), mean(recall(ti,:), 'omitnan'), ...
            sum(nCand(ti,:), 'omitnan'), sum(nTrue, 'omitnan'), ...
            mean(nCand(ti,:), 'omitnan'), 'VariableNames', ...
            {'threshSD','recall','totalCandidates','totalTrue','candidatesPerImage'})]; %#ok<AGROW>
        fprintf('  threshSD %.2f -> recall %.3f | %d candidates total (%.0f/image) vs %d true\n', ...
            R.threshSD(end), R.recall(end), R.totalCandidates(end), ...
            R.candidatesPerImage(end), R.totalTrue(end));
    end
end
