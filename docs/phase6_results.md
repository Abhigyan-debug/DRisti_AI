# Phase 6 — Integration, validation & benchmarking

Entry point: `src/runDrishtiSystem.m`. Failure analysis: `src/grading/analyseFailureCases.m`.

> **The headline of this phase is a negative result.** The README's central claim
> — that an integrated pipeline outperforms single-technique baselines — has now
> been tested three separate ways and **does not hold**. That is reported here as
> the finding, not buried.

---

## 1. Checklist

| README item | Status |
|---|---|
| Wire all 5 modules into a single MATLAB pipeline | **Done** — `runDrishtiSystem.m` |
| Full pipeline run on held-out Messidor-2 | **Already spent** — Phase 3, 2026-09-12. Not re-run; see §3 |
| Compare integrated vs single-technique baseline, quantify | **Done** — it is a *regression*, §4 |
| Document failure cases for transparency | **Done** — §5 |

---

## 2. What "integrated" means

Modules 1–4 run per image. Module 5 is a district-level queuing model, not a
per-image stage, so integration means feeding it the **service time actually
measured on the run that just happened** instead of a constant:

```
[1] quality gate → [2] lesion features → [3] grading → [4] report
                              │
                              └──→ measured s/image ──→ [5] district capacity
```

This closes the loop Phase 5 could not close alone. A 5-image IDRiD run measured
8.89 s/image against the 7.65 s the contract carries — within the spread of the
benchmark (mean 10.15, sd 4.76) and a reminder that service time is
image-dependent, not a constant.

### The holdout is protected in code, not by memory

`runDrishtiSystem` refuses to run on any path containing `messidor`:

```
drishti:holdoutProtected — Refusing to run: … Messidor-2 … was already spent
once (2026-09-12). See project rule 1.
```

A convenience entry point that batch-runs any folder is precisely how a holdout
gets touched a second time by accident. Verified: the guard fires.

---

## 3. Messidor-2: the one-shot was already spent

Project rule 1 allows Messidor-2 to be read **exactly once**. That read
happened on **2026-09-12** during Phase 3 — 1,748 images, 4 ungradable, 1,744
scored, thresholds frozen beforehand — and it was the *full* pipeline, not the
grader alone (the quality gate produced the 4 ungradable, and a
referral-or-recapture endpoint is reported).

**So Phase 6 does not re-run it.** Re-running to "look more closely" would be a
second touch, and the first thing a second touch buys is the temptation to keep
looking until the number improves. The result stands as measured:

| | APTOS validation | **Messidor-2 external** |
|---|---|---|
| Sensitivity | 90.3% | **31.2%** [27.1–35.5] |
| Specificity | 95.9% | **99.5%** [99.0–99.8] |
| AUC | 0.9891 | **0.8848** |

§5 analyses this run in depth using the **saved per-image scores**
(`results/messidor2_external_validation.mat`). That is analysis of an
already-spent read: nothing is re-scored, no threshold moves, and no conclusion
here can feed back into the model.

---

## 4. Integrated vs single-technique: measured, and it is a regression

`runModule1Ablation.m`, APTOS validation split (n=733), changing exactly one
thing — the Module 1 quality gate in front of the same grader:

| | Sensitivity | Specificity | AUC |
|---|---|---|---|
| **Baseline** — grader alone | 90.27% | **95.86%** | **0.9891** |
| **Integrated** — gate + grader | **90.94%** | 86.67% | 0.9010 |
| Δ | **+0.67 pp** | **−9.20 pp** | **−0.0881** |

The gate buys 0.67 pp of sensitivity and pays 9.20 pp of specificity for it.
On this endpoint the integrated system is **worse**.

### Why — the gate is not selecting the images the grader struggles with

| | Grader error rate |
|---|---|
| Images the gate **rejected** (58, 7.9%) | **3.45%** |
| Images the gate **passed** (675) | **6.67%** |

If the gate were doing its job as an accuracy intervention, error among rejected
images would *exceed* error among passed ones. Measured, it is roughly **half**.
The gate is rejecting images the grader handles **better than average**.

**This does not make the quality gate wrong — it makes its justification
clinical, not statistical.** Refusing to grade an ungradable image is correct
because a confident grade on an unreadable photo is dangerous, not because it
raises AUC. It does not raise AUC. Phase 5 separately measured that it also
*costs* throughput (34% of AI time, +4.6% acquisition). Both should be said
plainly rather than claiming an accuracy benefit that was measured and refuted.

### Three independent tests of the README's central claim

| Test | Result | Where |
|---|---|---|
| Hybrid lesion-features + CNN vs CNN | no improvement (0.9795 vs 0.9853) | phase3 §3d |
| Multi-domain training vs single-domain, on a third unseen domain | no improvement (0.8848 → 0.8757) | phase3 §3c |
| **Module 1 gate + grader vs grader alone** | **regression** (−9.2 pp spec) | **here** |

The defensible claim is not "integration beats single technique". It is that
integration buys **explainability, a recapture path, and deployability** — none
of which is an accuracy claim, and all of which are real.

---

## 5. Failure cases

From saved results only (`analyseFailureCases.m`). No inference, no re-read.

### 5.1 Domain shift — a calibration failure, not a ranking failure

On Messidor-2 at the frozen threshold of **0.4033**:

| | Value |
|---|---|
| Median score, **referable** cases | **0.0992** |
| Median score, non-referable cases | 0.0033 |
| Threshold sits | **4.1× above the median referable case** |
| Referable cases scoring below threshold | **68.8%** |

The model still *ranks* correctly (AUC 0.885) — referable cases score ~30× higher
than non-referable ones. The threshold is simply in the wrong place for this
camera. **A ranking failure and a calibration failure need opposite fixes**, and
this is the latter, which is why per-site calibration recovers it (31.2% → 90.0%).

### 5.2 Severity blindness — the failure is concentrated at grade 2

| True DR grade | n | referable | missed | **miss rate** | median score |
|---|---|---|---|---|---|
| 0 — no DR | 1017 | 0 | 0 | — | 0.0031 |
| 1 — mild NPDR | 270 | 8 | 8 | **100%** | 0.0044 |
| **2 — moderate NPDR** | **347** | **347** | **293** | **84.4%** | **0.0416** |
| 3 — severe NPDR | 75 | 75 | 13 | 17.3% | 0.8279 |
| 4 — proliferative | 35 | 35 | 6 | 17.1% | 0.9320 |

**This is a much more precise diagnosis than "31.2% sensitivity".** The system
detects sight-threatening disease reliably — grades 3 and 4 score 0.83 and 0.93,
far above the threshold, and are caught ~83% of the time. It is nearly blind to
grade 2, which scores 0.042, an order of magnitude *below* the threshold.

Clinically these are different failures. Missing proliferative DR risks imminent
vision loss. Missing moderate NPDR misses the window where intervention is
cheapest and most effective — and grade 2 is **67% of all referable patients** in
this cohort.

The 8 grade-1 referable cases are referable via **DME**, and **all 8 are missed** —
consistent with the DME arm resting on hard-exudate detection, whose measured
precision (0.549) only clears the display bar at a tightened threshold
(phase3 §3e.1).

### 5.3 Ungradable

4 of 1,748 Messidor-2 images (0.2%) were gated as ungradable — against a 10.9%
field reject rate in the literature. Messidor-2 is a curated research set; this
number should not be read as a field expectation.

---

## 6. What a deployment must do

1. **Calibrate per site before screening anyone.** ~200 locally-labelled images,
   `fitSiteCalibration.m`, calibration and evaluation sets disjoint. Without it,
   68.8% of referable patients score below threshold.
2. **Re-budget specialist time after calibrating** — calibration buys sensitivity
   with specificity (99.5% → 57.9%), moving specialist load ~20× (phase5 §5).
3. **Do not claim an accuracy benefit for integration.** Claim explainability,
   the recapture path, and deployability.
4. **Expect grade-2 misses.** This is the dominant failure mode and it is where
   most referable patients are.

---

## 7. Files

| File | Role |
|---|---|
| `src/runDrishtiSystem.m` | all five modules, one entry point; holdout guard |
| `src/grading/analyseFailureCases.m` | §5, from saved results only |
| `src/grading/runModule1Ablation.m` | §4 |
| `results/messidor2_external_validation.mat` | the one-shot, 2026-09-12 |
| `results/module1_ablation.mat` | the ablation |
