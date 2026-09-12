function results = evaluateGateOnDevSet(opts)
%EVALUATEGATEONDEVSET  Gate decision rates on the DEVELOPMENT corpora.
%
%   results = EVALUATEGATEONDEVSET() reports pass/enhance/reject rates and the
%   reasons behind each rejection, across APTOS, IDRiD and DRIVE.
%
%   results = EVALUATEGATEONDEVSET(nPerCorpus=70, saveRejects=false)
%
%   MESSIDOR-2 IS DELIBERATELY EXCLUDED
%   -----------------------------------
%   It is the held-out benchmark and is evaluated EXACTLY ONCE, at Phase 6,
%   after the gate is frozen. Repeatedly checking reject rates on it during
%   development is how a held-out set quietly becomes a tuning set - the
%   decisions you make after each look are the leak, even when you never touch
%   the labels.
%
%   Protocol
%   --------
%     1. Tune the gate here, on the development corpora.
%     2. Freeze config/quality_thresholds.json and commit it.
%     3. Run the gate on Messidor-2 once, reporting reject rate against
%        adjudicated_gradable, plus the throughput consequence.
%     4. Whatever comes out is the result. No going back to step 1.
%
%   Known calibration gap
%   ---------------------
%   None of these three corpora carry independent gradability labels, so this
%   function measures the gate's decision DISTRIBUTION, not its accuracy. Real
%   calibration needs labelled gradability, which this corpus does not carry.
%
%   See also GATEIMAGE, CALIBRATEQUALITYTHRESHOLDS.

    arguments
        opts.nPerCorpus (1,1) double {mustBePositive} = 70
        opts.saveRejects (1,1) logical = false
        opts.seed (1,1) double = 0
    end

    cfg = drishti_paths();
    rng(opts.seed);

    % Development corpora only. Adding Messidor-2 here defeats the purpose.
    corpora = { ...
        'APTOS', cfg.aptos.trainImages; ...
        'IDRiD', cfg.idrid.gradeTrainImages; ...
        'DRIVE', cfg.drive.trainImages};

    results = struct('corpus', {}, 'n', {}, 'pass', {}, 'enhance', {}, ...
                     'reject', {}, 'rejectCodes', {}, 'medianSeconds', {});

    fprintf('\n%-10s %5s %8s %9s %8s   %s\n', ...
        'corpus', 'n', 'pass', 'enhance', 'reject', 'reject reasons');

    for k = 1:size(corpora, 1)
        folder = corpora{k, 2};
        if ~isfolder(folder)
            continue
        end
        L = dir(fullfile(folder, '*'));
        L = L(~[L.isdir]);
        n = min(opts.nPerCorpus, numel(L));
        L = L(randperm(numel(L), n));

        counts = struct('pass', 0, 'enhance', 0, 'reject', 0);
        codes = strings(0, 1);
        times = zeros(n, 1);

        for i = 1:n
            img = imread(fullfile(folder, L(i).name));
            q = assessQuality(img);
            d = gateImage(q);
            times(i) = q.elapsed;
            counts.(d.decision) = counts.(d.decision) + 1;
            if strcmp(d.decision, 'reject')
                rj = d.reasons(strcmp({d.reasons.severity}, 'reject'));
                codes(end+1, 1) = string(rj(1).code); %#ok<AGROW>
            end
        end

        fprintf('%-10s %5d %7.0f%% %8.0f%% %7.0f%%   %s\n', corpora{k,1}, n, ...
            100*counts.pass/n, 100*counts.enhance/n, 100*counts.reject/n, ...
            summariseCodes(codes));

        results(end+1) = struct('corpus', corpora{k,1}, 'n', n, ...
            'pass', counts.pass/n, 'enhance', counts.enhance/n, ...
            'reject', counts.reject/n, 'rejectCodes', {codes}, ...
            'medianSeconds', median(times)); %#ok<AGROW>
    end

    fprintf('\n  median assessQuality: %.3f s/image\n', ...
        median([results.medianSeconds]));
    fprintf('  Messidor-2 excluded by design - see the help text.\n');
end


function s = summariseCodes(codes)
    if isempty(codes)
        s = '-';
        return
    end
    [u, ~, ix] = unique(codes);
    cnt = accumarray(ix, 1);
    [cnt, o] = sort(cnt, 'descend');
    u = u(o);
    m = min(3, numel(u));
    parts = strings(m, 1);
    for z = 1:m
        parts(z) = sprintf('%s(%d)', u(z), cnt(z));
    end
    s = strjoin(parts, ', ');
end
