# Literature Review & Benchmark Targets

**Phase 0 deliverable.** Compiled 2026-09-11.

Purpose: replace the README's qualitative goal of *"outperform single-technique
baselines"* with **concrete, sourced numbers** we must beat, and fix the operating
point we will tune to in Phase 3.

Every number below was read out of the primary source (linked). Where a figure is
widely repeated but we could not verify it against the source, it is marked
**[unverified]** rather than quoted as fact.

---

## 1. The bar that matters: referable DR (ICDR ≥ 2)

"Referable DR" (RDR) in the literature almost always means **moderate NPDR or
worse, *or* referable diabetic macular oedema**. Note the DME clause — several
published sensitivity figures include DME-only referrals, which our
grade-only pipeline does not currently detect. See §6.

### 1.1 Regulatory floor — IDx-DR (FDA De Novo, 2018)

The first autonomous AI diagnostic cleared by the FDA in any field of medicine.
Pivotal trial, 900 patients, 10 primary-care sites, against Wisconsin Fundus
Photograph Reading Center grading of widefield stereo photography + macular OCT.

| Endpoint | Pre-specified goal | Achieved |
|---|---|---|
| Sensitivity (mtmDR) | > 85% | **87.2%** |
| Specificity (mtmDR) | > 82.5% | **90.7%** |
| Imageability rate | — | **96.1%** |

> Source: Abràmoff et al., *npj Digital Medicine* 1:39 (2018) —
> [nature.com/articles/s41746-018-0040-6](https://www.nature.com/articles/s41746-018-0040-6)

**Why this matters to us:** the README's target of Sens > 90% / Spec > 85% sits
*above* the FDA-cleared operating point on both axes. That is a defensible,
non-arbitrary claim to make in the pitch — say it that way, not as a round number
we picked.

### 1.2 Research ceiling — Gulshan et al. (Google), JAMA 2016

The single most-cited DR screening result, and the reason our Messidor-2 holdout
is the right external benchmark: **this paper validated on exactly the 1748-image
Messidor-2 set we hold** (874 patients; 1745 fully gradable; RDR prevalence
254/1745 = 14.6%).

| Set | AUC | High-specificity OP | High-sensitivity OP |
|---|---|---|---|
| EyePACS-1 (9963 img) | 0.991 (0.988–0.993) | Sens **90.3%** / Spec **98.1%** | Sens **97.5%** / Spec **93.4%** |
| **Messidor-2 (1748 img)** | 0.990 (0.986–0.995) | Sens **87.0%** / Spec **98.5%** | Sens **96.1%** / Spec **93.9%** |

Reference standard: majority decision of a panel of **≥ 7 US board-certified
ophthalmologists**.

> Source: Gulshan et al., *JAMA* 316(22):2402–2410 (2016) —
> [PDF](https://static.googleusercontent.com/media/research.google.com/en//pubs/archive/45732.pdf)

### 1.3 The quality-gate result nobody quotes — and we should

The same paper ran a second task: **RDR *or* ungradable image** as the positive
class, i.e. "does this patient need a human?". On EyePACS-1:

- AUC **0.974**
- High-specificity OP: Sens **90.7%** / Spec **93.8%**
- High-sensitivity OP: Sens **96.7%** / Spec **84.0%**

Performance drops materially (0.991 → 0.974 AUC) the moment image quality enters
the decision. **This is the empirical case for Module 1.** It is also the number
our integrated pipeline should be compared against, because our Module 1 gate
makes us a "referral-or-recapture" system, not a pure classifier.

---

## 2. Per-dataset benchmark targets

### 2.1 Messidor-2 — external validation (Phase 6)

| Method | Sens | Spec | AUC |
|---|---|---|---|
| Gulshan 2016 (high-spec OP) | 87.0% | 98.5% | 0.990 |
| Gulshan 2016 (high-sens OP) | 96.1% | 93.9% | 0.990 |
| **DRishti-AI target** | **> 90%** | **> 85%** | report AUC + CI |

> ⚠️ **Blocker:** our Messidor-2 copy has images + left/right pairing only, **no
> grade labels**. The adjudicated reference standard (3 fellowship-trained retina
> specialists, consensus-adjudicated) was publicly released by Krause et al. and
> must be downloaded separately before any of this is measurable:
> [kaggle.com/datasets/google-brain/messidor2-dr-grades](https://www.kaggle.com/datasets/google-brain/messidor2-dr-grades)
> See [datasets.md](datasets.md) §4.

### 2.2 IDRiD — lesion segmentation (Phase 2)

Official challenge leaderboard, ranked by **AUPR** (area under the
precision–recall curve), computed on the 27-image test set. AUPR is used rather
than ROC-AUC because lesion pixels are a tiny minority — an important detail to
reproduce, or our numbers will not be comparable.

| Lesion | Best team | **AUPR** | Approach |
|---|---|---|---|
| Microaneurysms | iFLYTEK-MIG | **0.5017** | Cascaded CNN (ensemble, 320×320) |
| Haemorrhages | VRT | **0.6804** | U-Net (640×640) |
| Soft exudates | VRT | **0.6995** | U-Net (640×640) |
| Hard exudates | PATech | **0.8850** | DenseNet + U-Net (ensemble, 256×256) |

> Source: Porwal et al., *Medical Image Analysis* 59:101561 (2019), Table 8 —
> [par.nsf.gov/servlets/purl/10189648](https://par.nsf.gov/servlets/purl/10189648)

**Read this honestly:** the best microaneurysm AUPR in the world is **0.50**. MA
detection is *hard*. Any Phase 2 result we report near 0.9 for MAs means we have
a bug or a leak, not a breakthrough. Hard exudates at 0.885 is the only lesion
where high numbers are plausible.

### 2.3 IDRiD — disease grading (Phase 3)

| Team | Joint DR+DME accuracy | Approach |
|---|---|---|
| LzyUNCC | **0.6311** | ResNet + DLA, 5-model ensemble, 896×896, +Kaggle |
| VRT | 0.5534 | CNN, 10-model ensemble, 640×640, +Kaggle/Messidor |
| Mammoth | 0.5146 | DenseNet ensemble, 512×512, +Kaggle |

> Source: Porwal et al. 2019, Table 9.

Note this is *joint* DR **and** DME accuracy — both must be right — and the
challenge report explicitly attributes the low scores to teams performing poorly
on DR grading and to "difficulty in accurately discriminating the DR severity
grades" on a hard test set. **Do not compare our 5-class DR-only accuracy against
0.6311.** It is not the same metric.

Also note: every top team used **external data** (Kaggle EyePACS) and **large
input sizes** (512–896 px). Both are signals for our Phase 3 design.

### 2.4 IDRiD — optic disc / fovea localization (Phase 2)

| Task | Best team | Euclidean distance (px) | Approach |
|---|---|---|---|
| Optic disc centre | DeepDR | **21.072** | ResNet + VGG |
| | VRT | 33.538 | U-Net (+DRIVE) |

> Source: Porwal et al. 2019, Table 10. Images are 4288×2848, so 21 px is ≈ 0.5%
> of image width — a tight target.

### 2.5 DRIVE — vessel segmentation (Phase 2)

| Method | AUC | Dice |
|---|---|---|
| Little W-Net (Galdran et al.) | **98.10** | **82.79** |
| Little U-Net | 97.98 | 82.41 |
| Wu et al. 2018 | 98.07 | — |
| Shin et al. 2019 | 98.01 | 82.63 |
| Liskowski et al. 2016 | 97.90 | — |

> Source: Galdran et al., *Scientific Reports* 12:6174 (2022) —
> [PMC9007957](https://pmc.ncbi.nlm.nih.gov/articles/PMC9007957/)

**Critical methodological warning from that paper** — published DRIVE numbers are
frequently *not comparable*, because papers differ in:

1. **FOV mask handling** — including the trivially-black pixels outside the
   circular field of view inflates accuracy and AUC.
2. **Thresholding** — per-image optimal thresholds vs. one global threshold.
3. **Train/test splits** — not everyone uses the official 20/20 split.
4. **Metric choice** — the authors explicitly refuse to report *accuracy*
   ("this is a highly imbalanced problem; the Dice score is a more suitable
   figure of merit") and advise against sensitivity/specificity at a single cut-off.

A companion paper found these inconsistencies affect **100+ published papers**
([Med. Image Anal. 2021](https://www.sciencedirect.com/science/article/abs/pii/S1361841521003455)).

**Our rule for Phase 2:** report **Dice + AUC, FOV-masked, single global
threshold, official split**. State the protocol in the results table. Ignore any
paper claiming >99% Dice on DRIVE — that is an evaluation artifact.

### 2.6 APTOS 2019 — grading (Phase 3 training set)

- Competition metric: **quadratic weighted kappa (QWK)**, not accuracy.
- Winning private-LB score: **QWK 0.936**.
- The winning recipe: external data (88,702 images from the 2015 EyePACS Kaggle
  competition), heavy augmentation, L1 loss, generalized-mean pooling, multi-scale
  ensemble.

> Source: as documented in [arXiv:2301.04644](https://arxiv.org/pdf/2301.04644)

**Caveat for us:** the APTOS *test* labels were never publicly released — our
`test_images/` (1928 images) has no ground truth. All APTOS evaluation must come
from a split of the 3662 labelled training images. See [datasets.md](datasets.md).

---

## 3. Baseline definition (what "outperform a single technique" means)

The README requires beating a single-technique baseline. Phase 3 must produce
**two** models evaluated under an identical protocol:

| | Baseline | Integrated pipeline |
|---|---|---|
| Input | Raw image, resized | Module 1 gated + enhanced |
| Features | End-to-end CNN only | Module 2 lesion features + CNN |
| Quality gate | none | reject/recapture |
| Calibration | raw softmax | Platt / isotonic |

Report on the **same held-out Messidor-2 set**, same operating-point selection
procedure, with confidence intervals. Improvement must be stated as a delta with
a CI, not two bare numbers.

---

## 4. Epidemiology — corrections to our own README

Checking the README's §1.1 claims against primary sources turned up two that
should be updated before the pitch:

| README says | Sourced figure | Note |
|---|---|---|
| "77M+ diabetic adults" | **~101 million** | ICMR-INDIAB-17 found 11.4% diabetes prevalence; 77M is the older IDF estimate. Use the newer, larger number — it strengthens the case. |
| "~18% of diabetics develop DR" | **12.5%** (95% CI 11.0–14.2) | SMART India, a population-based screening study — [Lancet Global Health (2022)](https://www.thelancet.com/journals/langlo/article/PIIS2214-109X(22)00411-9/fulltext). ~3 million people aged 40+ have vision-threatening DR. |
| "1 ophthalmologist per 100,000 rural" | **[unverified]** | Could not confirm against a primary source. Either find a citation or drop the precise ratio. |
| "early screening prevents ~90% of vision loss" | **[unverified]** | Widely repeated; trace to a source before putting it on a slide. |

A further finding worth putting *in* the pitch: SMART India found **no
significant urban–rural difference** in DR prevalence. The rural problem is
therefore one of *access to screening*, not of lower disease burden — which is
precisely the argument for Module 5.

---

## 5. Team-supplied reference: `Research Paper.pdf`

*"Enhancing Diabetic Retinopathy Detection Using Optimized Deep Learning
Techniques with ResNet"*, Gangopadhyay, Patra & Deepajothi, **IJCSE** 13(4):59–67,
April 2025. DOI 10.26438/ijcse/v13i4.5967.

Reported: 94.3% classification accuracy, 93.5% validation precision, 92.7% average
precision, 91.8% recall, 92.2% F1, AUC 0.98, on the Kaggle EyePACS dataset.

**Assessment — do not cite this as a benchmark.** Reasons:

1. **No sensitivity/specificity for referable DR** — accuracy on an imbalanced
   5-class problem is not a screening metric.
2. **No external validation set** and no confidence intervals.
3. The prose shows clear signs of automated paraphrasing ("we gift a deep learning
   approach", "photo reputation obligations", recall rendered as *"average
   memory"* and *"don't forget"*), which is a reliability red flag independent of
   the results themselves.

It is fine as background reading on ResNet transfer learning for DR. It is not a
number we should claim to beat, and quoting 94.3% next to Gulshan's audited
figures would weaken our submission, not strengthen it.

---

## 6. Open questions carried into Phase 1+

1. **DME.** Every RDR benchmark above includes referable macular oedema in the
   positive class. Our Modules 2–3 grade DR only. Either (a) add DME risk
   grading — IDRiD part B ships a "Risk of macular edema" column we already
   have — or (b) state explicitly that our sensitivity is for DR-only referral and
   is therefore *not* directly comparable to Gulshan/IDx-DR. Decide before Phase 3.
2. **Operating point selection.** Gulshan reports two. We should too: a
   high-sensitivity screening point and a high-specificity point, with the
   threshold chosen on a validation split and *frozen* before touching Messidor-2.
3. **Grader ceiling.** Gulshan's reference standard came from ≥7 ophthalmologists
   precisely because single-grader labels are noisy. APTOS/IDRiD labels are not
   adjudicated to that standard — our achievable ceiling on those sets is lower
   than on Messidor-2, and we should say so rather than look like we underperformed.

---

## Source list

- Abràmoff et al. (2018), *npj Digital Medicine* — [nature.com/articles/s41746-018-0040-6](https://www.nature.com/articles/s41746-018-0040-6)
- Gulshan et al. (2016), *JAMA* — [PDF](https://static.googleusercontent.com/media/research.google.com/en//pubs/archive/45732.pdf)
- Porwal et al. (2019), *Medical Image Analysis* (IDRiD challenge) — [par.nsf.gov/servlets/purl/10189648](https://par.nsf.gov/servlets/purl/10189648)
- Galdran et al. (2022), *Scientific Reports* (DRIVE) — [PMC9007957](https://pmc.ncbi.nlm.nih.gov/articles/PMC9007957/)
- Med. Image Anal. (2021), DRIVE evaluation inconsistencies — [ScienceDirect](https://www.sciencedirect.com/science/article/abs/pii/S1361841521003455)
- SMART India (2022), *Lancet Global Health* — [thelancet.com](https://www.thelancet.com/journals/langlo/article/PIIS2214-109X(22)00411-9/fulltext)
- Krause et al., Messidor-2 adjudicated grades — [Kaggle](https://www.kaggle.com/datasets/google-brain/messidor2-dr-grades)
- APTOS 2019 winning score, as documented in [arXiv:2301.04644](https://arxiv.org/pdf/2301.04644)
- IDRiD challenge portal — [idrid.grand-challenge.org](https://idrid.grand-challenge.org/)
