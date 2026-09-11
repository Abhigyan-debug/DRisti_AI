function R = evaluateDiscLocalization(split, opts)
%EVALUATEDISCLOCALIZATION  Score the disc localizer against IDRiD ground truth.
%
%   R = EVALUATEDISCLOCALIZATION('train') evaluates on the 413-image training
%   split; 'test' uses the official 103-image test split.
%
%   R = EVALUATEDISCLOCALIZATION(split, limit=50, saveWorst=true)
%
%   Reports mean / median / p90 Euclidean error in pixels, plus the fraction
%   landing inside one disc radius - the clinically meaningful criterion, since
%   a centre inside the disc is good enough to seed segmentation and to
%   normalise disc-to-fovea distance.
%
%   THE BENCHMARK
%   -------------
%   IDRiD challenge winner (DeepDR): **21.07 px mean Euclidean error** on the
%   official test split. Second place (VRT): 33.54 px. Images are 4288x2848.
%
%   Two things to keep honest when comparing:
%     - The benchmark is on the TEST split. A training-split number is not
%       comparable and must never be quoted as if it were.
%     - Those entries were deep networks. A classical method landing in the
%       same range is a genuinely good result; landing at 2-3x is still useful
%       as a Module 2 seed, and should be reported as what it is rather than
%       dressed up.
%
%   See also LOCATEOPTICDISC, LOADIDRIDLANDMARKS.

    arguments
        split (1,:) char {mustBeMember(split, {'train', 'test'})} = 'train'
        opts.limit (1,1) double = Inf
        opts.saveWorst (1,1) logical = false
        opts.verbose (1,1) logical = true
    end

    BENCHMARK_PX = 21.07;   % DeepDR, IDRiD challenge winner (test split)

    T = loadIdridLandmarks(split, 'disc');
    n = min(height(T), opts.limit);

    err = nan(n, 1);
    conf = nan(n, 1);
    radius = nan(n, 1);
    secs = nan(n, 1);

    for k = 1:n
        img = imread(T.imagePath(k));
        d = locateOpticDisc(img);
        err(k) = hypot(d.centre(1) - T.x(k), d.centre(2) - T.y(k));
        conf(k) = d.confidence;
        radius(k) = d.radius;
        secs(k) = d.elapsed;
        if opts.verbose && mod(k, 50) == 0
            fprintf('  %d/%d  running median %.1f px\n', k, n, median(err(1:k), 'omitnan'));
        end
    end

    withinDisc = err <= radius;

    R = struct();
    R.split      = split;
    R.n          = n;
    R.errors     = err;
    R.meanPx     = mean(err, 'omitnan');
    R.medianPx   = median(err, 'omitnan');
    R.p90Px      = prctile(err, 90);
    R.maxPx      = max(err);
    R.withinDiscPct = 100 * mean(withinDisc);
    R.medianSeconds = median(secs, 'omitnan');
    R.benchmarkPx   = BENCHMARK_PX;
    R.table = table(T.imageName(1:n), err, conf, withinDisc, ...
        'VariableNames', {'imageName', 'errorPx', 'confidence', 'withinDisc'});

    if opts.verbose
        fprintf('\n  IDRiD %s split, n = %d\n', split, n);
        fprintf('    mean   %7.2f px\n', R.meanPx);
        fprintf('    median %7.2f px\n', R.medianPx);
        fprintf('    p90    %7.2f px\n', R.p90Px);
        fprintf('    max    %7.2f px\n', R.maxPx);
        fprintf('    centre inside the disc: %.1f%%\n', R.withinDiscPct);
        fprintf('    %.2f s/image\n', R.medianSeconds);
        fprintf('\n    benchmark (DeepDR, test split): %.2f px mean\n', BENCHMARK_PX);
        if strcmp(split, 'test')
            fprintf('    ratio to benchmark: %.2fx\n', R.meanPx / BENCHMARK_PX);
        else
            fprintf('    (training split - NOT comparable to the benchmark)\n');
        end

        % Confidence should predict error, or it is not worth reporting to
        % Module 4. Check rather than assume.
        ok = ~isnan(err) & ~isnan(conf);
        if nnz(ok) > 10
            rho = corr(conf(ok), err(ok), 'type', 'Spearman');
            fprintf('    confidence vs error, Spearman rho = %+.3f', rho);
            if rho < -0.2
                fprintf('  (usable as a reliability signal)\n');
            else
                fprintf('  (NOT predictive - do not surface it)\n');
            end
        end
    end

    if opts.saveWorst
        saveWorstCases(T, R, split);
    end
end


function saveWorstCases(T, R, split)
%SAVEWORSTCASES  Write the 8 worst localisations for visual inspection.
%
%   Looking at failures beat trusting metrics repeatedly in Phase 1 - the
%   thumbnail/native-resolution mistake, the glare metric, the CLAHE speckle.
%   Same discipline here.

    cfg = drishti_paths();
    outDir = fullfile(cfg.resultsDir, 'phase2', ['disc_worst_' split]);
    if isfolder(outDir), rmdir(outDir, 's'); end
    mkdir(outDir);

    [~, order] = sort(R.errors, 'descend', 'MissingPlacement', 'last');
    for i = 1:min(8, numel(order))
        k = order(i);
        img = imread(T.imagePath(k));
        d = locateOpticDisc(img);

        % Crop around the TRUE centre so both marks are visible together
        half = round(d.radius * 4);
        cx = round(T.x(k)); cy = round(T.y(k));
        rr = max(1, cy-half):min(size(img,1), cy+half);
        cc = max(1, cx-half):min(size(img,2), cx+half);
        crop = img(rr, cc, :);

        gtLocal   = [cx - cc(1) + 1, cy - rr(1) + 1];
        predLocal = [d.centre(1) - cc(1) + 1, d.centre(2) - rr(1) + 1];

        crop = insertShape(crop, 'circle', [gtLocal, d.radius], ...
            'Color', 'green', 'LineWidth', 6);
        if all(predLocal > 0) && predLocal(1) <= size(crop,2) && predLocal(2) <= size(crop,1)
            crop = insertShape(crop, 'circle', [predLocal, d.radius], ...
                'Color', 'red', 'LineWidth', 6);
        end
        imwrite(imresize(crop, [400 400]), ...
            fullfile(outDir, sprintf('%02d_%s_%.0fpx.png', i, T.imageName(k), R.errors(k))));
    end
    fprintf('    worst cases -> results/phase2/disc_worst_%s/ (green = truth, red = predicted)\n', split);
end
