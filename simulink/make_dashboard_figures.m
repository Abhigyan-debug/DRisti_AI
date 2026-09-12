function files = make_dashboard_figures(opts)
%MAKE_DASHBOARD_FIGURES  Phase 7 deck visuals, generated from measured results.
%
%   files = MAKE_DASHBOARD_FIGURES() writes PNGs to docs/figures/.
%   files = MAKE_DASHBOARD_FIGURES(outDir=..., show=false)
%
%   Every figure is built from a saved result or a live computation - none of
%   the numbers are typed in here. If a source file is missing the figure is
%   skipped with a warning rather than drawn from placeholder data, because a
%   plausible-looking chart backed by nothing is worse than a missing chart.
%
%   Sources:
%     1 bottleneck      recommend_district_configuration (live)
%     2 specialist load recommend_district_configuration (live)
%     3 calibration     results/site_calibration_study.mat
%     4 failure modes   results/messidor2_external_validation.mat (saved read)
%
%   RUN_DISTRICT_SCENARIO_ANALYSIS(true) calls this - its savePlots flag was
%   previously accepted, documented, and then never used.
%
%   See also RECOMMEND_DISTRICT_CONFIGURATION, ANALYSEFAILURECASES.

    arguments
        opts.outDir (1,:) char = ''
        opts.show (1,1) logical = false
    end

    here = fileparts(mfilename('fullpath'));
    outDir = opts.outDir;
    if isempty(outDir), outDir = fullfile(here, '..', 'docs', 'figures'); end
    if ~isfolder(outDir), mkdir(outDir); end

    cfg = drishti_paths();
    vis = 'off'; if opts.show, vis = 'on'; end
    files = strings(0,1);

    rec = recommend_district_configuration('verbose', false);

    % ---- 1. where the district actually binds -----------------------------
    f = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 760 420]);
    t = rec.unitsRequiredPerStage;

    % CATEGORICAL RE-SORTS THE BARS. barh(categorical(...)) plots in category
    % order, which is alphabetical - "AI compute node" first - while `worst` is
    % an index into the TABLE. Indexing CData by the table row therefore painted
    % the highlight on whatever happened to sort first: the red bar landed on AI
    % compute (0.29 units) while the real bottleneck, acquisition (4.36), stayed
    % blue. The chart's own title said "Acquisition, not specialist review" and
    % its colour said the opposite. Sort the data into category order first, then
    % table row and bar position mean the same thing.
    cats = categorical(t.stage);
    [cats, order] = sort(cats);
    vals = t.unitsRequiredAtFullUtilisation(order);

    b = barh(cats, vals, 0.6);
    b.FaceColor = 'flat';
    [~, worst] = max(vals);
    b.CData = repmat([0.45 0.62 0.81], numel(vals), 1);
    b.CData(worst,:) = [0.85 0.33 0.27];
    xlabel('units of that resource required (at 100% utilisation)');
    title({'Where a 100,000-patient/year district actually binds', ...
           'Acquisition, not specialist review'});
    grid on; set(gca,'FontSize',10);
    files(end+1) = saveFig(f, outDir, '01_bottleneck');

    % ---- 2. specialist load by operating point ----------------------------
    % The headline honest finding: the benefit of AI triage is ~2x, not ~10x,
    % once the classifier's real specificity is used instead of assuming the
    % referral rate equals disease prevalence.
    og = rec.ophthalmologists.contract_general;
    vals = [og.preAiBaselineMinPerDay, og.idealised.minPerDay, ...
            og.uncalibrated.minPerDay, og.calibrated.minPerDay];
    lbls = categorical({'Pre-AI: read everything', 'AI, idealised (NOT achievable)', ...
                        'AI, uncalibrated (UNSAFE)', 'AI, site-calibrated (SAFE)'});
    lbls = reordercats(lbls, {'Pre-AI: read everything','AI, idealised (NOT achievable)', ...
                              'AI, uncalibrated (UNSAFE)','AI, site-calibrated (SAFE)'});
    f = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 820 430]);
    b = bar(lbls, vals, 0.6, 'FaceColor','flat');
    b.CData = [0.40 0.40 0.45; 0.80 0.75 0.35; 0.85 0.33 0.27; 0.24 0.58 0.36];
    ylabel('ophthalmologist minutes / day');
    title({'Specialist load at 400 patients/day, by operating point', ...
           'Only the calibrated point is both safe and honest'});
    ylim([0 max(vals)*1.18]);
    text(1:4, vals + max(vals)*0.04, compose('%.1f', vals), ...
        'HorizontalAlignment','center','FontWeight','bold');
    grid on; set(gca,'FontSize',10);
    files(end+1) = saveFig(f, outDir, '02_specialist_load');

    % ---- 3. the calibration trade-off -------------------------------------
    cf = fullfile(cfg.resultsDir, 'site_calibration_study.mat');
    if isfile(cf)
        C = load(cf); S = C.R;

        % ⚠️ THIS IS THE IDRiD STUDY, NOT MESSIDOR-2.
        % RUNSITECALIBRATIONSTUDY fits on IDRiD TRAIN (413) and evaluates on
        % IDRiD TEST (103). The subtitle used to read "Messidor-2, disjoint
        % calibration/evaluation halves", which is a different experiment
        % entirely - phase3_results.md reports both, and the Messidor-2 one
        % gives 90.0%/57.9% at n=200 against this one's 83.9%/75.6%. A chart
        % labelled with the wrong dataset invites exactly the comparison that
        % makes two correct results look like a contradiction.
        %
        % The baseline is drawn too. Without it the curves are two flat lines
        % and the reader cannot see the thing the figure exists to show: what
        % calibration BUYS, and what it costs.
        f = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 820 450]);
        b = S.baseline;

        yyaxis left
        errorbar(S.sizes, 100*S.sensMean, 100*S.sensStd, '-o', 'LineWidth', 1.8);
        hold on
        yline(100*b.sensitivity, ':', 'LineWidth', 1.6, 'Color', [0.20 0.40 0.75]);
        ylabel('sensitivity (%)'); ylim([0 100]);

        yyaxis right
        plot(S.sizes, 100*S.specMean, '-s', 'LineWidth', 1.8);
        yline(100*b.specificity, ':', 'LineWidth', 1.6, 'Color', [0.85 0.45 0.15]);
        ylabel('specificity (%)'); ylim([0 100]);

        xlabel('local images used for site calibration');
        title({'How many local images does a new camera need?', ...
               sprintf('IDRiD train to test, disjoint by construction (n=%d eval)', S.nTest), ...
               'Dotted lines = uncalibrated APTOS threshold'});
        grid on; set(gca,'FontSize',10);
        legend({'sensitivity (calibrated)', 'sensitivity (uncalibrated)', ...
                'specificity (calibrated)', 'specificity (uncalibrated)'}, ...
               'Location','southeast', 'FontSize', 8);
        files(end+1) = saveFig(f, outDir, '03_calibration_tradeoff');
    else
        warning('drishti:noCalibStudy', 'site_calibration_study.mat missing - figure 3 skipped.');
    end

    % ---- 4. what the system misses ----------------------------------------
    mf = fullfile(cfg.resultsDir, 'messidor2_external_validation.mat');
    if isfile(mf)
        F = analyseFailureCases('verbose', false);
        G = F.messidor2.byTrueGrade;
        keep = G.nReferable > 0;              % grades 0 has nothing referable to miss
        G = G(keep,:);
        f = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 780 430]);
        b = bar(categorical(G.trueDrGrade), G.missRatePct, 0.6, 'FaceColor','flat');
        cmap = [0.85 0.33 0.27; 0.85 0.33 0.27; 0.45 0.62 0.81; 0.45 0.62 0.81];
        b.CData = cmap(1:height(G),:);
        xlabel('true ICDR grade'); ylabel('% of referable cases missed');
        ylim([0 105]);
        title({'The miss is concentrated at grade 2 - early referable disease', ...
               'Sight-threatening grades 3-4 are largely caught'});
        text(1:height(G), G.missRatePct + 4, compose('%.0f%%', G.missRatePct), ...
            'HorizontalAlignment','center','FontWeight','bold');
        grid on; set(gca,'FontSize',10);
        files(end+1) = saveFig(f, outDir, '04_failure_by_grade');
    else
        warning('drishti:noMessidorResult', 'messidor2 result missing - figure 4 skipped.');
    end

    fprintf('  %d dashboard figures -> %s\n', numel(files), outDir);
end


function p = saveFig(f, outDir, name)
%SAVEFIG  Write a deck-ready PNG.
%
%   MATLAB R2026a renders figures on a DARK background by default, which is
%   wrong for slides and unreadable in print. Every axis is forced to a light
%   theme here rather than relying on whatever theme the running session has.

    set(f, 'Color', 'w', 'InvertHardcopy', 'off');
    ax = findall(f, 'Type', 'axes');
    for a = ax'
        set(a, 'Color', 'w', 'XColor', [0.15 0.15 0.15], ...
               'YColor', [0.15 0.15 0.15], 'GridColor', [0.75 0.75 0.75]);
        set(a.Title,  'Color', 'k');
        set(a.XLabel, 'Color', 'k');
        set(a.YLabel, 'Color', 'k');
    end
    set(findall(f, 'Type', 'text'), 'Color', 'k');

    % Legends are not axes and were missed by the loop above, so they kept
    % R2026a's dark default: white-on-black box floating in a white chart.
    for lg = findall(f, 'Type', 'Legend')'
        set(lg, 'Color', 'w', 'TextColor', 'k', 'EdgeColor', [0.75 0.75 0.75]);
    end
    p = string(fullfile(outDir, [name '.png']));
    exportgraphics(f, p, 'Resolution', 150, 'BackgroundColor', 'white');
    close(f);
end
