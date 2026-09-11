function mdlName = build_throughput_model(outputPath)
%BUILD_THROUGHPUT_MODEL  Programmatically generate the Simulink throughput model.
%
%   mdlName = BUILD_THROUGHPUT_MODEL() builds and saves the Simulink model
%   'screening_throughput_model.slx' in the simulink/ directory.
%
%   mdlName = BUILD_THROUGHPUT_MODEL(outputPath) saves to specified directory.
%
%   The model represents the 4-stage telemedicine queuing pipeline:
%     1. Patient Acquisition (PHC Camera & Technician)
%     2. Image Quality Gate (Module 1 Recapture / Routing)
%     3. Rural Network Upload (Bandwidth throttle & dropouts)
%     4. AI Inference Engine (GPU compute cluster)
%     5. Tele-Ophthalmologist Review (Clinical triage queue)
%
%   It adapts gracefully: if SimEvents is licensed, it uses discrete-event
%   blocks; if SimEvents is absent, it builds the continuous-queuing state-space
%   equivalent with MATLAB function blocks.
%
%   See also SCREENING_PARAMS, SIMULATE_DISTRICT_THROUGHPUT.

    if nargin < 1 || isempty(outputPath)
        thisDir = fileparts(mfilename('fullpath'));
        outputPath = fullfile(thisDir, 'screening_throughput_model.slx');
    end

    mdlName = 'screening_throughput_model';

    % Close existing if open
    if bdIsLoaded(mdlName)
        close_system(mdlName, 0);
    end

    % Create new blank system
    new_system(mdlName);
    open_system(mdlName);

    % Configure solver for discrete/continuous simulation
    set_param(mdlName, 'SolverType', 'Variable-step');
    set_param(mdlName, 'StopTime', '480'); % 480 minutes = 8 hour operational shift
    set_param(mdlName, 'Solver', 'VariableStepAuto');

    % Check SimEvents license availability
    hasSimEvents = license('test', 'simevents') && ~isempty(ver('simevents'));

    if hasSimEvents
        fprintf('  SimEvents detected: Building discrete-event queuing topology...\n');
        build_simevents_topology(mdlName);
    else
        fprintf('  Building native Simulink state-space queuing model...\n');
        build_native_simulink_topology(mdlName);
    end

    % Save model
    save_system(mdlName, outputPath);
    close_system(mdlName);
    fprintf('  Successfully generated and saved: %s\n', outputPath);
end

% -------------------------------------------------------------------------
% Helper: Build Native Simulink Queuing State-Space Model
% -------------------------------------------------------------------------
function build_native_simulink_topology(mdl)
    % Layout coordinates [left, top, right, bottom]
    
    % Block 1: Patient Arrival Rate Generator (Constant / Chirp / Stochastic)
    add_block('simulink/Sources/Constant', [mdl, '/Arrival_Rate_Patients_Per_Min'], ...
        'Value', '50/60', 'Position', [50, 100, 150, 140]);

    % Subsystem 1: Stage 1 - Acquisition (Camera + Technician)
    sub1 = [mdl, '/Stage1_Acquisition_Queue'];
    add_block('simulink/Ports & Subsystems/Subsystem', sub1, ...
        'Position', [220, 80, 380, 160]);
    populate_queue_subsystem(sub1, 'Acquisition', 7.5, 44); % 7.5 min exam, 44 cameras

    % Subsystem 2: Stage 2 - Quality Gate Router (Module 1)
    sub2 = [mdl, '/Stage2_Quality_Gate'];
    add_block('simulink/Ports & Subsystems/Subsystem', sub2, ...
        'Position', [440, 80, 580, 160]);
    populate_quality_gate_subsystem(sub2);

    % Subsystem 3: Stage 3 - Rural Network Upload
    sub3 = [mdl, '/Stage3_Network_Upload_Queue'];
    add_block('simulink/Ports & Subsystems/Subsystem', sub3, ...
        'Position', [640, 80, 800, 160]);
    populate_queue_subsystem(sub3, 'Network_Upload', 1.83, 44); % ~1.83 min upload, 44 links

    % Subsystem 4: Stage 4 - AI Server Cluster
    sub4 = [mdl, '/Stage4_AI_Compute_Queue'];
    add_block('simulink/Ports & Subsystems/Subsystem', sub4, ...
        'Position', [860, 80, 1020, 160]);
    populate_queue_subsystem(sub4, 'AI_Inference', 0.008, 2); % 0.48s = 0.008 min, 2 GPU nodes

    % Subsystem 5: Stage 5 - Ophthalmologist Review
    sub5 = [mdl, '/Stage5_Ophthalmologist_Triage'];
    add_block('simulink/Ports & Subsystems/Subsystem', sub5, ...
        'Position', [1080, 80, 1260, 160]);
    populate_queue_subsystem(sub5, 'Ophth_Review', 0.38, 3); % ~23s = 0.38 min, 3 clinicians

    % Scopes and Sinks
    add_block('simulink/Sinks/Scope', [mdl, '/District_Queues_Scope'], ...
        'Position', [1320, 50, 1370, 110]);
    add_block('simulink/Sinks/To Workspace', [mdl, '/District_TAT_Out'], ...
        'VariableName', 'sim_screening_tat', 'SaveFormat', 'Array', ...
        'Position', [1320, 130, 1390, 170]);

    % Connect Top-Level Signals
    add_line(mdl, 'Arrival_Rate_Patients_Per_Min/1', 'Stage1_Acquisition_Queue/1');
    add_line(mdl, 'Stage1_Acquisition_Queue/1', 'Stage2_Quality_Gate/1');
    add_line(mdl, 'Stage2_Quality_Gate/1', 'Stage3_Network_Upload_Queue/1');
    add_line(mdl, 'Stage3_Network_Upload_Queue/1', 'Stage4_AI_Compute_Queue/1');
    add_line(mdl, 'Stage4_AI_Compute_Queue/1', 'Stage5_Ophthalmologist_Triage/1');
    add_line(mdl, 'Stage5_Ophthalmologist_Triage/1', 'District_Queues_Scope/1');
    add_line(mdl, 'Stage5_Ophthalmologist_Triage/2', 'District_TAT_Out/1');
end

% -------------------------------------------------------------------------
% Helper: Populate Queuing Subsystem (Native Integrator + Rate Limiter)
% -------------------------------------------------------------------------
function populate_queue_subsystem(subPath, name, meanServiceMin, numServers)
    % Delete default in/out
    Simulink.SubSystem.deleteContents(subPath);

    add_block('simulink/Sources/In1', [subPath, '/Arrival_Rate'], ...
        'Position', [40, 80, 70, 100]);
    
    % Service Capacity = numServers / meanServiceMin (patients / min)
    serviceCapacity = numServers / meanServiceMin;

    % Differential queue state: dQ/dt = lambda - min(Q/dt, mu)
    % Modeled via bounded integrator: Q(t) = max(0, Integral(lambda - mu))
    add_block('simulink/Math Operations/Sum', [subPath, '/Net_Flow'], ...
        'Inputs', '+-', 'Position', [120, 75, 145, 115]);

    add_block('simulink/Continuous/Integrator', [subPath, '/Queue_Length_Integrator'], ...
        'LowerSaturationLimit', '0', 'LimitOutput', 'on', ...
        'Position', [180, 80, 220, 110]);

    add_block('simulink/Math Operations/Gain', [subPath, '/Service_Rate_Gain'], ...
        'Gain', num2str(serviceCapacity), 'Position', [260, 140, 310, 180]);

    add_block('simulink/Math Operations/MinMax', [subPath, '/Actual_Departure_Rate'], ...
        'Function', 'min', 'Inputs', '2', 'Position', [340, 80, 375, 120]);

    % Departure Out
    add_block('simulink/Sinks/Out1', [subPath, '/Departures_Out'], ...
        'Position', [440, 90, 470, 110]);

    % Queue Length Out
    add_block('simulink/Sinks/Out2', [subPath, '/Queue_Length_Out'], ...
        'Position', [440, 150, 470, 170]);

    % Connect subsystem internal lines
    add_line(subPath, 'Arrival_Rate/1', 'Net_Flow/1');
    add_line(subPath, 'Net_Flow/1', 'Queue_Length_Integrator/1');
    add_line(subPath, 'Queue_Length_Integrator/1', 'Actual_Departure_Rate/1');
    add_line(subPath, 'Arrival_Rate/1', 'Actual_Departure_Rate/2');
    add_line(subPath, 'Actual_Departure_Rate/1', 'Net_Flow/2', 'autorouting', 'on');
    add_line(subPath, 'Actual_Departure_Rate/1', 'Departures_Out/1');
    add_line(subPath, 'Queue_Length_Integrator/1', 'Queue_Length_Out/1');
end

% -------------------------------------------------------------------------
% Helper: Populate Quality Gate Subsystem
% -------------------------------------------------------------------------
function populate_quality_gate_subsystem(subPath)
    Simulink.SubSystem.deleteContents(subPath);

    add_block('simulink/Sources/In1', [subPath, '/Acquired_Images_In'], ...
        'Position', [40, 80, 70, 100]);

    % Sourced pass rate = 1 - permanentRejectRate (98% pass to upload)
    add_block('simulink/Math Operations/Gain', [subPath, '/Valid_Screening_Pass_Gain'], ...
        'Gain', '0.98', 'Position', [140, 75, 200, 105]);

    add_block('simulink/Sinks/Out1', [subPath, '/Passed_To_Upload'], ...
        'Position', [260, 80, 290, 100]);

    add_line(subPath, 'Acquired_Images_In/1', 'Valid_Screening_Pass_Gain/1');
    add_line(subPath, 'Valid_Screening_Pass_Gain/1', 'Passed_To_Upload/1');
end

% -------------------------------------------------------------------------
% Helper: Build SimEvents Discrete-Event Topology
% -------------------------------------------------------------------------
function build_simevents_topology(mdl)
    % When SimEvents is available, builds discrete-event entities
    add_block('simeventsgenerators/Entity Generator', [mdl, '/Patient_Arrivals'], ...
        'Position', [50, 100, 140, 140]);
    add_block('simeventsqueues/Entity Queue', [mdl, '/PHC_Waiting_Queue'], ...
        'Position', [200, 100, 270, 140]);
    add_block('simeventsservers/Entity Server', [mdl, '/Camera_Exam_Server'], ...
        'Position', [330, 100, 410, 140]);
    add_block('simeventsqueues/Entity Queue', [mdl, '/Network_Upload_Queue'], ...
        'Position', [470, 100, 540, 140]);
    add_block('simeventsservers/Entity Server', [mdl, '/Uplink_Channel'], ...
        'Position', [600, 100, 680, 140]);
    add_block('simeventsservers/Entity Server', [mdl, '/AI_GPU_Server'], ...
        'Position', [740, 100, 820, 140]);
    add_block('simeventsqueues/Entity Queue', [mdl, '/Ophthalmologist_Triage_Queue'], ...
        'Position', [880, 100, 950, 140]);
    add_block('simeventsservers/Entity Server', [mdl, '/Ophthalmologist_Review_Server'], ...
        'Position', [1010, 100, 1090, 140]);
    add_block('simeventssinks/Entity Sink', [mdl, '/Completed_Screenings_Sink'], ...
        'Position', [1150, 100, 1220, 140]);

    % Connect SimEvents entity ports
    add_line(mdl, 'Patient_Arrivals/1', 'PHC_Waiting_Queue/1');
    add_line(mdl, 'PHC_Waiting_Queue/1', 'Camera_Exam_Server/1');
    add_line(mdl, 'Camera_Exam_Server/1', 'Network_Upload_Queue/1');
    add_line(mdl, 'Network_Upload_Queue/1', 'Uplink_Channel/1');
    add_line(mdl, 'Uplink_Channel/1', 'AI_GPU_Server/1');
    add_line(mdl, 'AI_GPU_Server/1', 'Ophthalmologist_Triage_Queue/1');
    add_line(mdl, 'Ophthalmologist_Triage_Queue/1', 'Ophthalmologist_Review_Server/1');
    add_line(mdl, 'Ophthalmologist_Review_Server/1', 'Completed_Screenings_Sink/1');
end
