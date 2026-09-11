# PPT Review — SIH26038, Team 111 (Neural Cyphers)

*Reviewed 2026-09-12 against the actual repository state. Every "not implemented"
below was verified by searching the code, not assumed.*

Owner: Oshi (R5), with R1 for the numbers.

---

## 🔴 FIX TONIGHT — slide 6 is from a different project

The **Current Limitations** box reads:

> - Cloud & Data Quality: Optical imagery may be affected by **clouds**.
> - Satellite Availability: Analysis depends on available **satellite passes**.
> - Compute Requirements: Large **vision-language models** may need powerful hardware.

This is a **satellite / remote-sensing** deck pasted into a retinal imaging
submission. There are no clouds, no satellites and no VLMs anywhere in this project.

A judge who reads that box will conclude the team did not write their own slides,
and every other claim on the deck becomes suspect. **This is the single highest
priority item in the whole submission.**

### Replace with limitations that are real (and we have measured evidence for)

- **Lesion detectors are weak.** Vessel Dice 0.622 vs 0.828 published; hard exudate
  Dice 0.210; microaneurysm counts implausibly high. Best-in-world MA AUPR is only
  0.50, so this is a genuinely hard problem, not an excuse.
- **Grad-CAM is not yet lesion-grounded.** Measured attention enrichment 1.51×
  over chance against expert masks — above chance, but not corroboration.
- **External validation shows a large generalisation gap.** Sensitivity falls from
  90.3% internally to **31.2%** on Messidor-2 at the frozen operating point. This is
  the most important limitation on the project and belongs on the slide.
- **No ophthalmologist has reviewed the outputs.** The review protocol exists; the
  clinician does not.
- **DME is inferred from hard exudates, not OCT** — the same proxy the published
  reference standards use, and a shared limitation worth naming.

Stating these *with numbers* reads as rigour. The satellite text reads as copy-paste.

---

## 🔴 The report prints a claim that is false

`src/explainability/generate_clinical_report.m:166` renders:

```
Calibrated Confidence: 87.3% (Platt Scaled)
```

**No Platt scaling exists anywhere in the codebase.** That value is a raw softmax
output, which is not a calibrated probability.

Printing "(Platt Scaled)" on a clinical report when nothing was scaled is a false
label on a medical document. Either implement the calibration or change the label to
`Model confidence (uncalibrated)`. The second takes one minute.

Owner: Natik (R4).

---

## 🟠 Claims on the deck that the code does not support

Each was verified by search:

| Slide claim | Reality |
|---|---|
| "Custom **U-Net**" (Tech Stack) | **Not implemented.** Vessel segmentation is classical multi-scale Frangi filtering, Dice 0.622. U-Net appears only in comments, as the benchmark we are measured *against*. |
| "Denoising **CNNs**" (Tech Stack) | It is `imguidedfilter` — an edge-preserving guided filter, not a CNN. |
| "**Confidence Score Calibration**" (Tech Stack) | Not implemented. See above. |
| "**Frontend Dashboard**: Single-Page Web Dashboard + React + Recharts + Tailwind" | **Does not exist.** No `.jsx`, no `.tsx`, no `package.json`, no frontend directory anywhere. |
| "**Simulink** + Simulink Profiler" | The throughput model is MATLAB `.m` code (`simulate_district_throughput.m`). There is **no `.slx` model**. It runs and produces results, but calling it Simulink is not accurate. |
| "Simulink simulation **solves** network bottlenecks" | The model *identifies* bottlenecks. It does not solve them. |

**How to fix without weakening the deck:** move these to a clearly labelled
**"Planned / Next Phase"** column. A deck that separates *built* from *planned* is
more credible than one that blurs them — and judges routinely ask "show me this
running."

---

## 🟠 The Grad-CAM claim is the one to soften

Slide 3 says:

> "Clear Grad-CAM heatmaps allow doctors to verify results in **under 30 seconds**."

Two problems:

1. **No doctor has ever reviewed one of these heatmaps.** The 30-second figure is a
   design target, not a measurement.
2. We built the corroboration check our own risk analysis called for, and it says the
   heatmaps are **only 1.51× better than chance** at landing on real lesions. On one
   grade-1 image the hotspot sat on the **optic disc** — normal anatomy.

**Reframe it as a strength, because it is one:**

> "We implemented an independent corroboration check for our heatmaps —
> cross-referencing Grad-CAM attention against lesions detected by a separate
> pipeline. It currently shows 1.51× enrichment over chance: better than random,
> not yet clinically grounded. Raising input resolution 384→640 px improved it 21%,
> and that is our next lever."

That is a team that knows whether its explanations work. The original claim is one
a judge can puncture with a single question.

---

## 🔴 UPDATE 2026-09-12 — Messidor-2 has now been run, and it changes the deck

External validation at the frozen operating point: **Sensitivity 31.2%**,
Specificity 99.5%, AUC 0.8848 — against 90.3% / 95.9% / 0.9891 internally.

**Any slide implying the internal number generalises is now known to be wrong.**
The cause is calibration shift across imaging domains: the frozen threshold (0.4033)
sits ~4× above the median referable score on Messidor-2 (0.0992). Full analysis in
[phase3_results.md](phase3_results.md) §3.

This makes the "Confidence Score Calibration" item on the Tech Stack slide urgent
rather than cosmetic: it is the direct fix for the failure, and it is not implemented.

**How to present it.** Do not hide it and do not lead with it. Lead with the internal
result, then:

> "We held Messidor-2 out entirely and froze our operating point before touching it.
> Sensitivity fell to 31.2% — the model still ranks well (AUC 0.885) but its
> calibration does not transfer across imaging domains. We found this because our
> protocol was designed to be able to find it."

A team that discovers its own generalisation gap is more credible than one that
reports a single internal number. But the gap must be stated, not implied.

---

## 🟢 Underselling the internal results (still true, with the caveat above)

Slide 3 lists ">90% Sensitivity & >85% Specificity" as a **benefit/target**.

**You have actually achieved, and measured:**

| Metric | Result |
|---|---|
| Referable DR sensitivity | **90.3%** |
| Referable DR specificity | **95.9%** |
| ROC AUC | **0.9891** |
| 5-class quadratic weighted kappa | **0.9087** |
| APTOS competition winner (reference) | 0.936 — *with a model ensemble + 88,702 extra images* |

*(APTOS validation split, n=733, ResNet-18 @ 640 px. DR-only endpoint.)*

**An achieved number beats a promised one every time.** Put these on the slide as
measured results with the protocol stated, e.g.:

> "**Measured:** Sensitivity 90.3%, Specificity 95.9%, AUC 0.9891 on a held-out
> validation split (n=733). Quadratic weighted kappa 0.9087 — within 0.03 of the
> APTOS competition winner, which used a model ensemble and 88,702 additional
> training images."

Pair it immediately with the external result — see the Messidor-2 section above.
Presenting the internal number alone is now knowingly misleading.

**Most teams will have quietly tuned on their test set.** Holding Messidor-2 out,
freezing the threshold first, and reporting the gap you find is the differentiator
judges in a clinical track will recognise.

---

## 🟡 Slide 2 contradicts your own architecture

The deck criticises:

> "Traditional DR Classifiers: Use deep neural networks (**e.g., ResNet**)...
> Gap: black-box nature lacks medical interpretability"

**Our grader is a ResNet-18.** As written, the deck attacks the thing it is built on,
and an attentive judge will notice.

**Reframe:** the differentiator is not avoiding ResNet — it is what we wrapped around
it. A validated quality gate that refuses ungradable images, and an explanation that
is *checked against independent evidence rather than asserted*. Say that instead.

---

## 🟡 Smaller items

- **Slide 5 (Feasibility)** is generic — "Uses existing tools", "Works with retinal
  image datasets". Replace with specifics you have: 4 datasets totalling 12.8 GB
  organised and verified, ~2 s/image end-to-end, a district throughput model showing
  **one ophthalmologist can cover 100,000 patients/year at 37% utilisation** — which
  is a genuinely counter-intuitive, quotable result.
- **References** are good (Gulshan, Abràmoff, Pratt, Silva, MATLAB) and match our
  literature review. Consider adding **Krause et al. 2018**, which is the source of
  the Messidor-2 reference standard we are validating against.
- **Module 1 deserves a slide of its own.** It is the most rigorously validated
  component in the project — thresholds measured from 380 images rather than guessed,
  three real defects found and fixed by inspection (a glare metric that was actually
  measuring red-channel clipping, a contrast metric that made enhancement look
  harmful, a noise blind spot), and a 7-mode synthetic degradation study proving the
  gate responds monotonically. No competing team will have that.

---

## Suggested priority order

1. **Delete the satellite limitations.** Nothing else matters as much.
2. **Fix the "(Platt Scaled)" label** in the report generator — one line.
3. **Put the real measured numbers on slide 3.**
4. **Move U-Net / dashboard / calibration to "Planned".**
5. Soften the Grad-CAM claim into the corroboration story.
6. Reframe slide 2 so it does not attack ResNet.

Items 1–3 are roughly 30 minutes and account for most of the risk.
