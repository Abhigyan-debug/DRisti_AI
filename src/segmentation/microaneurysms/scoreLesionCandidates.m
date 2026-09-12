function scores = scoreLesionCandidates(workImage, centroids, C)
%SCORELESIONCANDIDATES  Stage-2 classifier score for every candidate, unthresholded.
%
%   scores = SCORELESIONCANDIDATES(workImage, centroids, C) returns an N-by-1
%   vector of positive-class probabilities, one per row of `centroids`
%   ([x y] in workImage pixels), for the saved classifier struct C
%   (fields `trained` and `meta`).
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
%   CHUNKED. This logic previously allocated every patch for every candidate in
%   one array: zeros([48 48 3 n*8]) plus a full copy for the valid subset. On a
%   noisy image the microaneurysm generator proposes tens of thousands of
%   candidates, so n = 20000 is 4.4 GB for the array and 4.4 GB again for the
%   copy. It stayed invisible while nothing in the production path loaded a
%   classifier; wiring one in ran the validation out of memory on image 26 of
%   27. Memory is bounded by CHUNK, not by how noisy the image is.
%
%   See also CUTCANDIDATEPATCHES, DETECTDARKLESIONS, FITLESIONOPERATINGPOINT.

    arguments
        workImage (:,:,:) {mustBeNumeric}
        centroids (:,2) double
        C struct
    end

    CHUNK = 1024;

    inSz = C.meta.inputSize;
    n = size(centroids, 1);
    scores = zeros(n, 1);
    if n == 0, return; end

    useTTA = isfield(C.meta, 'tta') && C.meta.tta;
    nViews = 1; if useTTA, nViews = 8; end

    for b = 1:CHUNK:n
        sel = (b : min(b+CHUNK-1, n))';
        m = numel(sel);
        base = cutCandidatePatches(workImage, centroids, inSz(1), sel);
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
        else
            patches = base;
        end

        Y = predict(C.trained, dlarray(patches, 'SSCB'));
        P = double(gather(extractdata(Y)))';
        scores(sel) = mean(reshape(P(:,2), nViews, m), 1)';
        clear patches base Y P
    end
end
