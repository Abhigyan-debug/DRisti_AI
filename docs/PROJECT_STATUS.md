# Project Status

**Living document.** Update it when a phase moves or a blocker clears — it is the
first thing a teammate (or their AI agent) reads to understand where things stand.

*Last updated: 2026-09-11 — end of Phase 0. R3 closed B3 and B7; B10 opened.*

---

## At a glance

| Phase | State | Owner |
|---|---|---|
| 0 — Setup & literature grounding | ✅ **Complete** (2 data gaps carried forward) | Abhigyan |
| 1 — Image quality & enhancement | ✅ **Complete** — gate + enhancement + degradation study | Abhigyan (R1) |
| 2 — Segmentation | ⬜ Not started | Abhigyan (R1) |
| 3 — DR severity grading | ⬜ Not started — *metric design **unblocked**, B3 resolved* | Abhigyan (R1) |
| 4 — Explainability & reporting | 🟡 **Architecture & layout prototype complete** — *Grad-CAM review instrument ready* | Natik (R4) |
| **5 — Simulink throughput** | 🟡 **Model built** — *parameters pending reconciliation, see B11* | **Natik (R4)** — *reassigned 2026-09-11* |
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

### B3 — Is DME in or out of "referable"? ✅ **Resolved 2026-09-11**
**Resolution: option (a) — DME is IN.**
**Referable DR = ICDR grade ≥ 2 OR DME risk grade = 2.**

Frozen in [`config/clinical_definitions.json`](../config/clinical_definitions.json);
reasoning, costs and the three reported endpoints in
[clinical_definitions.md](clinical_definitions.md).

Why (a): it is the positive class IDx-DR and Gulshan use, so the headline
"above the FDA-cleared operating point" claim stays true; the labels exist on both
ends (IDRiD's column, and `adjudicated_dme` in the Krause Messidor-2 standard); and
IDRiD's DME grade is *defined* by hard-exudate distance from the macula, which
Module 2 already computes — so it costs a function, not a model.

**Live consequences:**
- Module 2's **disc/fovea localizer and hard-exudate segmenter now have a
  diagnostic consumer**, raising their priority relative to MA detection *(R1)*.
- **APTOS has no DME labels** → every APTOS number is the DR-only endpoint and must
  be labelled as not comparable to Gulshan/IDx-DR *(R1, R5)*.
- Phase 3 must read endpoints from the JSON, never hardcode a threshold *(R1)*.
- One supporting number is still unmeasured (§5 of the decision doc) — run
  `python tools/idrid_dme_crosstab.py` when IDRiD is on a machine. Needs one CSV,
  no images. **Does not reopen the decision.**

### B4 — MATLAB not yet installed ✅ **Resolved 2026-09-11**
R2026a installed and verified. GPU detected at compute capability 12.0 as predicted;
all 8 toolboxes licensed **including SimEvents and Medical Imaging** (that also closes
B9). MATLABROOT is `D:\MATLAB\_installer` — an odd name because the install was
pointed at the download folder. It works; **do not "clean up" that folder**.

Original note:
**Owner:** Abhigyan · **State:** done (R2026a)
Must be **R2026a or newer** — the RTX 5050 is compute capability 12.0 and R2025b
and earlier cap at 9.x. See [matlab_install.md](matlab_install.md).

### B5 — No `.m` file has ever been executed ✅ **Resolved 2026-09-11**
Every Phase 0 `.m` file ran correctly on first execution; no syntax fixes were needed.
Phase 0 + Phase 1 suites: 14/14 passing. Original entry below.

#### (original) 🟠
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

### B9 — SimEvents licence unconfirmed ✅ **Resolved 2026-09-11** — licensed, confirmed at install.

#### (original) 🟠
**Blocks:** Module 5 (Phase 5) using discrete-event blocks.
**Owner:** Abhigyan (verify during install) · **Effort:** one glance
Some campus TAH agreements are scoped per-department. Confirm SimEvents appears in
the product list during the MATLAB install. If it is absent, Module 5 is still
buildable with plain Simulink + Statistics & ML Toolbox for stochastic arrival and
service times — but Natik needs to know that **before** starting, not after
designing around blocks that won't open.

### B7 — Two README epidemiology claims unsourced ✅ **Resolved 2026-09-11**
All four README §1.1 figures are now sourced or removed. Record in
[literature_benchmarks.md](literature_benchmarks.md) §4.

- "1 ophthalmologist per 100,000 rural" → **dropped**, untraceable. Replaced with
  ~15 ophthalmologists/million nationally and the district range **1:6,309
  (Hyderabad) → 1:193,822 (Nalgonda)**. The ~30× within-state spread is a stronger
  argument than any national mean.
- "prevents ~90% of vision loss" → **re-attributed** as "up to 95%", US National Eye
  Institute. Not a trial endpoint — DRS/ETDRS report ~50% reductions. Present it as
  an NEI public-health figure, nothing more.
- 77M → **~101M** diabetics; ~18% → **12.5%** DR prevalence (SMART India).
- Added: **no significant urban–rural difference in DR prevalence**. Same burden,
  ~30× less access — the project's thesis in one line.

⚠️ The workforce figures are **abstract-only** (publisher returned an empty body on
three fetch attempts). Verify against full text before the pitch —
[telemedicine_parameters.md](telemedicine_parameters.md) §5.

### B10 — Datasets not present on R3's machine 🟡 *(machine-specific, not data loss)*
**Status:** the data is intact. Verified 2026-09-11 on Abhigyan's machine:
`python tools/verify_setup.py` → **READY**, all four corpora present at
`D:\DRishti_AI_data` with `_archives\` backup, and `<repo>\data` junctioned to it.

B10 was raised from a checkout that had no `config/local_paths.json` and no data root —
which is the *expected* state on any machine that has not set one up, and is exactly
what [environment_setup.md §0](environment_setup.md#0-what-do-i-actually-need)
describes. Nothing was lost.

**For R3 and R5 specifically: you do not need the datasets at all.** Clinical
research, sourcing and the deck touch no images. A `verify_setup.py` failure on your
machine is expected and is not a problem to fix.

Original entry below for the record.

#### (original) 🟠
**Blocks:** `verify_setup.py`, all Phase 1–3 work on this box, and the one
unmeasured number in B3.
**Owner:** Abhigyan · **Effort:** unknown — depends on whether the data still exists
The docs describe a data root at `D:\DRishti_AI_data` with `<repo>\data` as a
junction. On this machine **none of that is present**: no `data/` in the repo, no
`D:\DRishti_AI_data` (D: exists, 324 GB free), and no `config/local_paths.json`.
Either this is a different machine from the one Phase 0 ran on, or the ~12.8 GB root
and its `_archives\` backup are gone.

Establish which, before anyone trusts a "READY" from a previous session. If the data
is genuinely lost, `python tools/organize_datasets.py` rebuilds the layout *from the
archives* — which are inside the missing root, so re-downloading would be required.

### B11 — Module 5 parameter citations need verification 🔴 *(new, 2026-09-11)*
**Blocks:** any Phase 5 number reaching a slide.
**Owner:** Natik (R4) with Abhigyat (R3) · **Effort:** an hour
`simulink/screening_params.m` carries a sourced-looking citation block. Three of its
claims could not be verified, and one is contradicted by the document it cites:

- `initialRejectRate = 0.12` is attributed to
  [phase1_quality_baseline.md](phase1_quality_baseline.md). **That document explicitly
  does not establish a reject rate** — it says it measures distributions "but not what
  counts as a reject", and warns the deployment reject rate is still unknown.
- *"Rani et al., Eye 2021"* (Sankara Nethralaya) — not found. The real Sankara
  Nethralaya teleophthalmology paper appears to be **John et al., Telemed J E Health
  2012**.
- *"Prathiba et al., Community Eye Health 2018"* — the matching paper appears to be
  **Prathiba & Rema, Int J Family Med 2011**. Journal and year both differ.
- *"Raman et al., Ophthalmology 2016"* (6–8 min acquisition) — could not be verified.

Absence from a web search does not prove a citation is invented, but the first item is
provably misattributed and the rest share the pattern. **A judge checking one citation
would put the whole deck in doubt**, so this is red, not amber.

**Fix:** replace the block with `config/telemedicine_parameters.json`, where every
value is tagged SOURCED / DERIVED / ASSUMED and the assumptions are labelled as
assumptions. Most of Natik's numbers are close to the sourced ones already (reject
rate 12% vs. measured 10.9%; 1 Mbps uplink sits inside the 1/5/20 sweep). One real
divergence needs a decision: **`imagesPerPatient` 4 (2-field × 2 eyes) vs. 2
(macula-centric, per AIDRSS)** — it doubles the upload payload.

### B12 — DME scale mismatch between contract and Messidor-2 🔴 *(new, 2026-09-11)*
**Blocks:** the primary endpoint on the benchmark where the headline claim is made.
**Owner:** Abhigyat (R3) — the contract is frozen, so this is R3's call · **Effort:** one line

`config/clinical_definitions.json` defines DME on **IDRiD's 0/1/2 scale** and the
primary endpoint as `dr_grade >= 2 OR dme_grade >= 2`. But Messidor-2's
`adjudicated_dme` is **binary 0/1** — verified on disk: 1593 zeros, 151 ones, 4 blank.

Applied literally to Messidor-2, `dme_grade >= 2` matches **nothing**, and the primary
endpoint silently collapses to the DR-only secondary endpoint. No error is raised; the
number just comes out wrong and labelled as the DR-or-DME result.

**Measured impact: 8 of 1744 gradable images (0.5%).** Referable prevalence is 26.7%
under the intended rule versus 26.2% as written — small, because most DME-positive
cases already have DR >= 2.

**But those 8 cases are the entire point of the endpoint.** They are the DME-only
referrals — DR < 2 with DME present — which is exactly what the primary endpoint
catches and the secondary cannot. The rule as written misses **100% of its
distinctive contribution** on the benchmark, while appearing to work.

**Fix:** the endpoint needs a per-dataset DME mapping, e.g.
`{"idrid": ">=2", "messidor2": ">=1"}`, not a single global threshold. IDRiD grades DME
0/1/2 by hard-exudate distance from the macula; Krause et al. published Messidor-2 DME
as a binary referable/not flag. Both are correct for their own dataset — the contract
just cannot assume one scale covers both.

Do this **before** Phase 3 freezes thresholds, and note the contract is marked
`_frozen`, so amend it deliberately with a version bump rather than editing in place.

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

**Clinical contract** *(added 2026-09-11, R3)* — the referable-DR definition,
the three reported endpoints and the operating-point freeze policy, in
`config/clinical_definitions.json` + [clinical_definitions.md](clinical_definitions.md).
Phase 3/6 code reads the endpoint from the file rather than hardcoding a threshold,
so any number in the repo is traceable to the definition that produced it.

**Module 5 parameters** *(added 2026-09-11, R3)* — sourced rural-teleophthalmology
assumptions in `config/telemedicine_parameters.json` +
[telemedicine_parameters.md](telemedicine_parameters.md), every value tagged
SOURCED / DERIVED / ASSUMED. This is the mitigation for the README's named risk that
the Simulink model rests on invented numbers.

**Grad-CAM review instrument** *(added 2026-09-11, R3)* — blinded rating protocol
with negative controls and a pre-registered success threshold,
[gradcam_review_protocol.md](gradcam_review_protocol.md).

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
- [ ] **B10 — establish whether the dataset root still exists** *(Abhigyan — do this
      first, it gates B1 and all Phase 1–3 work)*
- [ ] B1 — download Messidor-2 grade labels *(Abhigyan, 5 min, highest leverage)*
- [x] ~~B3 — make the DME call~~ ✅ *(Abhigyat, 2026-09-11 — DME is IN)*
- [x] ~~Source rural-telemedicine bandwidth/staffing parameters~~ ✅
      *(Abhigyat — `config/telemedicine_parameters.json`; Natik is unblocked)*
- [x] ~~B7 — source or drop the two epidemiology claims~~ ✅ *(Abhigyat)*
- [ ] Install MATLAB + Simulink + SimEvents on Natik's machine *(Natik)*
- [ ] Deck skeleton with blanks for numbers *(Oshi)*
- [ ] **Read [telemedicine_parameters.md](telemedicine_parameters.md) §2 before
      building the Simulink model** *(Natik)* — the envelope calculation says
      ophthalmologist review is **not** the bottleneck (~9 specialist-minutes/day for
      a whole district). Acquisition is. Building the model around the wrong
      bottleneck would waste the phase.

**R3's remaining queue:**
- [ ] Recruit the ophthalmologist reviewer — longest lead time on the project, no
      technical dependency, [protocol ready](gradcam_review_protocol.md) *(Abhigyat)*
- [ ] Verify the OJPHI workforce figures against full text (abstract-only today)
- [ ] Get a real technician time-per-patient figure — the weakest Module 5 parameter
- [ ] Fill §5 of [clinical_definitions.md](clinical_definitions.md) once IDRiD exists

**Once MATLAB lands (B4):**
- [ ] B5 — run `setup_drishti` + smoke tests, fix what surfaces *(Abhigyan)*
- [ ] B9 — confirm SimEvents + Medical Imaging Toolbox are licensed *(Abhigyan)*
- [ ] Module 5 skeleton `.slx` — stub blocks, placeholder parameters, correct queue
      topology *(Natik)*
- [ ] Begin Phase 1 against `config/quality_thresholds.json` *(Abhigyan)*

**First Phase 2 task when Phase 1 is stable:** IDRiD optic disc localization — the
smallest task with a hard published benchmark (21.07 px) to calibrate against.
