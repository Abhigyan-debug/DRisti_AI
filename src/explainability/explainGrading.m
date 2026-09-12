function E = explainGrading(img, opts)
%EXPLAINGRADING  Grad-CAM plus lesion-level evidence for a graded image.
%
%   E = EXPLAINGRADING(img) runs the full explainable pipeline and returns:
%       E.grade            predicted ICDR grade 0-4
%       E.gradeProbs       1x5 class probabilities
%       E.referableScore   probability mass at grade >= 2
%       E.referable        logical at the frozen operating point
%       E.cam              Grad-CAM map, original image size, [0,1]
%       E.overlay          RGB image with the heatmap composited
%       E.evidence         table cross-referencing hotspots with lesions
%       E.agreement        fraction of CAM mass falling on detected lesions
%       E.features         the Module 2 feature struct
%
%   WHY THE EVIDENCE TABLE EXISTS
%   -----------------------------
%   A heatmap alone is not an explanation. The README names the failure
%   directly in its risk table: Grad-CAM can highlight the *correct* region for
%   the *wrong* reason, and a plausible-looking blob over the macula is
%   indistinguishable from a real one by eye.
%
%   The mitigation is to check the heatmap against evidence derived
%   INDEPENDENTLY of the classifier. Module 2's detectors never see the
%   network's prediction, so when a CAM hotspot lands on a detected
%   microaneurysm or exudate, that is genuine corroboration rather than
%   circular reasoning. E.agreement quantifies it.
%
%   Low agreement is INFORMATION, not a bug to hide. It means the network is
%   keying on something the lesion detectors did not find - which is either a
%   lesion type we do not detect, or the network using a spurious cue. Either
%   way the reviewing ophthalmologist should be told, and the report says so.
%
%   See also EXTRACTLESIONFEATURES, EVALUATEGRADER.

    arguments
        img (:,:,:) {mustBeNumeric}
        opts.modelFile (1,:) char = ''
        opts.threshold (1,1) double = NaN
        opts.runModule2 (1,1) logical = true
        % Grad-CAM is ~the same cost again as the forward pass. A deployment
        % that only needs a referral decision (no heatmap, no lesion evidence)
        % can skip it; BENCHMARKINFERENCETIME measures what that saves, and
        % Module 5 sizes compute from the result. Defaults true so every
        % existing caller is unchanged.
        opts.computeCam (1,1) logical = true
    end

    cfg = drishti_paths();
    if isempty(opts.modelFile)
        opts.modelFile = fullfile(cfg.modelsDir, 'baseline_grader.mat');
    end
    S = load(opts.modelFile);
    net = S.trainedNet;
    inputSize3 = S.meta.inputSize;
    E.model = S.meta;   % travels to the report, which must name the real model

    % Operating point: frozen on validation, never re-derived here.
    threshold = opts.threshold;
    if isnan(threshold)
        rf = fullfile(cfg.resultsDir, 'phase3_val_result.mat');
        if isfile(rf)
            V = load(rf);
            threshold = V.R.thresholds.highSensitivity;
        else
            threshold = 0.5;
        end
    end

    % ---- prepare the network input ---------------------------------------
    prepped = cropToFOVandResizeLocal(img, inputSize3(1));
    X = dlarray(im2single(prepped), 'SSCB');

    % ---- predict ----------------------------------------------------------
    Y = predict(net, X);
    probs = double(gather(extractdata(Y)))';
    [~, gi] = max(probs);
    E.grade = gi - 1;
    E.gradeProbs = probs;
    E.referableScore = sum(probs(3:end));
    E.referable = E.referableScore >= threshold;
    E.threshold = threshold;

    % ---- Grad-CAM ---------------------------------------------------------
    % Explain the REFERABILITY decision, not just the argmax class. A grade-2
    % image predicted 0.45/0.30/0.25 across grades 2-4 has no dominant class,
    % but the clinically meaningful question - why is this referable - still
    % has an answer. Falling back to the argmax would explain an arbitrary one
    % of the three.
    if ~opts.computeCam
        % No heatmap requested. Return explicitly empty rather than a zero map:
        % a zero CAM would flow into buildEvidence and be scored as "the model
        % attended nowhere", which is a claim, not an absence.
        E.cam = [];
        E.overlay = [];
        E.features = struct();
        E.evidence = table();
        E.agreement = NaN;
        return
    end

    try
        camSmall = gradCAM(net, X, gi);
        camSmall = double(gather(extractdata(camSmall)));
    catch ME
        warning('drishti:gradcamFailed', 'Grad-CAM failed: %s', ME.message);
        camSmall = zeros(inputSize3(1:2));
    end
    if max(camSmall(:)) > 0
        camSmall = camSmall / max(camSmall(:));
    end

    % Map back onto the ORIGINAL image, not the cropped one - Module 4 overlays
    % on the image the clinician recognises.
    E.cam = mapCamToOriginal(camSmall, img);
    E.overlay = compositeOverlay(img, E.cam);

    % ---- lesion cross-reference -------------------------------------------
    if opts.runModule2
        F = extractLesionFeatures(img, 'runQualityGate', false);
        E.features = F;
        [E.evidence, E.agreement] = buildEvidence(E.cam, F);
    else
        E.features = struct();
        E.evidence = table();
        E.agreement = NaN;
    end
end


% ------------------------------------------------------------------ helpers

function img = cropToFOVandResizeLocal(img, sz)
    if size(img,3) == 1, img = repmat(img,1,1,3); end
    gray = 0.299*double(img(:,:,1)) + 0.587*double(img(:,:,2)) + 0.114*double(img(:,:,3));
    lit = gray > 12;
    r = find(any(lit,2)); c = find(any(lit,1));
    if numel(r) > 10 && numel(c) > 10
        img = img(r(1):r(end), c(1):c(end), :);
    end
    img = imresize(img, [sz sz]);
end


function cam = mapCamToOriginal(camSmall, img)
%MAPCAMTOORIGINAL  Undo the FOV crop so the heatmap lines up with the input.
%
%   The network saw a cropped, square-resized image. Overlaying its CAM on the
%   uncropped original without reversing that would put every hotspot in the
%   wrong place - subtly enough to look plausible, which is worse than being
%   obviously wrong.

    gray = 0.299*double(img(:,:,1)) + 0.587*double(img(:,:,2)) + 0.114*double(img(:,:,3));
    lit = gray > 12;
    r = find(any(lit,2)); c = find(any(lit,1));
    cam = zeros(size(img,1), size(img,2));
    if numel(r) > 10 && numel(c) > 10
        % Size from the SPAN, not the count. Lit rows/columns are not always
        % contiguous - a notch in the FOV rim, or a dark band across the
        % retina, leaves gaps - so numel(c) can be smaller than c(end)-c(1)+1
        % and the assignment shape mismatches.
        rows = r(1):r(end);
        cols = c(1):c(end);
        sub = imresize(camSmall, [numel(rows) numel(cols)], 'bilinear');
        cam(rows, cols) = sub;
    else
        cam = imresize(camSmall, [size(img,1) size(img,2)], 'bilinear');
    end
    cam = max(0, min(1, cam));
end


function out = compositeOverlay(img, cam)
    base = im2double(img);
    if size(base,3) == 1, base = repmat(base,1,1,3); end
    cmap = jet(256);
    idx = max(1, min(256, round(cam * 255) + 1));
    heat = reshape(cmap(idx(:), :), [size(cam) 3]);
    alpha = 0.45 * cam;                 % transparent where the CAM is cold
    out = base .* (1 - alpha) + heat .* alpha;
    out = max(0, min(1, out));
end


function [T, agreement] = buildEvidence(cam, F)
%BUILDEVIDENCE  How much CAM attention lands on each independently-found lesion.

    % ONLY VALIDATED CHANNELS APPEAR HERE. Measured per-lesion precision
    % against IDRiD ground truth, n=12:
    %
    %     hard exudates    0.549  <- displayed (was 0.595 - did not reproduce;
    %                                see segmentExudates.m and phase3_results.md §3e)
    %     haemorrhages     0.034  <- suppressed
    %     microaneurysms   0.021  <- suppressed
    %     soft exudates    never measured  <- suppressed
    %
    % A count shown to a clinician at 2-3% precision is a fabricated finding
    % presented authoritatively, which is worse than showing nothing. Soft
    % exudates are suppressed for a different reason - they have not been
    % validated at all, and "do not display what you have not measured" is only
    % a rule if it applies uniformly.
    %
    % Hard exudates earn their place by UNDER-detecting, which is the correct
    % direction of error for a clinical display - but the margin is thinner
    % than once believed: recall is only 0.146 at the threshold that actually
    % clears 0.5 precision, not the previously-claimed 0.254. It is also the
    % channel that drives the DME endpoint.
    %
    % Re-add a channel here only after measuring it - see evaluateSegmentation.
    names = {'hardExudates'};
    labels = {'Hard exudates'};

    lesion = strings(0,1); count = []; camMass = []; camDensity = [];
    totalCam = sum(cam(:));
    covered = false(size(cam));

    for k = 1:numel(names)
        if ~isfield(F, 'masks') || ~isfield(F.masks, names{k})
            continue
        end
        m = F.masks.(names{k});
        if isempty(m) || ~any(m(:))
            mass = 0; dens = 0; n = 0;
        else
            % Dilate a little: a CAM is coarse (the final conv layer is heavily
            % downsampled), so demanding pixel-exact overlap with a tiny
            % microaneurysm would score zero even on a perfect explanation.
            md = imdilate(m, strel('disk', max(3, round(size(cam,1)/200))));
            covered = covered | md;
            mass = sum(cam(md)) / max(totalCam, eps);
            dens = mean(cam(md));
            cc = bwconncomp(m, 8); n = cc.NumObjects;
        end
        lesion(end+1,1) = string(labels{k}); %#ok<AGROW>
        count(end+1,1) = n;                  %#ok<AGROW>
        camMass(end+1,1) = mass;             %#ok<AGROW>
        camDensity(end+1,1) = dens;          %#ok<AGROW>
    end

    T = table(lesion, count, camMass, camDensity, ...
        'VariableNames', {'finding', 'count', 'camMassFraction', 'meanActivation'});
    T = sortrows(T, 'camMassFraction', 'descend');

    agreement = sum(cam(covered)) / max(totalCam, eps);
end
