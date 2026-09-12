function [tpPred, nPred, tpGt, nGt] = lesionCounts(pred, gt)
%LESIONCOUNTS  Per-lesion component matching, counted on BOTH sides.
%
%   [tpPred, nPred, tpGt, nGt] = LESIONCOUNTS(pred, gt) matches predicted and
%   ground-truth lesions as 8-connected components. Both inputs must already be
%   FOV-masked; this function does no masking of its own.
%
%   Precision and recall do not share a numerator under component matching, and
%   collapsing them into one "tp" is wrong in both directions:
%
%     precision = predicted components that touch ground truth / all predicted
%     recall    = ground-truth components that were touched   / all ground truth
%
%   Those differ whenever the mapping is not one-to-one - three fragments landing
%   on one haemorrhage is 3 correct predictions but only 1 lesion found, and a
%   single blob spanning two microaneurysms is 1 correct prediction but 2 found.
%   Both cases are common here, so each metric is counted on its own side.
%
%   WHY THIS IS ITS OWN FILE
%   ------------------------
%   It was a local function inside VALIDATELESIONDETECTORS, which meant any
%   other measurement had to re-implement the matching rule. That is how a
%   project ends up quoting two different numbers for one detector and being
%   unable to say which protocol produced which. FITLESIONOPERATINGPOINT
%   selects the stage-2 threshold under exactly the rule the display gate is
%   later measured with, because it calls this.
%
%   See also VALIDATELESIONDETECTORS, FITLESIONOPERATINGPOINT.

    ccP = bwconncomp(pred, 8);
    ccG = bwconncomp(gt, 8);
    nPred = ccP.NumObjects;
    nGt   = ccG.NumObjects;

    tpPred = 0;
    for i = 1:nPred
        if any(gt(ccP.PixelIdxList{i})), tpPred = tpPred + 1; end
    end

    tpGt = 0;
    for i = 1:nGt
        if any(pred(ccG.PixelIdxList{i})), tpGt = tpGt + 1; end
    end
end
