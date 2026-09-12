# Phase 2 — Segmentation: results and reporting decisions

*Measured 2026-09-12. Every number here is reproducible with the command shown
beside it. Nothing in this document is quoted from an earlier write-up.*

> **Status note (2026-09-13).** The dark-lesion path has been **re-measured** on
> the held-out split after the five defects in §4 were fixed. §2 is current.
> Microaneurysm and haemorrhage **recall rose ~5x and both channels now clear the
> recall gate**; both still fail the precision gate, MA by ~18x. The set of
> displayed channels is unchanged: hard exudates, and nothing else. §2a carries
> the before/after and says which parts of it are attributable to the fixes.

Phase 2 is **complete in the sense that matters**: all seven sub-tasks are built,
each is measured against the ground truth that exists for it, the protocol is
stated, and every channel is gated on that measurement before it can reach a
clinician. It is **not** complete in the sense of "all detectors work" — three of
the four lesion channels fail their reporting bar, and this document says so
plainly rather than reporting only the one that passes.

A validated negative result is a result. A detector that is quietly displayed
without one is a liability.

---

## 1. The reporting bar, frozen before measurement

[`config/lesion_validation_thresholds.json`](../config/lesion_validation_thresholds.json)
— SHA-256 `1c447a7428e4781a…`, frozen **before** `validateLesionDetectors` was
first executed. The saved result records that hash, and
`tests/test_lesion_validation.m` fails if the file changes without a re-run.

```
reliable = (micro precision >= 0.50) AND (micro recall >= 0.10)
```

Precision gates because a fabricated finding on a clinical document outweighs a
missed one — overall severity is carried by the grader, not by this channel. The
recall floor exists because precision alone can be bought by near-silence, and
once lesion *locations* are drawn, a silent detector reads as a clean retina. F1
is reported but does not gate.

---

## 2. Lesion channels — held-out results

```matlab
validateLesionDetectors('split','test')     % ~6 min, 27 images
```

**Protocol:** IDRiD segmentation **test** split, n=27. FOV-masked on both sides.
Per-lesion matching by 8-connected component overlap. Micro-averaged (pooled
counts). Single fixed operating point. An absent mask counts as *lesion absent*,
so all 27 images score every channel — soft exudates are present in only 14, and
scoring them on those 14 alone would discard every false positive on the other 13.

*Measured 2026-09-13 02:03. Gate file sha256 `1c447a7428e4781a…` — unchanged from
the freeze, so the bar was not touched between the two runs.*

| channel | precision | recall | F1 | TP | FP | FN | verdict |
|---|---|---|---|---|---|---|---|
| microaneurysms | 0.028 | 0.409 | 0.053 | 457 | 15774 | 641 | not validated — precision |
| haemorrhages | 0.164 | 0.311 | 0.215 | 165 | 839 | 368 | not validated — precision |
| **hard exudates** | **0.817** | **0.133** | **0.229** | 795 | 178 | 3567 | **DISPLAYED** |
| soft exudates | 0.038 | 0.026 | 0.031 | 1 | 25 | 37 | not validated — precision |

Both dark channels now fail on **precision alone**. Previously they failed both
gates. That is a change in the shape of the failure, not a pass.

**Why the test split.** `segmentExudates` ships `thresholdK = 3.0`, selected on
the *training* split by `sweepExudateThreshold`. Scoring it there measures fit to
the data that chose it. The test split has never fed a parameter choice.

**Micro vs macro.** Macro (mean of per-image rates, images with nothing
predicted left out of the mean rather than scored 0) gives precision MA 0.030,
HE 0.150, EX 0.702, SE 0.111 and recall MA 0.438, HE 0.291, EX 0.167, SE 0.014.
**All four verdicts are identical under both**, so no outcome here is an artefact
of the aggregation choice.

⚠️ Macro is **not comparable to the 2026-09-12 run**. The NaN-omission rule above
was introduced in the same commit as the five fixes, so the estimator changed
under it. Micro — the gating statistic — is comparable, and §2a uses only micro.

---

## 2a. What the five fixes actually did

Same command, same split, same 27 images, same frozen gate file, one fixed
operating point on each side. Micro-averaged:

| channel | metric | 2026-09-12 (with the five defects) | 2026-09-13 (fixed) | change |
|---|---|---|---|---|
| microaneurysms | precision | 0.046 | **0.028** | **worse, 0.6x** |
| | recall | 0.077 | **0.409** | better, 5.3x |
| | F1 | 0.057 | 0.053 | flat |
| | TP | 86 | 457 | 5.3x |
| | FP | 1798 | 15774 | 8.8x |
| haemorrhages | precision | 0.130 | **0.164** | better, 1.3x |
| | recall | 0.054 | **0.311** | better, 5.8x |
| | F1 | 0.077 | **0.215** | better, 2.8x |
| | TP | 58 | 165 | 2.8x |
| | FP | 388 | 839 | 2.2x |
| hard exudates | all | 0.817 / 0.133 / 0.229 | 0.817 / 0.133 / 0.229 | **identical** |
| soft exudates | all | 0.038 / 0.026 / 0.031 | 0.038 / 0.026 / 0.031 | **identical** |

**The two exudate channels are the control, and they held.** Their micro
precision, recall, F1, TP, FP and FN are identical across the two runs, down to
the count. The five fixes were confined to the dark-lesion path, so the exudate
channels should not have moved, and they did not. That is what makes the MA and
haemorrhage deltas attributable to the fixes rather than to run-to-run drift.

**Haemorrhages improved on every axis.** Precision, recall and F1 all rose; F1
nearly tripled. The channel is now short of the precision gate by ~3x rather
than ~4x.

**Microaneurysm precision got worse, and that is expected, not a regression.**
Two things changed direction at once:

- Stage 2 is now **off** for this channel (`applyClassifier = false`, chosen on
  TRAIN — see [train_operating_points_frozen.md](train_operating_points_frozen.md)),
  because it lost the TRAIN sweep to keeping every candidate. The old 0.046 was
  measured with a classifier connected *at the wrong patch geometry* — it was
  discarding candidates on the strength of a train/serve mismatch. Precision it
  bought that way was not precision the method had.
- The generator now runs at `threshSD = 1.00` instead of the 2.0 the production
  path was feeding a classifier trained at 0.75. That roughly triples the
  candidate pool, which is the direct cause of FP rising 8.8x.

The net on F1 is flat (0.057 → 0.053) and the net on recall is 5.3x. What the
fixes bought on this channel is a detector whose training and inference agree
and whose recall ceiling is real; what they did not buy is precision.

**Neither dark channel is displayable, and neither is close.** MA needs an ~18x
precision improvement, haemorrhages ~3x. Nothing in §2 or §4 licenses showing
either one to a clinician.

## 3. Three things this pass fixed

### 3a. The stage-2 classifiers were trained, measured, and never connected

`models/candidate_classifier_{microaneurysms,haemorrhages}.mat` existed and
`evaluateTwoStageDetector` scored them, but the production path —
`extractLesionFeatures` → `detectDarkLesions` — was called with no classifier at
all. **Every image that ever went through the pipeline, the dashboard or a
clinical report was scored by stage 1 alone.**

That is why two microaneurysm precisions coexisted in the project: 0.054 from the
two-stage evaluation, and 0.028 from what actually shipped. They were measured on
different pipelines and the weaker one was the one running.

Now wired via `loadCandidateClassifiers`, and `validateLesionDetectors` scores the
same call the report ships.

`detectDarkLesions` also routed classifiers through an `if/elseif`, so supplying
both applied only the first and left the other channel raw. It now loops.

### 3b. `scoreCandidates` allocated unboundedly

It built `zeros([48 48 3 n*8])` for every candidate at once, plus a full copy for
the valid subset. With ~20 000 candidates on a noisy image that is 4.4 GB twice
over. The bug was invisible while no classifier was loaded; wiring one in ran the
validation out of memory on image 26 of 27. Now chunked at 1024 candidates, so
memory is bounded by the chunk rather than by how noisy the image is.

### 3c. The hard/soft exudate boundary had never been fitted

`segmentExudates` split hard from soft on `combined >= 1.0` — a plausible-looking
constant on a normalised score, fitted to nothing. It produced a soft channel
with **precision 0.000**: four detections across 27 images, none correct.

```matlab
fitExudateSplit           % ~5 min, IDRiD TRAIN only
```

The sweep (train, n=54) is in `config/exudate_split.json`. The finding:

> **Soft-exudate precision peaks at 0.107 across the entire boundary range** —
> an order of magnitude below the 0.50 gate.

So the soft channel is a **detector-level failure, not a threshold choice**. No
boundary makes it reportable. The objective was stated before the sweep (max soft
F1 s.t. hard precision ≥ 0.50); when the sweep showed soft can never clear the
gate, the rule fell back — by a condition decided by the frozen gate, not by
preference — to maximising hard-exudate recall under the same constraint, because
the boundary then only affects the channel that is actually displayed. Both
branches and the full sweep table are in `fitExudateSplit`'s help. Fitted value:
**1.2**.

---

## 4. Five defects found AFTER these numbers were measured

The table in §2 is the last held-out measurement. Since it was taken, five
defects were found in the dark-lesion path. All five are fixed. **None of the
numbers above has been re-measured**, and nothing below claims the fixes helped
— they are stated as defects because each is wrong on its own terms, not
because a score moved.

The single command that redoes the cycle:

```matlab
rebuildDarkLesionDetectors        % sweep -> build -> train -> fit operating point
validateLesionDetectors('split','test')   % then this, ONCE
```

### 4a. Training patches and inference patches were cut at different scales

`buildCandidateDataset` cut its 48 px training patches from the
**full-resolution** frame. `detectDarkLesions` cut its 48 px inference patches
from the **working-scale** frame, where the field of view is normalised to
1536 px. On IDRiD (4288×2848, FOV diameter ~3280 px) that scale factor is
~0.47, so an inference patch covered about **2.1× the retinal area** of a
training patch. The classifier was trained on lesions at roughly twice the
apparent size it met in production.

Nothing errored: the patches were the right shape and the wrong content. And
because the factor is `min(1, 1536 / fovDiameter)`, the mismatch **scaled with
image resolution** and vanished on images small enough not to be downscaled —
a camera fingerprint baked into the classifier, which is the exact failure the
disc-diameter convention exists to prevent everywhere else in Module 2.

Both paths now call `cutCandidatePatches`, so the geometry cannot drift again.
Saved models carry `meta.patchGeometry`, and `loadCandidateClassifiers`
**refuses** a model without the current stamp — the two classifiers on disk
today were trained under the old geometry, so until they are rebuilt the
pipeline runs stage 1 alone and says so.

### 4b. Edge candidates bypassed the false-positive filter entirely

The builder *skipped* any candidate whose patch would leave the frame ("skip
rather than invent pixels"); the scorer *kept* it, **unscored**, because `keep`
was initialised `true` and only written where a patch could be cut. A candidate
too close to the edge to be classified therefore went straight through to the
report. IDRiD's FOV is flush with the top and bottom of the frame, so this was
not a corner case — it leaked unfiltered candidates on every image in the set.
Both sides now clamp (replicate) instead, so every candidate is scored.

### 4c. The production path fed the classifier the wrong candidate set

The classifiers were trained on candidates generated at `meta.threshSD`. The
production path — `extractLesionFeatures` and `validateLesionDetectors` —
called `detectDarkLesions` with **no threshSD at all** and got the `2.0`
default. A classifier trained to sort a dense, permissive candidate set was
applied to a sparse, strict one.

`evaluateTwoStageDetector` had honoured `meta.threshSD` since it was written.
That is why its numbers and the validated numbers disagreed and the
disagreement could not be explained by aggregation or split — they were two
different generators. `threshSD` now defaults to "adopt the classifier's own",
and an explicit value that conflicts with a loaded classifier disables that
classifier loudly rather than silently mismatching.

### 4d. Small elongated fragments were booked as flame haemorrhages

The MA/haemorrhage split was

```matlab
area <= maAreaMax && eccentricity < 0.85   ->  microaneurysm
else                                       ->  haemorrhage
```

so a five-pixel elongated vessel remnant — far too small to be any grade of
haemorrhage — fell into the `else` and was counted as one, specifically as a
*flame* haemorrhage. Eccentricity was acting as a router when it should have
been acting as a reject. Size is the clinical discriminator; small-and-elongated
is now discarded as a fragment. The old routing is still reachable
(`'fragmentRejection', false`) so the change can be measured on TRAIN rather
than asserted.

`haemByType` was also tallied *before* stage-2 filtering, so dot+blot+flame
could exceed the `haemCount` reported beside it. It is now tallied from the
survivors.

### 4e. The stage-2 threshold: nobody had ever chosen it

`detectDarkLesions` shipped `classifierThreshold = 0.5` as a literal in its
arguments block. **0.5 is the loosest point on the score sweep
`trainCandidateClassifier` already prints.** The detector was running at the
setting that maximises false positives, against a display gate that gates on
*precision* — the one knob that trades the failing metric for the passing one
was pinned to its worst value and written down nowhere.

It now lives in [`config/lesion_operating_points.json`](../config/lesion_operating_points.json),
is selected on the **TRAIN** split by `fitLesionOperatingPoint`, and is read at
runtime by `loadLesionOperatingPoints` — the same discipline already applied to
the hard/soft exudate boundary and to the referable-DR endpoint. Selection on
train is not pedantry: if the threshold were picked on test, the gate in
`lesion_validation_thresholds.json` would be certifying a number chosen to pass
it.

**This is where the haemorrhage question gets settled — and it is now settled.**
Wiring the classifier in had dropped held-out haemorrhage F1 from 0.138 to 0.077.
That observation came from the **test** split and was therefore not actionable
there; acting on it would be test-set tuning, which is the failure this phase's
whole protocol exists to prevent. So stage-1-alone was entered in the TRAIN sweep
as an ordinary row (threshold −Inf, keep every candidate).

**It won, on both channels.** `applyClassifier = false` for microaneurysms *and*
haemorrhages in [`config/lesion_operating_points.json`](../config/lesion_operating_points.json),
selected on TRAIN at 2026-09-12 22:54 by the pre-registered rule, `reachedTarget
= false` on both because no threshold reached the TRAIN precision target of 0.55.
**The shipped dark-lesion detector is stage 1 alone.** The §2 numbers measure
that, not a two-stage detector.

A separate 2x2 ablation then asked *why* stage 2 is useless here — whether the
patch-resolution change had destroyed the signal. It had not: geometry accounts
for nothing (all four within-threshSD comparisons under 1.5 SE), while the
candidate pool accounts for everything (at `threshSD` 1.0 both classifiers sit at
chance; at 1.5 they clear it). Full grid, standard errors and the freeze decision:
[train_operating_points_frozen.md](train_operating_points_frozen.md) §4–§5.

Practical impact on the report remains nil: both dark channels fail the precision
gate with or without the classifier, so nothing reaches a clinician either way.

### 4f. What is still true regardless

The binding constraint is **annotated data, not architecture** — 519
microaneurysm positives from 54 images — and stage 2 can only ever *discard*
candidates, so generator recall is a hard ceiling no classifier can raise.
Published IDRiD ceilings (MA AUPR 0.50, HE 0.68) say these are genuinely hard
problems. None of the five fixes changes that. They remove reasons the numbers
were worse than the method deserves; they do not make the method better than it
is. A per-lesion MA score near 0.9 after this would still mean a bug or a leak.

## 5. Other sub-tasks

| # | Task | State | Note |
|---|---|---|---|
| 2a | Optic disc localization | built, measured | `evaluateDiscLocalization`; well short of the 21.07 px benchmark — re-measure before quoting |
| 2b | Fovea localization | built | derived from 2a; drives laterality and the DME distance |
| 2c | Vessel segmentation | built, measured **non-standard** | `evaluateSegmentation('vessels')`. **DRIVE test GT is withheld (B2)**, so it is scored on the 20 *training* images. Not comparable to published test-split tables |
| 2d | Hard + soft exudates | **hard validated**, soft failed | §2, §3c |
| 2e | Microaneurysms | built, **failed gate on precision** | §2, re-measured 2026-09-13 after the five fixes; recall gate now passed, precision short ~18x — §2a |
| 2f | Haemorrhages | built, **failed gate on precision** | §2, re-measured 2026-09-13; improved on every axis, precision short ~3x — §2a |
| 2g | Neovascularization | built, **unvalidatable** | no ground truth exists in any corpus we hold; it is a heuristic and is never displayed as a finding |

---

## 6. What reaches the clinical report

Only hard exudates. The report carries:

- a **Module 2 detector validation** table listing *all four* channels with their
  precision/recall/F1 and a DISPLAYED or NOT VALIDATED badge — failures are shown,
  not omitted, because a report listing only the channel that worked implies the
  others were never tried;
- **validated lesion locations** for passing channels only, in **disc diameters**
  (never pixels — our corpora span a 6.7× resolution range);
- for every withheld channel, its measured numbers and the reason, never a zero.
  Zero means "we looked and found none", which is a clinical claim.

Reliability is read from `results/lesion_validation.mat` at runtime and **fails
closed**: no validation file on a machine means no channel is displayed. It used
to be four hardcoded booleans in `extractLesionFeatures`, which meant the report's
honesty depended on someone remembering to edit a source file after re-measuring.

---

## 7. Honest summary

The binding constraint is **annotated data, not architecture** — 519 microaneurysm
positives from 54 images. Published IDRiD ceilings (MA AUPR 0.50, HE 0.68,
SE 0.70, EX 0.885) confirm these are hard problems; a per-lesion MA score near 0.9
would mean a bug or a leak, not a breakthrough.

What Phase 2 delivers is one trustworthy channel, three honestly-labelled
failures, a reporting gate that cannot be bypassed by editing a flag, and a
re-runnable command behind every number.

After the five-defect fix and the re-measurement, the failure is better
characterised than it was: **both dark channels clear the recall gate and fail
only on precision**, the stage-2 classifier is measured as useless *and the
resolution explanation for that has been tested and refuted*, and the train→test
gap is small (MA precision 0.024 train → 0.028 test; HE 0.174 → 0.164). These
detectors are not overfit. They are weak, on a channel published work also finds
hard, with 519 MA positives from 54 images to learn from. The remaining lever is
annotated data.
