# Clinical Definitions & the Referable-DR Endpoint

**R3 deliverable.** Decided 2026-09-11. Machine-readable companion:
[`config/clinical_definitions.json`](../config/clinical_definitions.json).

This document resolves **blocker B3** (is DME in or out of "referable"?) and freezes
the endpoint definitions that Phase 3 trains against and Phase 6 reports.

> **Status: DECIDED.** Endpoint *definitions* are frozen. Numeric *thresholds* stay
> `null` until Phase 3 selects them on the validation split, then are frozen by commit
> before Messidor-2 is read.

---

## 1. The decision

**DME is IN the referable class.**

> **Referable DR = ICDR DR grade ≥ 2 *OR* DME risk grade = 2**

with two further endpoints reported alongside it (§4).

### Why in, not out

The question was never really clinical — moderate NPDR and centre-involving macular
oedema both need an ophthalmologist, and no one disputes that. The question was
whether we could *afford* it. Three findings say yes, and one says we cannot afford
the alternative:

**1. Every benchmark we quote includes it.** IDx-DR's cleared endpoint is
**mtmDR** — "more than mild DR **and/or** clinically significant macular oedema".
Gulshan et al.'s RDR class includes referable DME. If we exclude DME, our
sensitivity is measured on a *smaller, easier* positive class than the 87.2% and
87.0% we claim to beat. The README's headline claim — that our target sits above
the FDA-cleared operating point — would become false-by-construction. That is not a
number we could defend under questioning.

**2. The labels already exist, on both ends.** IDRiD ships `Risk of macular edema`
(0/1/2) for all 516 grading images, which we hold. The Krause et al. Messidor-2
reference standard ships an adjudicated DME column alongside DR severity and
gradability — so the endpoint is *measurable on the external benchmark*, not just
the training set. Had Messidor-2's labels been DR-only, option (a) would have been
unbuildable and this decision would have gone the other way.

**3. We get DME almost free from Module 2.** IDRiD's DME grade is not an independent
clinical judgement — it is *defined geometrically*:

| Grade | Definition |
|---|---|
| 0 | No apparent hard exudates |
| 1 | Hard exudates present, all > 1 optic disc diameter from the macula centre |
| 2 | Hard exudates within 1 optic disc diameter of the macula centre |

Every term in that definition is something Module 2 already produces: **hard exudate
segmentation** (the one lesion with a plausible benchmark ceiling — AUPR 0.885),
**fovea localization**, and **optic disc diameter**. DME grading is a distance
computation over three existing outputs, not a fourth trained model. The marginal
cost is a function, not a phase.

This also turns a weakness into a strength: it gives the disc/fovea localizer a
*diagnostic* purpose, not just an anatomical-normalization one, which strengthens
the "explainable by construction" pitch.

### What it costs — stated honestly

**APTOS has no DME labels.** Our largest training set (3,662 labelled images) is
DR-only. So:

- The DME head is trained and validated on **IDRiD alone** (413 train / 103 test).
  That is a small set, and we should expect the DME component to be the weaker half.
- **All APTOS-reported numbers are the DR-only endpoint**, and must be labelled as
  such. An APTOS number and a Messidor-2 number are not the same endpoint and must
  never appear in the same column of a results table without a note.

This is a real cost and it is why the secondary endpoint in §4 exists rather than
being a formality.

---

## 2. The ICDR scale we grade to

| DR grade | Name | Definition |
|---|---|---|
| 0 | No apparent retinopathy | — |
| 1 | Mild NPDR | Microaneurysms only |
| 2 | **Moderate NPDR** | More than MA only, less than severe — **referral starts here** |
| 3 | Severe NPDR | 4-2-1 rule, no proliferative signs |
| 4 | Proliferative DR | Neovascularization, or vitreous/preretinal haemorrhage |

Source: International Clinical Diabetic Retinopathy Disease Severity Scale
(Wilkinson et al., *Ophthalmology* 110(9):1677-1682, 2003).

---

## 3. A cautionary example — why §1's framing matters

The AIDRSS multicentric India study (Dey et al., 2025, [arXiv:2501.05826](https://arxiv.org/abs/2501.05826))
reports **"100% sensitivity for detecting referable DR"**. Read the definition:
they define *referable* as **DR3 and DR4 only** — severe NPDR and PDR — giving a
positive-class prevalence of **0.14%** (95% CI 0.05-0.23) in 4,482 gradable
patients. That is roughly **six patients**.

Under our definition, and under IDx-DR's and Gulshan's, moderate NPDR (their DR2,
4.40% of the cohort) is *referable*. Their headline sensitivity is computed on a
positive class about thirty times smaller than ours.

The result is not fraudulent and the paper states its definition plainly. But it is
a live demonstration of the project rules hard rule 3: **a sensitivity
figure without its positive-class definition is not a number.** Two systems
reporting "100% sensitivity for referable DR" can differ by a factor of thirty in
what they actually detect.

Put this example in the pitch. It is the clearest one-slide argument for why our
protocol discipline is a feature and not bureaucracy.

---

## 4. The three endpoints we report

Defined in [`config/clinical_definitions.json`](../config/clinical_definitions.json).
Phase 3 and Phase 6 code must read them from there, never hardcode a threshold.

| # | Endpoint | Rule | Comparable to | Scoreable on |
|---|---|---|---|---|
| **1** | **Referable DR** *(primary)* | `DR ≥ 2 OR DME = 2` | IDx-DR mtmDR; Gulshan RDR | IDRiD, Messidor-2 |
| 2 | Referable DR, DR-only | `DR ≥ 2` | *nothing* — state this | APTOS, IDRiD, Messidor-2 |
| 3 | Needs a human | endpoint 1 **OR** quality-gate reject | Gulshan "RDR or ungradable" | IDRiD, Messidor-2 |

**Endpoint 3 is the one that describes our actual product.** Module 1 can refuse to
grade an image, so a patient reaches an ophthalmologist either because we flagged
disease *or* because we could not see. Gulshan et al. report this separately and
their AUC falls from 0.991 to 0.974 when gradability enters the decision. Ours
should be expected to fall too. Reporting only endpoint 1 would describe a system
that does not exist.

### Operating points

Report **three**, all selected on the Phase 3 validation split and frozen before
Messidor-2 is touched:

| Point | Selection rule |
|---|---|
| High sensitivity | Max specificity s.t. validation sensitivity ≥ 0.95 |
| **Operating** *(headline)* | Max Youden J s.t. sensitivity ≥ 0.90 **and** specificity ≥ 0.85 |
| High specificity | Max sensitivity s.t. validation specificity ≥ 0.98 |

Gulshan reports two; we report three because our headline target is a *joint*
constraint that neither of their points expresses. The commit hash that froze each
threshold goes in the JSON — that is the audit trail proving no post-hoc tuning.

---

## 5. Open item — the measured cost of excluding DME

This decision was made on the published argument and on label availability. One
supporting number is **not yet measured**: how many IDRiD patients are DME-positive
but DR-negative, i.e. how many referrals a DR-only rule would actually miss in our
own data.

Run [`tools/idrid_dme_crosstab.py`](../tools/idrid_dme_crosstab.py) once IDRiD is
present on a machine and paste the table here. It needs one 24 KB CSV, no images.

> **Prediction on record, before measuring:** the DR ≥ 2 and DME = 2 classes overlap
> heavily — hard exudates near the macula usually accompany moderate-or-worse
> retinopathy — so the count of DME-only referrals should be **small, in the
> single-digit percent**. If it comes back large, that is surprising and worth
> re-reading the labels before believing it. The decision in §1 does not depend on
> the outcome; the argument for it is comparability, not yield.

Recording the prediction first is the point. A number that can only confirm you is
not evidence.

---

## 6. What this unblocks

- **B3 closed** — Phase 3 metric design can proceed.
- Module 2's disc/fovea localizer and hard-exudate segmenter now have a **second,
  diagnostic consumer**, which raises their priority relative to MA detection.
- Module 4's evidence table gains a DME row: *"hard exudate within 0.6 disc
  diameters of the fovea"* is a named clinical finding a reviewer can verify in
  seconds — exactly the sub-30-second-review design goal.

## 7. Still open for R3

- Recruit the ophthalmologist reviewer for the Phase 4 Grad-CAM rating —
  instrument drafted at [gradcam_review_protocol.md](gradcam_review_protocol.md).
- Fill §5 when IDRiD is available.
