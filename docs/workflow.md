# Workflow

Every command you need, in the order you will need them. Each number this project
quotes has a command beside it — if one does not, treat the number as unverified.

---

## 1. First run on a new machine

```bash
python tools/verify_setup.py          # exits non-zero if the machine is not ready
```

```matlab
setup_drishti                          % paths + toolbox check (startup.m auto-runs it)
check_environment                      % toolboxes, licences, GPU, datasets
runtests('tests')                      % full suite — should be 33 passed, 0 failed
```

If datasets are missing, point at them **without touching tracked files**: set
`DRISHTI_DATA_ROOT`, or copy `config/local_paths.example.json` to
`config/local_paths.json` and edit `dataRoot`.

> **MATLAB must be R2026a or newer.** The dev GPU (RTX 5050) is compute capability
> 12.0; R2025b and earlier cap at 9.x and silently fall back to CPU.

---

## 2. Screening one image

**Browser dashboard** — drag and drop, two processes:

```bash
# terminal 1 — wait for "READY - waiting for uploads"
matlab -batch "drishtiServeLoop"

# terminal 2
python webapp/server.py               # http://127.0.0.1:8420
```

`python webapp/server.py --start-matlab` launches both; it finds `matlab.exe` via
the Windows registry.

**MATLAB dashboard** — no server, no Python:

```matlab
drishtiDashboard
```

**Programmatic:**

```matlab
out = runDrishtiPipeline('path/to/image.jpg');
out = runDrishtiPipeline(f, 'saveReport', true, 'outputDir', 'reports/mine');
```

---

## 3. Batch and demo

```matlab
S = runDrishtiSystem('path/to/folder', 'limit', 50);   % cohort + district capacity
run_demo                                               % 6 images, prints the caveats too
run_demo(n=12, openReport=true)
```

---

## 4. Re-measuring things

**The discipline that makes these numbers mean anything: develop and tune on
TRAIN, measure once on TEST.** Every command below is labelled with which split it
touches.

### Lesion detectors — the reporting gate

```matlab
validateLesionDetectors('split','test')     % TEST · ~6 min · writes results/lesion_validation.mat
validateLesionDetectors('split','train')    % TRAIN · diagnostic only, labelled optimistic
```

This is what decides `reliable` for every lesion channel. Without it the pipeline
**fails closed** and displays nothing. See [phase2_results.md](phase2_results.md).

### Fitting, not measuring — train only

```matlab
fitExudateSplit                             % TRAIN · hard/soft boundary → config/exudate_split.json
sweepExudateThreshold                       % TRAIN · candidate threshold k
evaluateTwoStageDetector('microaneurysms')  % TRAIN · is the stage-2 classifier worth shipping?
calibrateQualityThresholds                  % Module 1 gate cut-offs
```

### Grading and calibration

```matlab
evaluateGrader                              % APTOS validation split
S = fitSiteCalibration(scores, truth);      % ~200 labelled LOCAL images
runDrishtiPipeline(f, 'siteCalibration', S)
```

> Calibration and evaluation sets must be **disjoint**. Fit, freeze, then evaluate
> on images the fit never saw.

### Other module evaluations

```matlab
evaluateSegmentation('vessels')             % DRIVE — non-standard split, see B2
evaluateDiscLocalization
analyseFailureCases                         % reads the saved Messidor-2 result; runs NO inference
```

---

## 5. Things you must not do

| Never | Why |
|---|---|
| Point anything at **Messidor-2** | Held-out benchmark, spent once on 2026-09-12. `assertNotHoldout` refuses it in code |
| `git add -f` anything under `data/ models/ results/ reports/` | Fundus images carry redistribution restrictions |
| Edit `config/lesion_validation_thresholds.json` without re-running validation | A test fails on the hash mismatch, by design |
| Quote a metric without its protocol | Split, threshold rule and FOV masking change the number |
| Delete `results/messidor2_external_validation.mat` | Irreplaceable — the holdout cannot be read again |

---

## 6. After editing MATLAB code

**Restart the worker.** `matlab -batch` caches functions and will not pick up
changes to a `.m` file mid-session. A code fix appears to do nothing until you
restart it — this costs everyone an hour exactly once.

```bash
# Ctrl-C the worker, then
matlab -batch "drishtiServeLoop"
```

The Python server does not need restarting for `.py` or `index.html` edits beyond
a browser reload.

---

## 7. Before you commit

```matlab
runtests('tests')                     % 33 passed, 0 failed
```

```bash
python tools/verify_setup.py          # must stay green
python tools/check_claims.py --strict # no banned or superseded numbers in the repo
python tools/test_check_claims.py     # ...and the checker itself still catches them
git status --short -- data/ models/ results/ reports/ webapp/jobs/   # must be empty
```

`check_claims.py` is the machine-checkable half of the honesty rules. It exists
because on 2026-09-13 a calibration correction was applied to eight files and
missed in three, one of which was the presentation script — the file nobody
re-reads. Rules live in `config/claim_rules.json`; retire a number by adding it
there in the same commit that publishes its replacement.

Keep `verify_setup.py` and `test_project_setup.m` green. When a `known_missing`
gap in `dataset_layout.json` is filled, the smoke test fails **on purpose** —
update the contract and [datasets.md](datasets.md).

---

## See also

[architecture.md](architecture.md) · [repository_map.md](repository_map.md) ·
[troubleshooting.md](troubleshooting.md) · [PROJECT_STATUS.md](PROJECT_STATUS.md)
