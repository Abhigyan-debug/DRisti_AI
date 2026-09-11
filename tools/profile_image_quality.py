#!/usr/bin/env python3
"""
Phase 1 prep - measure image-quality statistics across all four corpora.

Module 1 needs concrete reject/borderline thresholds. The README names the
metrics (sharpness, illumination uniformity, FOV coverage, glare) but not the
cut-offs. This script derives them from the data we actually hold, so Phase 1
starts from measured distributions rather than invented constants.

It also tests a specific design claim from docs/datasets.md section 6: that a
sharpness metric computed in raw pixel units is resolution-dependent and will
mis-score across corpora whose images span 640x480 to 4288x2848. We compute
sharpness both ways - raw, and normalised to a canonical FOV diameter - and
report the correlation with image size for each.

Outputs
    docs/phase1_quality_baseline.md   human-readable report
    config/quality_thresholds.json    machine-readable, consumed by Module 1

Usage
    python tools/profile_image_quality.py                # 60 images per corpus
    python tools/profile_image_quality.py --n 150
    python tools/profile_image_quality.py --n 0          # every image (slow)
"""

from __future__ import annotations

import argparse
import json
import math
import random
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_setup import resolve_data_root  # noqa: E402  (shared resolution order)

# Resize every image so the fundus disc spans this many pixels before measuring
# sharpness. This is what makes the metric comparable across cameras.
CANONICAL_FOV_PX = 512

CORPORA = {
    "APTOS": "aptos2019/train_images",
    "IDRiD": "idrid/grading/1. Original Images/a. Training Set",
    "DRIVE": "drive/training/images",
    "Messidor2": "messidor2/IMAGES",
}


# ---------------------------------------------------------------- metrics


def fov_mask(gray: np.ndarray, thresh: int = 12) -> tuple[np.ndarray, float, tuple]:
    """Locate the circular field of view.

    Fundus images are a bright disc on a near-black background. Threshold, then
    take the bounding box of lit rows/columns. Simpler than connected-component
    labelling and robust enough here, because the disc dominates the frame.

    Returns (boolean mask, estimated FOV diameter in px, bbox).
    """
    lit = gray > thresh
    rows = np.flatnonzero(lit.any(axis=1))
    cols = np.flatnonzero(lit.any(axis=0))
    if rows.size == 0 or cols.size == 0:
        return lit, 0.0, (0, 0, gray.shape[0], gray.shape[1])
    r0, r1 = int(rows[0]), int(rows[-1])
    c0, c1 = int(cols[0]), int(cols[-1])
    # The FOV is usually cropped top/bottom, so width is the better diameter
    # estimate; fall back to the larger extent.
    diameter = float(max(c1 - c0 + 1, r1 - r0 + 1))
    return lit, diameter, (r0, c0, r1, c1)


def erode_square(mask: np.ndarray, k: int = 7) -> np.ndarray:
    """Binary erosion with a k x k square. Mirrors MATLAB imerode(mask, strel('square', k)).

    Written out rather than pulled from scipy so this tool keeps its only
    dependency as Pillow + numpy, and so the structuring element provably
    matches the MATLAB side pixel for pixel.
    """
    r = k // 2
    out = mask.copy()
    # Separable: a square erosion is a horizontal pass then a vertical pass.
    for axis in (0, 1):
        cur = out
        acc = cur.copy()
        for s in range(1, r + 1):
            shifted_fwd = np.zeros_like(cur)
            shifted_bwd = np.zeros_like(cur)
            if axis == 0:
                shifted_fwd[s:, :] = cur[:-s, :]
                shifted_bwd[:-s, :] = cur[s:, :]
            else:
                shifted_fwd[:, s:] = cur[:, :-s]
                shifted_bwd[:, :-s] = cur[:, s:]
            acc &= shifted_fwd & shifted_bwd
        out = acc
    return out


def laplacian_variance(gray: np.ndarray, mask: np.ndarray | None = None) -> float:
    """Variance of the 4-neighbour Laplacian inside the eroded FOV.

    MUST stay identical to src/quality_enhancement/measureSharpness.m. The
    thresholds this script emits are consumed directly by the MATLAB gate, so a
    definition mismatch silently invalidates them. Two things matter:

      1. Measured on the 0-255 intensity scale (not [0,1]).
      2. The FOV mask is eroded by a 7x7 square first. The FOV boundary is a
         hard black-to-retina step and the strongest edge in the frame; leaving
         it in makes the score partly a function of how much black surround the
         camera left in, which is a crop convention rather than focus.
    """
    g = gray.astype(np.float32)
    lap = (
        4.0 * g[1:-1, 1:-1]
        - g[:-2, 1:-1]
        - g[2:, 1:-1]
        - g[1:-1, :-2]
        - g[1:-1, 2:]
    )
    if mask is not None:
        m = erode_square(mask, 7)[1:-1, 1:-1]
        if m.sum() < 100:
            return 0.0
        lap = lap[m]
    return float(lap.var())


def illumination_uniformity(gray: np.ndarray, mask: np.ndarray, blocks: int = 8) -> float:
    """Coefficient of variation of block mean intensity inside the FOV.

    0 = perfectly even lighting. Rises with vignetting, shadowing and the
    off-axis illumination typical of handheld cameras in field conditions.
    """
    h, w = gray.shape
    bh, bw = max(1, h // blocks), max(1, w // blocks)
    means = []
    for i in range(blocks):
        for j in range(blocks):
            sub = gray[i * bh:(i + 1) * bh, j * bw:(j + 1) * bw]
            subm = mask[i * bh:(i + 1) * bh, j * bw:(j + 1) * bw]
            # only score blocks that are mostly inside the FOV
            if subm.size and subm.mean() > 0.6:
                means.append(float(sub[subm].mean()))
    if len(means) < 4:
        return float("nan")
    mu = statistics.fmean(means)
    if mu <= 0:
        return float("nan")
    return statistics.pstdev(means) / mu


def measure(path: Path) -> dict | None:
    try:
        with Image.open(path) as im:
            im = im.convert("RGB")
            native_w, native_h = im.size
            rgb = np.asarray(im)
    except Exception:
        return None

    gray = (0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]).astype(np.uint8)
    mask, fov_d, _ = fov_mask(gray)
    if fov_d < 32:
        return None

    inside = gray[mask]
    if inside.size < 1000:
        return None

    # --- raw (native-resolution) sharpness: the naive metric --------------
    sharp_raw = laplacian_variance(gray, mask)

    # --- normalised sharpness: rescale so the FOV is always the same size --
    scale = CANONICAL_FOV_PX / fov_d
    if scale < 1.0:
        new_size = (max(32, int(native_w * scale)), max(32, int(native_h * scale)))
        with Image.open(path) as im2:
            im2 = im2.convert("L").resize(new_size, Image.BILINEAR)
            gsm = np.asarray(im2)
        msm, _, _ = fov_mask(gsm)
    else:
        gsm, msm = gray, mask
    sharp_norm = laplacian_variance(gsm, msm)

    frame_px = native_w * native_h
    return {
        "file": path.name,
        "width": native_w,
        "height": native_h,
        "megapixels": frame_px / 1e6,
        "fov_diameter_px": fov_d,
        "fov_coverage": float(mask.mean()),           # fraction of frame lit
        "sharpness_raw": sharp_raw,
        "sharpness_norm": sharp_norm,
        "illum_cv": illumination_uniformity(gray, mask),
        "mean_intensity": float(inside.mean()),
        "contrast_p99_p1": float(np.percentile(inside, 99) - np.percentile(inside, 1)),
        "glare_frac": float((rgb.max(axis=2)[mask] >= 250).mean()),
        "dark_frac": float((inside <= 15).mean()),
    }


# ---------------------------------------------------------------- reporting


def pct(vals: list[float], p: float) -> float:
    return float(np.percentile(np.asarray(vals, dtype=float), p)) if vals else float("nan")


def summarise(vals: list[float]) -> dict:
    a = np.asarray([v for v in vals if not math.isnan(v)], dtype=float)
    if a.size == 0:
        return {}
    return {
        "n": int(a.size),
        "min": float(a.min()),
        "p05": float(np.percentile(a, 5)),
        "median": float(np.median(a)),
        "p95": float(np.percentile(a, 95)),
        "max": float(a.max()),
    }


def pearson(x: list[float], y: list[float]) -> float:
    ax, ay = np.asarray(x, float), np.asarray(y, float)
    ok = ~(np.isnan(ax) | np.isnan(ay))
    ax, ay = ax[ok], ay[ok]
    if ax.size < 3 or ax.std() == 0 or ay.std() == 0:
        return float("nan")
    return float(np.corrcoef(ax, ay)[0, 1])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=60, help="images per corpus (0 = all)")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--data-root", type=Path, default=None)
    args = ap.parse_args()

    random.seed(args.seed)
    root = resolve_data_root(args.data_root)
    print(f"data root: {root}\n")

    results: dict[str, list[dict]] = {}
    for corpus, rel in CORPORA.items():
        folder = root / rel
        if not folder.is_dir():
            print(f"  SKIP {corpus}: {folder} not found")
            continue
        files = sorted(p for p in folder.iterdir() if p.is_file())
        if args.n and len(files) > args.n:
            files = random.sample(files, args.n)
        rows = []
        for i, f in enumerate(files, 1):
            m = measure(f)
            if m:
                rows.append(m)
            if i % 25 == 0 or i == len(files):
                print(f"  {corpus}: {i}/{len(files)}", flush=True)
        results[corpus] = rows
        print()

    # ---- write machine-readable thresholds ------------------------------
    all_rows = [r for rows in results.values() for r in rows]
    if not all_rows:
        print("no images measured")
        return 1

    thresholds = {
        "_comment": (
            "Module 1 quality thresholds derived from measured distributions across "
            "APTOS/IDRiD/DRIVE/Messidor-2. Percentiles are over the pooled sample. "
            "Treat these as STARTING POINTS calibrated on curated datasets - field "
            "images from handheld cameras will be worse, so re-check on degraded "
            "images before trusting the reject rate (README section 9)."
        ),
        "_generated_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "_sample_size": len(all_rows),
        "canonical_fov_px": CANONICAL_FOV_PX,
        "sharpness": {
            "metric": "variance of 4-neighbour Laplacian, measured AFTER rescaling "
                      f"so the FOV diameter is {CANONICAL_FOV_PX}px",
            "reject_below": round(pct([r["sharpness_norm"] for r in all_rows], 2), 2),
            "borderline_below": round(pct([r["sharpness_norm"] for r in all_rows], 10), 2),
        },
        "illumination_uniformity": {
            "metric": "coefficient of variation of 8x8 block means inside FOV",
            "reject_above": round(pct([r["illum_cv"] for r in all_rows], 98), 4),
            "borderline_above": round(pct([r["illum_cv"] for r in all_rows], 90), 4),
        },
        "fov_coverage": {
            "metric": "fraction of frame inside the field of view",
            "_WARNING": (
                "DO NOT USE THIS AS AN ABSOLUTE THRESHOLD. FOV coverage is a camera/crop "
                "fingerprint, not a quality signal: IDRiD sits at 0.691 with near-zero "
                "variance, Messidor-2 at ~0.465, APTOS is trimodal. A cut-off calibrated "
                "on the pooled distribution lands inside Messidor-2's own range and would "
                "reject gradable images from our external benchmark for camera geometry "
                "alone. Module 1 must judge framing relative to the DETECTED FOV (is the "
                "disc complete, is the macula centred) rather than as a fraction of frame."
            ),
            "pooled_p02_do_not_use": round(pct([r["fov_coverage"] for r in all_rows], 2), 4),
            "per_corpus_median": {
                c: round(float(np.median([r["fov_coverage"] for r in rows])), 4)
                for c, rows in results.items() if rows
            },
        },
        "glare": {
            "metric": "fraction of FOV pixels with any channel >= 250",
            "reject_above": round(pct([r["glare_frac"] for r in all_rows], 98), 5),
            "borderline_above": round(pct([r["glare_frac"] for r in all_rows], 90), 5),
        },
        "contrast": {
            "metric": "p99 - p1 of luminance inside FOV",
            "reject_below": round(pct([r["contrast_p99_p1"] for r in all_rows], 2), 2),
        },
    }
    out_json = REPO_ROOT / "config" / "quality_thresholds.json"
    out_json.write_text(json.dumps(thresholds, indent=2), encoding="utf-8")

    # ---- write the report ------------------------------------------------
    lines = []
    A = lines.append
    A("# Module 1 Quality Baseline")
    A("")
    A(f"*Generated by `tools/profile_image_quality.py` on "
      f"{datetime.now(timezone.utc).strftime('%Y-%m-%d')} — "
      f"{len(all_rows)} images sampled across four corpora.*")
    A("")
    A("Phase 1 prep. The README specifies **which** quality metrics Module 1 computes")
    A("but not what counts as a reject. These are the measured distributions the")
    A("thresholds in [`config/quality_thresholds.json`](../config/quality_thresholds.json)")
    A("come from.")
    A("")
    A("---")
    A("")
    A("## 1. The resolution-dependence problem, measured")
    A("")
    A("[datasets.md](datasets.md) §6 claimed that a sharpness metric in raw pixel")
    A("units is resolution-dependent and will mis-score across corpora.")
    A("")
    A("**This must be tested *within* a corpus, not pooled across all four.** Pooling")
    A("confounds resolution with dataset identity — DRIVE is simultaneously the")
    A("smallest and the sharpest corpus, so a pooled correlation mostly measures")
    A("\"which dataset is this\". The clean test is a corpus with wide internal")
    A("resolution variety and constant content: **APTOS**, which spans 640×480 to")
    A("2588×1958.")
    A("")
    A("Correlation of each sharpness metric against FOV diameter, per corpus:")
    A("")
    A("| Corpus | FOV diameter range | r (raw) | r (FOV-normalised) |")
    A("|---|---|---|---|")

    best_raw, best_norm = None, None
    for corpus, rows in results.items():
        if len(rows) < 10:
            continue
        fovs = [r["fov_diameter_px"] for r in rows]
        spread = max(fovs) / max(1.0, min(fovs))
        rr = pearson(fovs, [r["sharpness_raw"] for r in rows])
        rn = pearson(fovs, [r["sharpness_norm"] for r in rows])
        flag = "" if spread > 1.5 else "  *(near-constant resolution — uninformative)*"
        A(f"| {corpus} | {min(fovs):.0f}–{max(fovs):.0f} px | "
          f"{rr:+.3f} | {rn:+.3f} |{flag}")
        if spread > 1.5 and (best_raw is None or abs(rr) > abs(best_raw)):
            best_raw, best_norm, best_name = rr, rn, corpus
    A("")

    # pooled, reported only as a caveat
    mp = [r["megapixels"] for r in all_rows]
    r_raw = pearson(mp, [r["sharpness_raw"] for r in all_rows])
    r_norm = pearson(mp, [r["sharpness_norm"] for r in all_rows])
    A(f"*(Pooled across all corpora: raw `{r_raw:+.3f}`, normalised `{r_norm:+.3f}` — "
      "confounded, shown only for completeness.)*")
    A("")

    if best_raw is not None:
        if abs(best_norm) < abs(best_raw):
            A(f"**Verdict.** Within {best_name}, raw Laplacian variance correlates with FOV")
            A(f"diameter at `{best_raw:+.3f}` — the metric is measuring image size about as")
            A("much as it measures focus. Rescaling to a canonical FOV diameter cuts that")
            A(f"to `{best_norm:+.3f}`.")
            A("")
            A("So normalisation is **necessary but not sufficient**. A residual")
            A(f"correlation of `{abs(best_norm):.2f}` still means a threshold tuned on")
            A("small images will mis-fire on large ones. Module 1 should either band the")
            A("threshold by FOV diameter, or use a focus measure that is genuinely")
            A("scale-invariant (e.g. energy ratio across a fixed band of spatial")
            A("frequencies relative to FOV diameter, rather than a fixed-size kernel).")
        else:
            A(f"⚠️ Within {best_name}, normalising did **not** reduce the correlation")
            A(f"(`{best_raw:+.3f}` → `{best_norm:+.3f}`). Investigate before relying on either.")
    A("")

    # concrete effect by size band
    aptos_rows = results.get("APTOS", [])
    if len(aptos_rows) >= 30:
        A("Median sharpness by FOV-diameter band (APTOS), showing the effect concretely:")
        A("")
        A("| FOV diameter | n | raw | normalised |")
        A("|---|---|---|---|")
        bands = [("< 800 px", 0, 800), ("800–1600 px", 800, 1600), ("> 1600 px", 1600, 1e9)]
        for label, lo, hi in bands:
            g = [r for r in aptos_rows if lo <= r["fov_diameter_px"] < hi]
            if g:
                A(f"| {label} | {len(g)} | "
                  f"{statistics.median(r['sharpness_raw'] for r in g):.1f} | "
                  f"{statistics.median(r['sharpness_norm'] for r in g):.1f} |")
        A("")
    A("---")
    A("")
    A("## 2. Per-corpus distributions")
    A("")

    metrics = [
        ("sharpness_norm", "Sharpness (FOV-normalised)", "{:.1f}"),
        ("sharpness_raw", "Sharpness (raw)", "{:.1f}"),
        ("illum_cv", "Illumination CV", "{:.3f}"),
        ("fov_coverage", "FOV coverage", "{:.3f}"),
        ("glare_frac", "Glare fraction", "{:.4f}"),
        ("dark_frac", "Dark fraction", "{:.3f}"),
        ("contrast_p99_p1", "Contrast (p99-p1)", "{:.1f}"),
        ("mean_intensity", "Mean intensity", "{:.1f}"),
    ]

    for key, label, fmt in metrics:
        A(f"### {label}")
        A("")
        A("| Corpus | n | min | p05 | median | p95 | max |")
        A("|---|---|---|---|---|---|---|")
        for corpus, rows in results.items():
            if not rows:
                continue
            s = summarise([r[key] for r in rows])
            if not s:
                continue
            A(f"| {corpus} | {s['n']} | {fmt.format(s['min'])} | {fmt.format(s['p05'])} | "
              f"**{fmt.format(s['median'])}** | {fmt.format(s['p95'])} | {fmt.format(s['max'])} |")
        A("")

    A("---")
    A("")
    A("## 3. Derived thresholds")
    A("")
    A("Written to [`config/quality_thresholds.json`](../config/quality_thresholds.json).")
    A("Percentiles are over the pooled sample:")
    A("")
    A("| Check | Borderline | Reject |")
    A("|---|---|---|")
    A(f"| Sharpness (normalised) | below {thresholds['sharpness']['borderline_below']} | "
      f"below {thresholds['sharpness']['reject_below']} |")
    A(f"| Illumination CV | above {thresholds['illumination_uniformity']['borderline_above']} | "
      f"above {thresholds['illumination_uniformity']['reject_above']} |")
    A(f"| Glare fraction | above {thresholds['glare']['borderline_above']} | "
      f"above {thresholds['glare']['reject_above']} |")
    A(f"| FOV coverage | — | below {thresholds['fov_coverage']['reject_below']} |")
    A(f"| Contrast | — | below {thresholds['contrast']['reject_below']} |")
    A("")
    A("> ⚠️ **These are calibrated on curated research datasets.** All four corpora")
    A("> were captured by trained operators on mounted cameras. Field images from")
    A("> handheld devices in a PHC will be substantially worse, so a threshold set at")
    A("> the 2nd percentile here will reject far more than 2% in deployment. The")
    A("> README's own risk table calls this out. Re-calibrate against deliberately")
    A("> degraded images (Phase 1's synthetic degradation task) before trusting the")
    A("> reject rate.")
    A("")
    A("---")
    A("")
    A("## 4. Worst images found")
    A("")
    A("Useful as Phase 1 test cases — these are the real low-quality examples in our")
    A("data, better starting material than synthetic blur:")
    A("")
    for corpus, rows in results.items():
        if not rows:
            continue
        worst = sorted(rows, key=lambda r: r["sharpness_norm"])[:3]
        A(f"**{corpus}** (lowest normalised sharpness)")
        A("")
        for w in worst:
            A(f"- `{w['file']}` — sharpness {w['sharpness_norm']:.1f}, "
              f"illum CV {w['illum_cv']:.3f}, glare {w['glare_frac']:.4f}")
        A("")

    out_md = REPO_ROOT / "docs" / "phase1_quality_baseline.md"
    out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"wrote {out_md.relative_to(REPO_ROOT)}")
    print(f"wrote {out_json.relative_to(REPO_ROOT)}")
    print(f"\nsharpness vs megapixels:  raw r={r_raw:+.3f}   normalised r={r_norm:+.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
