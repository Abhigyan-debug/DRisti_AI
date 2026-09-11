function T = loadIdridLandmarks(split, landmark)
%LOADIDRIDLANDMARKS  Read IDRiD optic-disc / fovea centre ground truth.
%
%   T = LOADIDRIDLANDMARKS(split, landmark) returns a table with columns
%   imageName, x, y and imagePath.
%
%   split     'train' | 'test'
%   landmark  'disc'  | 'fovea'
%
%   The CSVs carry ~45 trailing empty columns and a blank tail row, and the
%   headers contain spaces and hyphens ('X- Coordinate', 'Y - Coordinate') that
%   readtable mangles differently across releases. Both are handled here so no
%   caller has to know.
%
%   Note the fovea CSVs have no 'a. ' / 'b. ' filename prefix while the
%   optic-disc ones do - see config/dataset_layout.json.
%
%   Example
%     T = loadIdridLandmarks('train', 'disc');
%     img = imread(T.imagePath{1});
%
%   See also LOCATEOPTICDISC, EVALUATEDISCLOCALIZATION.

    arguments
        split (1,:) char {mustBeMember(split, {'train', 'test'})}
        landmark (1,:) char {mustBeMember(landmark, {'disc', 'fovea'})} = 'disc'
    end

    cfg = drishti_paths();

    if strcmp(split, 'train')
        imageDir = cfg.idrid.locTrainImages;
        discFile  = 'a. IDRiD_OD_Center_Training Set_Markups.csv';
        foveaFile = 'IDRiD_Fovea_Center_Training Set_Markups.csv';
    else
        imageDir = cfg.idrid.locTestImages;
        discFile  = 'b. IDRiD_OD_Center_Testing Set_Markups.csv';
        foveaFile = 'IDRiD_Fovea_Center_Testing Set_Markups.csv';
    end

    if strcmp(landmark, 'disc')
        csvPath = fullfile(cfg.idrid.locLabels, '1. Optic Disc Center Location', discFile);
    else
        csvPath = fullfile(cfg.idrid.locLabels, '2. Fovea Center Location', foveaFile);
    end

    if ~isfile(csvPath)
        error('drishti:missingLandmarks', 'Ground truth not found: %s', csvPath);
    end

    opts = detectImportOptions(csvPath, 'VariableNamingRule', 'preserve');
    raw = readtable(csvPath, opts);

    % Columns are positional rather than by name: the headers differ in spacing
    % between the disc and fovea files, and MATLAB's name-mangling of
    % 'X- Coordinate' is not stable across releases.
    names = string(raw{:, 1});
    xs = raw{:, 2};
    ys = raw{:, 3};

    if ~isnumeric(xs), xs = str2double(string(xs)); end
    if ~isnumeric(ys), ys = str2double(string(ys)); end

    % Drop the trailing blank row(s)
    keep = names ~= "" & ~ismissing(names) & ~isnan(xs) & ~isnan(ys);
    names = names(keep);
    xs = double(xs(keep));
    ys = double(ys(keep));

    paths = strings(numel(names), 1);
    for k = 1:numel(names)
        paths(k) = string(fullfile(imageDir, char(names(k) + ".jpg")));
    end

    T = table(names, xs, ys, paths, ...
        'VariableNames', {'imageName', 'x', 'y', 'imagePath'});

    missing = ~arrayfun(@(p) isfile(p), T.imagePath);
    if any(missing)
        warning('drishti:missingImages', ...
            '%d of %d %s/%s images not found on disk (first: %s)', ...
            nnz(missing), height(T), split, landmark, T.imagePath(find(missing,1)));
    end
end
