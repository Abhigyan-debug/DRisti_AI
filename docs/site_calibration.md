# Per-site calibration — what it fits, what it needs, and what it actually buys

*Written 2026-09-13. Every number here is from a saved artifact or a saved
result file, with the command that produced it beside it.*

> **The headline, stated before the detail.** Per-site calibration is
> implemented, fitted, saved, loaded automatically, and measured on a held-back
> set. On the one site where it has been measured end to end, it moved
> sensitivity **75.0% → 82.8%** and specificity **97.4% → 76.9%**.
> It did **not** reach the 90% sensitivity target out of sample.
> **No Messidor-2 number has been re-measured, and none may be claimed.**

---

## 1. What `fitSiteCalibration` fits

[`src/grading/fitSiteCalibration.m`](../src/grading/fitSiteCalibration.m) fits
**two** things from **one** labelled sample drawn from the target camera.

### Inputs it needs

| input | what it must be | why |
|---|---|---|
| `scores` | the grader's **raw** referable score per image — probability mass at ICDR ≥ 2, i.e. `explainGrading`'s `E.referableScore` | this is the quantity the pipeline compares against the threshold at run time. A Platt-mapped score here would be a silent scale mismatch |
| `truth` | logical referable label per image | resolved through `config/clinical_definitions.json`, never by comparing a raw DME integer — that was blocker B12 |
| `targetSensitivity` | default 0.90 | the sensitivity the threshold is chosen to reach **on the calibration sample** |

**Hard requirements.** Both classes must be present or it raises
`drishti:degenerateCalibrationSet`. NaN scores are dropped. Below 50 images it
returns a populated `S.warning` — the threshold is a noisy estimate and the
struct says so, because the caller cannot tell from the number itself.

**It does not need:** images, masks, lesion features, the held-out benchmark, or
anything from Module 2. Scores and labels, nothing else.

### What it fits

| output | what it is |
|---|---|
| `a`, `b` | a **Platt map** (logistic on the raw score), fitted with smoothed targets so near-separable scores do not drive the fit to ±∞. This changes only the number **shown** as a confidence |
| `threshold` | the cut on the Platt-calibrated scale |
| `thresholdRaw` | the equivalent cut on the **raw** score scale. **This is the one that decides refer / no-refer** — `runDrishtiPipeline` compares `E.referableScore` against it directly |
| `calibrationSensitivity`, `calibrationSpecificity` | what that cut achieved **on the sample it was fitted to** — optimistic by construction |

### How the threshold is chosen

The lowest threshold whose sensitivity reaches `targetSensitivity` on the
calibration sample, and the specificity that came with it is recorded beside it.
**Sensitivity is the target; specificity is the price.** Neither is optimised
alone, and no output of this function reports one without the other.

### What it is not

It is not a fix to the model. The model's *ranking* transfers — AUC held at
0.885 on Messidor-2 while sensitivity collapsed to 31.2%. Only the cut point is
wrong, because **a threshold is a property of an imaging domain, not of a
model.** Calibration moves the cut point. It cannot make a detector better than
its AUC.

---

## 2. The calibration set — and the line that is not crossed

```matlab
buildSiteCalibration        % ~3 min: score 516 IDRiD images, fit, evaluate, save
```

| | dataset | n | role |
|---|---|---|---|
| **calibration** | IDRiD grading **TRAIN** split | 413 (259 referable) | the fit sees these |
| **evaluation** | IDRiD grading **TEST** split | 103 (64 referable) | the fit never sees these |

Disjoint by construction — they are different folders of a published split.

**Messidor-2 is not involved at any point.** It is not read, not fitted on, and
not consulted to choose anything. It was read exactly once, on 2026-09-12, and
that read is spent. The artifact records this in
`meta.heldOutBenchmarkUsed`, and `test_site_calibration.m` fails if any
provenance field ever names it.

**Why IDRiD is the right calibration site.** It is a different centre and camera
from APTOS (Aravind Eye Hospital, Kowa VX-10α), fully labelled, and carries no
holdout status — so it can be used repeatedly to develop and verify a fix. It is
a genuine cross-domain test, not an in-domain one.

---

## 3. What it measured

*Artifact: `models/site_calibration.mat`, fitted 2026-09-13 on
`baseline_grader.mat`.*

### On the calibration set — optimistic, do not quote

| | sensitivity | specificity |
|---|---|---|
| site-calibrated | 90.3% | 89.6% |

It reaches its 90% target here, as it must — this is the sample the threshold
was chosen on. This pair is recorded for completeness and is **not** a result.

### On the held-back set — these are the numbers

**IDRiD grading TEST split, n=103, prevalence 62.1%, never seen by the fit.**

| operating point | sensitivity | specificity |
|---|---|---|
| shipped APTOS threshold (uncalibrated) | 75.0% | 97.4% |
| **site-calibrated** | **82.8%** | **76.9%** |

Reproduces the n=413 row of the independent
`runSiteCalibrationStudy` sweep exactly, which is a useful cross-check that the
artifact builder and the study agree.

### Read this honestly

1. **Calibration helps, and it is not free.** +7.8 pp sensitivity for −20.5 pp
   specificity. For screening that is the correct direction — a false positive
   costs a review, a false negative costs sight — but it is a trade, not a win,
   and it raises referral volume straight into Module 5's throughput model.
2. **It did not reach the target out of sample.** 90.3% on the fit became 82.8%
   on held-back images. The 90% target is met on the calibration sample and
   **not** at a new site. Anyone quoting "calibration gets us to 90%" is quoting
   the optimistic half.
3. **413 images was the whole available pool** and it still fell short. The
   earlier size sweep shows the mean is flat from ~50 images onward
   (83.7% at 100, 83.9% at 200, 82.8% at 413) — more calibration data buys
   *reliability*, not a higher mean. The remaining gap is not a data-volume
   problem.

---

## 4. What may and may not be said about Messidor-2

**May be said.** Uncalibrated external sensitivity on Messidor-2 was **31.2%**
at the frozen threshold, specificity 99.5%, AUC 0.8848, measured once on
2026-09-12. That is the honest external headline and it stands unchanged.

**May be said.** Per-site calibration, measured end to end on a different
camera (IDRiD), recovers part of a transfer gap: 75.0% → 82.8% sensitivity at a
cost of 97.4% → 76.9% specificity.

**May NOT be said.** That calibration takes Messidor-2 from 31.2% to 90.0%.

That 90.0% / 57.9% pair comes from a **post-hoc demonstration on Messidor-2
itself** — random disjoint halves of the spent benchmark, reported in
[phase3_results.md](phase3_results.md) §3b. The splits are internally disjoint,
so it is not a leak in the narrow sense, but it is a procedure demonstrated on
the held-out set rather than an independent result, and the set cannot be read
again to check it. It is **not** independent support for a deployment claim.

The strongest independently-supported statement available is the IDRiD one in
§3, and it does not reach 90%.

---

## 5. How the pipeline uses it

**Resolution order**, in `runDrishtiPipeline`, `runDrishtiSystem`,
`drishtiServeLoop` and `drishtiDashboard`:

1. a calibration passed by the caller
2. this machine's saved artifact — [`loadSiteCalibration`](../src/grading/loadSiteCalibration.m)
   reads `models/site_calibration.mat`, or `$DRISHTI_SITE_CALIBRATION`
3. the shipped APTOS threshold — **uncalibrated**, announced loudly

### An absent artifact is not an error

No calibration is the *default* state, not a broken one. A rural site with no
local labels still has to be able to screen, and the uncalibrated state is
already loud: a red chip, a red strip above the result, a warning from
`runDrishtiSystem`, and the caveat above every report.

### A malformed artifact is refused, not patched

The failure that matters is not an absent file — it is a file that loads, looks
plausible, and silently shifts the operating point. An artifact is used only if
it carries `meta.artifactVersion` and every field the pipeline reads.

**A bare `fitSiteCalibration` struct is refused.** It has `a`, `b` and
`thresholdRaw`, so it would work — but it records no site and no grader, and an
operating point with no provenance is exactly what the 31.2% failure was made
of. Same fail-closed discipline as `loadCandidateClassifiers` and
`loadLesionReliability`.

### A calibration belongs to ONE camera

`meta.site` names it, and the UI shows it — the chip reads
`SITE CALIBRATED · IDRiD (Aravind…)`, not just `SITE CALIBRATED`. Nothing in
code can tell which camera took the photograph on screen; only the operator can.
Screening camera B through camera A's calibration is not calibrated, it is
miscalibrated with a green chip on it, and naming the site is what lets a person
catch that.

---

## 6. Calibration status in the UI

| surface | uncalibrated | calibrated |
|---|---|---|
| browser dashboard | red chip `NOT CALIBRATED` + red strip above both panels carrying the 31.2% figure | strip naming the site, the held-back set and n, sensitivity **and** specificity, and the uncalibrated pair on the same images |
| MATLAB dashboard | red chip + alert block | green chip naming the site + provenance line + both metrics |
| `runDrishtiSystem` | warning + summary line | fit set, held-back set, and both metric pairs |
| worker banner / heartbeat | `NOT CALIBRATED` | site label, forwarded to the browser |

Every one of these shows sensitivity and specificity **together**. A panel
showing only the sensitivity a calibration bought, and not the specificity it
spent, would describe half of a trade as if it were a result.

All of them also state that these are the *calibration site's* numbers — not the
current patient's confidence, and not a Messidor-2 result.

---

## 7. Tests

`runtests('tests/test_site_calibration.m')` — 13 tests, all passing.

They guard, in order: that the fit reaches its own target; that both threshold
scales are returned; that the Platt map is monotone (a calibration may relabel
the scale, never reorder patients); that a single-class sample is rejected; that
a small sample carries its noise warning; **that calibrating raises sensitivity
and lowers specificity** — a change improving both would mean the comparison is
not measuring what it claims; that an absent artifact leaves the system
uncalibrated rather than stopped; that an artifact without provenance or with a
missing field is **refused**; that the saved artifact carries its site, grader,
both sets and all four metrics; **that its provenance never names Messidor-2**;
that calibration and evaluation sets are disjoint; and that the held-back
numbers are not the optimistic ones.

---

## 8. What is still open

- **The 90% target is not met at a new site.** 82.8% held back, against a
  >90% target. Calibration narrows the transfer gap; it does not close it.
- **One site, one camera.** Every number in §3 is IDRiD. Two cameras would be
  a trend; one is an existence proof.
- **The site is not verified against the photograph.** Nothing checks that the
  loaded calibration matches the camera in use — it is surfaced to the operator
  instead, because no reliable signal exists in the image to check it against.
- **Specificity cost feeds Module 5 and has not been re-sized.** At 76.9%
  specificity the referral volume, and therefore the specialist review load,
  is materially higher than the uncalibrated case Module 5 was sized on.
