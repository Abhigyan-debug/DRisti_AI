#!/usr/bin/env python3
"""
Phase 0 - verify this machine is ready to work.

Checks the on-disk dataset layout against config/dataset_layout.json, which is
the single source of truth shared with the MATLAB side (tests/test_project_setup.m).

Exit code 0 = ready, 1 = something is wrong. Safe to wire into CI.

Usage
    python tools/verify_setup.py
    python tools/verify_setup.py --data-root D:/DRishti_AI_data
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
LAYOUT = REPO_ROOT / "config" / "dataset_layout.json"

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"
if os.name == "nt" and not os.environ.get("WT_SESSION"):
    os.system("")  # enable ANSI on legacy Windows terminals


def resolve_data_root(explicit: Path | None) -> Path:
    """Mirror the resolution order in config/drishti_paths.m."""
    if explicit:
        return explicit
    env = os.environ.get("DRISHTI_DATA_ROOT")
    if env:
        return Path(env)
    local = REPO_ROOT / "config" / "local_paths.json"
    if local.is_file():
        try:
            cfg = json.loads(local.read_text(encoding="utf-8"))
            if cfg.get("dataRoot"):
                return Path(cfg["dataRoot"])
        except json.JSONDecodeError as e:
            print(f"{YELLOW}warning: could not parse {local}: {e}{RESET}")
    return REPO_ROOT / "data"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-root", type=Path, default=None)
    args = ap.parse_args()

    layout = json.loads(LAYOUT.read_text(encoding="utf-8"))
    root = resolve_data_root(args.data_root)

    print(f"\nDRishti-AI setup check")
    print(f"  repo      : {REPO_ROOT}")
    print(f"  data root : {root}")
    if not root.exists():
        print(f"\n{RED}FAIL{RESET} data root does not exist. See docs/datasets.md.")
        return 1
    print()

    failures, warnings = [], []

    # ---- directories -----------------------------------------------------
    for spec in layout["directories"]:
        p = root / spec["path"]
        label = spec["path"]
        if not p.is_dir():
            print(f"  {RED}MISSING{RESET}  {label}")
            failures.append(label)
            continue
        files = [f for f in p.iterdir() if f.is_file()]
        n = len(files)
        expected = spec.get("count")
        if expected is not None and n != expected:
            print(f"  {RED}COUNT  {RESET}  {label}: {n} files, expected {expected}")
            failures.append(label)
            continue
        # spot-check the extension so we catch a half-extracted directory
        ext = spec.get("ext")
        if ext and files:
            allowed = {ext} if isinstance(ext, str) else set(ext)
            wrong = [f.name for f in files if f.suffix.lower() not in allowed]
            if wrong:
                print(f"  {YELLOW}EXT    {RESET}  {label}: {len(wrong)} file(s) not {ext}, e.g. {wrong[0]}")
                warnings.append(label)
                continue
        note = f"  {DIM}({spec['note']}){RESET}" if spec.get("note") else ""
        print(f"  {GREEN}ok     {RESET}  {label}  {DIM}[{n}]{RESET}{note}")

    # ---- individual files ------------------------------------------------
    print()
    for spec in layout["files"]:
        p = root / spec["path"]
        if p.is_file():
            print(f"  {GREEN}ok     {RESET}  {spec['path']}")
        else:
            print(f"  {RED}MISSING{RESET}  {spec['path']}")
            failures.append(spec["path"])

    # ---- known gaps ------------------------------------------------------
    print(f"\n  Known gaps (tracked, not failures):")
    for gap in layout["known_missing"]:
        p = root / gap["path"]
        if p.exists():
            print(f"    {GREEN}RESOLVED{RESET} {gap['path']} is now present - "
                  f"remove it from config/dataset_layout.json known_missing.")
        else:
            print(f"    {YELLOW}open{RESET}     {gap['path']}")
            print(f"             blocks: {gap['blocks']}")
            print(f"             fix:    {gap['fix']}")

    # ---- summary ---------------------------------------------------------
    print()
    if failures:
        print(f"{RED}NOT READY{RESET} - {len(failures)} problem(s). "
              f"Re-run: python tools/organize_datasets.py")
        return 1
    if warnings:
        print(f"{YELLOW}READY with {len(warnings)} warning(s).{RESET}")
        return 0
    print(f"{GREEN}READY{RESET} - dataset layout matches config/dataset_layout.json.")
    print(f"{DIM}MATLAB side: run setup_drishti from the repo root.{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
