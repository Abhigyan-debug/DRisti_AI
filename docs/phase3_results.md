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

## 3b. Per-site calibration — the fix, measured

The Messidor-2 failure was a *score-scale* problem, not a *signal* problem: AUC held
at 0.885 while sensitivity collapsed to 31.2%. The model ranks correctly on unseen
cameras; only the cut point is wrong. **A threshold is a property of an imaging
domain, not of a model.**

So the operating point is fitted per site, from a small labelled sample drawn from
the target camera, under one absolute rule:

> **The calibration set and the evaluation set must be disjoint.**
> Fit, freeze, then evaluate on images the fit never saw. Otherwise the result is
> indistinguishable from tuning on test.

### Measured on Messidor-2 (post-hoc demonstration, disjoint halves)

| Calibration images | Sensitivity | Specificity |
|---|---|---|
| **0 — APTOS threshold, current system** | **31.2%** | 99.5% |
| 25 | 85.9% ± 12.7 | 61.0% |
| 50 | 87.3% ± 7.5 | 61.5% |
| 100 | 87.3% ± 8.4 | 60.9% |
| **200** | **90.0% ± 4.9** | 57.9% |
| 400 | 89.8% ± 3.3 | 60.8% |

*30 random disjoint splits per row. This is a demonstration of the deployment
procedure on a set that has already been read — **not** a new external-validation
claim. The 31.2% figure remains the honest headline external result.*

### Measured on IDRiD (train → test, disjoint by construction)

| | Sensitivity | Specificity |
|---|---|---|
| APTOS threshold | 75.0% | 97.4% |
| Site-calibrated (100 imgs) | 83.7% ± 1.4 | 78.7% |

### What this establishes

1. **It recovers the failure.** Sensitivity 31.2% → 90.0% on Messidor-2, hitting the
   clinical target on the dataset where the system had been failing outright.
2. **The cost is specificity**: 99.5% → ~58%. For screening that is the correct
   direction — a false positive costs a review, a false negative costs sight — but it
   must be stated, not hidden. It also raises referral volume, which feeds directly
   into Module 5's throughput model.
3. **~200 labelled images per site** is the operational number. Below that the
   threshold is a noisy estimate (±12.7 at 25 images, ±4.9 at 200). More data buys
   *reliability*, not higher mean performance — the mean is flat from 50 onward.
4. **The benefit scales with how badly transfer fails.** On IDRiD, where the APTOS
   threshold already gave 75% sensitivity, calibration adds ~9pp. On Messidor-2,
   where it gave 31%, it adds ~59pp.

### The deployment claim this supports

> "We do not claim one threshold generalises to every camera — we measured that it
> does not, losing 59 points of sensitivity on unseen equipment. Deployment includes
> a per-site calibration step: roughly 200 labelled images from each new camera,
> used to fit the operating point, frozen before clinical use, and never reused for
> evaluation. That recovers 90% sensitivity on the benchmark where the uncalibrated
> system reached 31%."

That is a stronger and more honest deployment story than a single global number, and
it matches how clinical AI is actually rolled out.

---

## 3c. Multi-domain training — helps the domains you train on, not a third

Unchecked Phase 3 item: "train/tune on APTOS **+ IDRiD**". Trained a second
grader on APTOS train (2929) + IDRiD grading train (413), holding IDRiD **test**
back so a clean probe survives. Identical architecture, wider photometric jitter
to simulate camera variation.

| Model | APTOS val (in-domain) | IDRiD test | **Messidor-2 (unseen by both)** |
|---|---|---|---|
| APTOS-only | AUC 0.9891 · Sens 90.3% · Spec 95.9% | AUC 0.8938 · Sens 75.0% | **AUC 0.8848** |
| APTOS+IDRiD | AUC 0.9866 · Sens 90.3% · Spec 94.9% | AUC 0.9291 · Sens 89.1% | **AUC 0.8757** |

### Read this carefully — the two transfer columns say opposite things

**On IDRiD it looks like a large win**: AUC +0.035, sensitivity +14pp, at
negligible in-domain cost. But **IDRiD train was in the training set**, so IDRiD
test is a same-domain held-out split for that model, not a transfer test. It
shows only that training on a domain helps on that domain.

**On Messidor-2, which neither model has seen, it does not help** — AUC falls
slightly, 0.8848 → 0.8757. AUC is threshold-free, so nothing is tuned here; this
is a clean comparison of two fixed models.

**Conclusion: two training domains did not buy generalisation to a third.** The
intuition that "more domains ⇒ more robustness" is not supported at this scale.
With two corpora the network appears to learn both appearances rather than an
appearance-invariant representation.

### Why this matters for the deployment story

It closes the argument that began with the Messidor-2 failure:

1. **Single-domain training fails on unseen cameras** — 90.3% → 31.2% sensitivity.
2. **Adding a second training domain does not fix it** — helps that domain,
   AUC on a third unseen domain unchanged-to-slightly-worse.
3. **Per-site calibration does fix it** — ~200 labelled images per site recovers
   90.0% sensitivity (§3b).

So per-site calibration is not a workaround adopted for convenience; it is the
option left standing after the alternative was built and measured. That is a
much stronger claim than asserting it from first principles.

---

## 4. What is NOT done
- **The hybrid lesion-feature model.** Only the single-technique baseline exists,
  so the README's "integrated beats single-technique" claim is **not yet
  supported by a trained comparison**. The achievable version is Module 1 gate +
  grader versus grader alone.
- **Confidence calibration** (Platt/isotonic). Softmax outputs are not calibrated
  probabilities and should not be presented as confidence.
