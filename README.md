# Explainable AI for Diabetic Retinopathy Screening in Rural India

**Smart India Hackathon — Software Track**
**Organization:** MathWorks | **Department:** MathWorks | **Theme:** MedTech / BioTech / HealthTech

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

---

## 5. Project Roadmap

### Phase 0 — Setup & Literature Grounding
- [ ] Finalize team roles (ML/CV, MATLAB/Simulink, clinical research, UI/reporting, presentation)
- [ ] Set up MATLAB environment, toolbox licenses, GitHub repo structure
- [ ] Download & organize APTOS, IDRiD, DRIVE, Messidor-2 datasets
- [ ] Literature review: benchmark sensitivity/specificity numbers from published DR-grading papers (to define "outperform baseline" target concretely)

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

## 7. Suggested Repository Structure

```
dr-screening-pipeline/
├── README.md
├── data/
│   ├── aptos2019/
│   ├── idrid/
│   ├── drive/
│   └── messidor2/
├── src/
│   ├── quality_enhancement/
│   ├── segmentation/
│   │   ├── optic_disc_fovea/
│   │   ├── vessels/
│   │   ├── microaneurysms/
│   │   ├── exudates_hemorrhages/
│   │   └── neovascularization/
│   ├── grading/
│   ├── explainability/
│   └── utils/
├── simulink/
│   └── screening_throughput_model.slx
├── models/            # trained weights/checkpoints
├── reports/           # sample auto-generated reports
├── results/           # benchmark outputs, confusion matrices, ROC curves
└── docs/
    ├── architecture_diagram.png
    └── validation_report.md
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
