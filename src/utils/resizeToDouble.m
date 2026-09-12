function small = resizeToDouble(img, scale, method)
%RESIZETODOUBLE  imresize(im2double(img), scale) without the 3x memory peak.
%
%   small = RESIZETODOUBLE(img, scale) returns the same array as
%
%       imresize(im2double(img), scale, 'bilinear')
%
%   bit for bit, while never holding more than one channel of full-resolution
%   double at a time.
%
%   small = RESIZETODOUBLE(img, scale, method) uses another interpolation
%   method.
%
%   WHY
%   ---
%   `imresize(im2double(img), scale, ...)` converts the WHOLE frame first. On a
%   4288x2848x3 IDRiD frame that is 293 MB of double, allocated in full, purely
%   to be shrunk to about 60 MB on the next operation. Five functions in the
%   per-image hot path did exactly this - DETECTDARKLESIONS, SEGMENTEXUDATES,
%   SEGMENTVESSELS, LOCATEOPTICDISC and SWEEPEXUDATETHRESHOLD - and they run one
%   after another on the same image, so the transient peak recurs four or five
%   times per iteration.
%
%   It is what the out-of-memory abort moved to once TOGRAY was fixed:
%
%       Out of memory.
%       Error in imresize>resizeAlongDim (line 227)
%       Error in detectDarkLesions (line 122)
%
%   Resizing channel by channel peaks at one channel of double (98 MB) plus the
%   small output, instead of three channels at once.
%
%   BIT-EXACT, NOT APPROXIMATELY EQUAL
%   ----------------------------------
%   im2double scales elementwise and imresize's separable kernels act on each
%   colour plane independently, so splitting the work by channel changes the
%   order of nothing. This matters because fov.diameter and the working-scale
%   frame feed every Module 1 threshold and every Module 2 detector - a
%   half-ULP change here would ripple into measured numbers that were frozen
%   against the old behaviour. TEST_FOV_MEMORY pins the equality.
%
%   See also TOGRAY, DETECTFOV, IMRESIZE.

    arguments
        img {mustBeNumeric}
        scale (1,1) double {mustBePositive}
        method (1,:) char = 'bilinear'
    end

    if ndims(img) == 3 && size(img, 3) == 3
        % Convert and resize one plane at a time, and size the output from the
        % first plane rather than predicting imresize's rounding.
        first = imresize(im2double(img(:,:,1)), scale, method);
        small = zeros([size(first,1) size(first,2) 3]);
        small(:,:,1) = first;
        clear first
        for c = 2:3
            small(:,:,c) = imresize(im2double(img(:,:,c)), scale, method);
        end
        return
    end

    small = imresize(im2double(img), scale, method);
end
