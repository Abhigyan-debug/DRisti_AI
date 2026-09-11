function p = applyCalibration(C, scores)
%APPLYCALIBRATION  Map raw referable scores to calibrated probabilities.
%
%   p = APPLYCALIBRATION(C, scores) where C comes from FITCALIBRATOR.
%
%   The returned value may legitimately be shown to a clinician as a
%   confidence, on the dataset the calibrator was fitted for. On a different
%   imaging domain it is NOT trustworthy - see FITCALIBRATOR for the measured
%   evidence.
%
%   See also FITCALIBRATOR.

    arguments
        C struct
        scores double
    end

    switch C.method
        case 'platt'
            p = 1 ./ (1 + exp(-(C.a * scores + C.b)));

        case 'isotonic'
            % Piecewise-constant monotone map; interpolate between knots and
            % clamp outside the fitted range rather than extrapolating, since
            % an isotonic fit says nothing beyond the scores it saw.
            p = interp1(C.x, C.y, scores, 'linear', NaN);
            p(scores <= C.x(1))   = C.y(1);
            p(scores >= C.x(end)) = C.y(end);

        otherwise
            error('drishti:badCalibrator', 'Unknown method: %s', C.method);
    end

    p = max(0, min(1, p));
end
