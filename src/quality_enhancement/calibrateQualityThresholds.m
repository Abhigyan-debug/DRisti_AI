function th = calibrateQualityThresholds(opts)
%CALIBRATEQUALITYTHRESHOLDS  Derive Module 1 gate thresholds from the corpora.
%
%   th = CALIBRATEQUALITYTHRESHOLDS() samples every dataset, measures each
%   image with ASSESSQUALITY, and writes percentile-based thresholds to
%   config/quality_thresholds.json.
%
%   th = CALIBRATEQUALITYTHRESHOLDS(nPerCorpus=120, write=true)
%
%   Why this lives in MATLAB
%   ------------------------
%   tools/profile_image_quality.py produced Phase 0's analysis and is still the
%   right tool for exploration. But thresholds generated in Python have to
%   survive a language boundary to reach the gate, and they did not: the first
%   attempt was off by 255^2 (intensity scale) and then by the FOV-boundary
%   erosion, which together rejected 100% of all four corpora. The definitions
%   now agree to r = 0.97, but a residual ~17% offset remains from resampling
%   filter differences (MATLAB imresize antialiases; PIL does not identically).
%
%   Rather than chase that, the operational thresholds are derived HERE, by the
%   same code that enforces them. No transfer, no drift.
%
%   Percentile policy
%   -----------------
%   Screening is asymmetric: a false reject costs one retake, a false accept
%   sends an ungradeable image into grading to produce a confident wrong answer.
%   Cut-offs are therefore set at the tail of the CURATED corpora - all four
%   were shot by trained operators on mounted cameras, so their worst images are
%   still better than routine handheld PHC captures.
%
%   See also ASSESSQUALITY, GATEIMAGE, LOADQUALITYTHRESHOLDS.

    arguments
        opts.nPerCorpus (1,1) double {mustBePositive} = 120
        opts.write (1,1) logical = true
        opts.seed (1,1) double = 0
    end

    cfg = drishti_paths();
    rng(opts.seed);

    corpora = { ...
        'APTOS',     cfg.aptos.trainImages; ...
        'IDRiD',     cfg.idrid.gradeTrainImages; ...
        'DRIVE',     cfg.drive.trainImages; ...
        'Messidor2', cfg.messidor2.images};

    sharp = []; illum = []; glare = []; contrast = []; meanInt = []; fovDia = [];
    noise = [];
    band = strings(0,1); corpusOf = strings(0,1);

    for k = 1:size(corpora, 1)
        folder = corpora{k, 2};
        if ~isfolder(folder)
            warning('drishti:missingCorpus', 'Skipping %s - %s not found', corpora{k,1}, folder);
            continue
        end
        L = dir(fullfile(folder, '*'));
        L = L(~[L.isdir]);
        if numel(L) > opts.nPerCorpus
            L = L(randperm(numel(L), opts.nPerCorpus));
        end
        fprintf('  %s: %d images\n', corpora{k,1}, numel(L));

        for i = 1:numel(L)
            try
                img = imread(fullfile(folder, L(i).name));
            catch
                continue
            end
            q = assessQuality(img);
            if ~q.fov.valid
                continue
            end
            sharp(end+1,1)    = q.sharpness.normalised;   %#ok<AGROW>
            noise(end+1,1)    = q.noise;                  %#ok<AGROW>
            illum(end+1,1)    = q.illum.uniformityCV;     %#ok<AGROW>
            glare(end+1,1)    = q.illum.glareFraction;    %#ok<AGROW>
            contrast(end+1,1) = q.illum.contrast;         %#ok<AGROW>
            meanInt(end+1,1)  = q.illum.meanIntensity;    %#ok<AGROW>
            fovDia(end+1,1)   = q.fov.diameter;           %#ok<AGROW>
            band(end+1,1)     = string(q.sharpness.band); %#ok<AGROW>
            corpusOf(end+1,1) = string(corpora{k,1});     %#ok<AGROW>
        end
    end

    if numel(sharp) < 40
        error('drishti:tooFewSamples', ...
            'Only %d images measured - not enough to calibrate.', numel(sharp));
    end

    illum = illum(~isnan(illum));

    % ---- per-band sharpness -------------------------------------------------
    % One global cut-off does not survive a 6.7x resolution range even after FOV
    % normalisation (residual r = -0.43). Each band gets its own percentile.
    bands = ["small", "mid", "large"];
    bandStats = struct();
    for b = bands
        v = sharp(band == b);
        if numel(v) >= 10
            bandStats.(b) = struct( ...
                'n', numel(v), ...
                'reject', prctile(v, 2), ...
                'borderline', prctile(v, 10), ...
                'median', median(v));
        else
            % Too few samples to calibrate this band - fall back to the pooled
            % distribution rather than inventing a number from 3 images.
            bandStats.(b) = struct( ...
                'n', numel(v), ...
                'reject', prctile(sharp, 2), ...
                'borderline', prctile(sharp, 10), ...
                'median', median(sharp));
        end
    end

    th = struct();
    th.x_comment = ['Module 1 gate thresholds, derived by ' ...
        'src/quality_enhancement/calibrateQualityThresholds.m from measured ' ...
        'distributions across APTOS/IDRiD/DRIVE/Messidor-2. Generated by the ' ...
        'same code that enforces them - do not hand-edit. STARTING POINTS ' ...
        'only: all four corpora were captured by trained operators on mounted ' ...
        'cameras, so field images from handheld devices will be worse and a ' ...
        '2nd-percentile cut-off here will reject far more than 2% in ' ...
        'deployment. Re-calibrate against degraded images before trusting the ' ...
        'reject rate.'];
    th.x_generated = string(datetime('now', 'TimeZone', 'UTC', 'Format', 'uuuu-MM-dd HH:mm:ss''Z'''));
    th.x_sample_size = numel(sharp);
    th.canonical_fov_px = 512;

    th.sharpness = struct( ...
        'metric', ['variance of 4-neighbour Laplacian on 0-255 intensities, ' ...
                   'inside the FOV eroded by a 7x7 square, after rescaling so ' ...
                   'the FOV diameter is 512px'], ...
        'reject_below', round(prctile(sharp, 2), 3), ...
        'borderline_below', round(prctile(sharp, 10), 3), ...
        'by_band', bandStats);

    th.illumination_uniformity = struct( ...
        'metric', 'coefficient of variation of 8x8 block means inside the FOV', ...
        'reject_above', round(prctile(illum, 98), 4), ...
        'borderline_above', round(prctile(illum, 90), 4));

    % Glare is ZERO-INFLATED - specular blow-out is genuinely absent from most
    % images, so more than 90% of the sample is exactly 0. A percentile on that
    % distribution collapses to ~0.0001, i.e. "any glare at all rejects", which
    % is meaningless. Percentile calibration only works on metrics that vary
    % continuously; this one needs a physical floor.
    %
    % Floors: the degradation study found the previous floors (0.5%/2%) only
    % rejected synthetic glare at maximum severity - a detection floor of 1.000,
    % i.e. essentially never. Halved so a patch large enough to obscure the
    % macula is caught.
    GLARE_BORDERLINE_FLOOR = 0.002;
    GLARE_REJECT_FLOOR     = 0.008;
    th.glare = struct( ...
        'metric', ['fraction of FOV pixels with ALL channels >= 240/255 ' ...
                   '(achromatic blow-out). NOT any-channel: the red channel ' ...
                   'clips in ordinary fundus images and flagging that rejected ' ...
                   'healthy captures.'], ...
        'x_note', ['Zero-inflated metric - thresholds are physical floors, not ' ...
                   'percentiles. Measured p98 was ' ...
                   num2str(prctile(glare, 98), '%.5f') '.'], ...
        'reject_above', max(GLARE_REJECT_FLOOR, round(prctile(glare, 99.5), 5)), ...
        'borderline_above', max(GLARE_BORDERLINE_FLOOR, round(prctile(glare, 98), 5)));

    th.contrast = struct( ...
        'metric', 'p99 - p1 of luminance inside the FOV, [0,1] scale', ...
        'reject_below', round(prctile(contrast, 2), 4));

    % Noise: percentile-based, but floored. The curated corpora are cleaner
    % than field captures, so a pure p98 would set the bar far too low to ever
    % fire on a real handheld image.
    th.noise = struct( ...
        'metric', ['MAD-based sensor noise estimate inside the FOV, [0,1] ' ...
                   'luminance. Gated separately because noise RAISES the ' ...
                   'sharpness score (rho = +0.67) and is otherwise invisible.'], ...
        'reject_above', max(0.030, round(prctile(noise, 99), 4)), ...
        'borderline_above', max(0.012, round(prctile(noise, 90), 4)));

    th.exposure = struct( ...
        'metric', 'mean luminance inside the FOV, [0,1] scale', ...
        'x_note', ['These are physical limits, not percentiles. A retina ' ...
                   'averaging below 0.08 or above 0.75 is unreadable ' ...
                   'regardless of what the curated corpora contain.'], ...
        'dark_reject', 0.08, ...
        'bright_reject', 0.75, ...
        'dark_fraction_reject', 0.35);

    th.fov_coverage = struct( ...
        'x_WARNING', ['NOT a gate. FOV coverage is a camera/crop fingerprint, ' ...
                      'not a quality signal - see the per-corpus medians. A ' ...
                      'threshold calibrated on one corpus rejects another ' ...
                      'wholesale. Framing is judged via fov.truncated instead.'], ...
        'per_corpus_median', perCorpusMedian(corpusOf, fovDia));

    % ---- report -------------------------------------------------------------
    fprintf('\n  n = %d images\n', numel(sharp));
    fprintf('  sharpness  reject < %.2f   borderline < %.2f   median %.2f\n', ...
        th.sharpness.reject_below, th.sharpness.borderline_below, median(sharp));
    for b = bands
        s = bandStats.(b);
        fprintf('    %-6s n=%-4d reject < %7.2f  borderline < %7.2f  median %7.2f\n', ...
            b, s.n, s.reject, s.borderline, s.median);
    end
    fprintf('  illum CV   reject > %.4f   borderline > %.4f\n', ...
        th.illumination_uniformity.reject_above, th.illumination_uniformity.borderline_above);
    fprintf('  glare      reject > %.5f   borderline > %.5f\n', ...
        th.glare.reject_above, th.glare.borderline_above);
    fprintf('  contrast   reject < %.4f\n', th.contrast.reject_below);

    if opts.write
        out = fullfile(cfg.projectRoot, 'config', 'quality_thresholds.json');
        fid = fopen(out, 'w');
        fprintf(fid, '%s', jsonencode(th, 'PrettyPrint', true));
        fclose(fid);
        fprintf('\n  written -> config/quality_thresholds.json\n');
    end
end


function s = perCorpusMedian(corpusOf, fovDia)
    s = struct();
    for c = unique(corpusOf)'
        s.(char(c)) = round(median(fovDia(corpusOf == c)), 1);
    end
end
