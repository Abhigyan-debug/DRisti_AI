function r = processImage(img, opts)
%PROCESSIMAGE  Module 1 end to end: assess, enhance if recoverable, re-gate.
%
%   r = PROCESSIMAGE(img) runs the full quality stage and returns:
%       r.decision   'pass' | 'reject'       final verdict
%       r.gradable   logical
%       r.image      the image to pass downstream (enhanced where applicable)
%       r.original   the untouched input - Module 4 overlays Grad-CAM on THIS
%       r.enhanced   logical, whether correction ran
%       r.applied    which enhancement steps ran
%       r.before     ASSESSQUALITY struct for the original
%       r.after      ASSESSQUALITY struct post-enhancement ([] if not enhanced)
%       r.reasons    recapture reasons if rejected
%       r.summary    one-line human summary
%       r.elapsed    seconds - feeds Module 5's throughput model
%
%   Flow
%     assess -> gate -> reject            (unrecoverable; return a retake reason)
%                    -> pass              (use as-is)
%                    -> enhance -> re-gate
%
%   Why focus is judged ONCE, on the original
%   -----------------------------------------
%   CLAHE raises local contrast, and the sharpness metric is a variance of
%   local gradients - so enhancement inflates the focus score without restoring
%   any real detail. Re-scoring focus after enhancement would let a blurred
%   image "improve" its way past the gate and reach the grader, which is the
%   exact failure this module exists to prevent.
%
%   The original's focus verdict is therefore authoritative and is carried
%   forward. The re-gate only reconsiders the defects enhancement can genuinely
%   fix: illumination, contrast, glare and exposure.
%
%   Example
%     r = processImage(imread(f));
%     if r.gradable
%         grade = gradeImage(r.image);          % Module 3, later
%     else
%         fprintf('Retake: %s\n', r.summary);
%     end
%
%   See also ASSESSQUALITY, GATEIMAGE, ENHANCEIMAGE.

    arguments
        img (:,:,:) {mustBeNumeric}
        opts.thresholds struct = loadQualityThresholds()
        opts.allowEnhancement (1,1) logical = true
    end

    t0 = tic;
    th = opts.thresholds;

    r.original = img;
    r.before   = assessQuality(img);
    firstGate  = gateImage(r.before, th);

    % ---- unrecoverable ---------------------------------------------------
    if strcmp(firstGate.decision, 'reject')
        r = finish(r, 'reject', img, false, ...
            struct('illumination', false, 'clahe', false, 'denoise', false), ...
            [], firstGate.reasons, firstGate.summary, t0);
        return
    end

    % ---- already good ----------------------------------------------------
    if strcmp(firstGate.decision, 'pass')
        r = finish(r, 'pass', img, false, ...
            struct('illumination', false, 'clahe', false, 'denoise', false), ...
            [], firstGate.reasons, 'Gradable as captured.', t0);
        return
    end

    % ---- borderline: try to recover -------------------------------------
    if ~opts.allowEnhancement
        r = finish(r, 'pass', img, false, ...
            struct('illumination', false, 'clahe', false, 'denoise', false), ...
            [], firstGate.reasons, 'Borderline; enhancement disabled.', t0);
        return
    end

    [enhanced, applied] = enhanceImage(img, r.before, 'thresholds', th);

    % Did anything actually change? The gate routes an image here for any
    % borderline reason, but several of those - soft focus, mild glare - have
    % no corrective step, so enhanceImage legitimately does nothing. Reporting
    % those as "enhanced" would put a false claim in the Module 4 report and
    % overstate the enhancement stage's contribution in the Phase 6 comparison.
    didSomething = applied.illumination || applied.clahe || applied.denoise;
    if ~didSomething
        enhanced = img;
    end

    after = assessQuality(enhanced);
    secondGate = gateImage(after, th);

    % Carry the ORIGINAL focus verdict forward - see the header note.
    focusCodes = {'out_of_focus', 'soft_focus'};
    originalFocusReasons = firstGate.reasons( ...
        ismember({firstGate.reasons.code}, focusCodes));
    postReasons = secondGate.reasons( ...
        ~ismember({secondGate.reasons.code}, focusCodes));
    if ~isempty(originalFocusReasons)
        postReasons = [postReasons, originalFocusReasons];
    end

    if isempty(postReasons)
        decision = 'pass';
        if didSomething
            summary = sprintf('Gradable after correction (%s).', appliedList(applied));
        else
            summary = 'Gradable as captured.';
        end
    elseif any(strcmp({postReasons.severity}, 'reject'))
        decision = 'reject';
        isRej = strcmp({postReasons.severity}, 'reject');
        first = postReasons(find(isRej, 1));
        summary = sprintf('Ungradable after correction: %s', first.message);
    else
        % Still imperfect, but enhancement did what it could and nothing is
        % disqualifying. Screening asymmetry cuts the other way here: sending a
        % slightly imperfect image to a grader costs a moment of their time,
        % while a needless retake costs a patient a second visit to the PHC.
        decision = 'pass';
        summary = sprintf('Gradable after correction, with residual %s.', ...
            strjoin({postReasons.code}, ', '));
    end

    r = finish(r, decision, enhanced, didSomething, applied, after, postReasons, summary, t0);
end


% ------------------------------------------------------------------ helpers

function r = finish(r, decision, imgOut, wasEnhanced, applied, after, reasons, summary, t0)
    r.decision = decision;
    r.gradable = ~strcmp(decision, 'reject');
    r.image    = imgOut;
    r.enhanced = wasEnhanced;
    r.applied  = applied;
    r.after    = after;
    r.reasons  = reasons;
    r.summary  = summary;
    r.elapsed  = toc(t0);
end

function s = appliedList(applied)
    names = {};
    if applied.illumination, names{end+1} = 'illumination'; end
    if applied.clahe,        names{end+1} = 'contrast';     end
    if applied.denoise,      names{end+1} = 'denoise';      end
    if isempty(names)
        s = 'no change';
    else
        s = strjoin(names, '+');
    end
end
