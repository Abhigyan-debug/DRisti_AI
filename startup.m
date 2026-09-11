% STARTUP  Run automatically by MATLAB when it starts in this folder.
%
% Initialises the DRishti-AI project. To skip, start MATLAB elsewhere and call
% setup_drishti manually.
if isfile(fullfile(fileparts(mfilename('fullpath')), 'setup_drishti.m'))
    setup_drishti();
end
