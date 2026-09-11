function cacheDir = buildAptosCache(opts)
%BUILDAPTOSCACHE  Pre-resize APTOS once so training is not I/O bound.
%
%   cacheDir = BUILDAPTOSCACHE(size=384) writes FOV-cropped, resized copies of
%   every labelled APTOS image to <dataRoot>/_cache/aptos_<size>/.
%
%   Why this exists
%   ---------------
%   Measured during the smoke run: 18 iterations of batch-8 took 65 s, i.e.
%   ~0.45 s per image, with the GPU mostly idle. The cost is not the network -
%   it is decoding a multi-megabyte PNG, finding the field of view and
%   resizing, repeated EVERY epoch for every image.
%
%   At 2929 training images x 12 epochs that is ~4.4 hours of repeated
%   preprocessing to do identical work 12 times over. Doing it once costs a few
%   minutes and makes every subsequent epoch read a small file.
%
%   The cache is keyed by size and lives under the data root, so it is outside
%   the repo and git-ignored along with everything else in data/.
%
%   Safe to re-run: existing files are skipped.
%
%   See also TRAINBASELINEGRADER, LOADAPTOSSPLIT.

    arguments
        opts.size (1,1) double = 384
        opts.force (1,1) logical = false
    end

    cfg = drishti_paths();
    cacheDir = fullfile(cfg.dataRoot, '_cache', sprintf('aptos_%d', opts.size));
    if ~isfolder(cacheDir)
        mkdir(cacheDir);
    end

    labels = readtable(cfg.aptos.trainLabels);
    names = string(labels.id_code);
    n = numel(names);

    srcDir = cfg.aptos.trainImages;
    sz = opts.size;
    force = opts.force;

    todo = true(n, 1);
    if ~force
        for k = 1:n
            todo(k) = ~isfile(fullfile(cacheDir, names(k) + ".png"));
        end
    end

    if ~any(todo)
        fprintf('  cache already complete: %s\n', cacheDir);
        return
    end
    fprintf('  caching %d of %d images at %dpx -> %s\n', nnz(todo), n, sz, cacheDir);

    idx = find(todo);
    t0 = tic;
    parfor i = 1:numel(idx)
        k = idx(i);
        src = fullfile(srcDir, char(names(k) + ".png"));
        dst = fullfile(cacheDir, char(names(k) + ".png"));
        try
            img = imread(src);
            img = cropToFOVandResize(img, sz);
            imwrite(img, dst);
        catch
            % A single unreadable image must not kill a 3662-image cache job.
            fprintf('  WARN: failed %s\n', names(k));
        end
    end
    fprintf('  cached in %.1f min\n', toc(t0)/60);
end


function img = cropToFOVandResize(img, sz)
%CROPTOFOVANDRESIZE  Remove the black surround, then resize to a square.
%
%   APTOS FOV coverage is trimodal (measured: 0.474 / 0.791 / 0.906), so
%   resizing without cropping gives the network a different effective zoom per
%   camera, which it then has to learn around. Cropping first makes the retina
%   occupy a consistent fraction of every tensor.

    if size(img, 3) == 1
        img = repmat(img, 1, 1, 3);
    end
    gray = 0.299*double(img(:,:,1)) + 0.587*double(img(:,:,2)) + 0.114*double(img(:,:,3));
    lit = gray > 12;
    rows = find(any(lit, 2));
    cols = find(any(lit, 1));
    if numel(rows) > 10 && numel(cols) > 10
        img = img(rows(1):rows(end), cols(1):cols(end), :);
    end
    img = imresize(img, [sz sz]);
end
