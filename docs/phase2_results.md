# Phase 2 — Segmentation: results and reporting decisions

*Measured 2026-09-12. Every number here is reproducible with the command shown
beside it. Nothing in this document is quoted from an earlier write-up.*

> **Status note.** The microaneurysm and haemorrhage numbers in §2 are the last
> held-out measurement, and they predate five defects found afterwards in that
> path (§4). All five are fixed; none of the numbers has been re-measured. Read
> §2 as "what those channels scored with those bugs in", not as their current
> state — and do not read §4 as a claim that anything improved.

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

| channel | precision | recall | F1 | TP | FP | FN | verdict |
|---|---|---|---|---|---|---|---|
| microaneurysms | 0.046 | 0.077 | 0.057 | 86 | 1798 | 1001 | not validated |
| haemorrhages | 0.130 | 0.054 | 0.077 | 58 | 388 | 505 | not validated |
| **hard exudates** | **0.817** | **0.133** | **0.229** | 795 | 178 | 3567 | **DISPLAYED** |
| soft exudates | 0.038 | 0.026 | 0.031 | 1 | 25 | 37 | not validated |

**Why the test split.** `segmentExudates` ships `thresholdK = 3.0`, selected on
the *training* split by `sweepExudateThreshold`. Scoring it there measures fit to
the data that chose it. The test split has never fed a parameter choice.

**Micro vs macro.** Macro (mean of per-image rates) gives MA 0.045, HE 0.154,
EX 0.666, SE 0.000. **Every verdict is identical under both**, so the outcome is
not an artefact of the aggregation choice.

---

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

**This is where the haemorrhage question gets settled.** Wiring the classifier
in dropped held-out haemorrhage F1 from 0.138 to 0.077 (precision 0.115 →
0.130, recall 0.174 → 0.054). That observation came from the **test** split and
was therefore not actionable there — acting on it would be test-set tuning,
which is the failure this phase's whole protocol exists to prevent. So
stage-1-alone is entered in the TRAIN sweep as an ordinary row (threshold
−Inf, keep every candidate). If it wins under the pre-registered selection
rule, `applyClassifier` is written `false` and the shipped detector skips stage
2 for that channel. Decided on train, by a rule fixed in advance, recorded in a
committed file.

Practical impact today remains nil: haemorrhages fail the reporting gate with or
without the classifier, so nothing reaches a clinician either way.

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
| 2e | Microaneurysms | built, failed gate | §2; five defects fixed since, unmeasured — §4 |
| 2f | Haemorrhages | built, failed gate | §2; five defects fixed since, unmeasured — §4 |
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
