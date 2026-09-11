function C = fitCalibrator(opts)
%FITCALIBRATOR  Platt / isotonic calibration for the grader's referable score.
%
%   C = FITCALIBRATOR() fits on the APTOS validation split and saves to
%   models/calibrator.mat.
%
%   C = FITCALIBRATOR(method="platt"|"isotonic", modelFile=...)
%
%   WHAT CALIBRATION DOES AND DOES NOT FIX
%   --------------------------------------
%   A softmax output is a ranking score, not a probability. "0.85" from this
%   network does not mean 85% of such images are referable. Calibration fits a
%   monotone map from score to observed frequency so the number can be shown to
%   a clinician as a confidence and mean something.
%
%   That is worth doing on its own - Module 4's report currently prints a raw
%   softmax labelled "(Platt Scaled)", which is false - but be precise about
%   its limits:
%
%   IT DOES NOT FIX THE MESSIDOR-2 FAILURE. The map is fitted on APTOS, so it
%   inherits APTOS's score distribution. Messidor-2's scores collapse toward
%   zero (median referable 0.0992 vs a 0.4033 threshold), and a monotone map
%   fitted elsewhere cannot undo a domain shift. Measured: sensitivity 90.3%
%   internally, 31.2% on Messidor-2.
%
%   A rank/percentile rule WAS tested as a domain-robust alternative and is
%   also rejected: it lifts Messidor-2 to 82.6% sensitivity but drops IDRiD
%   from 70.9% to 55.7%, because flagging a fixed fraction of images assumes
%   the target prevalence matches the source. It trades a score-scale
%   assumption for a prevalence assumption. Both were measured; neither holds
%   generally. See docs/phase3_results.md.
%
%   So: calibrate for honest confidence reporting. Solve domain shift with
%   domain-robust training and per-site threshold validation, not with a
%   post-hoc map.
%
%   See also EVALUATEGRADER, APPLYCALIBRATION.

    arguments
        opts.method (1,:) char {mustBeMember(opts.method,{'platt','isotonic'})} = 'platt'
        opts.modelFile (1,:) char = ''
        opts.verbose (1,1) logical = true
    end

    cfg = drishti_paths();
    if isempty(opts.modelFile)
        opts.modelFile = fullfile(cfg.modelsDir, 'baseline_grader.mat');
    end

    % Reuse the validation-split scores already computed by evaluateGrader
    % rather than re-running inference.
    S = load(opts.modelFile);
    net = S.trainedNet;
    inputSize3 = S.meta.inputSize;
    cacheDir = fullfile(cfg.dataRoot, '_cache', sprintf('aptos_%d', inputSize3(1)));

    [~, valT] = loadAptosSplit();
    n = height(valT);
    scores = nan(n,1);
    for i = 1:32:n
        j = min(i+31, n);
        X = zeros([inputSize3(1:2) 3 j-i+1], 'single');
        for k = i:j
            im = im2single(imread(fullfile(cacheDir, char(valT.imageName(k) + ".png"))));
            if size(im,3)==1, im = repmat(im,1,1,3); end
            X(:,:,:,k-i+1) = im;
        end
        Y = predict(net, dlarray(X,'SSCB'));
        P = double(gather(extractdata(Y)))';
        scores(i:j) = sum(P(:,3:end), 2);
    end
    truth = double(valT.diagnosis >= 2);

    C = struct('method', opts.method, 'fittedOn', 'APTOS validation split', ...
               'n', n, 'fittedAt', string(datetime('now')));

    switch opts.method
        case 'platt'
            % Logistic regression of label on score. Platt's own
            % recommendation is to fit against smoothed targets rather than
            % hard 0/1, which prevents the fit running away to +/-inf when the
            % classes are cleanly separated - and ours nearly are (AUC 0.989).
            nPos = sum(truth); nNeg = n - nPos;
            tHi = (nPos + 1) / (nPos + 2);
            tLo = 1 / (nNeg + 2);
            target = truth * tHi + (1 - truth) * tLo;

            b = glmfit(scores, target, 'binomial', 'link', 'logit');
            C.b = b(1);
            C.a = b(2);

        case 'isotonic'
            % Monotone step fit via pool-adjacent-violators.
            %
            % CAVEAT: isotonic regression has enough freedom to fit its own
            % training data almost exactly, so the ECE it reports below is
            % ~0.0000 by construction and is NOT evidence of good calibration.
            % Platt's 2-parameter fit cannot do that, which makes its reported
            % improvement the trustworthy one. Prefer Platt unless you have a
            % separate split to measure isotonic honestly.
            [ss, ord] = sort(scores);
            tt = truth(ord);
            yy = pava(tt);
            % Collapse duplicate scores to single knots - interp1 requires
            % distinct sample points, and near-separated scores produce many
            % exact ties at 0 and 1.
            [ux, ia] = unique(ss, 'last');
            C.x = ux;
            C.y = yy(ia);
    end

    % ---- how good is the calibration? ------------------------------------
    cal = applyCalibration(C, scores);
    C.brierBefore = mean((scores - truth).^2);
    C.brierAfter  = mean((cal - truth).^2);
    C.eceBefore = expectedCalibrationError(scores, truth);
    C.eceAfter  = expectedCalibrationError(cal, truth);

    out = fullfile(cfg.modelsDir, 'calibrator.mat');
    save(out, 'C');

    if opts.verbose
        fprintf('\n  Calibrator (%s) fitted on %d APTOS validation images\n', C.method, n);
        fprintf('    Brier score          %.4f -> %.4f\n', C.brierBefore, C.brierAfter);
        fprintf('    Expected calib error %.4f -> %.4f\n', C.eceBefore, C.eceAfter);
        fprintf('    saved -> models/calibrator.mat\n');
        fprintf(['\n    NOTE: this makes confidence honest ON APTOS. It does NOT fix\n' ...
                 '    the Messidor-2 domain shift - a map fitted here cannot undo a\n' ...
                 '    score collapse elsewhere. See the function help.\n']);
    end
end


function y = pava(t)
%PAVA  Pool-adjacent-violators: nearest monotone non-decreasing fit.
    y = double(t(:));
    n = numel(y);
    w = ones(n,1);
    i = 1;
    while i < numel(y)
        if y(i) > y(i+1)
            % pool the violating pair, then back up to re-check
            newY = (w(i)*y(i) + w(i+1)*y(i+1)) / (w(i) + w(i+1));
            y(i) = newY; w(i) = w(i) + w(i+1);
            y(i+1) = []; w(i+1) = [];
            i = max(i-1, 1);
        else
            i = i + 1;
        end
    end
    % expand pooled blocks back to full length
    out = zeros(n,1); pos = 1;
    for k = 1:numel(y)
        out(pos:pos+w(k)-1) = y(k);
        pos = pos + w(k);
    end
    y = out;
end


function e = expectedCalibrationError(p, y, nBins)
%EXPECTEDCALIBRATIONERROR  Mean |confidence - accuracy| over score bins.
    if nargin < 3, nBins = 10; end
    edges = linspace(0, 1, nBins+1);
    e = 0; n = numel(p);
    for b = 1:nBins
        in = p >= edges(b) & p < edges(b+1);
        if b == nBins, in = in | p == 1; end
        if ~any(in), continue; end
        e = e + (nnz(in)/n) * abs(mean(p(in)) - mean(y(in)));
    end
end
