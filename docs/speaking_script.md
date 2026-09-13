# What to actually say — DRishti-AI pitch script

**SIH 2026 · SIH26038 · Team 111 "Neural Cyphers"**

Written to be **spoken**, not read off a slide. Short sentences on purpose.
Target ~6 minutes; a 3-minute cut is marked with ✂.

Pair with `docs/pitch_deck.md` (slides) and `docs/figures/` (visuals).

> **One rule for whoever presents:** never say a number without saying what it
> was measured on. That habit is the whole pitch.

---

## 0. Opening — 30 seconds ✂ *(keep)*

> "Every team presenting today will show you an accuracy number above 90%.
>
> So will we. Ours is 90.3%.
>
> *(pause)*
>
> Then we did something most teams don't do. We tested the same model on a
> camera it had never seen before. Accuracy dropped to 31%.
>
> *(pause)*
>
> That number is why our project is different. We found it, we understood it,
> and we built the fix. Let me show you."

**Delivery:** Slow down on "dropped to 31%". Let it land. Do not rush to defend it
— the pause *is* the pitch.

---

## 1. The problem — 45 seconds ✂ *(keep, can compress)*

> "India has about 15 ophthalmologists per million people. Developed countries
> have 38.6.
>
> But the average hides the real problem. Hyderabad district has one
> ophthalmologist for every 6,000 people. Nalgonda district has one for every
> 190,000.
>
> Diabetic retinopathy has no symptoms until it is nearly too late. Around 13%
> of people screened already have it.
>
> So the patient who needs screening most is the one furthest from a specialist."

**Delivery:** The 6,000 vs 190,000 contrast is the line that lands. Say it slowly.

---

## 2. What we actually built — 45 seconds ✂ *(keep)*

> "DRishti-AI is a five-module MATLAB and Simulink system.
>
> A technician at a primary health centre takes a fundus photograph.
>
> Module 1 checks the image is readable. If it isn't, the technician gets a
> specific instruction — 'refocus on the optic disc' — while the patient is
> still there.
>
> Modules 2 and 3 find the lesions and grade the disease.
>
> Module 4 produces a one-page report with a heat map showing *where* the model
> looked, cross-checked against lesions found independently.
>
> Module 5 is a Simulink model that tells a district how many cameras,
> technicians and specialists it actually needs."

**Delivery:** Point at the architecture diagram. Don't read the module numbers
robotically — describe the *patient's* journey.

---

## 3. The insight — our real novelty — 75 seconds ✂ *(KEEP — most important)*

> "Now back to that 31%.
>
> Here is what we found when we looked into it. The model was not broken. It was
> still ranking patients correctly — sick patients scored higher than healthy
> ones.
>
> The problem was the *threshold*. The cut-off we learned on one dataset sat four
> times higher than it should have for that new camera. So the model saw the
> disease and still said 'no referral'.
>
> *(pause)*
>
> The fix is per-site calibration: refit the threshold on locally labelled
> images from that specific centre. We measured it end to end on a second
> camera — IDRiD — fitting on one split and testing on images the fit never
> saw. Sensitivity went from 75% to 83%.
>
> And we are honest about the cost, and about the limit. Specificity fell from
> 97% to 77% — more false alarms, more specialist time, which we budget for
> instead of hiding. And it did **not** reach our 90% target on held-back
> images. It narrows the transfer gap. It does not close it.
>
> *(pause)*
>
> This is our core claim: **a screening AI is not a model you ship. It is a model
> plus a calibration procedure.** Ship only the model and it silently fails at a
> new clinic — and nobody notices, because it fails by staying quiet."

**Delivery:** This is the 20-mark novelty slide. Slow. Confident. "Fails by
staying quiet" is the closing line — pause after it.

**If asked "I have seen 90% quoted for your calibration":** that number exists
and it is not a result. It comes from splitting Messidor-2 into disjoint halves
and calibrating on one — a procedure demonstrated on the held-out set itself,
and the set is spent so it cannot be checked. The number we stand behind is the
IDRiD one, fit and evaluated on separate splits: 75% to 83%. We show the IDRiD
curve because IDRiD can be split repeatedly, so it is also the one that tells
you *how many images* you need. Both are tabulated in `phase3_results.md` §3b;
the say / do-not-say list is `site_calibration.md` §4.

---

## 4. Demo — 90 seconds ✂ *(cut to 30s: just show one report)*

> "This is one command. Sample images in, clinical reports out."

*(run `demo/run_demo.m`, or show a pre-generated report)*

> "Here is what the ophthalmologist sees.
>
> The fundus image with the model's attention overlaid. The grade. The
> confidence — and next to it, *what that confidence is based on*.
>
> Now look at the lesion panel. Hard exudates shows a number. Microaneurysms and
> haemorrhages say 'not validated'.
>
> *(pause)*
>
> That is deliberate. We measured those detectors. Microaneurysm precision is
> under 3%. If we printed a count, 97 out of 100 would be wrong. A wrong number on a
> medical document is worse than no number — so we suppress it.
>
> The report tells the clinician what we know, and it tells them what we don't."

**Delivery:** The "not validated" moment is your second-strongest beat. Most teams
show everything their model outputs. Showing restraint is the differentiator.

---

## 5. Results, stated honestly — 60 seconds ✂ *(compress to 20s)*

> "On in-domain validation: 90.3% sensitivity, 95.9% specificity.
>
> On the held-out external benchmark, which we read exactly once with the
> threshold frozen beforehand: 31.2%.
>
> Per-site calibration recovers part of that, and we can only prove how much on
> a camera we are still allowed to test — on IDRiD, held back, 75% to 83%. Not
> to 90%.
>
> And we know *where* it fails. It is not a uniform miss. Severe and
> proliferative disease — the sight-threatening cases — we catch. Early referable
> disease, grade 2, we miss 84% of the time.
>
> That matters clinically, and it tells us exactly what to fix next."

**Delivery:** Show figure `04_failure_by_grade.png`. Don't apologise for the 84%.
State it like an engineer who measured it.

---

## 6. Deployment impact — 45 seconds ✂ *(compress to 20s)*

> "Module 5 answers the question a district health officer actually asks: what do
> I need to buy, and who do I need to hire?
>
> For 100,000 patients a year: six cameras, six technicians, one compute node,
> one ophthalmologist.
>
> Two things surprised us. First, the bottleneck is not the specialist — it is
> image acquisition. Second, the compute node does not need a GPU.
>
> On a CPU, a typical image takes about seven and a half seconds. The average
> across all images is ten and a half, because about a third of images take
> longer — thirteen to twenty-five seconds. We size the compute on the average,
> not the typical case.
>
> A GPU saves 0.2% of that, so a rural deployment does not need one. That
> matters for cost.
>
> On specialist time: reading every image is 200 minutes a day. With our triage,
> 88. That is a 2.3 times reduction — not the 10x you get if you assume a perfect
> classifier. We used our real, measured specificity."

**Delivery:** "We used our real, measured specificity" — this is the line that
tells a technical judge you know what you're doing.

---

## 7. Close — 30 seconds ✂ *(keep)*

> "Our system is not finished. Grade 2 detection needs work. Our lesion detectors
> need more annotated data. No ophthalmologist has timed our report yet.
>
> We know all of that because we measured it, and it is written down.
>
> *(pause)*
>
> Anyone can train a model that scores 90% on the data it was trained on. We
> built the thing that tells you when that 90% stops being true.
>
> Thank you."

---

# Q&A bank — the questions that will actually come

### ⚠️ "Your external accuracy is only 31%. Isn't that a failure?"

**This will be asked. Answer without flinching.**

> "It would be, if we shipped it that way. 31% is what happens when you take a
> threshold learned on one camera and apply it to another — which is exactly what
> most deployed systems do without checking.
>
> We measured it, diagnosed it as a calibration problem and not a model
> problem, and built the fix. On the one camera where we could measure the fix
> end to end on held-back images it recovers about 8 points of sensitivity —
> real, and short of our target. The 31% is not our result — it is our
> *finding*, and the honest statement of the fix is part of it."

### "IDx-DR is FDA-cleared at 87% sensitivity. Why is yours better?"

> "It isn't better on accuracy, and I won't claim it is. IDx-DR is a mature,
> cleared product.
>
> We are solving a different problem: rural deployment where the camera, the
> operator and the population are different at every site. That is what the
> calibration procedure and the throughput model are for. IDx-DR also doesn't
> tell a district health officer how many technicians to hire."

### "Isn't AI for diabetic retinopathy already done?"

> "Detection is well-established, yes. What is not established is what happens
> when you move it to a new site. Our contribution is the deployment procedure —
> calibration, the staffing model, and a report that withholds what it cannot
> support."

### "Why does your report hide the microaneurysm count?"

> "Because we measured its precision at under 3% — on the IDRiD test split,
> 27 images, micro-averaged. Showing a count that is wrong 97 times out of 100
> on a clinical document is not a feature. We show hard exudates because we
> measured that one at 82%, against a bar of 50% we froze before measuring."

### "Does the quality gate improve your accuracy?"

**Trap question — answer honestly:**

> "No. We tested it. It costs us 9 percentage points of specificity.
>
> We keep it for a clinical reason, not a statistical one: an unreadable image
> must produce a retake instruction, never a confident grade. We'd rather the
> technician retake it while the patient is still in the room."

### ⚠️ "Your demo printed 14 seconds per image but your slide says 7.6. Which is it?"

**Both. Know this cold — the demo really does print a different number.**

> "Good catch — they measure different things.
>
> 7.6 seconds is the median: a typical image, with the system already warm.
>
> 10.6 seconds is the mean, and that is what we size compute on, because a
> queue cares about average work, not the typical case. About a third of images
> take 13 to 25 seconds — the same images every time, so it is image content,
> not noise.
>
> And the very first image of a session costs about 16 to 25 seconds for model
> loading. A short demo run includes that warm-up and a couple of slow images,
> so its average lands around 14. A long-running service pays that start-up
> cost once.
>
> All of it is in our parameter file with the full distribution."

### "How do I know this works in the field?"

> "You don't yet, and neither do we. We have not run a field pilot. What we have
> is a measured envelope and a calibration procedure to run before any site goes
> live. The next step is one PHC pilot."

### "What's your biggest weakness?"

> "Grade 2 detection — early referable disease. We miss 84% of it, and it is two
> thirds of the patients who need referral. The cause is our lesion detectors,
> and the constraint there is annotated training data, not the architecture."

---

## Things NOT to say

| ❌ Don't say | ✅ Say instead |
|---|---|
| "Our model is 90% accurate" | "90.3% in-domain; 31% on unseen equipment before calibration" |
| "Calibration takes us from 31% back to 90%" | "On the camera we could test end to end, 75% → 83% sensitivity for 97% → 77% specificity. The 90% is a post-hoc split of the spent benchmark — not an independent result." |
| "We detect microaneurysms" | "We detect them, but not accurately enough to report — so we don't" |
| "Better than existing solutions" | "Different problem: rural deployment and calibration" |
| "Our integrated pipeline outperforms baselines" | *(we tested this — it doesn't. Never claim it.)* |
| "Sub-30-second review" | "Designed for it; not yet timed with a clinician" |
| "7.65 seconds per image" *(bare)* | "7.6 s typical; 10.6 s average — we size on the average" |

---

## If you only get 60 seconds

> "India has one ophthalmologist per 190,000 people in its worst districts, and
> diabetic retinopathy is silent until it blinds you.
>
> We built a five-module MATLAB system that screens at a primary health centre
> and produces an explainable one-page report.
>
> Here is what makes ours different. We tested our model on a camera it had never
> seen. Accuracy fell from 90% to 31%. Most teams never run that test.
>
> We found the cause — a miscalibrated threshold — and built the fix: refit the
> threshold on local images before the site goes live. Measured on a second
> camera, it recovers most of the gap but not all of it, and it costs
> specificity.
>
> A screening AI isn't a model you ship. It's a model plus a calibration
> procedure. That's our contribution."
