# Phase 3 & 4 Results

*Measured 2026-09-12. Every number here came from a run in this repo; nothing is
estimated or carried over from literature.*

Reproduce with:
```matlab
R = evaluateGrader();                      % grading metrics
```

---

## 1. DR grading — the headline numbers

**Model:** ResNet-18, 640×640, fine-tuned on the committed APTOS split
(`config/aptos_split.json`), 2929 train / 733 validation, class-weighted loss,
early-stopped. Saved as `models/baseline_grader.mat`.

**Evaluated on:** the held-out APTOS validation split (n=733, 40.7% referable).

### Referable DR (ICDR ≥ 2)

| Operating point | Sensitivity | Specificity |
|---|---|---|
| High-sensitivity | **90.3%** | **95.9%** |
| High-specificity | 95.0% | 95.2% |
| **Project target** | > 90% | > 85% |

**ROC AUC 0.9891.** Target met on both axes at both operating points.

### 5-class ICDR

| Metric | Value | Reference |
|---|---|---|
| Quadratic weighted kappa | **0.9087** | APTOS competition winner: 0.936 |
| Accuracy | 0.804 | — |

The winner used a multi-model ensemble plus 88,702 extra images from the 2015
Kaggle competition. A single ResNet-18 within 0.03 QWK of that is a fair result.

### Caveats that must travel with these numbers

1. **This is the DR-only endpoint.** APTOS ships no DME labels, so referable
   here means `dr_grade >= 2` — the *secondary* endpoint in
   [`config/clinical_definitions.json`](../config/clinical_definitions.json).
   Gulshan and IDx-DR both include referable macular oedema, so **these figures
   are not directly comparable to theirs.** `evaluateGrader` prints this warning
   on every run.
2. **This is validation, not external validation.** Messidor-2 remains untouched.
   Thresholds are frozen in `results/phase3_val_result.mat`
   (high-sensitivity 0.4033, high-specificity 0.3080) and must not be re-tuned
   after the benchmark is read.
3. Accuracy is reported only because judges ask for it. 49.3% of APTOS is
   grade 0, so "no DR for everything" scores 49% accuracy with zero clinical
   value. Sensitivity and specificity are the meaningful numbers.

---

## 2. Explainability — an honest negative, partially fixed

Grad-CAM runs and produces overlays. **Whether those overlays explain anything
is a separate question, and we measured it.**

The README's risk table names the failure mode: *"Grad-CAM highlighting the
correct region for the wrong reason"*, with the mitigation being a cross-check
against lesions detected **independently of the classifier**. That check is
implemented in `explainGrading` and it is what produced the following.

### The metric

`enrichment = (fraction of CAM mass landing on lesions) / (lesion area fraction)`

Lesion area fraction is what a *uniform* heatmap would score, so **1.0× means no
lesion attention at all.**

### Results

| Comparison | Enrichment |
|---|---|
| 384px model vs **our Module 2 detectors** | **0.83×** (below chance) |
| 384px model vs **IDRiD expert masks** | 1.25× |
| **640px model vs IDRiD expert masks** | **1.51×** |

### What the diagnostic showed

The initial 0.83× blamed two things at once. Swapping our own detectors for
IDRiD's expert masks separated them: the number rose to 1.25× on identical
model and images. So **our weak detectors were depressing the measurement**
(exudate Dice 0.21, implausible MA counts) **and** the network's lesion
attention was genuinely poor.

The fix addressed the second: the model was seeing 384px images downsampled from
4288px, which destroys microaneurysms — a network cannot attend to lesions it
cannot resolve. Retraining at 640px raised enrichment to **1.51×**, a 21%
improvement, while grading metrics stayed flat to marginally better.

That direction matches the literature already in
[literature_benchmarks.md](literature_benchmarks.md): every IDRiD challenge
winner trained at 512–896px.

### What we can and cannot claim

**Can claim:** the corroboration check specified in our own risk analysis was
built, quantified, and acted on; lesion attention improves measurably with input
resolution.

**Cannot claim:** that the explanations are lesion-grounded. 1.51× means the
heatmap lands on lesions half again as often as chance — partial grounding, not
validated explainability. Visual inspection agrees: the CAMs are diffuse, and on
one grade-1 image the hotspot sat on the **optic disc**, which is normal anatomy.

This is a stronger position than showing a plausible heatmap and asserting it
explains the decision, which is unfalsifiable and what the risk table warned
against.

### Next steps if time allows

- Better lesion detectors would raise the measurement floor (the 0.83 → 1.25
  jump was entirely the reference change, not the model).
- Higher resolution still (896px) — the trend is monotonic so far.
- Grad-CAM++ or guided backpropagation for sharper localisation.

---

## 3. Messidor-2 external validation — THE HEADLINE DOES NOT GENERALISE

*Run once, 2026-09-12, with thresholds frozen beforehand. 1748 images, 4 ungradable,
1744 scored. Reference standard: Krause et al. adjudicated (3 retina specialists).*

### The result, at the frozen operating point

| | APTOS validation | **Messidor-2 external** |
|---|---|---|
| Sensitivity | 90.3% | **31.2%** [27.1–35.5] |
| Specificity | 95.9% | **99.5%** [99.0–99.8] |
| AUC | 0.9891 | **0.8848** |
| Referable prevalence | 40.7% | 26.7% |

**This is the valid, reportable external-validation result.** The threshold was frozen
before the set was read and was not adjusted afterwards. Sensitivity of 31% means the
system as configured would miss roughly two thirds of referable patients on this
population.

All three endpoints agree (primary 31.2%, DR-only 31.7%, referral-or-recapture 31.8%),
so this is not an artifact of the DME encoding.

### Why it failed — two distinct causes

**1. Severe calibration / domain shift.** The score distribution collapses:

| | Median referable score | Median non-referable |
|---|---|---|
| Messidor-2 | **0.0992** | 0.0033 |
| Frozen threshold | **0.4033** | — |

The frozen threshold sits roughly **4× above the median referable case**. Only 31.2%
of genuinely referable images score above it. APTOS (Indian, 2019, modern cameras)
and Messidor-2 (French, 2000s-era cameras) are different visual domains, and the raw
softmax output is not comparable across them.

**2. Genuine loss of discriminative power.** AUC falls 0.9891 → 0.8848. That is not
only calibration — the model separates the classes less well on unseen equipment.

**Post-hoc diagnostic — NOT a reportable operating point.** Had the threshold been
chosen *on* Messidor-2 (0.0049), the same model would give Sens 90.1% / Spec 62.7%.
Quoting that as a result would be tuning on the test set, which is precisely what this
exercise was designed to avoid. It is recorded only because it separates the two
causes: ranking largely survives, the operating point does not transfer, and even
optimally placed the specificity would be far below the 95.9% seen internally.

### What this means

- **Do not claim 90.3% / 95.9% generalises.** It does not. That figure is internal
  validation on a single Indian dataset.
- **Confidence calibration is not a nice-to-have.** Platt/isotonic scaling — still
  unimplemented, and listed on the deck as a feature — is the direct fix for cause 1.
  This failure is the argument for building it.
- **Most teams never discover this**, because they tune on their test set and report
  the tuned number. Finding it required holding the set out and freezing the
  threshold first.

### The honest claim

> "Internally we reach 90.3% sensitivity at 95.9% specificity. On a truly held-out
> external benchmark, with the operating point frozen in advance, that collapses to
> 31.2% sensitivity — the model's ranking largely survives (AUC 0.885) but its
> calibration does not transfer across imaging domains. We report this because it is
> the result our protocol produced, and it defines exactly what has to be fixed
> before any deployment claim: domain-robust calibration."

---

## 4. What is NOT done
- **The hybrid lesion-feature model.** Only the single-technique baseline exists,
  so the README's "integrated beats single-technique" claim is **not yet
  supported by a trained comparison**. The achievable version is Module 1 gate +
  grader versus grader alone.
- **Confidence calibration** (Platt/isotonic). Softmax outputs are not calibrated
  probabilities and should not be presented as confidence.
