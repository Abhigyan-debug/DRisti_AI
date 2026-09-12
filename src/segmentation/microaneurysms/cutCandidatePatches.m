function P = cutCandidatePatches(workImage, centroids, patchPx, idx)
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
%   See also DETECTDARKLESIONS, BUILDCANDIDATEDATASET, TRAINCANDIDATECLASSIFIER.

    arguments
        workImage (:,:,:) {mustBeNumeric}
        centroids (:,2) double
        patchPx (1,1) double
        idx (:,1) double = (1:size(centroids,1))'
    end

    % im2single is a no-op on a double already in [0,1] and divides a uint8
    % by 255, so a caller handing over a raw frame gets the same [0,1] range
    % the classifier was trained on rather than a silently 255x brighter patch.
    workImage = im2single(workImage);
    if size(workImage,3) == 1, workImage = repmat(workImage,1,1,3); end
    H = size(workImage,1); W = size(workImage,2);
    half = floor(patchPx/2);

    P = zeros([patchPx patchPx 3 numel(idx)], 'single');
    for j = 1:numel(idx)
        ctr = round(centroids(idx(j), :));
        rows = min(max(ctr(2)-half : ctr(2)+half-1, 1), H);
        cols = min(max(ctr(1)-half : ctr(1)+half-1, 1), W);
        P(:,:,:,j) = single(workImage(rows, cols, :));
    end
end
