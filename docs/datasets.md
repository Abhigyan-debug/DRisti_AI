# Dataset Inventory & Split Strategy

**Phase 0 deliverable.** Verified 2026-09-11 against the actual extracted files.

All counts below were **measured**, not copied from dataset documentation — and
then cross-checked against the published specs (they match; see §6).

---

## 1. Where the data lives

The datasets total **~12.8 GB** and are deliberately kept **outside the git repo**.

```
D:\DRishti_AI_data\            <- DATA ROOT (not on C:, which was 98% full)
├── _archives\                 <- original downloads, kept as backup (12.8 GB)
├── aptos2019\
├── idrid\
├── drive\
└── messidor2\
```

`<repo>\data` is a **Windows directory junction** pointing at `D:\DRishti_AI_data`,
so all code can just use the relative path `data/...` as if the datasets were in
the repo. `data/` is in `.gitignore`.

**Teammates on other machines** do *not* need a junction. Either:

- set the `DRISHTI_DATA_ROOT` environment variable, or
- copy `config/local_paths.example.json` → `config/local_paths.json` and edit it
  (it is git-ignored).

`config/drishti_paths.m` resolves these in that order. Run `setup_drishti` to
confirm every path resolves.

To reproduce the layout from scratch: `python tools/organize_datasets.py`
(idempotent — safe to re-run; writes `docs/dataset_manifest.json`).

---

## 2. APTOS 2019 — DR severity grading

**Role:** primary training set for Module 3 (Phase 3).

| | Files | Labels |
|---|---|---|
| `train_images/` | **3,662** | ✅ `train.csv` (`id_code`, `diagnosis` 0–4) |
| `test_images/` | **1,928** | ❌ **none — never publicly released** |

### ICDR grade distribution (train, n=3662)

| Grade | n | % |
|---|---|---|
| 0 — No DR | 1,805 | 49.3% |
| 1 — Mild NPDR | 370 | 10.1% |
| 2 — Moderate NPDR | 999 | 27.3% |
| 3 — Severe NPDR | 193 | 5.3% |
| 4 — Proliferative DR | 295 | 8.1% |
| **Referable (≥2)** | **1,487** | **40.6%** |

**Implications for Phase 3:**

- Grade 3 is only **5.3%** of the set (193 images). Class-weighted loss or
  resampling is not optional.
- The binary referable split (40.6 / 59.4) is far more balanced than the 5-class
  problem — tune the *referable* threshold on the binary task, report the 5-class
  confusion matrix separately.
- **The test set is unusable for evaluation.** All APTOS metrics must come from a
  stratified split of the 3,662 labelled images. Use a fixed seed and commit the
  split indices so results are reproducible.
- Resolutions are **wildly heterogeneous** (see §5) — this set alone justifies
  Module 1's normalization stage.

---

## 3. IDRiD — lesion-level ground truth (India-sourced)

**Role:** Module 2 lesion supervision + disc/fovea localization (Phase 2), and a
second grading source (Phase 3). Most clinically relevant corpus we hold, since
it is Indian-population data captured in Nanded, Maharashtra.

### 3a. Segmentation (`idrid/segmentation/`)

Images: **54 train / 27 test**, all 4288×2848.

Pixel-level masks per lesion — note **not every image has every lesion**:

| Lesion | Train masks | Test masks |
|---|---|---|
| Microaneurysms (MA) | 54 | 27 |
| Haemorrhages (HE) | 53 | 27 |
| Hard exudates (EX) | 54 | 27 |
| Soft exudates (SE) | **26** | 14 |
| Optic disc (OD) | 54 | 27 |

Soft exudates appear in fewer than half the images — an SE model trained on 26
images will be fragile. Plan accordingly (heavy augmentation; treat SE as the
lowest-confidence lesion channel in Module 4's evidence table).

### 3b. Disease grading (`idrid/grading/`)

Images: **413 train / 103 test**. Labels in
`2. Groundtruths/{a,b}. IDRiD_Disease Grading_{Training,Testing} Labels.csv`,
columns: `Image name`, `Retinopathy grade`, `Risk of macular edema`.

| Grade | Train | % | Test | % |
|---|---|---|---|---|
| 0 — No DR | 134 | 32.4% | 34 | 33.0% |
| 1 — Mild | 20 | 4.8% | 5 | 4.9% |
| 2 — Moderate | 136 | 32.9% | 32 | 31.1% |
| 3 — Severe | 74 | 17.9% | 19 | 18.4% |
| 4 — PDR | 49 | 11.9% | 13 | 12.6% |
| **Referable (≥2)** | **259** | **62.7%** | **64** | **62.1%** |

The train/test grade distributions match closely — the official split is
well-stratified, so **use it as-is** rather than re-splitting.

> 💡 The `Risk of macular edema` column is DME ground truth we already hold. See
> [literature_benchmarks.md](literature_benchmarks.md) §6 — every published RDR
> benchmark includes DME in the positive class, so this column is the cheapest
> path to making our numbers directly comparable.

### 3c. Localization (`idrid/localization/`)

Same **413 / 103** images, with CSV centre coordinates for:

- `2. Groundtruths/1. Optic Disc Center Location/`
- `2. Groundtruths/2. Fovea Center Location/`

Benchmark to beat: **21.07 px** mean Euclidean error (IDRiD challenge winner).

---

## 4. Messidor-2 — external validation

**Role:** held out entirely until Phase 6. Do not train on it, do not tune on it,
do not look at it.

| | Count |
|---|---|
| `IMAGES/` | **1,748** |
| `messidor-2.csv` (left/right eye pairs) | **874 rows** |

This is **exactly** the validation set used by Gulshan et al. (JAMA 2016): 1748
images, 874 patients. That makes our Phase 6 comparison directly meaningful.

> ### ⚠️ Blocker: no grade labels
>
> Our copy ships images + eye pairing only. `messidor-2.csv` has two columns
> (`left`, `right`) and **no diagnosis column**. Without labels, Phase 6 cannot
> report sensitivity or specificity at all.
>
> **Fix:** download the adjudicated reference standard released by Krause et al.
> — DR severity, DME, and gradability, adjudicated to consensus by 3
> fellowship-trained retina specialists:
> **<https://www.kaggle.com/datasets/google-brain/messidor2-dr-grades>**
>
> Place it at `data/messidor2/messidor_data.csv`. This is a Phase 0 task that is
> **not yet done** — it needs a Kaggle account.

Also note the paper reports **3 ungradable images** in this set (1745 fully
gradable). Our Module 1 should independently flag roughly that many; if it rejects
50, the gate is mis-tuned.

### Mixed file formats

`IMAGES/` is **not uniformly PNG**:

| Extension | Count |
|---|---|
| `.png` (lowercase) | 1,058 |
| `.JPG` (**uppercase**) | 690 |

Two consequences:

1. **Glob case-insensitively.** A `dir('*.png')` in MATLAB on a case-sensitive
   filesystem, or a hardcoded `.png`, silently drops 40% of the benchmark set —
   and the loss would be invisible until the final numbers looked odd.
2. **~40% of our external benchmark carries JPEG compression artifacts.** For
   microaneurysm-scale features this is not cosmetic. If Phase 6 performance
   splits along format lines, that is a finding to report, not a bug to hide.

`messidor-2.csv` was verified to match the files on disk exactly: 874 rows ×
2 eyes = 1,748 names, all present, none extra.

---

## 5. DRIVE — vessel segmentation

**Role:** train/evaluate the vessel model (Phase 2).

| Split | images | `1st_manual` (vessel GT) | `mask` (FOV) |
|---|---|---|---|
| `training/` | 20 | **20** ✅ | 20 |
| `test/` | 20 | **0** ❌ | 20 |

All images 565×584.

> ### ⚠️ Gap: no test-set vessel ground truth
>
> This distribution withholds the test annotations (they are the challenge's
> hidden labels). We therefore have **20 annotated images total**.
>
> **Options for Phase 2:**
> 1. Split the 20 annotated training images (e.g. 15 train / 5 val) and report on
>    our own split — stating clearly that this is *not* the official DRIVE test
>    protocol, so our Dice is not directly comparable to the table in
>    [literature_benchmarks.md](literature_benchmarks.md) §2.5.
> 2. Obtain the official test annotations from
>    [drive.grand-challenge.org](https://drive.grand-challenge.org) and report on
>    the official split — the only way our numbers are comparable.
>
> Option 2 is strongly preferred. Do it early; 20 images is a thin base either way.

Remember the evaluation protocol rules from the literature review: **FOV-masked,
single global threshold, Dice + AUC, official split** — and say so in the results.

---

## 6. Image resolutions (Module 1 design input)

Sampled 80 images per set:

| Set | Dominant resolutions |
|---|---|
| APTOS train | 1050×1050, 2416×1736, 2588×1958 — **highly mixed** |
| APTOS test | 640×480 (majority), 2416×1736, 819×614 |
| IDRiD (all parts) | 4288×2848 — **uniform** |
| Messidor-2 | 2240×1488, 2304×1536, 1440×960 — 3 camera configs |
| DRIVE | 565×584 — uniform |

Three consequences for **Module 1**:

1. **A 6.7× linear range** (640×480 → 4288×2848) across the corpora. Any
   sharpness metric computed in raw pixel units (Laplacian variance included) is
   resolution-dependent and will mis-score across datasets.

   **Now measured.** Within APTOS alone (constant content, FOV diameter 551–3616 px,
   n=220), raw Laplacian variance correlates with FOV diameter at **r = −0.80** — it
   is measuring image size about as much as it measures focus. Rescaling to a
   canonical FOV diameter cuts that to **r = −0.43**: necessary, but **not
   sufficient**. Module 1 needs FOV-diameter-banded thresholds, or a genuinely
   scale-invariant focus measure. See
   [phase1_quality_baseline.md](phase1_quality_baseline.md) §1.

   *This has to be tested within one corpus — pooled across all four the correlation
   is confounded, because DRIVE is simultaneously the smallest and the sharpest set.*

   **FOV coverage is a camera fingerprint, not a quality signal.** Median coverage is
   0.691 for IDRiD (σ≈0.001), 0.687 for DRIVE, **0.465** for Messidor-2, and trimodal
   for APTOS (0.474 / 0.791 / 0.906). A coverage threshold calibrated on IDRiD would
   reject **every Messidor-2 image** — our entire external benchmark — as poorly
   framed, while they are perfectly gradable. Judge coverage relative to the detected
   FOV geometry, never as an absolute fraction of the frame.
2. **APTOS train and test differ in resolution distribution** from each other —
   a reminder that field images will not look like training images.
3. Lesion scale matters: a microaneurysm is a few pixels at 640×480 and tens of
   pixels at 4288×2848. Module 2's MA detector must operate at a
   **FOV-normalised scale**, not a fixed pixel scale.

---

## 7. Split strategy (locked for the project)

| Dataset | Train | Validate | Test |
|---|---|---|---|
| APTOS 2019 | stratified split of 3,662 labelled | ↑ same, fixed seed, committed indices | — |
| IDRiD grading | official 413 | (fold from the 413) | official 103 |
| IDRiD segmentation | official 54 | (fold from the 54) | official 27 |
| DRIVE | from the 20 annotated, or official split if GT obtained | | |
| **Messidor-2** | **never** | **never** | **final benchmark only, once** |

**Rule:** the referable-DR operating threshold is chosen on validation data and
**frozen in a committed config file** before Messidor-2 is touched. Touching
Messidor-2 more than once turns it into a tuning set and invalidates the headline
claim.

---

## 8. Provenance & licensing

Before publishing results or the demo, confirm redistribution terms for each
corpus — they differ, and several prohibit redistributing images. **Do not commit
any fundus image to git**, including in `reports/` samples, until this is checked.

| Dataset | Source |
|---|---|
| APTOS 2019 | [kaggle.com/c/aptos2019-blindness-detection](https://www.kaggle.com/c/aptos2019-blindness-detection) |
| IDRiD | [ieee-dataport.org](https://ieee-dataport.org/open-access/indian-diabetic-retinopathy-image-dataset-idrid) (CC BY 4.0) |
| DRIVE | [drive.grand-challenge.org](https://drive.grand-challenge.org) |
| Messidor-2 | [adcis.net/en/third-party/messidor2](https://www.adcis.net/en/third-party/messidor2/) |

Cite Porwal et al. (2019) for IDRiD and Decencière et al. for Messidor as those
terms require.

---

## 9. Outstanding data tasks

- [ ] **Download Messidor-2 adjudicated grades** (Kaggle; blocks all of Phase 6)
- [ ] **Obtain DRIVE test-set vessel GT** (or accept a non-standard split, documented)
- [ ] Decide DME in/out of the referable definition (blocks Phase 3 metric design)
- [ ] Confirm per-dataset redistribution terms before the demo ships
- [ ] Commit the APTOS split indices once generated
