function n = detectNeovascularization(img, ctx)
%DETECTNEOVASCULARIZATION  Heuristic marker of proliferative DR (ICDR 4).
%
%   n = DETECTNEOVASCULARIZATION(img, ctx) returns:
%       n.suspectedAtDisc, n.suspectedElsewhere   logical
%       n.vesselTortuosityIndex                   double
%       n.abnormalVesselDensityDD2                double
%
%   New vessels are structurally different from normal retinal vasculature:
%   fine, densely packed, highly tortuous, and forming loops rather than the
%   smooth dichotomous branching of the normal arcades. That is what this
%   measures - local vessel density well above the retinal norm combined with
%   high tortuosity, checked separately at the disc (NVD) and in the periphery
%   (NVE), because the two are graded differently.
%
%   CALIBRATE YOUR EXPECTATIONS BEFORE USING THIS
%   ---------------------------------------------
%   Proliferative DR is 49 of 413 IDRiD training images (11.9%) and 3% of the
%   modelled screening population. With a heuristic this crude and a base rate
%   that low, most positives will be false. Do NOT tune it to fire more often
%   to "find more cases" - at a 3% prevalence that trades one true positive for
%   many false referrals, and a false referral in a screening programme costs a
%   patient a wasted trip to a district hospital.
%
%   It is a FLAG for the evidence table, not a diagnosis. Module 4 should
%   present it as "features suggestive of neovascularization - clinician
%   review required", never as a grade.
%
%   Entirely dependent on the vessel map, so it is the last detector to become
%   useful and the first to degrade when vessel segmentation is poor.
%
%   See also SEGMENTVESSELS, EXTRACTLESIONFEATURES.

    arguments
        img (:,:,:) {mustBeNumeric}
        ctx struct
    end

    n = struct('suspectedAtDisc', false, 'suspectedElsewhere', false, ...
               'vesselTortuosityIndex', 0, 'abnormalVesselDensityDD2', 0);

    if ~isfield(ctx, 'vesselMask') || isempty(ctx.vesselMask)
        return   % no vessel map, no honest answer
    end

    fov = ctx.fov;
    disc = ctx.disc;

    scale = min(1, 1024 / fov.diameter);
    vm = imresize(ctx.vesselMask, scale, 'nearest');
    mask = imresize(fov.mask, scale, 'nearest');
    discR = disc.radius * scale;
    discDiamWork = max(2 * discR, 1);

    % --- tortuosity -------------------------------------------------------
    % Ratio of skeleton length to the straight-line span of each branch. A
    % normal vessel segment is close to 1; new vessels loop and coil.
    skel = bwskel(vm);
    branchPts = bwmorph(skel, 'branchpoints');
    segs = skel & ~imdilate(branchPts, strel('disk', 1));
    cc = bwconncomp(segs, 8);
    ratios = [];
    for k = 1:cc.NumObjects
        px = cc.PixelIdxList{k};
        if numel(px) < 10, continue; end
        [yy, xx] = ind2sub(size(segs), px);
        span = hypot(max(xx)-min(xx), max(yy)-min(yy));
        if span > 2
            ratios(end+1) = numel(px) / span; %#ok<AGROW>
        end
    end
    if ~isempty(ratios)
        n.vesselTortuosityIndex = median(ratios);
    end

    % --- local vessel density --------------------------------------------
    % Density averaged over a disc-sized window, compared against the retina's
    % own median rather than an absolute cut - vessel maps vary too much
    % between cameras and between segmenters for a fixed threshold.
    dens = imfilter(double(vm), fspecial('disk', max(2, discR/2)), 'replicate');
    valid = imerode(mask, strel('disk', max(2, round(discR*0.2))));
    baseline = median(dens(valid));
    spread = std(dens(valid));
    abnormal = dens > baseline + 3 * spread & valid;

    n.abnormalVesselDensityDD2 = nnz(abnormal) / (discDiamWork^2);

    % --- where ------------------------------------------------------------
    [Y, X] = ndgrid(1:size(vm,1), 1:size(vm,2));
    dcx = disc.centre(1) * scale; dcy = disc.centre(2) * scale;
    nearDisc = sqrt((X-dcx).^2 + (Y-dcy).^2) <= discR * 1.5;

    tortuous = n.vesselTortuosityIndex > 1.35;
    n.suspectedAtDisc = tortuous && any(abnormal(nearDisc), 'all');
    n.suspectedElsewhere = tortuous && any(abnormal(~nearDisc), 'all');
end
