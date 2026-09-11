# Explainable AI for Diabetic Retinopathy Screening in Rural India

**Smart India Hackathon — Software Track**
**Organization:** MathWorks | **Department:** MathWorks | **Theme:** MedTech / BioTech / HealthTech

> **New here?** Start with **[docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md)** — what's
> done, what's blocked, and what to pick up. Then run `python tools/verify_setup.py`.
> Setup instructions: [docs/environment_setup.md](docs/environment_setup.md).
>

---

## 1. Problem Context

### 1.1 The Public Health Gap
- India has **77M+ diabetic adults** — the second-highest burden globally.
- **~18%** of diabetics develop Diabetic Retinopathy (DR), a leading cause of *preventable* blindness.
- Early screening prevents **~90%** of DR-related vision loss — but India has only **~1 ophthalmologist per 100,000 rural population**.
- Manual, in-person mass screening is logistically and economically infeasible at national scale.

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
- **Sensitivity > 90%** and **Specificity > 85%** for referable DR (ICDR Level 2+)
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
- **Clinical operating point:** threshold tuned so Sensitivity > 90%, Specificity > 85% for the binary "referable vs. not" decision, reported via ROC/AUC and a confusion matrix per class.
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
- [x] Define team roles and phase ownership → [docs/team_roles.md](docs/team_roles.md)
      — **names still need assigning**
- [x] Repo structure, `.gitignore`, path config, environment checker, smoke tests
      → [docs/environment_setup.md](docs/environment_setup.md)
- [ ] Install MATLAB + toolboxes — step-by-step guide ready at
      [docs/matlab_install.md](docs/matlab_install.md). **Must be R2026a+**: the dev
      machine's RTX 5050 is compute capability 12.0, unsupported before R2026a.
      `setup_drishti` / `check_environment` are written but unexecuted until then.
- [x] Organize & verify APTOS, IDRiD, DRIVE, Messidor-2 → [docs/datasets.md](docs/datasets.md)
      (`python tools/verify_setup.py` → READY)
- [ ] **Download Messidor-2 grade labels** — our copy has no labels; blocks *all* of
      Phase 6 ([why & where](docs/datasets.md))
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

### Phase 1 — Image Quality & Enhancement Pipeline
- [ ] Implement focus/illumination/FOV scoring functions
- [ ] Build CLAHE + illumination normalization + denoising pipeline
- [ ] Define reject/recapture logic and test on deliberately degraded images
- [ ] Unit-test against a mixed-quality subset (good, borderline, bad)

### Phase 2 — Segmentation Modules
- [ ] Optic disc & fovea localization (validate against IDRiD annotations)
- [ ] Vessel segmentation (train/evaluate on DRIVE — target Dice/AUC benchmarks)
- [ ] Microaneurysm detection pipeline (validate against IDRiD MA masks)
- [ ] Exudate segmentation + hemorrhage classification
- [ ] Neovascularization heuristic detector
- [ ] Consolidate all lesion outputs into a single structured feature vector per image

### Phase 3 — DR Severity Grading Model
- [ ] Build baseline end-to-end CNN classifier (for later "single technique" comparison)
- [ ] Build hybrid lesion-feature + classifier model
- [ ] Train/tune on APTOS + IDRiD; calibrate operating threshold for referable DR
- [ ] Evaluate: sensitivity, specificity, AUC, per-class confusion matrix
- [ ] Cross-validate against Messidor-2 (held-out benchmark)

### Phase 4 — Explainability & Reporting
- [ ] Implement Grad-CAM/Grad-CAM++ on the trained grading network
- [ ] Correlate Grad-CAM activation regions with Module 2 lesion locations
- [ ] Confidence calibration (Platt/isotonic)
- [ ] Auto-generate the one-page annotated report (design for sub-30-second review)
- [ ] Informal usability pass — simulate an ophthalmologist review workflow, time it

### Phase 5 — Simulink Throughput Simulation
- [ ] Model acquisition → upload → AI processing → review as a discrete-event/queuing system in Simulink
- [ ] Parameterize with realistic rural bandwidth and staffing assumptions
- [ ] Run scenario analysis for 100,000+ patients/year district target
- [ ] Output: recommended camera/technician/compute/ophthalmologist ratios and bottleneck report

### Phase 6 — Integration, Validation & Benchmarking
- [ ] Wire all 5 modules into a single MATLAB pipeline/app (App Designer front-end optional)
- [ ] Full pipeline run on held-out Messidor-2 set
- [ ] Compare integrated pipeline vs. single-technique baseline (Phase 3 baseline CNN) — quantify improvement
- [ ] Document failure cases (poor-quality images, ambiguous grades) for transparency

### Phase 7 — Demo, Docs & Pitch
- [ ] Package a working prototype demo (sample images → report output, live or recorded)
- [ ] Finalize Simulink dashboard visuals
- [ ] Prepare pitch deck: problem → architecture → validation metrics → deployment impact
- [ ] Record demo video (if required for submission)
- [ ] Final README, architecture diagram, and code cleanup

---

## 6. Success Metrics Checklist

- [ ] Sensitivity **> 90%** for referable DR (Level 2+)
- [ ] Specificity **> 85%** for referable DR
- [ ] Grad-CAM explanations qualitatively validated as clinically meaningful
- [ ] Sub-30-second reviewable report format
- [ ] Simulink model producing actionable staffing/infrastructure recommendations for 100,000+ patients/year
- [ ] Integrated pipeline demonstrably outperforms a single end-to-end baseline model on held-out benchmark data

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
│   ├── local_paths.example.json  # copy -> local_paths.json, set your data root
│   └── local_paths.json          # git-ignored, per-machine
├── tools/                        # Python, runs without MATLAB
│   ├── organize_datasets.py      # move/extract/verify raw downloads -> canonical layout
│   └── verify_setup.py           # "is this machine ready?" - CI-safe, exits non-zero
├── tests/
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
│   └── utils/
├── simulink/                     # Module 5
├── models/                       # trained weights - git-ignored
├── reports/                      # generated reports - git-ignored
├── results/                      # metrics, ROC curves - git-ignored
└── docs/
    ├── datasets.md               # inventory, distributions, split strategy, gaps
    ├── literature_benchmarks.md  # sourced targets we must beat
    ├── team_roles.md             # roles, phase ownership, working agreements
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
