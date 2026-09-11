# Phase 2 Work Split

**Why this document exists:** Phase 2 is the most parallelisable phase in the
project, and it is currently assigned entirely to one person. Phases 1 and 3 are
genuinely serial. Phase 2 is not — it is six independent detectors, each with its
own ground truth and its own metric.

This is the one place where adding people actually buys speed.

---

## The rule that makes parallel work possible

**Everybody writes [`config/lesion_features.json`](../config/lesion_features.json)
and nothing else.** Module 3 reads only that.

Agree the contract before starting. Five detectors built without it produce five
incompatible outputs and the integration cost eats the parallelism gain — which is
the usual reason adding people to a late project makes it slower, not faster.

**Every spatial quantity is in disc diameters, never pixels.** Our corpora span a
6.7× resolution range. A count-per-pixel feature encodes the camera model, and
Phase 3 would learn which dataset an image came from instead of whether the patient
has disease. Module 1 hit exactly this with its sharpness metric (r = −0.75 against
FOV diameter). The contract file carries the conversion.

---

## The split

| # | Task | Ground truth | Metric | Benchmark | Suggested owner |
|---|---|---|---|---|---|
| 2a | Optic disc localization | IDRiD, 413+103 | Euclidean px | 21.07 px | **Abhigyan** — *seed done, 239 px* |
| 2b | Fovea localization | IDRiD, 413+103 | Euclidean px | — | **Abhigyan** — reuses 2a |
| 2c | **Vessel segmentation** | DRIVE, 20 imgs | Dice, AUC | Dice 82.8 | **Natik** |
| 2d | **Hard + soft exudates** | IDRiD, 54+27 | AUPR | 0.885 / 0.699 | **whoever is free** |
| 2e | Microaneurysms | IDRiD, 54+27 | AUPR | **0.5017** | Abhigyan |
| 2f | Haemorrhages | IDRiD, 53+27 | AUPR | 0.6804 | pairs with 2e |
| 2g | Neovascularization | none (heuristic) | — | — | last, needs 2c |

### Why this order

**2c (vessels) → Natik.** The cleanest hand-off available. It is self-contained
(20 images, one dataset, one metric), it shares no code with the rest, and it
**unblocks two other things**: the vessel-convergence cue that the disc localizer
needs (measured and rejected with a crude proxy — `opts.vesselWeight` is waiting at
0 for a real map), and neovascularization detection which cannot start without it.
Natik already has MATLAB, Simulink and Deep Learning Toolbox installed.

**2d (exudates) is the highest clinical value per unit effort.** It has the highest
achievable benchmark of any lesion (0.885 — the only one where high numbers are
plausible), and since R3's DME decision it **directly drives a reported endpoint**:
`hardExudates.minDistanceToFoveaDD` is what grades DME risk. Do not leave this to last.

**2e (microaneurysms) stays with Abhigyan and should be expected to disappoint.**
Best in the world is AUPR 0.50. Budget time accordingly and do not let it consume
the schedule.

---

## What to tell each person

### Natik (R4) — vessel segmentation
- Data: `data/drive/training/{images,1st_manual,mask}` — only **20 annotated images**
- ⚠️ **DRIVE test ground truth is missing** (blocker B2). Split the 20 and document
  the protocol as non-standard, or obtain the official annotations first.
- Report **Dice + AUC, FOV-masked, single global threshold, official split.**
  Published DRIVE numbers are famously incomparable because papers differ on exactly
  these. Anything claiming >99% Dice is an evaluation artifact.
- 20 images is thin. Heavy augmentation, and expect the U-Net to be the easy part.
- Deliverable: a function returning a binary vessel map + the `vessels` block of the
  feature contract.

### Abhigyat (R3) — no code required
- **B12** (DME scale mismatch) — still open and still yours.
- Define the **dot vs blot vs flame** haemorrhage criteria clinically, so 2f
  implements a rule rather than inventing one.
- Confirm the DME distance rule: IDRiD grades by shortest distance from macula
  centre to any hard exudate, ≤1 DD = grade 2. 2d depends on this being right.
- **B11** — the Module 5 citations.

### Oshi (R5) — deck, plus one useful technical task
- The deck skeleton with blanks where numbers go.
- **Failure-case curation.** Every module writes its worst cases to
  `results/`. Someone who is not the author should look at them and keep a running
  failure catalogue — it is a Phase 6 deliverable and a credibility asset in a
  clinical pitch. Looking at outputs has caught more real bugs in this project than
  any metric has.

### Abhigyan (R1/R2)
- Finish 2a/2b, then 2e/2f.
- **Own the feature contract.** Anyone may propose a field; you merge it.

---

## Honest expectations

Adding three people to Phase 2 does not make it three times faster. Realistically:

- Only two of you can write MATLAB CV code today. That is the real constraint, not
  task count.
- Natik ramping into vessel segmentation costs time before it saves time — but that
  ramp happens during hours that would otherwise be spent waiting.
- Expect roughly **1.5–2× on Phase 2**, not 3×.

Phase 3 is not parallelisable in the same way and will land back on one person.
Plan for that rather than being surprised by it.

---

## Integration checkpoints

Do not let five branches run for a week and merge at the end.

1. **Day 1** — contract agreed, everyone has a stub returning the right struct with
   dummy values. Integration proven before any real work lands.
2. **Mid-phase** — each detector runs end-to-end on 10 IDRiD images and writes real
   features. Metrics can be bad; the plumbing must work.
3. **End** — full evaluation, all features populated, one consolidated table.

Checkpoint 1 is the one people skip and the one that matters most.
