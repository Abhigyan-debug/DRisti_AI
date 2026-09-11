# Installing MATLAB for DRishti-AI

**Target machine profile** (measured 2026-09-11):

| | |
|---|---|
| OS | Windows 11 Home Single Language, 64-bit |
| CPU | Intel Core i7-14700HX — 20 physical / 28 logical cores |
| RAM | 15.7 GB |
| GPU | **NVIDIA GeForce RTX 5050 Laptop, 8 GB, compute capability 12.0** |
| Disk | C: 18.7 GB free · **D: 188 GB free** · E: 83.8 GB free |

---

## ⚠️ Read this first: you must install R2026a or newer

MATLAB's supported GPU range is **release-dependent**, and this machine's GPU
sits outside the range of every release before R2026a:

| MATLAB release | Supported compute capability | RTX 5050 (12.0)? |
|---|---|---|
| R2024b | 5.0 – 9.x | ❌ |
| R2025a | 5.0 – 9.x | ❌ |
| R2025b | 5.0 – 9.x | ❌ |
| **R2026a+** | **5.0 – 12.x** | ✅ |

> Sources: [R2024b](https://www.mathworks.com/help/releases/R2024b/parallel-computing/gpu-computing-requirements.html),
> [R2025a](https://www.mathworks.com/help/releases/R2025a/parallel-computing/gpu-computing-requirements.html),
> [R2025b](https://www.mathworks.com/help/releases/R2025b/parallel-computing/gpu-computing-requirements.html),
> [R2026a](https://www.mathworks.com/help/releases/R2026a/parallel-computing/gpu-computing-requirements.html)
> GPU computing requirements pages.

**Why this matters more than it looks.** On R2025b or earlier, `gpuDeviceCount`
returns 0 and MATLAB does not explain why — training just runs on CPU. Phase 3
is the heaviest compute in the project (grading models at 512–896 px input, per
the IDRiD leaderboard), and losing the GPU turns a multi-hour job into a
multi-day one. **A driver update does not fix this.** Only the release does.

`check_environment` detects this case explicitly and tells you which situation
you're in, so you don't have to diagnose it from silence.

---

## Install path: campus (TAH) licence

Your college's Total Academic Headcount licence covers every product this
project needs, including Simulink, SimEvents and Medical Imaging Toolbox, at no
cost to you.

### Step 1 — Create a MathWorks account with your **college** email

This is the step people get wrong. MathWorks associates you with your
institution's licence **by email domain**. A personal Gmail will create a valid
account with **no licence attached**, and there is no obvious error telling you
why no products are available.

1. Go to <https://www.mathworks.com/mwaccount/register>
2. Register with your **`@yourcollege.ac.in`** (or equivalent) address
3. Verify the email

> Already have an account on a personal address? Don't make a second one.
> Add the college address under **My Account → Profile → Email Addresses**,
> then set it as primary. The licence association follows.

If your institution uses SSO, go through your college's own software portal
instead — many Indian colleges host their own MathWorks landing page.

### Step 2 — Confirm the licence appeared

Sign in and open <https://www.mathworks.com/mwaccount/>. Under **My Software**
you should see an *Academic – Total Headcount* licence.

**If nothing appears**, your college either doesn't hold a TAH licence or hasn't
included your department. Contact your IT / software licensing cell before going
further — this is the single most common blocker, and the fix is administrative,
not technical. Fall back to the 30-day trial only if they confirm there's no
licence.

### Step 3 — Download the R2026a installer

From <https://www.mathworks.com/downloads/> — select **R2026a or newer**, not
"latest previous release".

Download it into `D:\MATLAB\_installer\` (already created for you).

The installer itself is small; it pulls products down during installation, so
expect a long download on a slow connection. Budget an hour or two.

### Step 4 — Install to D:

Run the installer and sign in with the college account.

When it asks for the destination folder, **change it to `D:\MATLAB\R2026a`.**
The default is `C:\Program Files\MATLAB\R2026a`, and C: has only 18.7 GB free —
enough for the base install but not once Deep Learning Toolbox starts fetching
pretrained networks (these download separately, and several are multi-GB each).

**Select these products:**

| Product | Needed for |
|---|---|
| MATLAB | everything |
| Image Processing Toolbox | Module 1 (Phase 1) |
| Computer Vision Toolbox | Module 2 (Phase 2) |
| Deep Learning Toolbox | Modules 2–4 (Phase 2) |
| Medical Imaging Toolbox | Module 2 |
| Statistics and Machine Learning Toolbox | Module 3 (Phase 3) |
| **Parallel Computing Toolbox** | **GPU training — without it the RTX 5050 is unused** |
| Simulink | Module 5 (Phase 5) |
| SimEvents | Module 5 queuing blocks |
| MATLAB Report Generator | Module 4's one-page PDF |

Don't tick "select all" — a campus licence covers 100+ products and well over
40 GB.

### Step 4b — (Optional) silent install

If your licence exposes a **File Installation Key**, you can skip the GUI.
[`config/installer_input_drishti.txt`](../config/installer_input_drishti.txt) is
a ready-made input file with the product list above already selected.

```powershell
# from an ADMIN PowerShell
D:\MATLAB\_installer\setup.exe -inputFile D:\MATLAB\_installer\installer_input_drishti.txt
```

Read the header of that file first — the `product.*` keys must match the
template shipped with *your* installer exactly, or the install aborts.

---

## Step 5 — Verify

From the repo root:

```powershell
cd C:\Users\Lenovo\Desktop\DRishti_AI
matlab -batch "setup_drishti"
```

Or open MATLAB with the repo as the current folder — `startup.m` runs it
automatically.

You want to see:

- every required toolbox marked `ok`
- all four datasets marked `ok`
- `GPU: NVIDIA GeForce RTX 5050 Laptop GPU (8.6 GB, compute capability 12.0)`
- `READY - all required toolboxes and datasets present.`

Then run the smoke tests:

```matlab
>> runtests('tests/test_project_setup.m')
```

These load a real image from each of the four corpora and check the label files
parse — they catch a broken install that a toolbox list alone would not.

> **Expect a few small failures on first run.** Every `.m` file in this repo was
> written without MATLAB available to execute it. The logic and structure are
> sound; syntax slips are possible. Fix them as they surface — they are not
> design problems.

---

## Step 6 — Add MATLAB to PATH (optional but convenient)

So `matlab` works from any terminal:

```powershell
[Environment]::SetEnvironmentVariable(
  "Path",
  [Environment]::GetEnvironmentVariable("Path","User") + ";D:\MATLAB\R2026a\bin",
  "User")
```

Restart the terminal afterwards.

---

## Troubleshooting

**"No licence available" / no products offered at install time**
The account isn't associated with the campus licence. Almost always the email
domain — see Step 1. Check <https://www.mathworks.com/mwaccount/> shows the
licence *before* re-running the installer.

**`gpuDeviceCount` returns 0 but the card is clearly there**
You installed a release older than R2026a. Confirm with `version('-release')`.
`check_environment` reports this case explicitly. The only fix is upgrading the
release.

**Install fails or stalls with no message**
Check `D:\MATLAB\_installer\install_log.txt`. Antivirus interfering with the
installer is common; so is running out of space on the *temp* drive even when
the destination has room — `%TEMP%` lives on C:.

**Out of disk during install**
`%TEMP%` is on C:. Either free space there or redirect it:
```powershell
$env:TMP = "D:\MATLAB\_installer\tmp"; $env:TEMP = $env:TMP
```
then launch the installer from that same shell.

**Simulink won't open models / SimEvents blocks missing**
SimEvents is a separate product from Simulink. Re-run the installer and add it
— you don't need to uninstall anything.

---

## Disk budget

| Item | Size |
|---|---|
| MATLAB + the 10 products above | ~15–25 GB |
| Pretrained networks (Deep Learning Toolbox, downloaded on demand) | 2–10 GB |
| Installer download | ~4 GB (deletable afterwards) |
| Datasets (already on D:) | 12.8 GB |
| Dataset archives (already on D:, deletable) | 12.8 GB |
| Model checkpoints and cached preprocessing | 10–30 GB |

D: has 188 GB free. Comfortable.

---

## If the campus licence falls through

| Option | Trade-off |
|---|---|
| **30-day trial** | All toolboxes, instant. Clock starts on activation — only start it when you're ready to build, and check the hackathon timeline first. |
| **Student licence** (~₹2,000–3,500) | Includes Simulink. **Verify SimEvents and Medical Imaging Toolbox are covered before paying** — they are often add-ons. |
| **MATLAB Online** | No install. But no local GPU (kills Phase 3 training), and getting 12.8 GB of datasets into MATLAB Drive is impractical on the free tier. Viable as a fallback for Module 5 / Simulink work only. |
