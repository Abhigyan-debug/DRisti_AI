# Team Roles & Ownership

**Phase 0 deliverable.** Roles assigned — see [Assignment](#assignment).

Five roles, mapped to the README's module structure.

> ### Note: R1 and R2 are the same person
>
> Abhigyan holds both the ML/CV lead and the MATLAB integration role. To stop that
> becoming the schedule's single point of failure, **Module 5 (Simulink) was
> reassigned to Natik (R4) on 2026-09-11** — see
> [Parallelisation](#parallelisation).
>
> Abhigyan now leads Phases 1, 2, 3 and 6. Still the heaviest load on the team, so
> guard it: work that can go to R3/R4/R5 should.

---

## Role definitions

### R1 — ML / Computer Vision lead
**Owns:** Modules 2 and 3 (segmentation, grading).
**Phases:** 2, 3, and the Phase 6 baseline comparison.

- Vessel, disc/fovea, MA, exudate, haemorrhage, neovascularization detectors
- The lesion feature vector contract that Module 3 consumes
- Both Phase 3 models: the single-technique baseline **and** the hybrid model
- Owns the rule that Messidor-2 is touched exactly once

**Needs:** Deep Learning Toolbox, Computer Vision Toolbox, a GPU.
**First task:** IDRiD optic disc localization — smallest task with a hard
published benchmark (21.07 px) to calibrate against.

---

### R2 — MATLAB integration engineer
**Owns:** pipeline integration, the app shell, and repo plumbing.
**Phases:** 6, plus the scaffolding the others build on.

- Wiring Modules 1–4 into one runnable pipeline; App Designer front-end
- Full pipeline run on the held-out Messidor-2 set; baseline vs. integrated comparison
- Keeps `setup_drishti` / `check_environment` / the tests green as the repo grows
- Documents failure cases (Phase 6 deliverable, and a credibility asset)

**Needs:** Image Processing, Computer Vision, Deep Learning, Statistics & ML.
**First task:** once MATLAB lands, run `setup_drishti` and
`runtests('tests/test_project_setup.m')` and fix what surfaces — no `.m` file here
has ever been executed.

> **Module 5 moved to R4** (decision taken 2026-09-11, Option A below). R2 no longer
> owns Simulink. Phase 6 pipeline integration stays here, because wiring Modules 1–4
> is image-pipeline work and Module 5 is a separate resource-planning simulation that
> does not sit in the image path.

---

### R3 — Clinical research / validation
**Owns:** the clinical argument and every number that reaches a slide.
**Phases:** 0 (done, see [literature_benchmarks.md](literature_benchmarks.md)), 4, 6.

- [x] Guards the ICDR definitions and the referable-DR threshold →
      `config/clinical_definitions.json` + [clinical_definitions.md](clinical_definitions.md)
- [x] **DME decision** ✅ *2026-09-11* — **DME is IN**: referable = ICDR ≥ 2 OR
      DME risk = 2, matching IDx-DR's `mtmDR` class. Closed blocker B3.
- [x] Sourced the Simulink model's bandwidth/staffing assumptions →
      `config/telemedicine_parameters.json` + [telemedicine_parameters.md](telemedicine_parameters.md),
      every value tagged SOURCED / DERIVED / ASSUMED. Natik unblocked.
- [x] Fixed the two [unverified] README epidemiology claims ✅ — one dropped as
      untraceable, one re-attributed. Closed blocker B7.
- [ ] **Recruits the ophthalmologist reviewer** for the Grad-CAM usefulness rating —
      instrument ready at [gradcam_review_protocol.md](gradcam_review_protocol.md).
      **Longest lead time on the project and no technical dependency — start now.**
- [ ] Verify the OJPHI workforce figures against full text (abstract-only today)
- [ ] Get a real technician time-per-patient figure — the weakest Module 5 parameter

**Needs:** no toolboxes. Needs literature access and, ideally, one clinician contact.
**First task:** ~~resolve the DME question~~ → **done.** Next: reviewer recruitment.

---

### R4 — Simulink modelling + UI / reporting
**Owns:** Module 5 *and* Module 4.
**Phases:** **5 (start now)**, then 4, then 7.

Two jobs, deliberately sequenced so they don't collide: Module 5 has **no
dependencies and starts today**; Module 4 can't finish until Modules 2–3 produce
output, so it follows.

**Module 5 — Simulink screening throughput (Phase 5, start immediately)**

- Discrete-event/queuing model of acquisition → upload → AI processing → review
- Scenario analysis for the 100,000 patients/year district target
- Output: required cameras, technicians, compute nodes, reviewing ophthalmologists,
  and where the bottleneck actually is
- Parameters come from R3's sourced rural-telemedicine studies — **cite them**;
  unrealistic assumptions are the named risk in the README's risk table

*First task:* stand up a skeleton `.slx` with stub blocks and arbitrary parameters.
The model **structure** is worth more early than accurate numbers — get the queue
topology right, then let R3's citations replace the placeholders.

**Module 4 — the report (Phase 4, after Phase 3)**

- The one-page annotated report: image + Grad-CAM overlay, ICDR grade, calibrated
  confidence, lesion evidence table, recommended action
- **The sub-30-second review target is a design constraint, not a nice-to-have** —
  own it, time it with a stopwatch, iterate
- Module 1's structured recapture messages ("Recentre on macula") — these are UI
  copy aimed at a rural technician, not debug strings
- The App Designer front-end, with R2

*Can start before Phase 3:* paper-prototype the report layout and time a mock
review against a hand-made example. Costs nothing, exposes the layout problems early.

**Needs:** **Simulink + SimEvents** (verify these are licensed under the campus
agreement — they are sometimes scoped per-department), Statistics & ML Toolbox,
Image Processing Toolbox, MATLAB Report Generator (or hand-rolled PDF).

---

### R5 — Presentation / documentation
**Owns:** the submission.
**Phases:** 7, and continuously.

- Pitch deck: problem → architecture → validation → deployment impact
- Architecture diagram, demo video, final README
- Keeps `docs/` honest as results land — especially the failure cases
- Owns the framing that our target sits *above* the FDA-cleared IDx-DR operating
  point (87.2% / 90.7%) — a specific, defensible claim

**Needs:** nothing but the results.
**First task:** draft the deck skeleton now, with blanks where numbers go. It
exposes which results actually matter and stops Phase 7 from being a scramble.

---

## Assignment

| Role | Name | Owns |
|---|---|---|
| R1 — ML / CV | **Abhigyan** *(this laptop)* | Modules 2–3 · Phases 1, 2, 3 |
| R2 — MATLAB integration | **Abhigyan** *(this laptop)* | pipeline integration · Phase 6 |
| R3 — Clinical research | **Abhigyat** | metric definitions · the DME call · sourcing |
| R4 — Simulink + reporting | **Natik** | **Module 5 (Phase 5)** · Module 4 (Phase 4) |
| R5 — Presentation / docs | **Oshi** | pitch · diagram · demo · keeping `docs/` honest |

**Everyone:** run `python tools/verify_setup.py` and `setup_drishti` on your own
machine before writing code, and commit nothing under `data/`.

---

## Phase ownership

| Phase | Lead | Support |
|---|---|---|
| 0 — Setup & grounding ✅ | Abhigyan (R2) | Abhigyat (R3) |
| 1 — Quality & enhancement | Abhigyan (R1) | Natik (recapture message copy) |
| 2 — Segmentation | Abhigyan (R1) | — |
| 3 — Grading | Abhigyan (R1) | Abhigyat (metric design) |
| 4 — Explainability & reporting | Natik (R4) | Abhigyan, Abhigyat |
| **5 — Simulink throughput** | **Natik (R4)** | Abhigyat (sourced assumptions) |
| 6 — Integration & benchmarking | Abhigyan (R2) | Abhigyat |
| 7 — Demo & pitch | Oshi (R5) | all |

Abhigyan leads 4 of 8 phases (down from 5 before Module 5 moved); Natik leads 2.

---

## Parallelisation

**Decision taken 2026-09-11: Option A — Module 5 reassigned to Natik (R4).**

Abhigyan holds R1 + R2, which originally put Phases 1, 2, 3, 5 and 6 on one person
while three teammates carried one role each. Moving Module 5 off that path is the
cleanest available hand-off:

- Module 5 needs **no images, no trained model, no results** — it starts today
- It is discrete-event *modelling*, not CV, so it shares no skills with Phases 1–3
  and no context-switching cost with the critical path
- Natik's own Module 4 work is Phase 4 and idle until Modules 2–3 produce output,
  so the two jobs sequence naturally rather than competing
- It keeps the piece that directly answers the problem statement's *district-scale
  rollout* question, instead of demoting it to a stretch goal

**Cost, stated honestly:** Natik needs Simulink + SimEvents access and a ramp-up on
discrete-event modelling. Because the task has no upstream dependencies, that
ramp-up happens during time that would otherwise be spent waiting — it is free time,
not lost time. Phase 6 pipeline integration stays with Abhigyan; only Phase 5 moved.

**Immediate follow-ups from this decision:**

- [ ] Confirm **SimEvents** is licensed under the campus agreement (verify during
      the MATLAB install product selection — some TAH agreements are scoped by
      department). If it is not, Module 5 can still be built with plain Simulink
      plus Statistics & ML for stochastic arrivals, but say so before starting.
- [ ] Natik installs MATLAB with Simulink + SimEvents on their own machine
- [ ] Abhigyat prioritises sourcing the bandwidth/staffing parameters — Natik is
      now blocked on those sooner than the original plan assumed

### These three run from day one

- **Module 5 skeleton** (Natik, R4) — stub `.slx` with placeholder parameters; get
  the queue topology right first
- ~~**Clinical/metric decisions** (Abhigyat, R3)~~ ✅ **delivered 2026-09-11** — DME
  call made, Module 5 parameters sourced, epidemiology claims fixed. R3's remaining
  critical-path item is **ophthalmologist recruitment**, which has the longest lead
  time on the project
- **Deck skeleton** (Oshi, R5) — blanks where numbers go; it exposes which results
  actually matter

## Working agreements

1. **Nothing under `data/`, `models/`, or `results/` goes into git.** `.gitignore`
   enforces it; don't use `git add -f`.
2. **Messidor-2 is touched once**, at Phase 6, with a frozen threshold.
3. **Every reported number carries its evaluation protocol** — split, threshold
   rule, FOV masking. See [literature_benchmarks.md](literature_benchmarks.md) §2.5
   for why this matters.
4. **Failure cases get documented, not hidden.** The README lists this as a
   Phase 6 deliverable, and it is a credibility asset in a clinical pitch.
5. Keep `tests/test_project_setup.m` and `tools/verify_setup.py` green.
