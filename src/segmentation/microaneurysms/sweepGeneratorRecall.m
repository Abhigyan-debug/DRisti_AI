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
%   See also BUILDCANDIDATEDATASET, DETECTDARKLESIONS.

    arguments
        opts.lesion (1,:) char {mustBeMember(opts.lesion,{'microaneurysms','haemorrhages'})} = 'microaneurysms'
        opts.threshSDs (1,:) double = [0.75 1.0 1.25 1.5 2.0]
        opts.limit (1,1) double = Inf
    end

    cfg = drishti_paths();
    switch opts.lesion
        case 'microaneurysms', sub = '1. Microaneurysms'; suf = '_MA.tif'; fld = 'maMask';
        case 'haemorrhages',   sub = '2. Haemorrhages';   suf = '_HE.tif'; fld = 'haemMask';
    end
    maskDir = fullfile(cfg.idrid.segTrainMasks, sub);
    L = dir(fullfile(maskDir, ['*' suf]));
    n = min(numel(L), opts.limit);

    % Pre-compute the per-image context ONCE (disc/vessels/FOV do not depend on
    % threshSD), then re-run only the cheap thresholding step per sweep value.
    ctxs = cell(n,1); imgs = cell(n,1); gts = cell(n,1);
    for k = 1:n
        base = erase(L(k).name, suf);
        ip = fullfile(cfg.idrid.segTrainImages, [base '.jpg']);
        if ~isfile(ip), continue; end
        img = imread(ip);
        gt = imread(fullfile(maskDir, L(k).name));
        if ndims(gt) == 3, gt = gt(:,:,1); end
        fov = detectFOV(img);
        disc = locateOpticDisc(img, 'fov', fov);
        v = segmentVessels(img, 'fov', fov, 'discRadiusPx', disc.radius);
        imgs{k} = img; gts{k} = (gt > 0) & fov.mask;
        ctxs{k} = struct('fov', fov, 'disc', disc, 'vesselMask', v.mask);
        fprintf('  context %d/%d\n', k, n);
    end

    R = table();
    for t = opts.threshSDs
        recall = nan(n,1); nCand = nan(n,1); nTrue = nan(n,1);
        for k = 1:n
            if isempty(ctxs{k}), continue; end
            d = detectDarkLesions(imgs{k}, ctxs{k}, 'threshSD', t);
            cand = d.(fld) & ctxs{k}.fov.mask;
            gt = gts{k};
            ccG = bwconncomp(gt, 8);
            hit = 0;
            for q = 1:ccG.NumObjects
                if any(cand(ccG.PixelIdxList{q})), hit = hit + 1; end
            end
            recall(k) = hit / max(ccG.NumObjects, 1);
            nTrue(k) = ccG.NumObjects;
            ccC = bwconncomp(cand, 8);
            nCand(k) = ccC.NumObjects;
        end
        R = [R; table(t, mean(recall,'omitnan'), sum(nCand,'omitnan'), sum(nTrue,'omitnan'), ...
            mean(nCand,'omitnan'), 'VariableNames', ...
            {'threshSD','recall','totalCandidates','totalTrue','candidatesPerImage'})]; %#ok<AGROW>
        fprintf('  threshSD %.2f -> recall %.3f | %d candidates total (%.0f/image) vs %d true\n', ...
            t, R.recall(end), R.totalCandidates(end), R.candidatesPerImage(end), R.totalTrue(end));
    end
end
