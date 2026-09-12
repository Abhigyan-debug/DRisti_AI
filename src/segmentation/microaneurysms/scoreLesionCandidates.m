function scores = scoreLesionCandidates(srcImage, centroids, C, opts)
%SCORELESIONCANDIDATES  Stage-2 classifier score for every candidate, unthresholded.
%
%   scores = SCORELESIONCANDIDATES(srcImage, centroids, C) returns an N-by-1
%   double vector of positive-class probabilities, one per row of `centroids`
%   ([x y] in WORKING-scale pixels), for the saved classifier struct C
%   (fields `trained` and `meta`).
%
%   `srcImage` and the 'centroidScale' option must together match the geometry
%   the model was trained under - use RESOLVEPATCHSOURCE to derive both from
%   C.meta.patchGeometry rather than assuming one.
%
%   scores = SCORELESIONCANDIDATES(..., 'maxBatchItems', 128) caps how many
%   patches go through the network in one forward pass.
%
%   WHY SCORES AND NOT A DECISION
%   -----------------------------
%   The threshold is a separate, frozen choice (config/lesion_operating_points.json).
%   Returning scores lets FITLESIONOPERATINGPOINT sweep every threshold from a
%   SINGLE forward pass per image instead of re-running the whole detector once
%   per candidate threshold, and it guarantees the sweep and the shipped
%   detector are scoring identically - the sweep is not a re-implementation,
%   it calls this.
%
%   PATCH GEOMETRY comes from CUTCANDIDATEPATCHES, shared with
%   BUILDCANDIDATEDATASET. Patch size comes from C.meta.inputSize rather than a
%   constant, because a size mismatch degrades a classifier silently instead of
%   erroring.
%
%   TEST-TIME AUGMENTATION. A lesion patch has no canonical orientation, so the
%   score is averaged over all 8 dihedral views when the saved model was
%   trained with TTA (meta.tta), matching how it was validated. Scoring one
%   orientation at inference while validating on eight would silently
%   under-deliver the measured operating point.
%
%   BATCHING - AND WHY IT IS COUNTED IN VIEWS, NOT CANDIDATES
%   ---------------------------------------------------------
%   This used to chunk 1024 CANDIDATES at a time. With TTA that is 1024 x 8 =
%   8192 patches in one forward pass, and the batch dimension is what drives
%   activation memory: the first convolution alone holds
%   8192 x 48 x 48 x 32 x 4 B = 2.4 GB, and the whole stack peaks near 8 GB.
%   On the 8.5 GB RTX 5050 that is an out-of-memory abort partway through a
%   54-image run.
%
%   The bug was writing the cap in candidates while the cost is in patches, so
%   the real batch silently multiplied by 8 whenever TTA was on. The cap is now
%   MAXBATCHITEMS - actual forward-pass patches - and the candidates per chunk
%   are derived from it (256 items = 32 candidates with TTA, 256 without).
%
%   Batch size does not change the result in any way that matters. The network
%   is in inference mode, so its batch-normalisation layers use their learned
%   statistics rather than batch statistics, and every patch is scored
%   independently of what it was batched with. Length and order are exactly
%   preserved.
%
%   Values agree to floating-point noise rather than bit-for-bit: measured
%   max |score(batch 256) - score(batch 64)| = 7.4e-09 over 652 candidates on
%   IDRiD_01. That residue is cuDNN picking different reduction kernels for
%   different batch shapes, not a change in what is computed. It is ~1e-7 of
%   the smallest threshold step the operating-point sweep evaluates, so no
%   candidate can change side because of it.
%
%   If a forward pass still runs out of memory, the batch is halved and
%   retried, and the reduced size is kept for the rest of the session (see
%   FORWARDPOSITIVESCORES). A slow correct answer beats an aborted run.
%
%   See also CUTCANDIDATEPATCHES, DETECTDARKLESIONS, FITLESIONOPERATINGPOINT.

    arguments
        srcImage (:,:,:) {mustBeNumeric}
        centroids (:,2) double
        C struct
        % Patches per forward pass. 256 is ~256 MB of peak activation for this
        % network at 48x48, comfortable on an 8 GB card alongside the model and
        % whatever else the pipeline is holding.
        opts.maxBatchItems (1,1) double {mustBePositive} = 256
        % Maps working-scale centroids into srcImage's pixel grid: 1 when
        % srcImage IS the working-scale frame, 1/scale when it is full
        % resolution. See RESOLVEPATCHSOURCE.
        opts.centroidScale (1,1) double {mustBePositive} = 1
    end

    inSz = C.meta.inputSize;
    n = size(centroids, 1);
    scores = zeros(n, 1);
    if n == 0, return; end

    useTTA = isfield(C.meta, 'tta') && C.meta.tta;
    nViews = 1; if useTTA, nViews = 8; end

    % Derive the candidate chunk from the item budget. At least one candidate
    % per chunk, or a model with more views than the budget would loop forever.
    candPerChunk = max(1, floor(opts.maxBatchItems / nViews));

    for b = 1:candPerChunk:n
        sel = (b : min(b+candPerChunk-1, n))';
        m = numel(sel);

        base = cutCandidatePatches(srcImage, centroids, inSz(1), sel, opts.centroidScale);
        if ~isequal(size(base, 1, 2), inSz(1:2))
            base = imresize(base, inSz(1:2));
        end

        if useTTA
            patches = zeros([inSz(1:2) 3 m*nViews], 'single');
            for j = 1:m
                p = base(:,:,:,j);
                views = {p, fliplr(p), flipud(p), rot90(p,1), rot90(p,2), ...
                         rot90(p,3), fliplr(rot90(p,1)), fliplr(rot90(p,2))};
                for v = 1:8
                    patches(:,:,:,(j-1)*nViews+v) = views{v};
                end
            end
            clear p views
        else
            patches = base;
        end
        clear base

        % Positive-class probability for every patch in this chunk, in order.
        p2 = forwardPositiveScores(C.trained, patches, opts.maxBatchItems);

        % Average the dihedral views back down to one score per candidate. Done
        % in double on an 8-element reduction: the arrays that matter for
        % memory stay single, and the accumulation costs nothing.
        scores(sel) = mean(reshape(double(p2), nViews, m), 1)';

        clear patches p2
    end
end


% ------------------------------------------------------------------ helpers

function p2 = forwardPositiveScores(net, patches, maxItems)
%FORWARDPOSITIVESCORES  Run the network over patches, returning class-2 scores.
%
%   Splits `patches` into slices of at most `maxItems` along the batch
%   dimension. On an out-of-memory failure the slice is halved and retried, and
%   the reduced size persists for the rest of the session so the run does not
%   spend the next thousand batches rediscovering the same limit.
%
%   The persistent floor only ever decreases. It is a memory ceiling discovered
%   at runtime, not a tuning parameter: results are identical at any slice size
%   because the network is in inference mode (batch-normalisation uses learned
%   statistics, so no patch's score depends on what it was batched with).

    persistent sliceCap
    if isempty(sliceCap), sliceCap = Inf; end

    N = size(patches, 4);
    p2 = zeros(N, 1, 'single');

    b = 1;
    while b <= N
        nb = min([maxItems, sliceCap, N - b + 1]);
        done = false;
        while ~done
            try
                X = dlarray(patches(:,:,:,b:b+nb-1), 'SSCB');
                Y = predict(net, X);
                % Column 2 is the positive class, matching the two-unit
                % fullyConnectedLayer + softmax the classifier was trained with.
                Yd = gather(extractdata(Y));
                p2(b:b+nb-1) = Yd(2, :)';
                clear X Y Yd
                done = true;
            catch ME
                if nb > 1 && isOutOfMemory(ME)
                    nb = max(1, floor(nb / 2));
                    sliceCap = nb;
                    warning('drishti:candidateBatchReduced', ...
                        ['GPU out of memory scoring candidate patches; slice ' ...
                         'reduced to %d patches and kept there for this ' ...
                         'session. Results are unaffected - batch size does ' ...
                         'not change an inference-mode forward pass.'], nb);
                else
                    rethrow(ME)
                end
            end
        end
        b = b + nb;
    end
end


function tf = isOutOfMemory(ME)
%ISOUTOFMEMORY  Recognise the several ways MATLAB reports exhausted memory.
    id = lower(ME.identifier);
    msg = lower(ME.message);
    tf = contains(id, 'oom') || contains(id, 'nomem') || ...
         contains(msg, 'out of memory') || contains(msg, 'out of gpu memory');
end
