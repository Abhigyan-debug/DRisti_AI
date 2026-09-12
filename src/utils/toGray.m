function gray = toGray(img)
%TOGRAY  Convert a fundus image to a normalised double grayscale in [0,1].
%
%   gray = TOGRAY(img) accepts uint8/uint16/double, RGB or already-grayscale,
%   and always returns double in [0,1].
%
%   Fundus-specific note: this uses standard luminance weights, NOT the green
%   channel. The green channel carries the best lesion contrast and Module 2
%   should use it for detection - but for QUALITY assessment we want overall
%   exposure and focus, which luminance represents better. Use GETGREEN where
%   lesion contrast is what matters.
%
%   See also GETGREEN, DETECTFOV.

    arguments
        img {mustBeNumeric}
    end

    % PER-CHANNEL CONVERSION, and why it is not a micro-optimisation.
    %
    % This used to be `img = im2double(img)` on the whole frame, then a
    % weighted sum. On a 4288x2848 IDRiD frame that materialises
    % 4288*2848*3*8 B = 293 MB of double purely to collapse it to one channel
    % on the very next line - and DETECTFOV calls this as its first statement,
    % once per image, on every pass over the split. It is where a long run
    % actually runs out of host memory:
    %
    %     Out of memory.
    %     Error in toGray (line 27)  gray = 0.299*img(:,:,1) + ...
    %     Error in detectFOV (line 35)
    %
    % Converting one channel at a time peaks at 98 MB instead of 293 MB.
    %
    % The result is BIT-IDENTICAL, not merely close: im2double scales
    % elementwise, so im2double(img)(:,:,k) and im2double(img(:,:,k)) are the
    % same values, and the products and sum that follow are then the same
    % operations in the same order. Module 1's measured thresholds are safe.
    isRGB = ndims(img) == 3 && size(img, 3) == 3;

    if isRGB
        if ~isfloat(img)
            gray = 0.299 * im2double(img(:,:,1)) + ...
                   0.587 * im2double(img(:,:,2)) + ...
                   0.114 * im2double(img(:,:,3));
            return
        end
        if max(img(:)) > 1
            img = img / 255;    % already double, but on a 0-255 scale
        end
        gray = 0.299 * img(:,:,1) + 0.587 * img(:,:,2) + 0.114 * img(:,:,3);
        return
    end

    if ~isfloat(img)
        img = im2double(img);
    elseif max(img(:)) > 1
        % Already double but on a 0-255 scale
        img = img / 255;
    end

    if ismatrix(img)
        gray = img;
    else
        error('toGray:badInput', ...
            'Expected an RGB or grayscale image, got size [%s].', ...
            num2str(size(img)));
    end
end
