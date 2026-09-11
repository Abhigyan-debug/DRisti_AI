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

    if ~isfloat(img)
        img = im2double(img);
    elseif max(img(:)) > 1
        % Already double but on a 0-255 scale
        img = img / 255;
    end

    if ndims(img) == 3 && size(img, 3) == 3
        gray = 0.299 * img(:,:,1) + 0.587 * img(:,:,2) + 0.114 * img(:,:,3);
    elseif ismatrix(img)
        gray = img;
    else
        error('toGray:badInput', ...
            'Expected an RGB or grayscale image, got size [%s].', ...
            num2str(size(img)));
    end
end
