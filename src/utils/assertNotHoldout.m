function assertNotHoldout(paths)
%ASSERTNOTHOLDOUT  Refuse to touch the held-out external benchmark.
%
%   ASSERTNOTHOLDOUT(paths) errors if any path looks like Messidor-2.
%   Accepts a char path, a string array, or a cellstr.
%
%   WHY THIS IS A FUNCTION AND NOT A COMMENT
%   ----------------------------------------
%   Project rule 1 makes Messidor-2 a one-shot, and it was spent on
%   2026-09-12. The rule is only as strong as the number of entry points that
%   enforce it. RUNDRISHTISYSTEM had the check inlined as a local function,
%   which protected batch runs and nothing else - so the moment a second entry
%   point appeared (a dashboard with a file picker, where a user can browse
%   straight into the dataset folder in two clicks) the holdout was one
%   mis-click from being read again.
%
%   A held-out set is destroyed silently. There is no error, no failing test,
%   no visible symptom - just a headline claim that quietly stops being true.
%   So the guard lives in one place that every entry point calls.
%
%   See also RUNDRISHTISYSTEM, RUNDRISHTIPIPELINE, DRISHTIDASHBOARD.

    if isempty(paths), return; end
    p = string(paths);
    hit = contains(lower(p), 'messidor');
    if ~any(hit)
        return
    end

    error('drishti:holdoutProtected', ...
        ['Refusing to read: %d of these paths look like Messidor-2, which is ' ...
         'the HELD-OUT external benchmark and was already spent once ' ...
         '(2026-09-12, results/messidor2_external_validation.mat). See ' ...
         'project rule 1. To analyse that run, use analyseFailureCases, ' ...
         'which reads the saved result and performs no inference.'], nnz(hit));
end
