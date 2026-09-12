function P = cutCandidatePatches(workImage, centroids, patchPx, idx, centroidScale)
%CUTCANDIDATEPATCHES  The one place a stage-2 candidate patch is ever cut.
%
%   P = CUTCANDIDATEPATCHES(workImage, centroids, patchPx) returns a
%   patchPx-by-patchPx-by-3-by-N single array in [0,1], one patch per row of
%   `centroids` ([x y], in workImage pixels).
%
%   P = CUTCANDIDATEPATCHES(..., idx) cuts only the candidates in `idx`, so a
%   caller can chunk without changing the geometry.
%
%   WHY THIS IS A FUNCTION AND NOT TWO COPIES
%   -----------------------------------------
%   It used to be two copies, and they disagreed. BUILDCANDIDATEDATASET cut its
%   training patches from the FULL-RESOLUTION image at the full-resolution
%   centroid; SCORECANDIDATES (inside DETECTDARKLESIONS) cut its inference
%   patches from the WORKING-SCALE image at the working-scale centroid. The
%   working scale normalises the field of view to 1536 px, so on IDRiD
%   (4288x2848, FOV diameter ~3280 px) the scale factor is ~0.47 and a 48 px
%   inference patch covers ~2.1x the retinal area of a 48 px training patch.
%
%   The classifier was therefore trained on lesions at roughly twice the
%   apparent size it met at inference, on every image large enough to be
%   downscaled. Nothing errored, nothing warned: the patches were the right
%   shape and the wrong content. Worse, the mismatch is a function of image
%   resolution, so it varied across our 6.7x resolution range and vanished
%   entirely on images small enough that scale == 1 - a camera fingerprint
%   baked into the classifier, which is the exact failure the disc-diameter
%   convention exists to prevent everywhere else in Module 2.
%
%   Both paths now call this, so the geometry cannot drift apart again.
%
%   EDGE CANDIDATES ARE CLAMPED, NOT DROPPED
%   ----------------------------------------
%   Index clamping gives replicate padding without allocating a padded copy.
%   The two paths disagreed here too, and in opposite directions: the builder
%   SKIPPED any candidate whose patch would leave the frame ("skip rather than
%   invent pixels"), while the scorer KEPT it unscored - so a candidate too
%   close to the edge to be classified bypassed the false-positive filter
%   entirely and went straight into the report. On IDRiD the FOV is cropped
%   flush to the top and bottom of the frame, so this is not a rare corner: it
%   is a standing leak of unfiltered candidates on every image in the set.
%
%   Inventing a few replicated pixels at the rim is the lesser error. It is
%   applied identically on both sides, so the classifier is trained on the same
%   thing it is asked to score.
%
%   PATCH GEOMETRY IS A CHOICE, AND IT IS THE CALLER'S
%   --------------------------------------------------
%   P = CUTCANDIDATEPATCHES(image, centroids, patchPx, idx, centroidScale)
%   multiplies the (working-scale) centroids by `centroidScale` before cutting,
%   so the same centroids can address either image:
%
%       centroidScale = 1        cut from the WORKING-scale frame
%       centroidScale = 1/scale  cut from the FULL-RESOLUTION frame
%
%   The patch is always patchPx square IN THE TARGET IMAGE'S PIXELS. So a
%   full-resolution patch covers LESS retina but resolves it ~2.2x more finely
%   on IDRiD, and a working-scale patch covers more retina at coarser detail.
%   Neither is obviously right for microaneurysms - they are a few tens of
%   pixels across at full resolution, so the texture that separates one from a
%   dark noise blob may not survive downsampling, while the surrounding context
%   that separates one from a vessel cross-section may need the wider view.
%   ABLATECANDIDATEPATCHGEOMETRY measures which.
%
%   What must never differ again is the geometry between the two SIDES: the
%   model records which one it was trained under (meta.patchGeometry) and
%   DETECTDARKLESIONS cuts to match.
%
%   See also DETECTDARKLESIONS, BUILDCANDIDATEDATASET, TRAINCANDIDATECLASSIFIER,
%   RESOLVEPATCHSOURCE, ABLATECANDIDATEPATCHGEOMETRY.

    arguments
        workImage (:,:,:) {mustBeNumeric}
        centroids (:,2) double
        patchPx (1,1) double
        idx (:,1) double = (1:size(centroids,1))'
        centroidScale (1,1) double {mustBePositive} = 1
    end

    % CONVERT THE PATCH, NOT THE FRAME.
    %
    % This used to run `workImage = im2single(workImage)` before the loop. On
    % the full-resolution path that is a 4288x2848x3 single = 146 MB temporary
    % allocated to read a handful of 48 px windows out of it - and
    % SCORELESIONCANDIDATES calls this once per chunk, so a 1200-candidate
    % image churned that allocation ~38 times. It is a pure waste that also
    % fragments the heap, and it contributed to the host-memory exhaustion that
    % killed a long ablation run.
    %
    % im2single on the small extracted window instead is the same arithmetic
    % (it scales elementwise) at 27 kB a time. Kept because it is what makes a
    % uint8 frame and a [0,1] double frame produce the same patch values: a
    % raw uint8 frame would otherwise be 255x too bright for the classifier.
    isGray = size(workImage,3) == 1;
    H = size(workImage,1); W = size(workImage,2);
    half = floor(patchPx/2);

    P = zeros([patchPx patchPx 3 numel(idx)], 'single');
    for j = 1:numel(idx)
        ctr = round(centroids(idx(j), :) * centroidScale);
        % Span exactly patchPx. Writing this as ctr-half : ctr+half-1 gives
        % 2*half samples, which is one short whenever patchPx is ODD - an
        % assignment-size error rather than a silent one, but only for callers
        % that pass an odd size. Production uses 48, so it sat here unfired.
        rows = min(max(ctr(2)-half : ctr(2)-half+patchPx-1, 1), H);
        cols = min(max(ctr(1)-half : ctr(1)-half+patchPx-1, 1), W);
        patch = im2single(workImage(rows, cols, :));
        if isGray, patch = repmat(patch, 1, 1, 3); end
        P(:,:,:,j) = patch;
    end
end
