# Module 5 Parameters — Sourced Rural Teleophthalmology Assumptions

**R3 deliverable** for **R4 (Natik)**, who is blocked on these for Phase 5.
Machine-readable: [`config/telemedicine_parameters.json`](../config/telemedicine_parameters.json).

The README's risk table names *"Simulink model assumptions being unrealistic"* as a
headline project risk, with the mitigation *"base parameters on published rural
telemedicine deployment studies, cite sources."* This document is that mitigation.

---

## 1. How to read the parameter file

Every value carries a `confidence` tag. **This is the important part of the
deliverable**, more than the numbers themselves:

| Tag | Meaning | How to use it |
|---|---|---|
| `SOURCED` | Read from a cited primary source | Quote it |
| `SOURCED-ABSTRACT` | Read from an abstract; full text not retrievable | Verify before a slide |
| `DERIVED` | Computed from a sourced figure or our own measured data | Show the derivation |
| `ASSUMED` | **We picked it. Not evidence.** | Must appear as an assumption, and be swept |
| `PENDING` | Not knowable yet | Fill when upstream work lands |

Current counts: **11 sourced · 3 sourced-abstract · 1 derived · 6 assumed · 1 pending.**

The six `ASSUMED` values are not a failure of the literature search — they are
parameters that deployment papers simply do not publish (nobody reports technician
seconds-per-patient). The honest move is to label them and sweep them, which is why
§3 is a sensitivity list rather than a table of answers.

---

## 2. The envelope — check the model against this first

Before trusting the Simulink output, confirm it reproduces this hand calculation.
A discrete-event model that disagrees with arithmetic on the *means* has a bug; one
that agrees on means and differs on *queue depth* is doing its job.

```
100,000 patients/year ÷ 250 days      =  400 patients/day
400 × 2 images/patient                =  800 images/day
800 × 1.109 (10.9% recapture)         =  887 image captures/day
400 × 5 min ÷ 60                      =   33.3 technician-hours/day
33.3 ÷ 7-hour day                     =  ~4.8 → 5 technicians
400 × 4.54% referral × 30 s           =   ~9 ophthalmologist-minutes/day
```

That last line is the interesting one. **Read it before building anything.**

### The finding that should shape the model

At a 4.54% referral rate and a 30-second review, a *single* ophthalmologist could
clear a whole district's referrals in about nine minutes a day. Ophthalmologist
review is **not** the bottleneck — and the project's framing (a crippling shortage
of specialists) might lead you to assume it is.

The bottleneck is almost certainly **image acquisition**: ~5 technicians occupied
full-time, constrained by cameras and by patients physically travelling 8–10 km to a
vision centre. Upload is the second candidate, and only in the low-bandwidth scenario.

This does not undermine the project — it sharpens it. The value of AI triage is not
that it saves an overloaded ophthalmologist's time in aggregate; it is that it makes
**1 specialist sufficient for a district that has a fraction of one**, at the
district ratios in §5, while keeping the specialist's attention on the 4.5% of
images that carry disease. Say it that way. Module 5's job is to *demonstrate* that
rather than assert it, and to find the real constraint.

> **For R4:** if your model reports the ophthalmologist as the bottleneck, check the
> referral rate you fed it. That would be the signature of modelling *all* images as
> reviewed rather than only the flagged ones — which is exactly the pre-AI baseline
> worth modelling as a comparison arm.

---

## 3. Sweep these, don't fix them

Ranked by how much the answer moves:

1. **Upload bandwidth — 1 / 5 / 20 Mbps.** No rural *upload* figure exists in the
   sources found (§6 is a documented gap). At 3.5 MB/image and 887 images/day the
   daily payload is ~3.1 GB; at 1 Mbps that does not fit in a working day, at 20 Mbps
   it is trivial. The bottleneck switches inside this range, so it is the most
   decision-relevant axis in the model.
2. **Technician time per patient — 3 / 5 / 8 min.** Linear in technician count.
3. **Arrival process — Poisson vs. camp batches.** Screening camps deliver 40–60
   patients in a morning. Batch arrivals change *queue depth and waiting time*
   dramatically while leaving the mean throughput untouched. This is the single
   strongest argument for using SimEvents rather than a spreadsheet — make the model
   earn its existence here.
4. **Operating days — 250 vs. 300.**
5. **Cohort — general population (13.7% DR) vs. diabetic-only (38.2%).** Triples
   yield per image and changes the optimal staffing mix.

---

## 4. Two measurements that would upgrade this file

Both are cheap and both replace an `ASSUMED` with a real number:

**Image file size** (currently a 3.5 MB placeholder). Once IDRiD is on a machine:

```bash
python -c "import pathlib,statistics as s; f=[p.stat().st_size/1e6 for p in pathlib.Path('data/idrid/grading/1. Original Images').rglob('*.jpg')]; print(f'n={len(f)} median={s.median(f):.2f} MB mean={s.mean(f):.2f} max={max(f):.2f}')"
```

IDRiD is uniformly 4288×2848 — a realistic modern non-mydriatic camera — so its
median file size is a defensible field estimate. Put the measured number in the
JSON and cite it as `DERIVED` from our own corpus.

**Technician time per patient.** Nobody publishes it. The cheapest credible source
is a phone call to any nearby vision centre or a camp observation — 20 patients with
a stopwatch would make this the best-grounded parameter in the model instead of the
weakest. This is the highest-value remaining R3 task for Phase 5.

---

## 5. Workforce context — the number to build the pitch on

| Figure | Value | Source |
|---|---|---|
| Ophthalmologists per million, India | **15** | OJPHI 2024;16:e50921 |
| Ophthalmologists per million, developed countries | 38.6 | same |
| Best district ratio (Hyderabad) | 1 : 6,309 | same |
| **Worst district ratio (Nalgonda)** | **1 : 193,822** | same |

⚠️ All four are `SOURCED-ABSTRACT` — read from the abstract because the publisher
returned an empty body on three fetch attempts. **Verify against the full text
before these go on a slide.**

**Use the spread, not the average.** A ~30× gap between two districts *in the same
state* is a far stronger and more specific argument than any national mean, and it
directly motivates Module 5: the question is not "does India have enough
ophthalmologists" but "what does a district at 1:193,822 need in order to screen
100,000 people a year?" That is the question the Simulink model answers.

Note also the SMART India finding already in
[literature_benchmarks.md](literature_benchmarks.md) §4: **no significant
urban–rural difference in DR prevalence.** Same disease burden, 30× less specialist
access. That pairing is the project's thesis in one line.

---

## 6. Documented gaps

| Gap | Impact | Status |
|---|---|---|
| **Rural upload bandwidth** | Binding constraint, unknown | No figure found. Published stats are national *download* averages (60.85 Mbps, NBM 2.0, Mar 2026). Sweep instead. |
| Technician time-and-motion | Sets technician count | Not published. §4 suggests how to get it. |
| AI inference time | AI stage service rate | `PENDING` on Phase 3. Measure CPU-only too — that is the PHC-realistic case. |
| Full text of OJPHI 2024;16:e50921 | Workforce figures unverified | Publisher returned empty body; PMC is CAPTCHA-walled. Try institutional access. |

---

## 7. Sources

- **Dey et al. (2025)**, *AI-Driven Diabetic Retinopathy Screening: Multicentric
  Validation of AIDRSS in India* — [arXiv:2501.05826](https://arxiv.org/abs/2501.05826).
  Kolkata, 5,029 participants / 10,058 images. Full text read.
  Supplies: images per patient, quality reject rate, DR prevalence, severity breakdown.
  ⚠️ Note its non-standard "referable = DR3–DR4" definition —
  see [clinical_definitions.md](clinical_definitions.md) §3.
- **Abràmoff et al. (2018)**, *npj Digital Medicine* 1:39 —
  [nature.com](https://www.nature.com/articles/s41746-018-0040-6). Imageability 96.1%.
- **Gulshan et al. (2016)**, *JAMA* 316(22):2402–2410. 3/1,748 Messidor-2 ungradable.
- **Aravind Eye Care System**, vision centre model — [aravind.org](https://aravind.org/vision-centre/).
  Catchment 50,000–70,000 within 8–10 km; >90% treated on-site, <10% referred onward.
- **OJPHI (2024)** 16:e50921, South India ophthalmic workforce —
  [doi:10.2196/50921](https://doi.org/10.2196/50921). *Abstract only.*
- **National Broadband Mission 2.0** — national average fixed broadband download
  60.85 Mbps as of 2026-03-31. Rural upload not reported.
- **SMART India (2022)**, *Lancet Global Health* — no urban–rural DR prevalence
  difference. Already catalogued in [literature_benchmarks.md](literature_benchmarks.md).
