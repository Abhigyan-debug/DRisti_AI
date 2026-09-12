# Phase 5 — Simulink screening-throughput model

**Module 5.** Deliverable: `simulink/screening_throughput_model.slx` plus the
analysis that sizes a district. Everything below is reproducible from
`simulink/` — no figure here came from a script that is not in the repo.

> **Read §6 before quoting any number.** Several inputs are ASSUMED, and
> `config/telemedicine_parameters.json` requires that assumptions appear as
> assumptions, never as findings. In particular the **30 s clinician review time
> is a design target, not a measurement** — no clinician has been timed.
>
> **Sensitivity is not one number.** 90.3% is APTOS-internal; the same threshold
> measured **31.2%** on Messidor-2 uncalibrated. Per-site calibration recovers
> part of that gap — **82.8%** at the one site measured end to end — and does
> **not** reach the 90% target out of sample. See §5b — **per-site calibration
> is a deployment requirement**, not an optimisation.
>
> ⚠️ **Staffing below was re-sized on 2026-09-13.** It previously used a
> 90.0% / 57.9% operating point taken from a post-hoc demonstration on
> Messidor-2 itself. That pair was never independently supported and has been
> replaced by the IDRiD-measured **82.8% / 76.9%**.

---

## 1. What Phase 5 asked for, and where it stands

| README checklist item | Status |
|---|---|
| Model acquisition → upload → AI → review as a queuing system in Simulink | **Done** — `.slx` builds and simulates |
| Parameterise with realistic rural bandwidth/staffing assumptions | **Done** — bound to the R3 contract, provenance-tagged |
| Run scenario analysis for 100,000+ patients/year | **Done** — 4 scenarios + staffing sweep |
| Output recommended ratios and bottleneck report | **Done** — §4, verified two independent ways |

---

## 2. AI service time: measured on CPU, 64× above the placeholder

`screening_params.m` carried `aiInferenceLatencySec = 0.120` — "120 ms per image
on server GPU". That is a *CNN forward pass*. The deployed pipeline also runs the
quality gate, Module 2's classical detectors and Grad-CAM on every image, and
those dominate.

**Measured** — `simulink/benchmarkInferenceTime.m`, n=10 IDRiD images (2 warm-up
discarded), MATLAB R2026a, **CPU**:

| Configuration | s/image | Note |
|---|---|---|
| **Full pipeline — MEAN** | **10.56** | **the number Module 5 uses** (n=18) |
| Full pipeline — median | 7.61 | the *typical* image |
| — quality gate | 2.59 | |
| — grading + Grad-CAM + Module 2 | 4.74 | |
| — report generation | 0.21 | negligible |
| Grading only (no Module 2, no Grad-CAM) | 3.19 | 2.4× faster |
| ~~Old placeholder~~ | ~~0.120~~ | **~88× understated** |

### Mean and median differ by 39% — and the mean is the one that matters

The distribution is **right-skewed and near-bimodal**, not noisy:

| | s |
|---|---|
| min / p25 | 6.76 / 7.31 |
| **median** | **7.61** |
| **mean** | **10.56** |
| p75 / p90 | 13.59 / 18.94 |
| max | 25.23 |
| **images > 12 s** | **33%** |

About two thirds of images run 6.8–8.3 s; about one third run 13–25 s. **The same
images are slow in every run**, so this is image content, not measurement noise.

**Module 5 uses the MEAN (10.56 s).** A queue's service time is an expectation —
throughput is total work over time — so the mean is the correct statistic. An
earlier revision of this document used the median (7.65 s), which under-states the
compute requirement by ~39%. The median answers "how long does a typical image
take"; it is the wrong number for sizing a node.

**Cold start is separate again:** the first image of a MATLAB session costs
~16–25 s (model load, BLAS/JIT warm-up) and is excluded from the statistics above.
A long-running service pays it once; a per-invocation script pays it every time.
A short demo run that includes the cold image and a couple of slow ones will
report an average nearer 14 s — that is expected, and it is not a contradiction.

### This *is* the CPU number the contract asked for

The contract's note said plainly that "the CPU number is the one that matters for
a PHC deployment". It is now measured — and an earlier revision of this document
mislabelled the identical measurement as "dev GPU RTX 5050" on the strength of a
GPU merely being present. It was always a CPU figure: `explainGrading.m` builds a
plain `dlarray`, so `predict()` executes on the CPU regardless of the GPU.

Measured directly, both devices:

| Stage | CPU | GPU |
|---|---|---|
| CNN forward pass | 0.050 s | 0.034 s |
| Forward + Grad-CAM | 0.514 s | **0.732 s** (GPU *slower*) |

**A PHC edge node does not need a GPU.** The pipeline is CPU-bound in classical
CV, not in the network: moving the CNN to a GPU would save ~0.016 s out of ~10.6 s
(**0.2%**), and Grad-CAM is actually slower on GPU because transfer overhead
exceeds compute for a model this small. Edge feasibility therefore rests on
whether ~7.7 s/image/node is acceptable — not on GPU availability. That resolves
the open item this document previously carried.

**Why it matters less than it looks.** Even at 10.56 s/image the AI stage needs
**1 compute node**, not 2 — it was never going to be the bottleneck. But the
correction is the difference between *knowing* that and *assuming* it.

### The quality gate does not improve throughput — it costs throughput

Stated plainly so the claim is never made in the other direction. In this model
Module 1 is a net **cost** on both stages it touches:

- **AI compute:** 2.59 s of the 7.61 s median per image (34%) is the quality gate.
- **Acquisition:** the recapture loop raises technician time from 5.00 to
  **5.23 min/patient** (+4.6%), because a rejected image sends the patient back
  to the camera rather than out of the system.

Its justification is **clinical, not operational**: an ungradable image must
produce a retake instruction, never a confident grade. Nothing in Phase 5
measures a throughput benefit from it, and no throughput benefit should be
claimed for it. (Phase 3's Module-1 ablation examined *accuracy*, not
throughput — a different question.)

**Grading-only is a real deployment option.** Phase 3 §3d measured that lesion
features add nothing to the CNN's accuracy, and every lesion channel except hard
exudates is withheld from the report anyway. Dropping Module 2 and Grad-CAM buys
2.4× throughput at the cost of the heatmap and the evidence table — i.e. the
explainability the project is named for. Recorded as an option, not a
recommendation.

---

## 3. One parameter contract, not two

`config/telemedicine_parameters.json` is designated as *the* Module 5
contract and tags every value SOURCED / DERIVED / ASSUMED.
`simulink/screening_params.m` had been keeping its own copy, and the two had
drifted:

| Parameter | Contract | `screening_params.m` (before) | Effect of the gap |
|---|---|---|---|
| `images_per_patient` | **2** (SOURCED) | 4 | 2× upload payload and AI compute |
| technician time/patient | **5.0 min** (ASSUMED) | 7.5 min | 1.5× acquisition demand |
| PHC uplink | **5.0 Mbps** (ASSUMED) | 1.024 Mbps | 5× upload time |
| quality reject rate | **0.109** (SOURCED) | 0.12 | minor |
| AI time/image | `null` (PENDING) | 0.120 s | see §2 |

`screening_params.m` now **loads** the contract and returns a per-field
provenance map; anything the contract does not cover is tagged `R4-LOCAL`.
Duplicated constants that disagree are worse than either value alone, because
the Phase 5 output then rests on numbers that bypassed R3's tagging entirely.

### The referral rate is reported as a range, on purpose

Two defensible figures exist and they are **not** contradictory — they have
different denominators:

- **4.54%** — contract, DERIVED from Dey et al. 2025, a *general* screened
  population. Its own note calls this a **floor** (DME-only referrals excluded).
- **16%** — the grade mix in `screening_params.m`, a *diabetic-only* cohort.

A 3.5× spread on the number that drives specialist staffing. Collapsing it to a
point estimate would manufacture precision the evidence does not support, so
every review figure below is an interval.

---

## 4. Result: minimum viable district configuration

> **⚠️ ASSUMPTION-DEPENDENT RESULT.** Every figure in this section moves if any
> of the assumptions in §6 changes. The load-bearing ones are the 30 s review
> time (a *design target*, **not measured**), 5.0 min technician time, 5 Mbps
> uplink, 250 operating days/year and the 85% utilisation ceiling. The only
> MEASURED inputs are AI service time (10.56 s/image mean), 2 images/patient and the
> 10.9% reject rate.

`recommend_district_configuration.m`, at a **85% utilisation ceiling** (ASSUMED
planning headroom — sizing to 100% means unbounded queues).

Target: 100,000 patients/year ÷ 250 days = **400 patients/day**.

| Resource | Minimum | Basis |
|---|---|---|
| Cameras (+1 technician each) | **6** | 5.23 min/patient incl. recapture |
| PHC uplinks | **1** | 0.19 min/patient (2 images, 7.0 MB) |
| AI compute nodes | **1** | 0.35 min/patient (MEASURED mean 10.56 s × 2, CPU) |
| Ophthalmologists | **1** | at the site-calibrated operating point (§5) |

**Binding constraint: acquisition (camera + technician)** — it needs 4.36 units
at full utilisation against 0.16 (uplink), 0.21 (AI) and 0.26 (review at the
calibrated operating point).

### Verified two independent ways

The analytic right-sizing was re-run through the stochastic discrete-event
simulator at the recommended configuration:

| Check | Result |
|---|---|
| Annual throughput | 100,325 (target 100,000) ✓ |
| Camera utilisation | 0.761 (under the 0.85 ceiling) ✓ |
| AI utilisation | 0.212 |
| Same-day SLA (<2 h) | 100% |
| Median TAT / p95 | 20.6 min / 55.4 min |
| Bottleneck | **Camera/Technician Acquisition** ✓ agrees |

It reproduces R3's independent hand calculation in
`docs/telemedicine_parameters.md` §2 — "400 × 4.54% × 30 s ≈ 9
ophthalmologist-minutes/day" — at **9.1 min/day**, and confirms their prediction
that acquisition, not specialist review, is the constraint.

**But that 9.1 figure assumes referral rate = disease prevalence, i.e. a perfect
classifier.** At the measured calibrated operating point it is ~89 min/day (§5).
Acquisition still binds — 4.36 units against 0.26 — but by a smaller margin than
the idealised arithmetic suggests.

---

## 5. What the AI is worth — corrected for what the classifier actually flags

> **⚠️ This section previously claimed a 6–22× reduction in specialist load. That
> was wrong.** It set the reviewed fraction equal to *disease prevalence*, which
> silently assumes a **perfect classifier**. The specialist reviews what the model
> **flags**, not what is diseased:
>
> ```
> flagged = prevalence×sensitivity + (1 − prevalence)×(1 − specificity)
> ```
>
> The false-positive term dominates whenever specificity is below ~0.95.

All three operating points are **measured** (`docs/phase3_results.md` §3, §3b) and
are **not interchangeable**. Review time is held at the contract's 30 s
(**ASSUMED**, see §6) for every row, so only the flagged fraction varies.

Specialist minutes/day at 400 patients/day:

| Operating point | Sens / Spec | Flagged | General cohort (4.5%) | Diabetic cohort (16%) |
|---|---|---|---|---|
| Pre-AI baseline — read everything | — | 100% | 200 min | 200 min |
| *Idealised* (referral = prevalence) | 100% / 100% | 4.5–16% | 9.1 min | 32.0 min |
| **Uncalibrated** site, frozen threshold | **31.2% / 99.5%** | 1.9–5.4% | 3.8 min | 10.8 min |
| **Site-calibrated** (IDRiD, held-back split) | **82.8% / 76.9%** | **26–33%** | **51.6 min** | **65.3 min** |

**The honest number is ~3.1–3.9×, not ~6×.** At the safest operating point
measured, specificity of 76.9% means roughly **a quarter to a third of all
screens get flagged**, the large majority of them false positives — and it still
misses ~17% of referable patients, so it does **not** meet the >90% target.

**The uncalibrated row is a trap.** It shows the *lightest* specialist load of any
AI configuration — 3.8 min/day — precisely because it misses most disease. Light
load there is a symptom of the failure, not a benefit.

The value of AI triage is still real: one specialist can cover a district that has
a fraction of one, and their attention is directed at the flagged half rather than
spread over everything. But it is a ~2× effect at the measured operating point.

---

## 5b. Per-site calibration is a deployment requirement

**Not an optimisation, not a tuning step — a precondition for deploying at a new
site at all.**

Measured on Messidor-2 at the frozen APTOS threshold (`docs/phase3_results.md` §3):

| | Sensitivity | Specificity |
|---|---|---|
| **Uncalibrated** (APTOS threshold, current system) | **31.2%** [27.1–35.5] | 99.5% |
| Site-calibrated, 25 images | 85.9% ± 12.7 | 61.0% |
| Site-calibrated, 100 images | 87.3% ± 8.4 | 60.9% |
| **Site-calibrated, ~200 images** | **90.0% ± 4.9** | 57.9% |

⚠️ **The rows above are a post-hoc demonstration on Messidor-2 itself and are
NOT quotable as deployment performance** — see
[site_calibration.md](site_calibration.md) §4. The independently-supported
measurement is IDRiD, fit on TRAIN n=413 and evaluated on held-back TEST n=103:

| | Sensitivity | Specificity |
|---|---|---|
| Uncalibrated (APTOS threshold) | 75.0% | 97.4% |
| **Site-calibrated — used for the staffing above** | **82.8%** | **76.9%** |

### What this obliges a deployment to do

1. **Collect ~200 locally-labelled images before going live** at each new site or
   camera model. `buildSiteCalibration.m` fits, evaluates and saves the local
   operating point; the pipeline loads it automatically.
2. **The calibration set and the evaluation set must be disjoint.** Overlap makes
   the result indistinguishable from tuning on test.
3. **Do not ship the APTOS threshold to a new camera.** At 31.2% sensitivity an
   AI-triage policy would auto-clear ~**44 of the ~64 referable patients/day** a
   district sees — without a human ever seeing them.
4. **Re-budget specialist time after calibrating.** Calibration buys sensitivity
   by spending specificity (97.4% → 76.9% as measured on IDRiD), which is what
   moves specialist load from 3.8 to ~65 min/day. Sizing staff on pre-calibration
   numbers under-provisions by ~17×.

### Sensitivity figures must not be conflated

| Figure | Scope | Valid for |
|---|---|---|
| **90.3% / 95.9%** | APTOS validation split, n=733 | **in-domain only** |
| **31.2%** | Messidor-2, frozen threshold, uncalibrated | a new, uncalibrated site |
| **82.8%** | IDRiD, fit on TRAIN n=413 → held-back TEST n=103 | a calibrated site (the only end-to-end measurement) |
| ~~90.0% ± 4.9~~ | Messidor-2 post-hoc demonstration on itself | **nothing — not independently supported** |

Phase 3 states it directly: *"Do not claim 90.3% / 95.9% generalises. It does
not."* Nothing in Phase 5 treats 90.3% as a universal property of the model, and
the code carries all three figures separately
(`recommend_district_configuration.m` → `R.triageSafetyNote`).

---

## 6. Assumptions vs findings — read before quoting

### Findings (measured or sourced)

| Finding | Basis |
|---|---|
| AI service time **10.56 s/image mean on CPU** (median 7.61) | MEASURED, n=18, protocol in §2 |
| CNN forward 0.050 s CPU / 0.034 s GPU; +Grad-CAM 0.514 / 0.732 s | MEASURED, §2 |
| **A PHC edge node needs no GPU** (GPU saves 0.2% of pipeline time) | follows from the above |
| **Acquisition is the binding constraint** | 4.36 units vs 0.16 / 0.21 / 0.26; agrees across two independent methods |
| Uncalibrated external sensitivity **31.2%** | MEASURED, `phase3_results.md` §3 |
| Calibrated **82.8%** at **76.9%** spec, held-back split | MEASURED, `site_calibration.md` §3 |
| **Per-site calibration is a deployment requirement** | follows from the above (§5b) |
| 2 images/patient, 10.9% quality reject rate | SOURCED (Dey et al. 2025) |
| The quality gate **costs** throughput (33% of AI time, +4.6% acquisition) | MEASURED, §2 |

### Assumptions (chosen, not evidence — vary them before trusting any conclusion)

| Assumption | Value | Why it matters |
|---|---|---|
| **Ophthalmologist review time** | **30 s/image** | **NOT MEASURED.** This is Module 4's *design target*. Phase 4 built the timing instrument (`usabilityPass.m`) but **no clinician has been timed.** Every specialist-load figure in §5 scales linearly with it. |
| Technician time/patient | 5.0 min | drives the binding constraint directly |
| Rural PHC uplink | 5 Mbps | upload is 0.19 min/patient at this value |
| Operating days/year | 250 | sets patients/day |
| Utilisation ceiling | 85% | planning headroom |
| Arrival process | Poisson | real PHC demand is bursty (market days, clinic hours), which raises queue peaks without changing mean utilisation |
| Image size | 3.5 MB | |

### Three review-time numbers, and what each one measures

They appear in different places and look contradictory only if one is quoted for
another. **None of them is an observed review time — no clinician has been timed.**

| Number | Kind | What it actually measures |
|---|---|---|
| **21.6 s** | ASSUMED | `screening_params.meanReviewSeconds` — the per-grade decision times (15/25/30/60/90 s) weighted by the modelled case mix. An assumption about **deciding**, averaged over a cohort that is ~72% grade 0. Used by the stochastic simulator. |
| **30 s** | ASSUMED | Module 4's flat design target, and the contract value. Used by `recommend_district_configuration` for **every** triage arm, so that only the flagged *fraction* differs between arms. |
| **~38 s** | **MEASURED** | A **floor on READING** the report's decision-critical text — 126 words at 200 wpm (`usabilityPass`). Excludes looking at the image; excludes judgement entirely. |

**These are not in conflict, and the comparison that matters is this:** the
measured reading floor (~38 s) is **above both assumed decision times**. Reading
the report cannot be done in 21.6 s, so 21.6 s cannot be the total time to read
*and* decide. Both assumptions are therefore **optimistic**, and every
specialist-load figure in §5 is more likely an under-estimate than an
over-estimate.

The 21.6 s figure is also lower than the 30 s one purely because it is averaged
over a mostly-healthy cohort — grade 0 is assumed to take 15 s. It is not a
"better" estimate, just a differently-weighted one.

### Still open

- **Human review timing.** The single highest-leverage missing measurement. The
  instrument exists (`usabilityPass.m` writes a stopwatch-ready review set);
  it needs a clinician.
- **SimEvents is licensed but not installed** on this machine, so the `.slx` uses
  the native-Simulink continuous-queue formulation rather than true discrete
  entities. `check_environment` reported a false `[ok]` for it (licence and
  `ver()` both pass for an absent product); it now reports `[NOT INST]`.

*Closed this round:* CPU inference time (§2) — previously the largest open item,
and the one the contract said mattered most for edge deployment.

---

## 7. Files

| File | Role |
|---|---|
| `simulink/screening_throughput_model.slx` | the generated model (builds + simulates) |
| `build_throughput_model.m` | generates it; seeds the model workspace from the contract |
| `screening_params.m` | loads the contract, returns values + provenance |
| `benchmarkInferenceTime.m` | measures AI service time (§2) |
| `recommend_district_configuration.m` | right-sizing + bottleneck (§4, §5) |
| `simulate_district_throughput.m` | stochastic discrete-event simulator |
| `run_district_scenario_analysis.m` | 4 scenarios + staffing sweep + recommendation |
