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

> **Referable DR = ICDR DR grade ≥ 2 *OR* referable DME**
>
> where **referable DME = hard exudates within 1 optic disc diameter of the fovea
> centre** — a *clinical* criterion, resolved to each dataset's own encoding via
> [§3a](#3a-dme-is-one-finding-encoded-differently-per-dataset). **Never compare a raw
> DME integer against a literal threshold.**

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

## 3a. DME is one finding, encoded differently per dataset

*Added 2026-09-11 as contract **v1.1.0**, closing blocker **B12**.*

The first version of this contract wrote the DME clause as the literal
`dme_grade >= 2`. That is **IDRiD's** scale. Messidor-2's `adjudicated_dme` is
**binary 0/1**, so on the benchmark that matters most the clause matched nothing, the
primary endpoint silently collapsed into the DR-only secondary, and **no error was
raised** — a wrong number wearing the right label.

### Why the two scales mean the same thing

Both corpora apply the *same* clinical criterion and differ only in how they record
it. Krause et al., who produced the Messidor-2 reference standard, state it directly:

> "…hard exudates within 1 disc diameter was considered referable DME"

and note their Messidor-2 (their *"Validation"*) set "used a standard of hard exudates
within **1 DD of the fovea**." IDRiD's grade 2 is defined identically. So:

| Dataset | Column | Scale | Referable DME is |
|---|---|---|---|
| IDRiD | `Risk of macular edema` | 0 / 1 / 2 | **`== 2`** |
| Messidor-2 | `adjudicated_dme` | binary 0 / 1 | **`== 1`** |
| APTOS | — | none | **not scoreable** → use the secondary endpoint, and say so |

> **Grade 1 is not referable.** IDRiD grade 1 means exudates are present but *further*
> than 1 DD from the macula. `>= 1` would wrongly refer them; the operator is `==`,
> not `> 0`.

> **The 4 ungradable Messidor-2 images** are not a DME value and must not be coerced
> to 0. They are excluded from endpoints 1 and 2 and count as **positive** in
> endpoint 3 — an image nobody can grade still needs a human. Report the gradable
> denominator (1,744) explicitly; Gulshan's is 1,745, and an unexplained difference
> looks like a mistake.

### The shared caveat worth stating

Krause et al. name it as a limitation of their own reference standard: they used
**hard exudates as a proxy for DME**, which properly needs stereo imaging or OCT.
IDRiD does the same. Our Module 2 derives DME the same way — exudate mask, fovea,
disc diameter — so **our method matches the reference standard's method**. That is a
point in our favour, but the proxy must be stated whenever a DME number is reported.

### The general lesson

The bug was not a wrong threshold; it was **encoding a clinical concept as a
dataset-specific integer**. A rule that silently matches nothing is worse than one
that crashes, because it still produces a plausible number. The contract now requires
code evaluating the primary endpoint to **fail loudly** if a dataset has no DME
mapping, rather than falling through to a DR-only result.

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
a live demonstration of project hard rule 3: **a sensitivity
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
| **1** | **Referable DR** *(primary)* | `DR ≥ 2 OR dme_referable` ([§3a](#3a-dme-is-one-finding-encoded-differently-per-dataset)) | IDx-DR mtmDR; Gulshan/Krause RDR | IDRiD, Messidor-2 |
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

## 5. The measured cost of excluding DME — **MEASURED 2026-09-13**

This decision was made on the published argument and on label availability. One
supporting number was left unmeasured: how many IDRiD patients are DME-positive
but DR-negative, i.e. how many referrals a DR-only rule would actually miss in our
own data. It has now been measured with
[`tools/idrid_dme_crosstab.py`](../tools/idrid_dme_crosstab.py) — two 24 KB CSVs,
no images, no MATLAB.

> **Prediction on record, made before measuring:** the DR ≥ 2 and DME = 2 classes
> overlap heavily — hard exudates near the macula usually accompany
> moderate-or-worse retinopathy — so the count of DME-only referrals should be
> **small, in the single-digit percent**. If it comes back large, that is
> surprising and worth re-reading the labels before believing it. The decision in
> §1 does not depend on the outcome; the argument for it is comparability, not
> yield.

**Result: 0 of 516 patients, 0.0%.** The prediction holds, with room to spare.

Rule applied: `dr_grade >= 2 OR dme_referable`, with IDRiD's `dme_referable`
resolved through the `dme_encoding` map as `value == 2`
(`config/clinical_definitions.json` v1.1.0).

### IDRiD train (n=413)

| DR grade | DME 0 | DME 1 | DME 2 | total |
|---|---|---|---|---|
| 0 | 134 | 0 | 0 | 134 |
| 1 | 20 | 0 | 0 | 20 |
| 2 | 16 | 33 | 87 | 136 |
| 3 | 3 | 4 | 67 | 74 |
| 4 | 4 | 4 | 41 | 49 |

referable DR-only (DR≥2) **259 (62.7%)** · DME-referable (DME=2) 195 (47.2%) ·
both 195 (47.2%) · **DME-only referrals 0 (0.0%)** · combined rule 259 (62.7%).

### IDRiD test (n=103)

| DR grade | DME 0 | DME 1 | DME 2 | total |
|---|---|---|---|---|
| 0 | 34 | 0 | 0 | 34 |
| 1 | 5 | 0 | 0 | 5 |
| 2 | 0 | 3 | 29 | 32 |
| 3 | 3 | 3 | 13 | 19 |
| 4 | 3 | 4 | 6 | 13 |

referable DR-only (DR≥2) **64 (62.1%)** · DME-referable (DME=2) 48 (46.6%) ·
both 48 (46.6%) · **DME-only referrals 0 (0.0%)** · combined rule 64 (62.1%).

### What this means — and what it does not

**It is stronger than "small".** Look at the DME 1 and DME 2 columns for DR grades
0 and 1: they are empty in both splits. In IDRiD, *no patient graded DR 0 or DR 1
carries any macular-oedema risk label at all.* DME positivity is not merely
correlated with DR ≥ 2 here, it is **nested inside it**. A DR-only rule and the
combined rule select the identical patients.

**Therefore every IDRiD number in this project is unaffected by the DME clause.**
The site-calibration figures (75.0% → 82.8% sensitivity), the lesion-detector
splits and the IDRiD grading evaluation would all be numerically identical under a
DR-only endpoint. That is worth knowing: it removes DME as a confound when reading
any IDRiD result.

**It does NOT show the DME clause is useless**, and it must not be quoted that way —
the very next dataset contradicts it:

- **It is one dataset's grading convention.** The nesting most likely reflects that
  the same reader assigned both labels against a protocol where macular oedema is
  not recorded below moderate retinopathy. Another centre's readers need not behave
  that way, and a real patient can have clinically significant macular oedema with
  minimal retinopathy — that is precisely why the published definition includes it.
- **The nesting does NOT replicate on Messidor-2 — and that is the decisive point.**
  Messidor-2's DME marginal was read during the B12 diagnosis (1593 / 151 / 4 blank,
  declared in the Phase 6 write-up), and **8 of 1744 gradable images are DME-only
  referrals** — DR < 2 with DME present. Referable prevalence is 26.7% under the
  intended rule against 26.2% DR-only. Small, but non-zero: on a second camera the
  DME clause selects patients a DR-only rule does not. **The system missed all 8 of
  them** at the frozen threshold. So the IDRiD result below is a property of IDRiD's
  grading convention, not a general fact about the disease, and anyone citing the
  0.0% as grounds to drop the clause would be generalising from the one cohort where
  it happens to be redundant.
- **APTOS has no DME labels at all**, which is why APTOS numbers are the DR-only
  endpoint and are not comparable to Gulshan or IDx-DR.
- **The clause earns its place on comparability, not yield.** Our endpoint matches
  IDx-DR's `mtmDR` positive class; that is what makes the comparison legitimate.
  Dropping a clause because it happened to add zero patients in one cohort would
  break that match to buy nothing.

**The decision in §1 stands, unchanged — as §1 said in advance that it would.**
Recording the prediction first is the point. A number that can only confirm you is
not evidence.

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
- ~~Fill §5 when IDRiD is available.~~ ✅ **Done 2026-09-13** — measured, 0/516 DME-only referrals; the pre-registered prediction held.
