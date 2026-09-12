# TRAIN operating points — frozen before the patch-geometry ablation, and the ablation result

*Recorded 2026-09-12. Every value below is copied from the file named beside it,
not retyped from memory and not rounded.*

**Selection data: IDRiD segmentation TRAIN split only.
Held-out test split: NOT USED.**

Snapshot of record:
[`config/lesion_operating_points_before_ablation.json`](../config/lesion_operating_points_before_ablation.json)
— sha256 `9dae8cc0aa476c96…`, byte-identical to
`config/lesion_operating_points.json` at the moment the ablation started.

---

## 1. Dark-lesion channels — `config/lesion_operating_points.json`

Written by `fitLesionOperatingPoint.m` at 2026-09-12 22:54, from
`rebuildDarkLesionDetectors` at generator `threshSD = 1.00`,
`fragmentRejection = true`, patch geometry `workingScale/v2`.

| channel | applyClassifier | classifierThreshold | TRAIN precision | TRAIN recall | reachedTarget |
|---|---|---|---|---|---|
| microaneurysms | **false** | 0 | 0.02352186464236074 | 0.35696517412935325 | false |
| haemorrhages | **false** | 0 | 0.17376867736579968 | 0.25054945054945055 | false |

`applyClassifier = false` means **stage 1 alone** — the stage-2 CNN is not
applied to that channel, and `classifierThreshold` is inert. The recorded `0` is
a placeholder, not a chosen threshold: the selection rule's winning row was the
stage-1 row (threshold −Inf), and `-Inf` is not representable in JSON.

`reachedTarget = false` on both: no threshold reached the pre-registered TRAIN
precision target of **0.55**, so the rule fell back to best TRAIN F1, and the
best TRAIN F1 was keeping every candidate.

### Why stage 1 won

Both classifiers emit near-constant scores. From the TRAIN sweep:

| channel | candidates | kept at 0.5 | kept at 0.7 |
|---|---|---|---|
| microaneurysms | 37412 | 16481 | **0** |
| haemorrhages | 1807 | 530 | **4** |

Nothing scores above 0.7. Held-out patch AUC was **0.5056** (microaneurysms) and
**0.5579** (haemorrhages, on only 434 patches / 76 positives). At threshold 0.5
the MA classifier makes precision *worse* than keeping everything (0.0168 vs
0.0235) — it discards true positives at least as fast as false ones.

## 2. Exudate channels — NOT in that file

Hard and soft exudates have **no stage-2 classifier and therefore no
classifierThreshold**. There is nothing to fill in for them here, and inventing
a number would be worse than the gap. Their TRAIN-selected parameters are:

| parameter | value | where | selected on |
|---|---|---|---|
| candidate cutoff `thresholdK` | **3.0** | `segmentExudates.m` (arguments block) | TRAIN, by `sweepExudateThreshold` |
| hard/soft boundary `splitThreshold` | **1.2** | `config/exudate_split.json` | TRAIN, n=54, by `fitExudateSplit` |

`fitExudateSplit`'s recorded objective: *max soft F1 subject to hard precision
≥ 0.50, falling back to max hard recall when soft cannot clear the reporting
gate at any boundary.* The fallback branch is the one that fired — soft-exudate
precision peaks at 0.107 across the entire boundary range, so no boundary makes
that channel reportable.

## 3. What none of this is

These are **TRAIN numbers, optimistic by construction**. They are the detector's
settings, not its performance, and they must never be quoted as accuracy.

The display gate is a separate, earlier freeze —
`config/lesion_validation_thresholds.json` (precision ≥ 0.50 AND recall ≥ 0.10,
micro-averaged) — measured only by `validateLesionDetectors('split','test')`.
That **has now been run once** against this configuration (2026-09-13 02:03) and
the result is in [phase2_results.md](phase2_results.md) §2. It did not change the
settings above, and it must not: this file is the input to that measurement, not
an output of it.

For scale: microaneurysm TRAIN precision is 0.024 against a 0.50 gate, on the
optimistic split. That is a ~20x shortfall before the train-to-test gap is even
considered.

## 4. Patch-geometry ablation — the result

```matlab
ablateCandidatePatchGeometry()      % 83.2 min, TRAIN/VAL only, seed 0
```
Saved: `results/patch_geometry_ablation.mat` (run 2026-09-12 23:39).
**Protocol:** patch-level AUC on the classifier's own held-out *images* inside
the IDRiD segmentation **TRAIN** split. Identical 40/14 image split in all four
cells. The IDRiD **test** split was not touched.

| channel | threshSD | fullRes | workingScale | val patches | val positives |
|---|---|---|---|---|---|
| microaneurysms | 1.0 | 0.4990 | 0.5388 | 10095 | 238 |
| microaneurysms | 1.5 | 0.5905 | **0.6100** | 5612 | 150 |
| haemorrhages | 1.0 | 0.5467 | 0.5053 | 434 | 76 |
| haemorrhages | 1.5 | 0.5921 | **0.6321** | 259 | 46 |

Hanley–McNeil standard errors, and each cell against chance:

| cell | AUC | SE | z vs 0.5 |
|---|---|---|---|
| MA fullRes 1.0 | 0.4990 | 0.0189 | −0.06 |
| MA workingScale 1.0 | 0.5388 | 0.0193 | 2.01 |
| MA fullRes 1.5 | 0.5905 | 0.0247 | 3.66 |
| MA workingScale 1.5 | 0.6100 | 0.0248 | **4.44** |
| HE fullRes 1.0 | 0.5467 | 0.0370 | 1.26 |
| HE workingScale 1.0 | 0.5053 | 0.0366 | 0.15 |
| HE fullRes 1.5 | 0.5921 | 0.0478 | 1.92 |
| HE workingScale 1.5 | 0.6321 | 0.0475 | **2.78** |

### 4a. The resolution hypothesis is REFUTED

The ablation existed to ask whether cutting training patches at working scale
(~0.45x on IDRiD, a microaneurysm going from ~34 px to ~16 px inside a 48 px
patch) destroyed the fine texture MA discrimination needs. It does not.

Within a threshSD row — the clean comparison, same candidates and same labels —
the geometry difference never reaches 1.5 standard errors:

| comparison | difference | unpaired SE | z |
|---|---|---|---|
| MA @1.0, fullRes → workingScale | +0.0398 | 0.0271 | +1.47 |
| MA @1.5, fullRes → workingScale | +0.0194 | 0.0350 | +0.56 |
| HE @1.0, fullRes → workingScale | −0.0414 | 0.0521 | −0.79 |
| HE @1.5, fullRes → workingScale | +0.0400 | 0.0674 | +0.59 |

`workingScale` is nominally ahead in three of four cells and behind in the
fourth, all inside noise. **The regression from the historical 0.694 was not
caused by patch resolution.** Note what is *not* claimed: this does not show
the two geometries are equivalent, only that this experiment cannot separate
them at these sample sizes (46–238 positives per cell).

The SEs above are unpaired and therefore conservative for what is a paired
comparison — both geometries score the same val patches. A paired DeLong test
would be the right instrument and could not be run: `ablateCandidatePatchGeometry`
saves per-cell AUC and the score sweep, **not the per-patch scores**. Recorded
as a limitation, not worked around.

### 4b. What *does* separate the cells is the candidate pool

At threshSD 1.0 both classifiers sit at chance (z = −0.06, 2.01, 1.26, 0.15).
At 1.5 both clear it (z = 3.66, 4.44, 1.92, 2.78). So the classifier *can*
learn something — but only against the easier negative distribution that the
stricter generator produces.

**This does not rank the two thresholds, and must not be read as doing so.**
The ablation's own help states why: changing threshSD changes the negative
distribution itself, so a lower AUC at 1.0 may mean "the classifier got worse"
*or* "the negatives got harder" while the detector as a whole improved. AUC
also cannot see generator recall, which moves the opposite way — MA generator
recall falls 0.382 → 0.235 between 1.0 and 1.5.

### 4c. Nothing here is near the display gate

The best cell in the grid is AUC 0.6321, on 46 positives. Across all eight
cells, patch-level precision at the classifier's own best threshold never
exceeds **0.293** (HE workingScale 1.5) and never exceeds **0.040** for
microaneurysms. The display gate is lesion-level micro precision ≥ **0.50**.
No configuration in this experiment is within a factor of two of it, and the
MA cells are short by more than 10x.

---

## 5. Freeze decision — 2026-09-13, recorded BEFORE the held-out run

**Frozen configuration: `workingScale/v2`, generator `threshSD = 1.00`,
`fragmentRejection = true`, `applyClassifier = false` on both dark channels.**

That is the configuration already on disk and already fit on TRAIN at
2026-09-12 22:54. **The ablation changes nothing**, and the reasoning is
recorded here so that "we changed nothing" is a decision with a justification
rather than an omission:

1. **Geometry:** §4a is a null result. There is no measured reason to switch to
   `fullRes`, and `workingScale` is what both training and inference already
   cut, so switching would buy a nominal +0.04 AUC at 0.6 SE in exchange for
   re-running a 99-minute rebuild.
2. **threshSD stays 1.00.** The value was chosen by a rule stated *before* its
   sweep ran — largest threshSD at which both channels' TRAIN generator recall
   reaches 0.25 — on generator-recall grounds. Generator recall is a hard
   ceiling on final recall, and recall is half the display gate. Re-picking it
   at 1.50 now, *after* seeing an AUC table, would be choosing a parameter on
   the strength of a metric that cannot see the constraint the parameter was
   chosen to satisfy. §4c is the reason it would not even pay: the stage-2
   classifier it would enable still cannot reach the precision gate.
3. **`applyClassifier = false` stands.** Stage 2 is not applied to either dark
   channel, so the AUC grid above describes a component that is **switched off
   in the shipped pipeline**. It is recorded because a future rebuild needs to
   know that the resolution theory was tested and failed, not because it
   licenses displaying anything.

**Consequence for the held-out run:** it measures **stage 1 alone** for
microaneurysms and haemorrhages. It is not a test of the two-stage detector.

---

## 6. Status

- [x] `rebuildDarkLesionDetectors` completed — 99.3 min, exit 0, no errors
- [x] Operating points read and recorded above
- [x] Snapshot saved and hash-verified against the live config
- [x] Selection provenance recorded: TRAIN only
- [x] Patch-geometry ablation (development experiment, TRAIN/VAL only) — §4
- [x] Freeze one configuration — §5, recorded before the held-out run
- [x] Held-out test — `validateLesionDetectors('split','test')`, run ONCE
      (2026-09-13 02:03; gate sha `1c447a7428e4781a…` unchanged). Result:
      MA precision 0.028 / recall 0.409, HE 0.164 / 0.311. Both clear the recall
      gate, both fail precision, neither is displayed. No setting in this file
      was altered afterwards.

The ablation wrote only to `models/ablation/` and
`results/patch_geometry_ablation.mat`. It did not call
`fitLesionOperatingPoint`, did not write the config, and did not touch the test
split, so the record in §1 stayed valid throughout — confirmed by the hash.
