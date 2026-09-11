function q = assessQuality(img, opts)
%ASSESSQUALITY  Score a fundus image on every Module 1 quality dimension.
%
%   q = ASSESSQUALITY(img) returns a struct of measurements. It does NOT decide
%   pass/reject - that is GATEIMAGE's job, kept separate so the thresholds can
%   be re-tuned without re-measuring, and so the metrics can be logged for
%   images that were accepted.
%
%   q = ASSESSQUALITY(img, canonicalFovPx=512) overrides the reference FOV size.
%
%   Returns
%     q.fov          struct from DETECTFOV
%     q.sharpness    struct from MEASURESHARPNESS
%     q.illum        struct from MEASUREILLUMINATION
%     q.sizePx       [height width] of the input
%     q.elapsed      seconds taken - Module 5 needs a real per-image cost, not
%                    a guess, to model AI throughput
%
%   Example
%     img = imread(fullfile(cfg.aptos.trainImages, '000c1434d8d7.png'));
%     q   = assessQuality(img);
%     d   = gateImage(q);
%     fprintf('%s: %s\n', d.decision, d.summary);
%
%   See also GATEIMAGE, ENHANCEIMAGE, DETECTFOV.

    arguments
        img (:,:,:) {mustBeNumeric}
        % 0 means "take it from config/quality_thresholds.json"
        opts.canonicalFovPx (1,1) double {mustBeNonnegative} = 0
    end

    t0 = tic;

    th = loadQualityThresholds();
    canonical = opts.canonicalFovPx;
    if canonical == 0
        canonical = th.canonicalFovPx;
    end

    q.sizePx    = [size(img, 1), size(img, 2)];
    q.fov       = detectFOV(img);
    q.sharpness = measureSharpness(img, q.fov, canonical);
    q.illum     = measureIllumination(img, q.fov);
    q.elapsed   = toc(t0);
end
