function CC = loadCandidateClassifiers()
%LOADCANDIDATECLASSIFIERS  Stage-2 false-positive classifiers, if they exist.
%
%   CC = LOADCANDIDATECLASSIFIERS() returns a cell array of classifier structs
%   ({} when none are on disk), ready to hand to DETECTDARKLESIONS.
%
%   WHY THIS EXISTS
%   ---------------
%   TRAINCANDIDATECLASSIFIER has been producing models/candidate_classifier_*.mat
%   for a while, and EVALUATETWOSTAGEDETECTOR measured them - but nothing in the
%   production path ever loaded them. EXTRACTLESIONFEATURES called
%   DETECTDARKLESIONS with no classifier at all, so every image that went through
%   the pipeline, the dashboard and the clinical report was scored by stage 1
%   alone. The two-stage detector was built, measured, written up, and then not
%   connected to anything.
%
%   That is why the validated microaneurysm precision was 0.028 rather than the
%   0.054 the two-stage evaluation reported: the two numbers were measured on
%   different pipelines, and the weaker one was the one actually shipping.
%
%   Missing files are not an error. A teammate who has not trained the
%   classifiers still gets a working stage-1 pipeline, just a noisier one.
%
%   GEOMETRY COMPATIBILITY - WHY A MODEL CAN BE REFUSED
%   ---------------------------------------------------
%   Training patches used to be cut from the FULL-RESOLUTION frame while
%   inference cut them from the WORKING-SCALE frame, about a 2x difference in
%   how much retina sat behind a 48 px patch on IDRiD. Both sides now go
%   through CUTCANDIDATEPATCHES, cutting whichever geometry the model records.
%
%   That fix inverts the mismatch for any model trained before it. Such a model
%   loads without complaint, has the right input size, and produces plausible
%   scores - it is simply looking at the wrong thing. So models are refused
%   unless meta.patchGeometry is one of ACCEPTED_GEOMETRY, and the pipeline
%   falls back to stage 1 alone until they are retrained. Both geometries are
%   accepted because either is self-consistent between training and inference -
%   RESOLVEPATCHSOURCE cuts to match the stamp. What is refused is a model with
%   NO stamp, from before the two sides were tied together.
%
%   This fails CLOSED, for the same reason LOADLESIONRELIABILITY does: a silent
%   degradation that still returns numbers is worse than a loud absence. The
%   warning names the fix.
%
%   See also CUTCANDIDATEPATCHES, DETECTDARKLESIONS, TRAINCANDIDATECLASSIFIER,
%   EVALUATETWOSTAGEDETECTOR.

    persistent cached cachedStamp

    cfg = drishti_paths();
    files = { fullfile(cfg.modelsDir, 'candidate_classifier_microaneurysms.mat'), ...
              fullfile(cfg.modelsDir, 'candidate_classifier_haemorrhages.mat') };

    stamp = '';
    for k = 1:numel(files)
        d = dir(files{k});
        if isempty(d)
            stamp = [stamp '|missing']; %#ok<AGROW>
        else
            stamp = [stamp sprintf('|%.6f:%d', d.datenum, d.bytes)]; %#ok<AGROW>
        end
    end
    if ~isempty(cached) && strcmp(stamp, cachedStamp)
        CC = cached;
        return
    end

    % Bump this when the patch geometry changes again; every model trained
    % under a different one is then refused instead of silently misapplied.
    ACCEPTED_GEOMETRY = {'workingScale/v2', 'fullRes/v2'};

    CC = {};
    stale = {};
    for k = 1:numel(files)
        if ~isfile(files{k}), continue; end
        try
            C = load(files{k});
        catch
            continue    % a corrupt model file must not take the pipeline down
        end
        if ~(isfield(C, 'trained') && isfield(C, 'meta') && isfield(C.meta, 'lesion'))
            continue
        end
        if ~isfield(C.meta, 'patchGeometry') || ...
                ~any(strcmp(char(C.meta.patchGeometry), ACCEPTED_GEOMETRY))
            [~, nm, ext] = fileparts(files{k});
            stale{end+1} = [nm ext]; %#ok<AGROW>
            continue
        end
        CC{end+1} = C; %#ok<AGROW>
    end

    if ~isempty(stale)
        warning('drishti:staleClassifierGeometry', ...
            ['Ignoring %d stage-2 classifier(s) trained under an older patch ' ...
             'geometry: %s. They predate the patchGeometry stamp, so there is ' ...
             'no way to know which scale their patches were cut at and their ' ...
             'scores cannot be trusted. Running stage 1 alone until ' ...
             'rebuildDarkLesionDetectors has retrained them.'], ...
            numel(stale), strjoin(stale, ', '));
    end

    cached = CC;
    cachedStamp = stamp;
end
