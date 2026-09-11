# Environment Setup

**Phase 0 deliverable.** How to get a machine ready to work on DRishti-AI.

---

## 0. What do I actually need?

**Not everyone needs the full setup.** Installing MATLAB and downloading 12.8 GB of
fundus images takes most of a day — only do it if your role requires it.

| You are | MATLAB | Datasets | What to do |
|---|---|---|---|
| **Abhigyat** — R3, clinical research | ❌ | ❌ | `git clone` only (or just read on GitHub). Your work is literature, the DME decision, and sourcing Module 5's parameters. |
| **Oshi** — R5, presentation / docs | ❌ | ❌ | `git clone` only. You need results, not a toolchain. |
| **Natik** — R4, Module 5 then Module 4 | ✅ Simulink + SimEvents | ❌ *not yet* | Follow §A below. **Module 5 is a queuing simulation with no images in it** — you do not need the datasets to build it. You will need them later for Module 4. |
| **Abhigyan** — R1 + R2 | ✅ all toolboxes | ✅ | Full setup, §A then §B. Already done. |

> ⚠️ If you don't have the datasets, **`python tools/verify_setup.py` will fail** —
> that is expected, not a broken install. It only checks the data layout. Skip it.

---

## 1. Clone and install MATLAB

*(Natik, Abhigyan)*

```bash
git clone https://github.com/Abhigyan-debug/DRisti_AI.git
cd DRisti_AI
```

Install MATLAB **R2026a or newer** with the products for your role — see
[matlab_install.md](matlab_install.md). Then, from the repo root:

```matlab
>> setup_drishti
```

`startup.m` runs this automatically if you launch MATLAB with the repo as the
current folder. It adds `src/` to the path and reports toolbox status.

Without the datasets, `setup_drishti` will list them as `MISSING` and
`check_environment` will say `NOT READY`. **That is correct and harmless** — the
MATLAB path is still set up and Simulink work proceeds normally.

### Getting the datasets

*(Abhigyan now; Natik later, for Module 4)*

The datasets are **not in the repo** and cannot be — cloning gets you no data.
Two options:

1. **Copy from Abhigyan's `D:\DRishti_AI_data`** — much faster, and `_archives/`
   there already holds the original downloads.
2. **Re-download** from Kaggle / IEEE DataPort / grand-challenge / ADCIS, then run
   `python tools/organize_datasets.py` to build the canonical layout.

Then point the repo at them:

```bash
cp config/local_paths.example.json config/local_paths.json
#    edit dataRoot to wherever you put them

python tools/verify_setup.py        # should now print READY
```

---

## 2. MATLAB toolboxes

> ### ⚠️ Install R2026a or newer
>
> The development machine has an **RTX 5050 (compute capability 12.0)**. MATLAB
> R2025b and earlier support only compute capability 5.0–9.x, so on those
> releases the GPU is **silently unusable** and Phase 3 trains on CPU. R2026a is
> the first release covering 12.x. Full detail and install steps:
> **[matlab_install.md](matlab_install.md)**.

`check_environment` (called by `setup_drishti`) checks all of these and tells you
which phase each one blocks.

### Required

| Toolbox | Needed from |
|---|---|
| Image Processing Toolbox | Phase 1 |
| Computer Vision Toolbox | Phase 2 |
| Deep Learning Toolbox | Phase 2 |
| Statistics and Machine Learning Toolbox | Phase 3 |
| Simulink | Phase 5 |

### Optional but recommended

| Toolbox | Why |
|---|---|
| Medical Imaging Toolbox | Medical image datastores, 2-D/3-D labelling |
| Parallel Computing Toolbox | GPU training — without it Phase 3 is CPU-bound and slow |
| SimEvents | Discrete-event queuing blocks for Module 5 |
| MATLAB Report Generator | Module 4's one-page PDF report |

Install via **Home → Add-Ons → Get Add-Ons**. Students: check whether your
institution has a campus-wide licence before buying anything — most Indian
engineering colleges have a MathWorks TAH licence covering all of the above.

> **Note:** MATLAB is **not installed** on the machine this repo was set up on.
> Everything in `config/`, `tests/` and `src/` is written against the MATLAB API
> but has **not been executed**. The first person with MATLAB should run
> `setup_drishti` and `runtests('tests/test_project_setup.m')` and fix whatever
> surfaces — expect small issues, not design problems.

---

## 3. Datasets

Datasets live **outside the repo** (~12.8 GB, plus ~12.8 GB of archives).
`config/drishti_paths.m` resolves the root in this order:

1. `DRISHTI_DATA_ROOT` environment variable
2. `config/local_paths.json` → `dataRoot`  ← *recommended*
3. `<repo>/data`

On the original setup machine, `<repo>\data` is a **Windows directory junction**
to `D:\DRishti_AI_data`, because `C:` had only 6 GB free:

```powershell
cmd /c mklink /J "C:\path\to\DRishti_AI\data" "D:\DRishti_AI_data"
```

You do not need to replicate that — just set `dataRoot`.

To build the layout from the raw downloads:

```bash
python tools/organize_datasets.py          # move, extract, verify, write manifest
python tools/organize_datasets.py --help   # other modes
```

It is idempotent. See [datasets.md](datasets.md) for what ends up where and for
the two outstanding data gaps.

### Disk budget

| | Size |
|---|---|
| Extracted datasets | ~12.8 GB |
| Original archives (`_archives/`, optional backup) | ~12.8 GB |
| Model checkpoints, cached preprocessing (estimate) | 10–30 GB |

Budget **~40 GB** on the data drive. Delete `_archives/` if you're short — the
datasets are re-downloadable, though APTOS needs a Kaggle account.

---

## 4. Python tooling

Only needed for the dataset tooling in `tools/`, not for the pipeline itself.

- Python 3.9+ (3.14 on the setup machine)
- `pillow` — only for `tools/organize_datasets.py` image sampling

```bash
pip install pillow
```

Everything else is standard library.

---

## 5. Git

`.gitignore` already excludes `data/`, `models/`, `results/`, `reports/`, MATLAB
autosaves (`*.asv`, `*.m~`), Simulink caches (`slprj/`, `*.slxc`), and
`config/local_paths.json`.

**Do not `git add -f` anything under those paths.** Fundus images in particular
may carry redistribution restrictions — see [datasets.md](datasets.md) §8.

Recommended for `.gitattributes` if you later track any binary model artefacts:
use Git LFS rather than committing weights directly.

---

## 6. Verifying your setup

| Check | Command | Needs MATLAB |
|---|---|---|
| Dataset layout | `python tools/verify_setup.py` | no |
| Dataset manifest | `python tools/organize_datasets.py --manifest-only` | no |
| Toolboxes + paths | `setup_drishti` | yes |
| Full smoke test | `runtests('tests/test_project_setup.m')` | yes |

`verify_setup.py` exits non-zero on failure, so it can go straight into CI.

Both the Python and MATLAB checks read the same contract file,
`config/dataset_layout.json` — update that one file when the layout changes, and
both sides stay in sync.

---

## 7. Troubleshooting

**`setup_drishti` says the data root is MISSING**
The path in `config/local_paths.json` is wrong, or you started MATLAB from a
different folder. Run `drishti_paths` and check `dataRootSource` to see which
resolution rule fired.

**`verify_setup.py` reports COUNT mismatches**
An extraction was interrupted. Re-run `python tools/organize_datasets.py` — it
skips what is already correct and redoes the rest.

**`check_environment` reports "LICENCE" rather than "MISSING"**
The toolbox is installed but no licence seat is free. On a campus network licence
this usually means waiting, or disconnecting another session.

**A `known_missing` test fails**
That is intentional. It means a tracked gap has been filled — update
`config/dataset_layout.json` and [datasets.md](datasets.md) to match.
