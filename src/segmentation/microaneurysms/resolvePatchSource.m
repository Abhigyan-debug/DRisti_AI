function [srcImage, centroidScale, geometry] = resolvePatchSource(C, fullImage, workImage, scale)
%RESOLVEPATCHSOURCE  Which image a model's stage-2 patches must be cut from.
%
%   [srcImage, centroidScale, geometry] = RESOLVEPATCHSOURCE(C, fullImage,
%   workImage, scale) reads the geometry the classifier C was TRAINED under
%   (C.meta.patchGeometry) and returns the image to cut from plus the factor
%   that maps working-scale centroids into that image.
%
%       'fullRes/...'       -> fullImage, 1/scale
%       'workingScale/...'  -> workImage, 1
%
%   ONE PLACE, BECAUSE THE ALTERNATIVE ALREADY COST US
%   --------------------------------------------------
%   Training cut patches from the full-resolution frame while inference cut
%   them from the working-scale frame - a ~2.2x difference on IDRiD in how much
%   retina sat behind a 48 px patch. It raised no error, because both sides
%   produced correctly shaped patches; it just fed the network something it had
%   never been trained on. Nothing detected it for as long as the classifiers
%   existed.
%
%   The lesson is not "pick the right geometry" but "stop letting the two sides
%   decide independently". The geometry is now a property OF THE MODEL, written
%   at training time and obeyed at inference. A model whose stamp is missing or
%   unrecognised is refused by LOADCANDIDATECLASSIFIERS rather than guessed at,
%   because guessing is what the old code did.
%
%   An unknown stamp here is an error, not a default. Silently falling back to
%   one geometry is precisely the failure mode this function exists to close.
%
%   See also CUTCANDIDATEPATCHES, DETECTDARKLESIONS, LOADCANDIDATECLASSIFIERS,
%   ABLATECANDIDATEPATCHGEOMETRY.

    arguments
        C struct
        fullImage (:,:,:) {mustBeNumeric}
        workImage (:,:,:) {mustBeNumeric}
        scale (1,1) double {mustBePositive}
    end

    stamp = '';
    if isfield(C, 'meta') && isfield(C.meta, 'patchGeometry')
        stamp = char(C.meta.patchGeometry);
    end

    geometry = strtok(stamp, '/');
    switch geometry
        case 'fullRes'
            srcImage = fullImage;
            centroidScale = 1 / scale;
        case 'workingScale'
            srcImage = workImage;
            centroidScale = 1;
        otherwise
            error('drishti:unknownPatchGeometry', ...
                ['Classifier carries patchGeometry ''%s'', which this code does ' ...
                 'not know how to cut patches for. Refusing to guess - an ' ...
                 'incorrect guess produces plausible scores from patches the ' ...
                 'network never saw in training, which is the exact defect the ' ...
                 'stamp exists to prevent. Retrain, or add the geometry here.'], stamp);
    end
end
