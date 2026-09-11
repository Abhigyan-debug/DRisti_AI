function tests = test_module4_reporting
%TEST_MODULE4_REPORTING  Unit tests for Module 4 reporting & explainability.
%
%   Run with:
%       >> runtests('tests/test_module4_reporting.m')
%
%   See also CLINICAL_REPORT_TEMPLATE, GENERATE_CLINICAL_REPORT, RECAPTURE_MESSAGES.

    tests = functiontests(localfunctions);
end

% -------------------------------------------------------------------------
% Test 1: Template Data Structure Integrity
% -------------------------------------------------------------------------
function testReportTemplateIntegrity(testCase)
    tpl = clinical_report_template();

    testCase.verifyNotEmpty(tpl);
    testCase.verifyNotEmpty(tpl.patientId);
    testCase.verifyTrue(isfield(tpl, 'lesions'));
    testCase.verifyTrue(isfield(tpl.lesions, 'microaneurysmCount'));
    testCase.verifyTrue(isfield(tpl.lesions, 'hardExudateAreaPct'));
    testCase.verifyTrue(isfield(tpl, 'predictedGrade'));
    testCase.verifyTrue(tpl.predictedGrade >= 0 && tpl.predictedGrade <= 4);
    testCase.verifyTrue(isfield(tpl, 'evidenceTable'));
    testCase.verifyTrue(size(tpl.evidenceTable, 1) >= 1);
end

% -------------------------------------------------------------------------
% Test 2: Recapture Message Dictionaries
% -------------------------------------------------------------------------
function testRecaptureMessages(testCase)
    codes = {'DEFOCUS', 'UNDER_EXPOSED', 'OVER_EXPOSED', 'OFF_CENTER', ...
             'EYELASH_MEDIA', 'PUPIL_CONSTRICT', 'MOTION_ARTIFACT'};

    for i = 1:numel(codes)
        msg = recapture_messages(codes{i});
        testCase.verifyNotEmpty(msg.title);
        testCase.verifyNotEmpty(msg.action);
        testCase.verifyNotEmpty(msg.technicianTip);
        testCase.verifyNotEmpty(msg.severity);
    end
end

% -------------------------------------------------------------------------
% Test 3: HTML Report Generation
% -------------------------------------------------------------------------
function testGenerateHtmlReport(testCase)
    tpl = clinical_report_template();
    tpl.patientId = 'TEST-UNIT-001';

    tempDir = tempname;
    mkdir(tempDir);
    outHtml = fullfile(tempDir, 'test_report.html');

    resPath = generate_clinical_report(tpl, [], [], outHtml);

    testCase.verifyEqual(exist(resPath, 'file'), 2, 'Generated HTML file must exist');
    
    % Verify content inside HTML
    content = fileread(resPath);
    testCase.verifyTrue(contains(content, 'TEST-UNIT-001'));
    testCase.verifyTrue(contains(content, 'DRishti-AI'));
    testCase.verifyTrue(contains(content, 'Review Target: &lt;30s'));
    testCase.verifyTrue(contains(content, 'Explainability Evidence Table'));

    % Cleanup
    delete(outHtml);
    rmdir(tempDir);
end
