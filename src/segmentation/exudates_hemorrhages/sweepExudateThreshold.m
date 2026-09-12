function R = sweepExudateThreshold(opts)
%SWEEPEXUDATETHRESHOLD  Is hard-exudate recall left on the table above precision 0.5?
%
%   R = SWEEPEXUDATETHRESHOLD() re-runs the hard-exudate candidate step at
%   several brightness thresholds (the `median + k*std` cutoff in
%   SEGMENTEXUDATES) against IDRiD ground truth, reporting per-lesion
%   recall/precision at each. The shipped detector fixes k=2.2 with no measured
%   justification for that exact value; this checks whether a lower k trades a
%   little precision for meaningfully more recall while staying above the 0.5
%   display bar - hard exudates is the one channel already fit to show a
%   clinician, so headroom here is the cheapest possible win.
%
%   Does NOT change SEGMENTEXUDATES.m. Read the numbers, then decide.
%
%   See also SEGMENTEXUDATES, EVALUATESEGMENTATION.

    arguments
        opts.ks (1,:) double = [1.4 1.6 1.8 2.0 2.2 2.6]
        opts.limit (1,1) double = Inf
    end

    cfg = drishti_paths();
    exDir = fullfile(cfg.idrid.segTrainMasks, '3. Hard Exudates');
    L = dir(fullfile(exDir, '*.tif'));
    n = min(numel(L), opts.limit);

    % Pre-compute what does not depend on k.
    ctxs = cell(n,1); imgs = cell(n,1); gts = cell(n,1); flats = cell(n,1); valids = cell(n,1);
    scales = nan(n,1); discDiams = nan(n,1);
    for i = 1:n
        base = erase(L(i).name, '_EX.tif');
        ip = fullfile(cfg.idrid.segTrainImages, [base '.jpg']);
        if ~isfile(ip), continue; end
        img = imread(ip);
        gt = imread(fullfile(exDir, L(i).name));
        if ndims(gt) == 3, gt = gt(:,:,1); end

        fov = detectFOV(img);
        disc = locateOpticDisc(img, 'fov', fov);
        v = segmentVessels(img, 'fov', fov, 'discRadiusPx', disc.radius);

        WORK_FOV_PX = 1024;
        scale = min(1, WORK_FOV_PX / fov.diameter);
        small = resizeToDouble(img, scale);
        mask = imresize(fov.mask, scale, 'nearest');
        if size(small,3) ~= 3, small = repmat(small,1,1,3); end
        discR = disc.radius * scale;
        green = small(:,:,2);
        bg = estimateBackground(green, mask, fov.diameter * scale);
        flat = green - bg;
        valid = imerode(mask, strel('disk', max(2, round(discR * 0.10))));
        [Y, X] = ndgrid(1:size(green,1), 1:size(green,2));
        dcx = disc.centre(1) * scale; dcy = disc.centre(2) * scale;
        valid = valid & sqrt((X-dcx).^2 + (Y-dcy).^2) > discR * 1.25;
        vm = imresize(v.mask, size(green), 'nearest');
        vesselDilated = imdilate(vm, strel('disk', 2));

        imgs{i} = img; gts{i} = (gt>0);
        flats{i} = flat; valids{i} = valid & ~vesselDilated;
        scales(i) = scale; discDiams(i) = 2*discR;
        fprintf('  context %d/%d\n', i, n);
    end

    R = table();
    for k = opts.ks
        rec = nan(n,1); prec = nan(n,1); nDet = nan(n,1); nTrue = nan(n,1);
        for i = 1:n
            if isempty(imgs{i}), continue; end
            flat = flats{i}; valid = valids{i};
            vals = flat(valid);
            thr = median(vals) + k * std(vals);
            cand = flat > thr & valid;
            minA = max(4, round((discDiams(i)*0.01)^2));
            cand = bwareaopen(cand, minA);
            cand = imresize(cand, [size(imgs{i},1) size(imgs{i},2)], 'nearest');

            fov = detectFOV(imgs{i});
            pred = cand & fov.mask;
            g = gts{i} & fov.mask;

            ccG = bwconncomp(g, 8); ccP = bwconncomp(pred, 8);
            nTrue(i) = ccG.NumObjects; nDet(i) = ccP.NumObjects;
            hg = 0;
            for c = 1:ccG.NumObjects
                if any(pred(ccG.PixelIdxList{c})), hg = hg+1; end
            end
            hp = 0;
            for c = 1:ccP.NumObjects
                if any(g(ccP.PixelIdxList{c})), hp = hp+1; end
            end
            rec(i) = hg / max(ccG.NumObjects,1);
            prec(i) = hp / max(ccP.NumObjects,1);
        end
        row = table(k, mean(rec,'omitnan'), mean(prec,'omitnan'), ...
            mean(nDet,'omitnan'), mean(nTrue,'omitnan'), ...
            'VariableNames', {'k','recall','precision','meanDetected','meanTrue'});
        R = [R; row]; %#ok<AGROW>
        fprintf('  k=%.1f  (BEFORE hard/soft split, candidates only) recall %.3f  precision %.3f  (%.1f vs %.1f/image)\n', ...
            k, row.recall, row.precision, row.meanDetected, row.meanTrue);
    end
    fprintf('\n  NOTE: this measures the CANDIDATE step before the hard/soft split,\n');
    fprintf('  so precision here is an upper bound on what segmentExudates.m\n');
    fprintf('  actually reports for hard exudates alone (the split only removes\n');
    fprintf('  candidates, moving some to soft, never adds any).\n');
end
