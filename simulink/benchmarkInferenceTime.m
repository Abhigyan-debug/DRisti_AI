function R = benchmarkInferenceTime(opts)
%BENCHMARKINFERENCETIME  Measure per-image AI service time for the throughput model.
%
%   R = BENCHMARKINFERENCETIME() times RUNDRISHTIPIPELINE over IDRiD images and
%   reports the per-stage breakdown that Module 5 needs as its Stage-4 service
%   time.
%
%   R = BENCHMARKINFERENCETIME(n=12, warmup=2)
%
%   WHY THIS EXISTS
%   ---------------
%   config/telemedicine_parameters.json carries
%       ai_processing.inference_time_per_image_s = null, confidence: PENDING
%   R3 deliberately left it unmeasured rather than guessing. Meanwhile
%   simulink/screening_params.m hardcoded 0.120 s "per image on server GPU",
%   which is a CNN forward pass, not what the deployed pipeline actually costs:
%   the quality gate, Module 2's classical detectors (disc, vessels, fovea,
%   exudates, dark lesions) and Grad-CAM all run per image too, and they
%   dominate. Sizing compute from the forward pass alone understates the real
%   requirement by roughly two orders of magnitude.
%
%   WHAT IS REPORTED, AND WHY THE SPLIT MATTERS
%   -------------------------------------------
%   Two service times, because they correspond to two deployable configurations
%   and Phase 5 is supposed to output a deployment recommendation:
%
%     full        quality gate + Module 2 lesion features + grading + Grad-CAM.
%                 This is what RUNDRISHTIPIPELINE does today and what produces
%                 an explainable report.
%     gradeOnly   quality gate + grading, no Module 2, no Grad-CAM. Produces a
%                 referral decision with no lesion evidence and no heatmap.
%
%   Phase 3 measured that lesion features add nothing to the CNN's accuracy
%   (section 3d), and every lesion channel except hard exudates is withheld from
%   the report anyway - so gradeOnly is a real option, not a strawman, and the
%   compute difference between the two is a genuine planning input.
%
%   PROTOCOL. Wall-clock, single process, one image at a time, GPU warm (the
%   first `warmup` images are timed but discarded - the first CUDA call of a
%   session pays one-off context setup). No batching and no parallel workers, so
%   this is a per-node SEQUENTIAL service time. A real deployment batching 4-8
%   images per forward pass would do better on the CNN stage and no better on
%   the classical CV stages, which are the bulk.
%
%   See also RUNDRISHTIPIPELINE, SCREENING_PARAMS, SIMULATE_DISTRICT_THROUGHPUT.

    arguments
        opts.n (1,1) double = 12
        opts.warmup (1,1) double = 2
        opts.verbose (1,1) logical = true
        % Also time the CNN stage explicitly on each device. The classical CV
        % stages (quality gate, Module 2) are CPU-only regardless, so a GPU can
        % only ever accelerate the forward pass and Grad-CAM.
        opts.compareDevices (1,1) logical = true
    end

    cfg = drishti_paths();
    L = dir(fullfile(cfg.idrid.segTrainImages, '*.jpg'));
    n = min(opts.n, numel(L));

    full = nan(n,1); gradeOnly = nan(n,1);
    qGate = nan(n,1); gradeExplain = nan(n,1);

    for k = 1:n
        ip = fullfile(L(k).folder, L(k).name);
        img = imread(ip);

        % --- full pipeline (what runDrishtiPipeline ships today) ----------
        t = tic;
        out = runDrishtiPipeline(img, 'verbose', false);
        full(k) = toc(t);
        if isfield(out.timings, 'qualityGate'), qGate(k) = out.timings.qualityGate; end
        if isfield(out.timings, 'gradeAndExplain'), gradeExplain(k) = out.timings.gradeAndExplain; end

        % --- grading only: quality gate + CNN, no Module 2, no Grad-CAM ---
        t = tic;
        q = processImage(img);
        if q.gradable
            explainGrading(q.image, 'runModule2', false, 'computeCam', false);
        end
        gradeOnly(k) = toc(t);

        if opts.verbose
            fprintf('  %2d/%d  %-14s full %6.2f s | gradeOnly %6.2f s\n', ...
                k, n, L(k).name, full(k), gradeOnly(k));
        end
    end

    % Discard warm-up images from the statistics, keep them in the raw vectors.
    keep = false(n,1); keep(min(opts.warmup,n)+1:end) = true;
    if ~any(keep), keep = true(n,1); end   % n <= warmup: use everything rather than nothing

    R = struct();
    R.n = nnz(keep);
    R.nWarmupDiscarded = nnz(~keep);
    R.fullSec         = median(full(keep), 'omitnan');
    R.fullSecMean     = mean(full(keep), 'omitnan');
    R.fullSecStd      = std(full(keep), 'omitnan');
    R.gradeOnlySec    = median(gradeOnly(keep), 'omitnan');
    R.qualityGateSec  = median(qGate(keep), 'omitnan');
    R.gradeExplainSec = median(gradeExplain(keep), 'omitnan');
    R.raw = table(string({L(1:n).name})', full, gradeOnly, keep, ...
        'VariableNames', {'image','fullSec','gradeOnlySec','countedInStats'});
    R.protocol = ['Wall-clock, sequential, single process, warm; first ' ...
        num2str(opts.warmup) ' images discarded. Per-image SERVICE time, not throughput.'];

    % --- which device is the pipeline ACTUALLY using? ----------------------
    % explainGrading builds a plain CPU dlarray, so predict() runs on the CPU
    % even when a GPU is present. An earlier version of this benchmark labelled
    % its numbers "dev GPU RTX 5050" on the strength of the GPU merely existing,
    % which put a mislabelled figure into the parameter contract. Measure both
    % devices explicitly rather than inferring from hardware.
    R.devices = struct('measured', false);
    if opts.compareDevices
        R.devices = compareCnnDevices(fullfile(L(1).folder, L(1).name));
    end


    if opts.verbose
        fprintf('\n  ===== AI SERVICE TIME (n=%d, %d warm-up discarded) =====\n', ...
            R.n, R.nWarmupDiscarded);
        fprintf('  full pipeline        %6.2f s/image  (mean %.2f, sd %.2f)\n', ...
            R.fullSec, R.fullSecMean, R.fullSecStd);
        fprintf('    of which quality gate  %6.2f s\n', R.qualityGateSec);
        fprintf('    of which grade+explain %6.2f s\n', R.gradeExplainSec);
        fprintf('  grading only         %6.2f s/image  (%.1fx faster)\n', ...
            R.gradeOnlySec, R.fullSec / max(R.gradeOnlySec, eps));
        fprintf('\n  screening_params.m assumed 0.120 s/image -> understates the\n');
        fprintf('  full pipeline by %.0fx. Compute sizing must use a measured number.\n', ...
            R.fullSec / 0.120);

        if R.devices.measured
            fprintf('\n  --- CNN stage, per device (classical CV is CPU-only either way) ---\n');
            fprintf('    forward pass  CPU %6.3f s | GPU %6.3f s\n', ...
                R.devices.cpuForwardSec, R.devices.gpuForwardSec);
            fprintf('    forward+CAM   CPU %6.3f s | GPU %6.3f s\n', ...
                R.devices.cpuForwardCamSec, R.devices.gpuForwardCamSec);
            fprintf('    pipeline as shipped runs the CNN on: %s\n', R.devices.shippedDevice);
            fprintf('    => the %.2f s/image above is a %s figure.\n', ...
                R.fullSec, upper(R.devices.shippedDevice));
        end

    end
end


% ------------------------------------------------------------------ helpers

function D = compareCnnDevices(imagePath)
%COMPARECNNDEVICES  Time the CNN stage on CPU and on GPU, explicitly.
%
%   Only the forward pass and Grad-CAM can move to a GPU. The quality gate and
%   Module 2 are classical CV on the CPU whatever hardware is present, so the
%   GPU speed-up available to this pipeline is bounded by the CNN's share of
%   total time - which the breakdown above shows is the minority of it.

    D = struct('measured', false);
    cfg = drishti_paths();
    mf = fullfile(cfg.modelsDir, 'baseline_grader.mat');
    if ~isfile(mf), return; end
    S = load(mf);
    net = S.trainedNet;
    sz = S.meta.inputSize;

    img = imread(imagePath);
    prepped = imresize(img, sz(1:2));
    Xc = dlarray(im2single(prepped), 'SSCB');

    % --- CPU ---------------------------------------------------------------
    predict(net, Xc);                                   % warm
    t = tic; for i = 1:3, Yc = predict(net, Xc); end     %#ok<NASGU>
    D.cpuForwardSec = toc(t) / 3;

    t = tic;
    for i = 1:3
        Y = predict(net, Xc); [~, gi] = max(extractdata(Y));
        gradCAM(net, Xc, gi);
    end
    D.cpuForwardCamSec = toc(t) / 3;

    % --- GPU ---------------------------------------------------------------
    D.gpuForwardSec = NaN; D.gpuForwardCamSec = NaN;
    if gpuDeviceCount('available') > 0
        try
            Xg = dlarray(gpuArray(im2single(prepped)), 'SSCB');
            predict(net, Xg); wait(gpuDevice);           % warm
            t = tic; for i = 1:3, predict(net, Xg); end
            wait(gpuDevice); D.gpuForwardSec = toc(t) / 3;

            t = tic;
            for i = 1:3
                Y = predict(net, Xg); [~, gi] = max(gather(extractdata(Y)));
                gradCAM(net, Xg, gi);
            end
            wait(gpuDevice); D.gpuForwardCamSec = toc(t) / 3;
        catch ME
            warning('drishti:gpuBenchFailed', 'GPU timing failed: %s', ME.message);
        end
    end

    % What does the SHIPPED code path actually use? explainGrading passes a CPU
    % dlarray, so unless that changes, the answer is CPU.
    D.shippedDevice = 'cpu';
    D.shippedDeviceNote = ['explainGrading.m builds X = dlarray(im2single(...)) ' ...
        'with no gpuArray, so predict() executes on the CPU regardless of the ' ...
        'GPU being present. Moving to GPU would require an explicit gpuArray.'];
    D.measured = true;
end
