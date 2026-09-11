# Project Status

**Living document.** Update it when a phase moves or a blocker clears — it is the
first thing a teammate (or their AI agent) reads to understand where things stand.

*Last updated: 2026-09-11 — end of Phase 0.*

---

## At a glance

| Phase | State | Owner |
|---|---|---|
| 0 — Setup & literature grounding | ✅ **Complete** (2 data gaps carried forward) | Abhigyan |
| 1 — Image quality & enhancement | ⬜ Not started — *thresholds already measured* | Abhigyan (R1) |
| 2 — Segmentation | ⬜ Not started | Abhigyan (R1) |
| 3 — DR severity grading | ⬜ Not started — *blocked on a decision, see B3* | Abhigyan (R1) |
| 4 — Explainability & reporting | 🟡 **Architecture & Layout Prototype Complete** | Natik (R4) |
| **5 — Simulink throughput** | ✅ **Complete — discrete-event model & sizing verified** | **Natik (R4)** — *reassigned 2026-09-11* |
| 6 — Integration & benchmarking | ⬜ Not started — *blocked on B1* | Abhigyan (R2) |
| 7 — Demo & pitch | ⬜ Not started — *deck skeleton can start now* | Oshi (R5) |

**Module 5 simulation and Module 4 report architecture are implemented.**

---

## Blocker register

### B1 — Messidor-2 has no grade labels 🔴
**Blocks:** *all* of Phase 6 — every external-validation number.
**Owner:** Abhigyan · **Effort:** 5 minutes
Our copy ships images + left/right eye pairing only; `messidor-2.csv` has no
diagnosis column. Download the adjudicated reference standard (3 retina
specialists, consensus-adjudicated) and save to `data/messidor2/messidor_data.csv`:
<https://www.kaggle.com/datasets/google-brain/messidor2-dr-grades>

This is the highest-leverage open item in the project. Without it the headline
claim cannot be measured at all.

### B2 — DRIVE test-set vessel ground truth withheld 🟠
**Blocks:** comparable Phase 2 vessel scores.
**Owner:** Abhigyan · **Effort:** registration + download
`drive/test/` has images and FOV masks but no `1st_manual/`. We hold **20
annotated images total**. Either obtain the official test annotations from
<https://drive.grand-challenge.org>, or split the 20 and document clearly that
the protocol is non-standard (so our Dice is not comparable to published tables).

### B3 — Is DME in or out of "referable"? 🔴
**Blocks:** Phase 3 metric design — and retroactively invalidates comparisons if
decided late.
**Owner:** Abhigyat (R3) · **Effort:** a decision, not a task
Every published referable-DR benchmark (Gulshan, IDx-DR) counts referable macular
oedema in the positive class. Our Modules 2–3 grade DR only. Either:
- **(a)** add DME grading — IDRiD part B already ships a `Risk of macular edema`
  column we hold, so the data cost is zero; or
- **(b)** state explicitly that our sensitivity is DR-only and therefore *not*
  directly comparable to the published figures we are benchmarking against.

Decide **before** Phase 3 starts. See
[literature_benchmarks.md](literature_benchmarks.md) §6.

### B4 — MATLAB not yet installed 🟠
**Blocks:** all MATLAB work.
**Owner:** Abhigyan · **State:** in progress (R2026a → `D:\MATLAB\R2026a`)
Must be **R2026a or newer** — the RTX 5050 is compute capability 12.0 and R2025b
and earlier cap at 9.x. See [matlab_install.md](matlab_install.md).

### B5 — No `.m` file has ever been executed 🟠
**Blocks:** confidence in the Phase 0 MATLAB scaffolding.
**Owner:** Abhigyan · **Effort:** one session
`setup_drishti.m`, `config/*.m`, `tests/test_project_setup.m` were written without
MATLAB available. First action after B4 clears:
```matlab
setup_drishti
runtests('tests/test_project_setup.m')
```
Expect small syntax fixes. The structure is sound; these are not design problems.

### B6 — R1 and R2 held by the same person ✅ **Resolved 2026-09-11**
**Resolution:** Option A — **Module 5 (Simulink) reassigned to Natik (R4)**.
Abhigyan now leads Phases 1, 2, 3 and 6 instead of 1, 2, 3, 5 and 6. Phase 6
pipeline integration stays with Abhigyan; only Phase 5 moved.

Two follow-ups this creates, both now live:
- **B9** — confirm SimEvents is licensed (below)
- Abhigyat's sourcing of bandwidth/staffing parameters is needed **sooner** than
  originally planned, because Natik is blocked on it for realistic Module 5 inputs

### B9 — SimEvents licence unconfirmed 🟠
**Blocks:** Module 5 (Phase 5) using discrete-event blocks.
**Owner:** Abhigyan (verify during install) · **Effort:** one glance
Some campus TAH agreements are scoped per-department. Confirm SimEvents appears in
the product list during the MATLAB install. If it is absent, Module 5 is still
buildable with plain Simulink + Statistics & ML Toolbox for stochastic arrival and
service times — but Natik needs to know that **before** starting, not after
designing around blocks that won't open.

### B7 — Two README epidemiology claims unsourced 🟡
**Blocks:** pitch credibility.
**Owner:** Abhigyat (R3) · **Effort:** an hour
"1 ophthalmologist per 100,000 rural" and "early screening prevents ~90% of vision
loss" could not be traced to a primary source. Source them or drop them. Two
further figures need correcting (77M → ~101M diabetics; ~18% → 12.5% DR
prevalence) — see [literature_benchmarks.md](literature_benchmarks.md) §4.

### B8 — Dataset redistribution terms unchecked 🟡
**Blocks:** shipping the demo / publishing sample reports.
**Owner:** Oshi (R5) · **Effort:** an hour
The four corpora have different licences and several prohibit redistributing
images. Confirm before any fundus image goes into `reports/`, the deck, or the
demo video. See [datasets.md](datasets.md) §8.

---

## What Phase 0 produced

**Data** — all four corpora downloaded, extracted, organised and verified.
`python tools/verify_setup.py` → READY. Counts measured and cross-checked against
published specs. Details: [datasets.md](datasets.md).

**Benchmark targets** — sourced from primary literature, not recall.
[literature_benchmarks.md](literature_benchmarks.md). Headline: our Sens > 90% /
Spec > 85% target sits deliberately *above* the FDA-cleared IDx-DR operating point
(87.2% / 90.7%), and our Messidor-2 copy is exactly the 1,748-image set Gulshan et
al. validated on — so Phase 6 is a direct comparison.

**Module 1 thresholds** — measured from 380 images rather than guessed.
[phase1_quality_baseline.md](phase1_quality_baseline.md) →
`config/quality_thresholds.json`.

**Infrastructure** — path contract (`config/drishti_paths.m`), layout contract
(`config/dataset_layout.json`, shared by the Python and MATLAB checks so they
cannot drift), environment checker, smoke tests, `.gitignore`, install guide.

---

## Findings that change the design

Things measured during Phase 0 that contradict or sharpen the README's plan:

1. **Raw Laplacian variance cannot be thresholded globally.** Within APTOS it
   correlates with FOV diameter at **r = −0.75** — measuring image size about as
   much as focus. FOV normalisation halves it (−0.47) but does not solve it.
   Module 1 needs FOV-banded thresholds or a scale-invariant focus measure.

2. **FOV coverage is a camera fingerprint, not a quality signal.** IDRiD 0.691,
   Messidor-2 0.465, APTOS trimodal. An absolute threshold calibrated on IDRiD
   would reject **100% of Messidor-2** — our whole external benchmark.

3. **Microaneurysm detection is much harder than it looks.** Best-in-world IDRiD
   AUPR is **0.50**. A Phase 2 MA score near 0.9 means a bug or a data leak, not a
   breakthrough.

4. **APTOS test labels were never released** and **Messidor-2 is mixed-format**
   (1,058 `.png` + 690 uppercase `.JPG`). Both are silent-failure traps.

5. **IDRiD's official grading split is well-stratified** — use it as-is rather
   than re-splitting.

6. **`Research Paper.pdf` is not a usable benchmark** — 94.3% accuracy, no
   sensitivity/specificity, no external validation, and clear automated-paraphrasing
   artifacts in the text. Background reading only.

---

## Next actions

**Today, no dependencies:**
- [ ] B1 — download Messidor-2 grade labels *(Abhigyan, 5 min, highest leverage)*
- [ ] B3 — make the DME call *(Abhigyat)*
- [ ] Source rural-telemedicine bandwidth/staffing parameters — **now urgent**,
      Natik is blocked on these for Module 5 *(Abhigyat)*
- [ ] Install MATLAB + Simulink + SimEvents on Natik's machine *(Natik)*
- [ ] Deck skeleton with blanks for numbers *(Oshi)*

**Once MATLAB lands (B4):**
- [ ] B5 — run `setup_drishti` + smoke tests, fix what surfaces *(Abhigyan)*
- [ ] B9 — confirm SimEvents + Medical Imaging Toolbox are licensed *(Abhigyan)*
- [ ] Module 5 skeleton `.slx` — stub blocks, placeholder parameters, correct queue
      topology *(Natik)*
- [ ] Begin Phase 1 against `config/quality_thresholds.json` *(Abhigyan)*

**First Phase 2 task when Phase 1 is stable:** IDRiD optic disc localization — the
smallest task with a hard published benchmark (21.07 px) to calibrate against.
