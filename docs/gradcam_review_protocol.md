# Grad-CAM Clinical Usefulness Review — Protocol & Instrument

**R3 deliverable**, drafted 2026-09-11, for execution in **Phase 4** with **R4 (Natik)**.

The README lists *"Grad-CAM explanations qualitatively validated as clinically
meaningful"* as a success metric. This document makes that measurable, because
"we showed it to a doctor and they liked it" is not a result.

> **Status: instrument ready, reviewer not yet recruited.** Recruitment is the open
> R3 task. The protocol is written so it can run with **one** reviewer; two is better.

---

## 1. The problem this guards against

The README's own risk table names it: **Grad-CAM highlighting the "correct" region
for the "wrong" reason.** There is a second, subtler risk that matters more for a
qualitative rating:

**A reviewer told "the AI says referable, do you agree with the heatmap?" will
almost always agree.** Fundus images of diabetic eyes contain lesions nearly
everywhere; a blob over the posterior pole will look plausible by chance. An
unblinded plausibility rating measures the reviewer's agreeableness, not the
explanation's quality.

So the instrument below is built around three defences: **blinding**, **negative
controls**, and a **pre-registered primary outcome**.

---

## 2. Design

**Type:** single-reviewer (preferably two), blinded, within-subject rating study
with negative controls.

**Unit of analysis:** one image + one heatmap overlay.

### Sample: 60 cases

| Stratum | n | Purpose |
|---|---|---|
| Model **correct**, referable (ICDR 2–4) | 20 | The main claim |
| Model **correct**, not referable (ICDR 0–1) | 10 | Does it explain a negative sensibly? |
| Model **wrong** (FP or FN) | 10 | Does the heatmap *reveal* the error? The most valuable stratum. |
| **Negative control** — heatmap from an untrained / randomly-initialised network | 10 | Floor |
| **Negative control** — correct heatmap paired with a *different* patient's image | 10 | Detects rubber-stamping |

The 20 negative controls are the core of the design. **If the reviewer rates
controls as useful at a similar rate to real explanations, the study has measured
nothing** and the result must be reported that way rather than quietly dropped.

### Blinding

The reviewer is **not** told:
- the model's predicted grade or confidence,
- whether the model was right,
- which cases are controls.

Cases are presented in a **single randomised order** (fix the seed, commit it).
Whoever prepares the deck must not be the person who rates it.

---

## 3. The instrument

For each case, the reviewer sees the fundus image, the heatmap overlay, and the
lesion evidence table — i.e. the actual Module 4 report — then answers:

**Q1. Does the highlighted region correspond to retinal pathology?**
`1 No — highlights normal anatomy or background` ·
`2 Partially — includes pathology and substantial irrelevant area` ·
`3 Yes — predominantly pathology`

**Q2. Is the highlighted pathology the finding that determines this eye's grade?**
`1 No` · `2 Partly — relevant but not the determining finding` · `3 Yes`

**Q3. Would this overlay change how long you need to review this case?**
`1 Slower than no overlay` · `2 No difference` · `3 Faster`

**Q4. Independently of the AI, what is your ICDR grade for this image?** `0–4`, or
`ungradable`.

**Q5. PRIMARY — Is this explanation clinically useful?** `Yes` / `No`
> Framing given to the reviewer verbatim: *"Useful means: if this report appeared in
> your screening queue, the overlay would help you reach or check a decision faster
> than the image alone. Not whether the AI is right."*

**Q6.** Free text — anything misleading, or any missed finding. *(Optional; the most
informative field in practice.)*

---

## 4. Pre-registered analysis

Write these down before collecting data. Deciding afterwards which comparison to
report is how qualitative studies become marketing.

**Primary outcome.** Proportion answering **Yes** to Q5 among the 40 real cases,
with a 95% Wilson confidence interval.

**Success threshold — declared in advance: ≥ 70% rated useful, with the CI's lower
bound above 50%.** At n=40, a 70% point estimate gives roughly a 54–83% CI, so this
is about the smallest honest bar this sample can support. Do not move it afterwards.

**Control comparison (the one that makes the primary outcome meaningful).** Q5 Yes-rate
on 40 real cases vs. 20 controls, Fisher's exact test. **If p > 0.05, report the
primary outcome as uninterpretable.** State that plainly — a null here is a real and
publishable finding about heatmap evaluation, not a failure to hide.

**Secondary.**
- Q1/Q2 distributions. A high Q1 with a low Q2 is the README's named risk caught in
  the act: right region, wrong reason. Report it as such if it appears.
- Q4 vs. our reference label → reviewer-vs-reference agreement (quadratic weighted
  kappa). This calibrates the *reviewer*, and gives us a same-protocol human
  comparator for the Phase 6 results table.
- Q5 Yes-rate on the 10 model-wrong cases. If the overlay makes errors *visible*,
  that is a safety argument worth its own slide.

**Reporting.** n, reviewer's qualification and years of experience, blinding as
actually executed, all refusals/exclusions, every CI. Per
the project rules hard rule 3, the protocol travels with the number.

---

## 5. Recruitment — the open task

**Need:** one ophthalmologist, ideally retina-trained, ~90 minutes. Two reviewers
would let us report inter-rater agreement, which is worth the extra ask.

Channels, in order of likely success:
1. Faculty or alumni contacts at a local medical college's ophthalmology department.
2. A nearby LVPEI / Aravind / Sankara network vision centre — these institutions run
   teleophthalmology themselves and are the most likely to find the work relevant.
3. District hospital ophthalmology OPD.
4. Ophthalmology residents — a senior resident is an acceptable reviewer if
   qualification is reported honestly. **Do not** present a resident as a
   "retina specialist".

**The ask, kept to one paragraph:** *"We are building an explainable DR screening
prototype for a student hackathon. We would like one ophthalmologist to rate 60
fundus images with AI-generated heat overlays — about 90 minutes, remote, no patient
contact, no clinical responsibility. We will name you as clinical reviewer if you
wish, or keep it anonymous."*

### Before anyone sees an image

⚠️ **Blocker B8 (dataset redistribution terms) must clear first.** Showing IDRiD or
Messidor-2 images to an external reviewer is a *disclosure*. Check the licence for
each corpus the review deck draws on before the deck is built — this is the same
check R5 owes for the demo video and the pitch deck. Flagged here because it is easy
to miss when the images feel like "just test data".

---

## 6. Dependencies

| Needs | From | Phase |
|---|---|---|
| Trained grading model + Grad-CAM | R1 | 3 → 4 |
| Report layout producing the overlay | R4 | 4 |
| Model-correct/incorrect case lists | R1 | 4 |
| Licence clearance for external image disclosure (B8) | R5 | **before the deck** |
| Recruited reviewer | **R3** | **now** |

Recruitment has the longest lead time of anything on this list and no technical
dependency. Start it now, not in Phase 4.
