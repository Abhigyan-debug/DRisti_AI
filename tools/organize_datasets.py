#!/usr/bin/env python3
"""
Phase 0 - dataset organisation.

Takes the raw downloads (Kaggle / IEEE DataPort / grand-challenge / ADCIS archives)
and lays them out in the canonical structure the rest of the pipeline expects:

    <DATA_ROOT>/
      _archives/                 original .zip files, kept untouched as a backup
      aptos2019/
        train_images/            3662 .png
        test_images/             1928 .png
        train.csv  test.csv  sample_submission.csv
      idrid/
        segmentation/            IDRiD part A  (lesion masks: MA / HE / EX / SE / OD)
        grading/                 IDRiD part B  (ICDR grade + DME risk labels)
        localization/            IDRiD part C  (optic disc + fovea centre coords)
      drive/
        training/  test/         vessel segmentation ground truth
      messidor2/
        IMAGES/                  1744 .png
        messidor-2.csv           left/right eye pairing

The script is idempotent: re-running it skips anything already in place.

Usage
    python tools/organize_datasets.py                 # move + extract + manifest
    python tools/organize_datasets.py --no-move       # archives are already at DATA_ROOT
    python tools/organize_datasets.py --manifest-only # just re-scan and rewrite the manifest
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATA_ROOT = Path(os.environ.get("DRISHTI_DATA_ROOT", r"D:\DRishti_AI_data"))
STAGING = REPO_ROOT / "data"  # where the raw downloads currently sit

# archive name -> (destination subdir, path prefix to strip when extracting)
ARCHIVES = {
    "aptos2019-blindness-detection.zip": ("aptos2019", None),
    "A. Segmentation.zip": ("idrid/segmentation", "A. Segmentation/"),
    "B. Disease Grading.zip": ("idrid/grading", "B. Disease Grading/"),
    "C. Localization.zip": ("idrid/localization", "C. Localization/"),
    "datasets.zip": ("drive", None),  # contains nested training.zip / test.zip
}
SPLIT_MESSIDOR = ["IMAGES.zip.001", "IMAGES.zip.002", "IMAGES.zip.003", "IMAGES.zip.004"]

# Expected file counts, verified against this project's actual extraction on
# 2026-09-11 and cross-checked with the published dataset specifications.
EXPECTED = {
    "aptos2019/train_images": 3662,
    "aptos2019/test_images": 1928,
    "idrid/segmentation/1. Original Images/a. Training Set": 54,
    "idrid/segmentation/1. Original Images/b. Testing Set": 27,
    "idrid/grading/1. Original Images/a. Training Set": 413,
    "idrid/grading/1. Original Images/b. Testing Set": 103,
    "idrid/localization/1. Original Images/a. Training Set": 413,
    "idrid/localization/1. Original Images/b. Testing Set": 103,
    "drive/training/images": 20,
    "drive/training/1st_manual": 20,
    "drive/test/images": 20,
    "messidor2/IMAGES": 1748,
}

# Known gaps in the copies we hold. Surfaced on every run so they cannot be
# quietly forgotten; see docs/datasets.md for the resolution plan.
KNOWN_GAPS = [
    "drive/test has no 1st_manual/ - vessel ground truth for the DRIVE test "
    "split is withheld in this distribution. Phase 2 must re-split the 20 "
    "annotated training images, or obtain the official test annotations.",
    "messidor2 ships images + left/right pairing only, with NO ICDR grade "
    "labels. Phase 6 external validation needs the separately-published "
    "Messidor-2 reference grades before it can report sensitivity/specificity.",
]


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}PB"


def free_space(path: Path) -> int:
    return shutil.disk_usage(path).free


# ---------------------------------------------------------------- move


def move_archives(data_root: Path) -> None:
    """Move the raw downloads off the system drive into <DATA_ROOT>/_archives."""
    archives_dir = data_root / "_archives"
    archives_dir.mkdir(parents=True, exist_ok=True)

    if not STAGING.exists() or STAGING.is_symlink():
        log("staging dir is already a junction/symlink - nothing to move")
        return

    movable = [p for p in STAGING.iterdir() if p.is_file()]
    if not movable:
        log("no loose files in data/ - nothing to move")
        return

    total = sum(p.stat().st_size for p in movable)
    log(f"moving {len(movable)} files ({human(total)}) -> {archives_dir}")
    for src in movable:
        dst = archives_dir / src.name
        if dst.exists() and dst.stat().st_size == src.stat().st_size:
            log(f"  = {src.name} already at destination, removing staging copy")
            src.unlink()
            continue
        log(f"  -> {src.name} ({human(src.stat().st_size)})")
        shutil.move(str(src), str(dst))
    log("move complete")


# ---------------------------------------------------------------- extract


def extract_zip(zip_path: Path, dest: Path, strip_prefix: str | None = None) -> int:
    """Extract zip_path into dest, optionally stripping a leading path component."""
    dest.mkdir(parents=True, exist_ok=True)
    count = 0
    with zipfile.ZipFile(zip_path) as zf:
        infos = zf.infolist()
        needed = sum(i.file_size for i in infos)
        avail = free_space(dest)
        if needed > avail:
            raise RuntimeError(
                f"{zip_path.name} needs {human(needed)} but only {human(avail)} free at {dest}"
            )
        total = len(infos)
        for n, info in enumerate(infos, 1):
            name = info.filename
            if strip_prefix and name.startswith(strip_prefix):
                name = name[len(strip_prefix) :]
            if not name or name.endswith("/"):
                continue
            target = dest / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists() and target.stat().st_size == info.file_size:
                count += 1
                continue
            with zf.open(info) as src, open(target, "wb") as out:
                shutil.copyfileobj(src, out, length=1 << 20)
            count += 1
            if n % 500 == 0 or n == total:
                log(f"    {zip_path.name}: {n}/{total}")
    return count


def already_populated(dest: Path, min_files: int = 5) -> bool:
    if not dest.exists():
        return False
    return sum(1 for _ in dest.rglob("*") if _.is_file()) >= min_files


def join_split_archive(archives_dir: Path, out_path: Path) -> Path:
    """Concatenate byte-split volumes (IMAGES.zip.001..004) into one valid zip."""
    if out_path.exists():
        log(f"  = joined archive already present: {out_path.name}")
        return out_path
    parts = [archives_dir / p for p in SPLIT_MESSIDOR]
    missing = [p.name for p in parts if not p.exists()]
    if missing:
        raise FileNotFoundError(f"missing Messidor-2 volumes: {missing}")
    total = sum(p.stat().st_size for p in parts)
    log(f"  joining {len(parts)} volumes ({human(total)}) -> {out_path.name}")
    with open(out_path, "wb") as out:
        for p in parts:
            with open(p, "rb") as f:
                shutil.copyfileobj(f, out, length=1 << 22)
    return out_path


def extract_all(data_root: Path) -> None:
    archives_dir = data_root / "_archives"

    for archive_name, (subdir, strip) in ARCHIVES.items():
        src = archives_dir / archive_name
        dest = data_root / subdir
        if not src.exists():
            log(f"! missing archive {archive_name} - skipping {subdir}")
            continue
        if already_populated(dest):
            log(f"= {subdir} already extracted - skipping")
            continue
        log(f"extracting {archive_name} -> {subdir}")
        extract_zip(src, dest, strip)

    # DRIVE ships as a zip-of-zips: datasets.zip -> {training.zip, test.zip}
    drive_dir = data_root / "drive"
    for nested in ("training.zip", "test.zip"):
        nz = drive_dir / nested
        target = drive_dir / nested.replace(".zip", "")
        if nz.exists() and not already_populated(target):
            log(f"extracting nested {nested} -> drive/{target.name}")
            extract_zip(nz, target)
        if nz.exists() and already_populated(target):
            nz.unlink()

    # DRIVE's nested zips unpack one level too deep (training/training/...).
    for split in ("training", "test"):
        doubled = drive_dir / split / split
        if doubled.is_dir():
            log(f"flattening drive/{split}/{split} -> drive/{split}")
            for item in doubled.iterdir():
                shutil.move(str(item), str(drive_dir / split / item.name))
            doubled.rmdir()

    # Messidor-2: byte-split volumes + a separate pairing CSV
    messidor_dir = data_root / "messidor2"
    if not already_populated(messidor_dir / "IMAGES"):
        joined = join_split_archive(archives_dir, archives_dir / "IMAGES_joined.zip")
        log("extracting Messidor-2 IMAGES")
        extract_zip(joined, messidor_dir)
        joined.unlink()  # ~2.3GB temp, drop it once extracted
        log("  removed temporary joined archive")
    else:
        log("= messidor2/IMAGES already extracted - skipping")

    csv_src = archives_dir / "messidor-2.csv"
    csv_dst = messidor_dir / "messidor-2.csv"
    if csv_src.exists() and not csv_dst.exists():
        shutil.copy2(csv_src, csv_dst)
        log("copied messidor-2.csv")


# ---------------------------------------------------------------- manifest


def sha256_head(path: Path, nbytes: int = 1 << 20) -> str:
    """Hash of the first MB - enough to spot a corrupt/truncated file cheaply."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read(nbytes))
    return h.hexdigest()[:16]


def scan(data_root: Path) -> dict:
    manifest = {
        "generated_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "data_root": str(data_root),
        "datasets": {},
    }
    for name in ("aptos2019", "idrid", "drive", "messidor2"):
        root = data_root / name
        if not root.exists():
            manifest["datasets"][name] = {"present": False}
            continue
        by_ext: dict[str, int] = {}
        by_dir: dict[str, int] = {}
        total_bytes = 0
        for p in root.rglob("*"):
            if not p.is_file():
                continue
            by_ext[p.suffix.lower()] = by_ext.get(p.suffix.lower(), 0) + 1
            rel = p.relative_to(root).parent.as_posix() or "."
            by_dir[rel] = by_dir.get(rel, 0) + 1
            total_bytes += p.stat().st_size
        manifest["datasets"][name] = {
            "present": True,
            "path": str(root),
            "n_files": sum(by_ext.values()),
            "size_bytes": total_bytes,
            "size_human": human(total_bytes),
            "by_extension": dict(sorted(by_ext.items(), key=lambda kv: -kv[1])),
            "by_directory": dict(sorted(by_dir.items())),
        }
    return manifest


def check_expectations(manifest: dict, data_root: Path) -> list[str]:
    problems = []
    for rel, expected in EXPECTED.items():
        d = data_root / rel
        if not d.exists():
            problems.append(f"MISSING  {rel} (expected {expected} files)")
            continue
        actual = sum(1 for p in d.rglob("*") if p.is_file())
        if actual != expected:
            problems.append(f"COUNT MISMATCH  {rel}: {actual} files, expected {expected}")
    return problems


# ---------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-root", type=Path, default=DEFAULT_DATA_ROOT)
    ap.add_argument("--no-move", action="store_true", help="skip moving archives off C:")
    ap.add_argument("--manifest-only", action="store_true", help="only rescan + rewrite manifest")
    args = ap.parse_args()

    data_root: Path = args.data_root
    data_root.mkdir(parents=True, exist_ok=True)
    log(f"data root: {data_root}  ({human(free_space(data_root))} free)")

    if not args.manifest_only:
        if not args.no_move:
            move_archives(data_root)
        extract_all(data_root)

    log("scanning for manifest...")
    manifest = scan(data_root)
    problems = check_expectations(manifest, data_root)
    manifest["expectation_check"] = problems or ["all expected counts matched"]
    manifest["known_gaps"] = KNOWN_GAPS

    out = REPO_ROOT / "docs" / "dataset_manifest.json"
    out.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    log(f"manifest written -> {out.relative_to(REPO_ROOT)}")

    print()
    for name, info in manifest["datasets"].items():
        if info.get("present"):
            print(f"  {name:<12} {info['n_files']:>6} files  {info['size_human']:>9}")
        else:
            print(f"  {name:<12}  NOT PRESENT")
    print()
    for p in manifest["expectation_check"]:
        print(f"  {p}")
    print("\n  Known gaps (see docs/datasets.md):")
    for g in KNOWN_GAPS:
        print(f"    - {g}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
