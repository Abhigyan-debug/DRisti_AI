# Explainable AI for Diabetic Retinopathy Screening in Rural India

**Smart India Hackathon — Software Track**
**Organization:** MathWorks | **Department:** MathWorks | **Theme:** MedTech / BioTech / HealthTech

> **New here?** Run `python tools/verify_setup.py` to check this machine, then read
> the measured results in [docs/](docs/) — each phase documents its own protocol.
> Setup instructions: [docs/environment_setup.md](docs/environment_setup.md).
>
> **Checking our claims?** `python tools/check_all.py` — six checks, no MATLAB and
> no datasets needed (add `--skip-setup`). It verifies that every pre-registered
> contract still hashes to its recorded value, that no retired or banned figure
> appears anywhere in the repository, and that every code path still refuses to
> re-read the held-out benchmark. §6 says what that does and does not prove.

---

## 1. Problem Context

### 1.1 The Public Health Gap

*Every figure here is sourced. Provenance and the claims we removed:
[docs/literature_benchmarks.md](docs/literature_benchmarks.md) §4.*

- India has **~101 million diabetic adults** — the second-highest burden globally
  (ICMR-INDIAB, 11.4% prevalence).
- **12.5%** of people with diabetes have DR (95% CI 11.0–14.2); **~3 million**
  adults aged 40+ have vision-threatening DR — a leading cause of *preventable*
  blindness ([SMART India, *Lancet Global Health* 2022](https://www.thelancet.com/journals/langlo/article/PIIS2214-109X(22)00411-9/fulltext)).
- Early detection, timely treatment and follow-up can reduce the risk of severe
  vision loss by **up to 95%** (US National Eye Institute).
- India has **~15 ophthalmologists per million** people, against 38.6 per million
  in developed countries — and the shortage is one of *distribution*, not just
  totals: district-level ratios range from **1:6,309 (Hyderabad) to 1:193,822
  (Nalgonda)** within a single state (OJPHI 2024;16:e50921).
- **DR prevalence shows no significant urban–rural difference** (SMART India). Same
  disease burden, ~30× less specialist access — the rural problem is **access to
  screening**, not lower disease. This is precisely what Module 5 addresses.
- Manual, in-person mass screening is logistically and economically infeasible at
  national scale.

### 1.2 Why Existing AI Solutions Fall Short
| Limitation | Consequence |
|---|---|
| Black-box models | No clinical trust, no regulatory pathway, no ophthalmologist buy-in |
| No/weak clinical validation | Cannot be deployed safely in primary healthcare centres (PHCs) |
| Fragile to image quality | Portable/handheld fundus cameras in field conditions produce noisy, poorly-lit, off-axis images → high false referrals or missed disease |

### 1.3 What's Needed
A **clinically validated, explainable, field-robust** screening pipeline that:
1. Filters out ungradeable images before they waste clinician time.
2. Detects and localizes DR-relevant lesions, not just a single class label.
3. Grades DR severity per the **International Clinical DR (ICDR) Scale (0–4)**.
4. Explains *why* it made a decision, in a way an ophthalmologist can verify in **<30 seconds**.
5. Fits into a realistic **telemedicine throughput model** for district-scale (100,000+ patients/year) rollout.

---

## 2. Solution Overview

A MATLAB/Simulink-based end-to-end pipeline with five integrated modules:

```
Fundus Image → [1] Quality Assessment & Enhancement
             → [2] Retinal Structure Segmentation (disc/fovea, vessels, lesions)
             → [3] DR Severity Grading (ICDR 0–4, referable DR = Level 2+)
             → [4] Explainability (Grad-CAM, lesion evidence, calibrated confidence, auto-report)
             → [5] Simulink Screening-Throughput Simulation (district-level resource planning)
```

### Target Performance (Clinical Bar)
- **Sensitivity > 90%** and **Specificity > 85%** for **referable DR**, defined as
  **ICDR grade ≥ 2 *or* centre-involving macular oedema** — the same positive class
  as IDx-DR's cleared `mtmDR` endpoint, so the comparison is like-for-like.
  Frozen in [`config/clinical_definitions.json`](config/clinical_definitions.json);
  reasoning in [docs/clinical_definitions.md](docs/clinical_definitions.md)
- Grad-CAM outputs independently rated **"clinically useful"** by ophthalmologist reviewers
- Validated against **published benchmarks** (IDRiD, Messidor-2, APTOS 2019 leaderboards) — integrated pipeline must **outperform single-technique baselines** (e.g., plain CNN classifier with no QA/segmentation stage)

---

## 3. Module-Level Design

### Module 1 — Image Quality Assessment & Enhancement
- **Inputs:** raw fundus image (any resolution/camera)
- **Checks:** focus/sharpness (Laplacian variance), illumination uniformity, field-of-view coverage, artifact/glare detection
- **Adaptive enhancement:** CLAHE (contrast), illumination normalization (background subtraction / homomorphic filtering), denoising (non-local means / wavelet)
- **Gate logic:** borderline → enhance & re-score; ungradeable → reject with a **structured recapture reason** (e.g., "Increase illumination", "Recentre on macula")
- **Toolboxes:** Image Processing Toolbox

### Module 2 — Retinal Structure Segmentation
- **Optic disc & fovea localization** — Hough/circular Hough transform seeded, refined with a lightweight CNN or region-growing on the brightest, high-vessel-density region.
- **Vessel segmentation** — matched filtering / U-Net (trained on DRIVE) → vessel map used both diagnostically and as an anatomical reference frame (e.g., disc-to-fovea distance normalization).
- **Microaneurysm (MA) detection** — sub-pixel candidate detection via top-hat morphology + Radon-transform-based candidate extraction, false-positive reduction via a small CNN classifier (IDRiD MA ground truth).
- **Exudate segmentation** — intensity + texture-based candidate regions, refined by proximity-to-vessel and color-space (a*b* in Lab) features.
- **Hemorrhage classification** — shape/size discrimination from MAs (dot vs. blot vs. flame-shaped).
- **Neovascularization detection** — vessel density/tortuosity anomaly detection near disc and periphery (marker of proliferative DR).
- **Toolboxes:** Image Processing Toolbox, Computer Vision Toolbox, Deep Learning Toolbox, Medical Imaging Toolbox

### Module 3 — DR Severity Grading
- **Approach:** hybrid — lesion-count/severity features (from Module 2) **feed into** a calibrated classifier (e.g., ordinal regression or CNN + gradient-boosted trees on engineered features) rather than a pure end-to-end black box.
- **Output classes (ICDR 0–4):**
  - 0 — No DR
  - 1 — Mild NPDR
  - 2 — Moderate NPDR *(referable threshold starts here)*
  - 3 — Severe NPDR
  - 4 — Proliferative DR
- **DME risk grade (0–2)** — derived geometrically from Module 2's hard-exudate mask,
  fovea centre and disc diameter, not a separately trained model. Required because
  referable DR includes centre-involving oedema.
- **Clinical operating point:** threshold tuned so Sensitivity > 90%, Specificity > 85% for the binary "referable vs. not" decision, reported via ROC/AUC and a confusion matrix per class. Three operating points and three endpoints are reported — see [docs/clinical_definitions.md](docs/clinical_definitions.md) §4. Thresholds are **frozen before Messidor-2 is read**.
- **Toolboxes:** Deep Learning Toolbox, Statistics and Machine Learning Toolbox

### Module 4 — Explainability Module
- **Grad-CAM / Grad-CAM++** heatmaps overlaid on the fundus image, highlighting regions driving the grade.
- **Lesion-level evidence table** — cross-references Grad-CAM hotspots with Module 2's detected lesions (MA count, exudate area, hemorrhage count) so every AI decision maps to a **named clinical finding**, not just a heatmap.
- **Calibrated confidence scores** — Platt scaling / isotonic regression so output probabilities are trustworthy, not just softmax scores.
- **Auto-generated annotated report** — single-page PDF/summary: image + overlay, ICDR grade, confidence, lesion counts, recommended action — designed for **<30 second ophthalmologist review**.
- **Toolboxes:** Deep Learning Toolbox, Image Processing Toolbox

### Module 5 — Simulink Screening-Throughput Simulation
- Models the **telemedicine pipeline as a queuing/throughput system**:
  - Image acquisition rate (per camera/technician, per PHC)
  - Network bandwidth constraints for image upload to a central server
  - AI processing throughput (images/hour per compute node)
  - Ophthalmologist review capacity (reviews/hour, <30s target)
- **Goal:** given a target of 100,000+ patients/year at district level, output the required number of cameras, technicians, compute nodes, and reviewing ophthalmologists — and identify bottlenecks.
- **Toolboxes:** Simulink, Statistics and Machine Learning Toolbox (for stochastic arrival/service modeling)

---

## 4. Datasets

| Dataset | Use | Link |
|---|---|---|
| APTOS 2019 Blindness Detection | DR severity grading (0–4) training/validation | kaggle.com/c/aptos2019-blindness-detection |
| IDRiD (Indian Diabetic Retinopathy Image Dataset) | Lesion-level ground truth (MA, hemorrhage, exudates), disc/fovea localization — most clinically relevant since it's India-sourced | ieeedataport.org/open-access/indian-diabetic-retinopathy-image-dataset-idrid |
| DRIVE | Vessel segmentation ground truth | drive.grand-challenge.org |
| Messidor-2 | Independent external validation / benchmarking | adcis.net/en/third-party/messidor2 |

**Split strategy:** train/tune on APTOS + IDRiD, hold out Messidor-2 purely for final benchmark validation to avoid optimistic bias.

> 📋 All four are downloaded, extracted and verified. See **[docs/datasets.md](docs/datasets.md)**
> for measured file counts, ICDR grade distributions, resolution profiles, the locked
> split strategy, and two outstanding gaps (Messidor-2 has **no grade labels**; DRIVE
> has **no test vessel GT**). Note that APTOS's 1,928 test images have no public
> labels — all APTOS evaluation must come from a split of the 3,662 labelled images.

---

## 5. Project Roadmap

### Phase 0 — Setup & Literature Grounding ✅ *(complete except where noted)*
- [x] Define team roles and phase ownership
- [x] Repo structure, `.gitignore`, path config, environment checker, smoke tests
      → [docs/environment_setup.md](docs/environment_setup.md)
- [x] Install MATLAB + toolboxes — **R2026a installed and in use.**
      ⚠️ **SimEvents is licensed but NOT installed** (`ver()` and `license()` both
      pass for an absent product); `check_environment` now reports `[NOT INST]`
      and the Simulink model uses the native continuous-queue formulation.
- [x] Organize & verify APTOS, IDRiD, DRIVE, Messidor-2 → [docs/datasets.md](docs/datasets.md)
      (`python tools/verify_setup.py` → READY)
- [x] **Messidor-2 grade labels obtained** (Krause et al. adjudicated). Used for the
      single held-out read on 2026-09-12 — **that one-shot is now SPENT**, see
      [docs/phase6_results.md](docs/phase6_results.md) §3.
- [ ] **Obtain DRIVE test-set vessel GT** — withheld in our copy; affects Phase 2 comparability
- [x] Literature review with sourced benchmark targets → [docs/literature_benchmarks.md](docs/literature_benchmarks.md)

**Key Phase 0 findings:**
- Our Sens > 90% / Spec > 85% target sits **above the FDA-cleared IDx-DR operating
  point** (87.2% / 90.7%) — a specific, defensible claim for the pitch.
- Our Messidor-2 copy is **exactly** the 1748-image set Gulshan et al. validated on
  (JAMA 2016), making the Phase 6 comparison directly meaningful.
- Best-in-world microaneurysm segmentation is **AUPR 0.50** — calibrate Phase 2
  expectations accordingly.
- Two README epidemiology figures need correcting; see
  [literature_benchmarks.md](docs/literature_benchmarks.md) §4.

### Phase 1 — Image Quality & Enhancement Pipeline ✅ *thresholds in [docs/phase1_quality_baseline.md](docs/phase1_quality_baseline.md)*
- [x] Implement focus/illumination/FOV scoring functions
- [x] Build CLAHE + illumination normalization + denoising pipeline
- [x] Define reject/recapture logic and test on deliberately degraded images
      ([docs/phase1_degradation_study.md](docs/phase1_degradation_study.md))
- [x] Unit-test against a mixed-quality subset — `tests/test_quality_metrics.m`

> Thresholds were **measured from 380 images**, not guessed. Note Phase 6 §4: the
> gate does **not** improve grading accuracy — its justification is clinical.

### Phase 2 — Segmentation Modules ⚠️ *built and measured; most channels fail their bar*
- [x] Optic disc & fovea localization (validated against IDRiD annotations)
- [x] Vessel segmentation — DRIVE **Dice 0.622** vs 0.828 U-Net benchmark.
      ⚠️ scored on the *training* split; test GT is withheld in our copy (B2)
- [x] Microaneurysm detection — validated, and it **does not work**: precision
      **0.028** / recall **0.409** on the held-out IDRiD test split
      (micro-averaged, n=27, re-measured 2026-09-13). Clears the recall gate,
      ~18× below the 0.50 precision bar. Stage 2 is **off** — it lost the TRAIN
      sweep to keeping every candidate. **Suppressed from the report**
- [x] Exudate + haemorrhage — haemorrhage precision **0.164** / recall 0.311
      (suppressed; improved on every axis by the rebuild, still ~3× short).
      Hard exudates **0.817 precision / 0.133 recall at k=3.0**, the one
      displayed channel
- [x] Neovascularization heuristic — implemented, **never validated** (no ground truth)
- [x] Consolidate into a structured feature vector — `extractLesionFeatures.m`,
      contract in `config/lesion_features.json`

> **This phase is honestly "done but weak".** Every channel carries its measured
> recall/precision and a `reliable` flag; unreliable channels render as
> "not validated", never as zero. Details: [docs/phase3_results.md](docs/phase3_results.md) §3e.

### Phase 3 — DR Severity Grading Model ✅ *complete; results in [docs/phase3_results.md](docs/phase3_results.md)*
- [x] Baseline end-to-end CNN — ResNet-18 @ 640px. **Sens 90.3% / Spec 95.9%, AUC 0.9891**
- [x] Hybrid lesion-feature model — built and measured. **Does not beat the baseline**
      (0.9795 vs 0.9853, inside sampling noise). Lesion features alone reach AUC 0.870,
      so they carry real signal, but add nothing a CNN at 0.985 has not already learned.
- [x] Train on APTOS **+ IDRiD**; calibrate threshold — multi-domain training helps on
      the domains trained on, **not on a third unseen one** (Messidor-2 AUC 0.885 → 0.876)
- [x] Evaluate: sensitivity, specificity, AUC, per-class confusion matrix
- [x] Cross-validate against Messidor-2 — **Sens 31.2% at the frozen threshold.**
      Per-site calibration narrows that gap but does **not** close it: measured
      end to end on IDRiD (fit on TRAIN n=413, evaluated on held-back TEST
      n=103) it moves **75.0% → 82.8%** sensitivity for **97.4% → 76.9%**
      specificity — [docs/site_calibration.md](docs/site_calibration.md)

> ⚠️ **The "integrated outperforms single-technique" claim in §2 is NOT supported by
> measurement.** We built it and tested it. Module 2's contribution is *explanatory*
> (naming the finding behind a decision), not predictive. The quality gate likewise
> costs 9.2pp specificity on APTOS for 0.7pp sensitivity. Correct the claim rather
> than repeat it — details in [docs/phase3_results.md](docs/phase3_results.md).

### Phase 4 — Explainability & Reporting ✅ *(one item partial)*
- [x] Grad-CAM on the trained grading network — `explainGrading.m`
- [x] Correlate Grad-CAM with Module 2 lesion locations — **enrichment 1.51×** vs
      expert masks. Above chance but **not strong corroboration**; do not claim
      validated explainability
- [x] Confidence calibration (Platt) — `models/calibrator.mat`. Fitted on APTOS;
      the report states that basis rather than implying it generalises
- [x] Auto-generate the one-page annotated report — `generate_clinical_report.m`,
      self-contained HTML with the fundus/Grad-CAM image embedded
- [~] **Informal usability pass — instrument built, no clinician timed.**
      `usabilityPass.m` produces a stopwatch-ready review set and audits every
      report (9/9 structural checks). It measured a **~38 s read-time floor** for
      the critical path at 200 wpm — i.e. the sub-30 s target may not be met, and
      the 30 s figure Module 5 assumes could be optimistic. **Needs a human.**

### Phase 5 — Simulink Throughput Simulation ✅
- [x] Model acquisition → upload → AI processing → review as a discrete-event/queuing system in Simulink
- [x] Parameterize with realistic rural bandwidth and staffing assumptions
- [x] Run scenario analysis for 100,000+ patients/year district target
- [x] Output: recommended camera/technician/compute/ophthalmologist ratios and bottleneck report

Results: **[docs/phase5_results.md](docs/phase5_results.md)**.

**Measured:** AI service time on CPU — **10.56 s/image mean** (median 7.61,
33% of images 13-25 s). Module 5 sizes on the mean, not the median. The code had
assumed 0.120 s — an ~88× gap. A GPU saves 0.2% of pipeline time and is *slower* for
Grad-CAM, so **a PHC edge node does not need a GPU**. Minimum viable district =
**6 cameras/technicians, 1 uplink, 1 compute node, 1 ophthalmologist**;
**acquisition is the binding constraint**, not specialist review — confirmed by
two independent methods.

**Assumption-dependent:** every throughput figure rests on a **30 s clinician
review time, which is a design target and has never been measured** — no
clinician has been timed. Treat staffing numbers accordingly.

**Per-site calibration is a deployment requirement.** Sensitivity is not one
number: 90.3% is APTOS-internal, and the same frozen threshold measured **31.2%**
on Messidor-2 uncalibrated. Calibration is fitted, saved and loaded
automatically, and on the one site measured end to end (IDRiD, fit on TRAIN
n=413, evaluated on held-back TEST n=103) it moves sensitivity **75.0% → 82.8%**
and specificity **97.4% → 76.9%**.

**It does not reach the >90% target out of sample** — 90.3% on the images it was
fitted to became 82.8% on images the fit never saw. Calibration buys sensitivity
by spending specificity, which raises specialist load from ~11 to ~65 min/day, so
the honest benefit of AI triage is **~3×**, not the ~6× an idealised classifier
implies. Details and the full protocol:
[docs/site_calibration.md](docs/site_calibration.md).

### Phase 6 — Integration, Validation & Benchmarking ✅ *results in [docs/phase6_results.md](docs/phase6_results.md)*
- [x] Wire all 5 modules into a single MATLAB pipeline — `src/runDrishtiSystem.m`
      (Modules 1–4 per image; the measured service time feeds Module 5's district model).
      Refuses to run on Messidor-2 in code, so the holdout cannot be spent twice by accident.
- [x] Full pipeline run on held-out Messidor-2 — **already spent in Phase 3**
      (2026-09-12, 1,748 images, thresholds frozen beforehand). **Not re-run**: rule 1
      allows exactly one read, and it has happened. Sens **31.2%** / Spec 99.5% / AUC 0.8848.
- [x] Compare integrated vs single-technique — **it is a regression, not an improvement**.
      Module 1 gate + grader vs grader alone (APTOS, n=733): sensitivity **+0.67 pp**,
      specificity **−9.20 pp**, AUC 0.9891 → 0.9010. The gate rejects images the grader
      handles *better* than average (3.45% vs 6.67% error). Its justification is clinical,
      not statistical.
- [x] Document failure cases — the miss is **concentrated at grade 2**: 84.4% of moderate
      NPDR missed (median score 0.042 vs threshold 0.403), while grades 3–4 are caught
      (~17% missed, median 0.83/0.93). All 8 DME-only referable cases missed.

> **The README's central claim — integrated beats single-technique — has now been tested
> three ways and does not hold** (hybrid §3d, multi-domain §3c, quality gate §4). What
> integration actually buys is explainability, a recapture path and deployability.

### Phase 7 — Demo, Docs & Pitch
- [x] Package a working prototype demo — **`demo/run_demo.m`**, one command:
      sample images → HTML reports → district sizing. Prints measured performance
      *with its caveats* so the honest version is the default version.
- [x] Finalize Simulink dashboard visuals — 4 figures in `docs/figures/`,
      generated from measured results by `make_dashboard_figures()`.
      (`run_district_scenario_analysis(true)` now actually produces them — the
      `savePlots` flag was previously accepted, documented and never used.)
- [x] Prepare pitch deck — slide-by-slide content in
      **[docs/pitch_deck.md](docs/pitch_deck.md)**, every figure traceable to a
      results document. Needs building into slides by R5.
- [ ] Record demo video (if required for submission) — script-ready; `run_demo`
      is the recordable artefact
- [~] Final README, architecture diagram, and code cleanup — architecture diagram
      done (pitch deck slide 2); README accurate; cleanup pending

---

## 6. Success Metrics Checklist

*Status against what has actually been measured. Where a target is met only under
a condition, the condition is stated — an unqualified tick here would misrepresent
the system.*

- [ ] Sensitivity **> 90%** for referable DR (Level 2+) — **met in-domain only.**
      90.3% on APTOS (in-domain). On the held-out Messidor-2 the same frozen
      threshold gave **31.2%**. Per-site calibration recovers part of that gap —
      **82.8%** on a held-back split at the one site measured end to end — but
      **no operating point currently reaches 90% out of sample.**
- [ ] Specificity **> 85%** for referable DR — **traded against the above.**
      95.9% in-domain and 99.5% uncalibrated on Messidor-2, but the calibrated
      operating point that lifts sensitivity to 82.8% drops specificity to
      **76.9%**. Neither target is met at the same operating point.
- [ ] Grad-CAM explanations qualitatively validated as clinically meaningful —
      **not validated.** Lesion enrichment 1.51× is above chance but weak, and no
      ophthalmologist has rated the heatmaps. Protocol ready
      ([docs/gradcam_review_protocol.md](docs/gradcam_review_protocol.md)).
- [ ] Sub-30-second reviewable report format — **not demonstrated.** No clinician
      has been timed. `usabilityPass` measured a **~38 s read-time floor** for the
      report's critical path (126 words at 200 wpm) — that is a floor on *reading*
      alone, excluding the image and any judgement, and it is already **above** the
      30 s target. The 21.6 s figure quoted elsewhere is a different quantity (an
      assumed *decision* time averaged over a mostly grade-0 cohort), not a
      measurement — see [docs/phase5_results.md](docs/phase5_results.md) §6.
- [x] Simulink model producing actionable staffing/infrastructure recommendations
      for 100,000+ patients/year — [docs/phase5_results.md](docs/phase5_results.md).
      Figures are assumption-dependent (see §6 there).
- [ ] Integrated pipeline demonstrably outperforms a single end-to-end baseline —
      **tested three ways, does not hold.** Quality gate + grader is a *regression*
      (−9.2 pp specificity); hybrid lesion features and multi-domain training also
      failed to beat the baseline. See [docs/phase6_results.md](docs/phase6_results.md) §4.
- [x] **The claims in this repository are machine-checked** — `python tools/check_all.py`
      verifies that no banned or superseded figure appears anywhere, that every
      metric carries its evaluation protocol, that the six pre-registered contracts
      still hash to their recorded values, and that every entry point still guards
      the spent benchmark. Three of the six checks are tests *of* the other three,
      because a verifier that has quietly stopped comparing anything reports
      success forever. **Scope, stated honestly:** this proves the repository says
      only what it measured and that the bars were frozen before the measurements —
      it does **not** re-derive any number. Re-measuring is still a human's job.

---

## 7. Repository Structure

*Actual structure as of Phase 0. See [docs/environment_setup.md](docs/environment_setup.md) to get set up.*

```
DRishti_AI/
├── README.md
├── startup.m                     # auto-runs setup_drishti when MATLAB opens here
├── setup_drishti.m               # adds paths, resolves data root, checks toolboxes
├── config/
│   ├── drishti_paths.m           # THE path contract - every dataset path lives here
│   ├── check_environment.m       # toolbox + licence + GPU + dataset readiness
│   ├── dataset_layout.json       # shared layout contract (MATLAB + Python read this)
│   ├── clinical_definitions.json # THE referable-DR endpoint - frozen, R3-owned
│   ├── frozen_artifacts.json     # the pre-registration manifest: what was frozen, when
│   ├── claim_rules.json          # banned + superseded numbers, machine-checkable
│   ├── local_paths.example.json  # copy -> local_paths.json, set your data root
│   └── local_paths.json          # git-ignored, per-machine
├── tools/                        # Python, runs without MATLAB - anyone can run these
│   ├── check_all.py              # ALL of the below, one verdict. Run before committing.
│   ├── verify_setup.py           # "is this machine ready?" - CI-safe, exits non-zero
│   ├── verify_freeze.py          # has any pre-registered contract moved since freezing?
│   ├── check_claims.py           # does the repo state only what was measured?
│   ├── test_check_claims.py      # ...and would that checker still catch a banned claim
│   ├── test_verify_freeze.py     # ...and would the freeze check still detect tampering
│   ├── test_holdout_guard.py     # does every entry point still guard the spent benchmark
│   ├── idrid_dme_crosstab.py     # the measured cost of excluding DME
│   └── organize_datasets.py      # move/extract/verify raw downloads -> canonical layout
├── tests/                        # MATLAB suite - 57 cases, needs MATLAB
│   └── test_project_setup.m      # Phase 0 smoke tests (runtests)
├── data/                         # junction/symlink to the data root - GIT-IGNORED
│   ├── aptos2019/  idrid/  drive/  messidor2/
├── src/
│   ├── quality_enhancement/      # Module 1
│   ├── segmentation/             # Module 2
│   │   ├── optic_disc_fovea/  vessels/  microaneurysms/
│   │   ├── exudates_hemorrhages/  neovascularization/
│   ├── grading/                  # Module 3
│   ├── explainability/           # Module 4
│   ├── app/                      # MATLAB dashboard + plain-language layer
│   └── utils/
├── simulink/                     # Module 5
├── webapp/                       # browser dashboard (server.py + index.html)
├── models/                       # trained weights - git-ignored
├── reports/                      # generated reports - git-ignored
├── results/                      # metrics, ROC curves - git-ignored
└── docs/                         # full index in docs/repository_map.md
    ├── architecture.md           # how it fits together, and why
    ├── workflow.md               # every command, and what not to run
    ├── repository_map.md         # what lives where; what must never be deleted
    ├── troubleshooting.md        # traps that cost real time
    ├── phase1..phase6 results    # measured outcomes, one per phase
    ├── clinical_definitions.md   # referable-DR endpoint, the DME call
    ├── literature_benchmarks.md  # sourced targets; what is NOT comparable
    ├── datasets.md               # inventory, distributions, split strategy, gaps
    ├── environment_setup.md      # this machine -> ready
    └── dataset_manifest.json     # generated by tools/organize_datasets.py
```

---

## 8. Tools & Toolboxes

- Image Processing Toolbox
- Computer Vision Toolbox
- Deep Learning Toolbox
- Medical Imaging Toolbox
- Simulink
- Statistics and Machine Learning Toolbox

---

## 9. Key Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Small/imbalanced lesion-level datasets (esp. IDRiD) → overfitting | Heavy augmentation, cross-dataset validation, class-weighted loss |
| Grad-CAM highlighting "correct" region for the "wrong" reason | Cross-check heatmaps against Module 2's independently-detected lesions, not just visual plausibility |
| Field image quality far worse than curated datasets | Explicitly test with synthetic degradation (blur, low light, glare) beyond just what's in the public datasets |
| Simulink model assumptions being unrealistic | Base bandwidth/staffing parameters on published rural telemedicine deployment studies, cite sources in docs |
| Time pressure to hit hackathon deadline vs. clinical rigor | Prioritize Phases 1–3 (core pipeline) first; treat Simulink and polished reporting as Phase 5+ stretch once core metrics are validated |

---

## 10. References for Clinical/Technical Grounding

- International Clinical Diabetic Retinopathy (ICDR) Disease Severity Scale
- IDRiD Challenge papers (lesion segmentation & grading benchmarks)
- APTOS 2019 Kaggle competition leaderboard/writeups (grading benchmarks)
- Messidor-2 grading benchmark papers
- DRIVE dataset vessel segmentation benchmark papers
