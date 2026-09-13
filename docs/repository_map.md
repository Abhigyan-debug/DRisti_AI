# Repository map

What lives where, what is generated, and what must never be deleted.

---

## Top level

```
DRishti_AI/
├── setup_drishti.m          paths + toolbox check; startup.m auto-runs it
├── startup.m                MATLAB session bootstrap
├── DRisti_AI.prj            MATLAB Project file
├── resources/project/       MATLAB Project metadata — generated, do not hand-edit
├── config/                  contracts: every decision code reads from
├── src/                     all MATLAB source
├── simulink/                Module 5 model + parameters
├── webapp/                  browser dashboard (the one Python that needs MATLAB)
├── tools/                   Python support — must run WITHOUT MATLAB
├── tests/                   the suite; keep green
├── demo/                    run_demo.m
├── docs/                    everything explaining the above
├── data/ -> D:\...          junction to datasets, OUTSIDE the repo (~12.8 GB)
├── models/                  trained weights — gitignored
├── results/                 measurement outputs — gitignored
└── reports/                 generated reports — gitignored
```

---

## `src/` — by module

| Path | Module | Notes |
|---|---|---|
| `src/quality_enhancement/` | 1 | `processImage` is the entry; focus is judged once, on the original |
| `src/segmentation/` | 2 | `extractLesionFeatures` assembles the contract |
| `src/segmentation/optic_disc_fovea/` | 2a·2b | disc drives every disc-diameter measurement |
| `src/segmentation/vessels/` | 2c | DRIVE test GT withheld — see B2 |
| `src/segmentation/exudates_hemorrhages/` | 2d | the only validated lesion channel |
| `src/segmentation/microaneurysms/` | 2e·2f | dark lesions + stage-2 classifiers |
| `src/segmentation/neovascularization/` | 2g | heuristic; no ground truth exists |
| `src/grading/` | 3 | training, calibration, external validation |
| `src/explainability/` | 4 | Grad-CAM, evidence table, clinical report |
| `src/app/` | — | both dashboards + the plain-language layer |
| `src/utils/` | — | shared helpers incl. `assertNotHoldout` |
| `src/runDrishtiPipeline.m` | 1–4 | one image, all modules |
| `src/runDrishtiSystem.m` | 1–5 | cohort + district capacity |

### Files that own an honesty rule

| File | Rule |
|---|---|
| `src/utils/assertNotHoldout.m` | refuses Messidor-2 at every entry point |
| `src/segmentation/loadLesionReliability.m` | display gating; **fails closed** |
| `src/segmentation/validateLesionDetectors.m` | measures against the frozen bar |
| `src/app/plainLanguageReport.m` | translation without promoting hedges into claims |
| `src/explainability/buildReportData.m` | withheld channels render as "not validated", never 0 |
| `src/grading/evaluateMessidor2.m` | refuses while the saved result exists — the shot is spent |
| `src/grading/buildSiteCalibration.m` | checks fit/eval disjointness, never assumes it |
| `tools/check_claims.py` | no banned or superseded figure, anywhere |
| `tools/verify_freeze.py` | the pre-registration chain still hashes as recorded |
| `tools/test_holdout_guard.py` | every entry point still guards the spent benchmark |

---

## `config/` — contracts

| File | Owns | Committed |
|---|---|---|
| `drishti_paths.m` | every dataset path | ✅ |
| `dataset_layout.json` | layout, shared by Python + MATLAB tests | ✅ |
| `quality_thresholds.json` | Module 1 cut-offs (measured) | ✅ |
| `clinical_definitions.json` | referable-DR endpoint, per-dataset DME encoding | ✅ |
| `lesion_validation_thresholds.json` | lesion reporting bar — **frozen + hashed** | ✅ |
| `exudate_split.json` | hard/soft boundary, fitted on train | ✅ |
| `lesion_features.json` | the Phase 2 output contract | ✅ |
| `telemedicine_parameters.json` | Module 5 inputs, tagged SOURCED/DERIVED/ASSUMED | ✅ |
| `aptos_split.json` | committed split indices | ✅ |
| `frozen_artifacts.json` | the pre-registration manifest — what was frozen, when, and its hash | ✅ |
| `claim_rules.json` | banned + superseded figures, machine-checkable | ✅ |
| `local_paths.json` | **per-machine**, git-ignored | ❌ |

---

## Generated — safe to delete, regenerable

| Path | Regenerate with |
|---|---|
| `slprj/`, `*.slxc` | opening/building the Simulink model |
| `tools/__pycache__/` | automatic |
| `webapp/jobs/` | automatic; the server sweeps stale files itself |
| `reports/**` | `run_demo`, the dashboards, or `runDrishtiPipeline(saveReport=true)` |
| `models/*.mat` | retraining — **hours of GPU time**, so prefer not to |

---

## ⛔ Never delete

| File | Why |
|---|---|
| `results/messidor2_external_validation.mat` | The held-out set was read **once**, 2026-09-12. It cannot be re-read. This file is the only copy of that result |
| `results/phase3_val_result.mat` | Carries the frozen operating point the whole external claim rests on |
| `results/lesion_validation.mat` | Drives lesion display gating; deleting it hides every channel (fail-closed, but you lose the measurement) |
| `config/*.json` | Contracts — several are frozen and hash-checked |

---

## Not ours to remove

`Research Paper.pdf` — team-supplied IJCSE paper. **Background reading only; never
cite it as a benchmark** (94.3% accuracy, no sensitivity/specificity, no external
validation). Reasons in [literature_benchmarks.md](literature_benchmarks.md) §5.

---

## `docs/` index

| Doc | What it answers |
|---|---|
| [architecture.md](architecture.md) | How the system fits together, and why |
| [workflow.md](workflow.md) | Every command, and what not to run |
| [troubleshooting.md](troubleshooting.md) | Traps that cost real time |
| [phase2_results.md](phase2_results.md) | Lesion detector validation |
| [phase3_results.md](phase3_results.md) | Grading + explainability results |
| [phase5_results.md](phase5_results.md) · [phase6_results.md](phase6_results.md) | Throughput model, integration |
| [clinical_definitions.md](clinical_definitions.md) | The referable-DR endpoint and the DME call |
| [literature_benchmarks.md](literature_benchmarks.md) | Sourced targets; what is *not* comparable |
| [datasets.md](datasets.md) | Measured counts, distributions, resolution profiles |
| [gradcam_review_protocol.md](gradcam_review_protocol.md) | Blinded review instrument (reviewer not yet recruited) |
| [telemedicine_parameters.md](telemedicine_parameters.md) | Module 5 parameter provenance |
| [phase1_quality_baseline.md](phase1_quality_baseline.md) · [phase1_degradation_study.md](phase1_degradation_study.md) | Module 1 |
| [environment_setup.md](environment_setup.md) | Machine setup |
| [matlab_install.md](matlab_install.md) | MATLAB install guide (R2026a requirement) |
| [pitch_deck.md](pitch_deck.md) · [speaking_script.md](speaking_script.md) | Presentation |
