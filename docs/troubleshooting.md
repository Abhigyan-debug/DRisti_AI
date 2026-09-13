# Troubleshooting

Traps that have actually cost time on this project, with the diagnosis that
resolved each. Everything here was hit for real, not imagined.

---

## MATLAB

### "Undefined function `runDrishtiPipeline`"

`setup_drishti` has not run. `startup.m` does it automatically when MATLAB opens
*at the project root*; opening elsewhere skips it.

```matlab
setup_drishti
```

### Code changes have no effect

**`matlab -batch` caches functions for the life of the session.** Editing a `.m`
file while `drishtiServeLoop` is running changes nothing — the worker keeps
running the version it parsed at startup. The symptom is maddening: your fix is
clearly in the file, and the output is clearly the old behaviour.

**Restart the worker after every `.m` edit.** This was hit twice in one session.

### MATLAB is installed but `where matlab` finds nothing

MATLAB is not on `PATH` by default on Windows. Worse, on this project's dev
machine `MATLABROOT` is `D:\MATLAB\_installer` — a directory name that reads like
a leftover installer and caused a search to conclude MATLAB was absent entirely.

Find it properly:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\MathWorks\MATLAB\*' | Select MATLABROOT
```

⚠️ **Do not "clean up" `D:\MATLAB\_installer`.** It is the real installation.

### "Out of memory" partway through a validation run

IDRiD frames are 4288×2848. A single `im2double` is ~293 MB, and several
full-resolution masks live at once.

Two causes were found and fixed, both worth knowing:

1. **`scoreCandidates` allocated `zeros([48 48 3 n*8])`** for every candidate at
   once, plus a full copy. With ~20 000 candidates that is 4.4 GB twice. Now
   chunked at 1024 candidates.
2. **`segmentExudates` retained per-component pixel lists** on every call. They
   are only needed by `fitExudateSplit`, so they are now opt-in via
   `returnSplitDiagnostics`.

If you still hit it: **stop the dashboard worker first.** A warm worker holds a
loaded ResNet, and stale MATLAB processes accumulate.

```powershell
Get-Process -Name MATLAB | Select Id, @{n='MB';e={[math]::Round($_.WorkingSet64/1MB)}}
```

### `run('/tmp/script.m')` fails

Git Bash's `/tmp` is not a Windows path MATLAB can resolve. Use a full Windows
path, or put scripts inside the project.

### `struct('_purpose', ...)` errors

MATLAB field names cannot start with an underscore, even though the JSON
convention in `config/` uses `_purpose` and `_note` keys. Build those with
`jsonencode` on a struct using legal names, or assemble the JSON text directly.

---

## Browser dashboard

### "The MATLAB inference worker is not running" — but it *is*

Fixed, and worth understanding because the reasoning generalises.

MATLAB is single-threaded: while `runDrishtiPipeline` is executing, nothing can
refresh the heartbeat file. The server used to read that silence as death after
12 s and abandon jobs that were running perfectly well — reliably, for any image
slower than the ones the timeout was tuned on.

The fix is a **claim marker**: the worker writes `<id>.started` in the
microseconds before the expensive call. Once a job is claimed the server waits and
never consults the heartbeat again. Only an *unclaimed* job with a heartbeat older
than 240 s counts as a dead worker.

If you see this message now, the worker genuinely is not running.

### Engine chip says OFFLINE

`webapp/jobs/worker.alive` is missing or stale. Start the worker and wait for
`READY - waiting for uploads` — startup includes a ~30 s warm-up that pays the
one-off GPU/cuDNN cost so the first user does not.

### A screening takes 30 s, not 8 s

Expected for large frames. 8 s is a warm IDRiD-sized image; the page shows an
elapsed counter so a long wait does not look like a hang.

### Upload refused: "that filename looks like Messidor-2"

Working as designed. The held-out benchmark was spent once on 2026-09-12 and is
refused at every entry point. Rename only if you are *certain* the image is not
from that corpus.

---

## Data

### Messidor-2 glob finds ~60% of the images

It is mixed-format: 1 058 `.png` + 690 `.JPG` (**uppercase**). Glob
case-insensitively or you silently drop 40% of the benchmark.

### A quality metric behaves differently across datasets

Two known traps, both measured:

- **FOV coverage is a camera fingerprint, not a quality signal** (IDRiD 0.691,
  Messidor-2 0.465). An absolute threshold rejects all of Messidor-2.
- **Raw Laplacian variance tracks image size** (r = −0.75 within APTOS), so it
  cannot be thresholded globally across a 6.7× resolution range.

### Ground-truth mask missing for some images

IDRiD ships a mask only where that lesion **is present** — soft exudates exist in
26 of 54 train and 14 of 27 test images. An absent mask means *lesion absent*, not
*unlabelled*. Scoring only the images that have masks discards every false
positive on the negatives, which is how a weak detector comes to look strong.

### `test_project_setup` fails after you add data

By design. When a `known_missing` gap in `dataset_layout.json` is filled, the
contract is out of date — update it and [datasets.md](datasets.md).

---

## Results that look wrong

### A lesion channel shows "not validated" when you expect numbers

Either the gate was not cleared, or `results/lesion_validation.mat` is absent. The
pipeline **fails closed**: no measurement means no display.

```matlab
validateLesionDetectors('split','test')
```

### A microaneurysm score near 0.9

**That is a bug or a leak, not a breakthrough.** Best in the world on IDRiD is
AUPR ~0.50. Check you are not scoring on the split you tuned on, and that ground
truth and prediction are not accidentally the same array.

### Sensitivity collapses on a new camera

Expected and measured: 90.3% internal vs **31.2%** on Messidor-2 at the frozen
threshold. The model *ranks* fine (AUC 0.885) — the cut point does not transfer.
Fit a local operating point with `buildSiteCalibration` (~200 labelled local
images); the pipeline then loads it automatically. Measured end to end on IDRiD
it recovers sensitivity 75.0% → 82.8% and costs specificity 97.4% → 76.9%. It
does **not** reach the 90% target out of sample.

### Simulink model runs but SimEvents blocks are missing

SimEvents is **licensed but not installed**. `ver()` and `license()` both report
success for an absent product — which is exactly why `check_environment` reports
`[NOT INST]` from a separate check. The model uses the native continuous-queue
formulation instead.

---

## See also

[workflow.md](workflow.md) · [architecture.md](architecture.md) ·
[repository_map.md](repository_map.md)
