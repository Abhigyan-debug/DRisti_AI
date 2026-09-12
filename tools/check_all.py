#!/usr/bin/env python3
"""
Run every check that does not need MATLAB. One command, one verdict.

WHY
---
There are six of these now, and a six-command checklist is a checklist people
skip. Worse, they skip it silently and in a hurry - which is exactly when the
checks matter. So: one command before a commit, before a demo, before a
submission.

    python tools/check_all.py

WHAT IT RUNS

    verify_setup       is the dataset layout on this machine what the contract says
    verify_freeze      has any pre-registered contract moved since it was frozen
    test_verify_freeze ...and would that check still detect tampering
    check_claims       does the repo state only what was measured (--strict)
    test_check_claims  ...and would that checker still catch a banned claim
    test_holdout_guard does every entry point still guard the spent benchmark

Three of those six are tests OF the other three. That is deliberate. A verifier
that has quietly stopped comparing anything reports success forever, which is
worse than having no verifier at all, because it launders an unchecked claim
into a checked-looking one.

WHAT IT DOES NOT RUN
--------------------
The MATLAB suite - 57 cases in tests/ - which needs MATLAB and therefore runs on
one machine. This is the half everyone can run, including R3 and R5, who have no
datasets and no MATLAB and still need to know the docs are honest.

`--skip-setup` drops the dataset check, which is the only one that fails on a
machine without the corpora. That failure is expected there and is not a defect.

Exit code 0 = everything passed. CI-safe.

Usage
    python tools/check_all.py
    python tools/check_all.py --skip-setup   # no datasets on this machine
    python tools/check_all.py --verbose      # show each check's own output
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
TOOLS = REPO_ROOT / "tools"

GREEN, RED, YELLOW, DIM, BOLD, RESET = (
    "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[1m", "\033[0m"
)
if os.name == "nt" and not os.environ.get("WT_SESSION"):
    os.system("")
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

CHECKS = [
    ("verify_setup.py", [], "dataset layout matches the contract", True),
    ("verify_freeze.py", [], "no pre-registered contract has moved", False),
    ("test_verify_freeze.py", [], "...and that check still detects tampering", False),
    ("check_claims.py", ["--strict"], "no banned or superseded claims", False),
    ("test_check_claims.py", [], "...and that checker still catches them", False),
    ("test_holdout_guard.py", [], "every entry point guards the spent benchmark", False),
]


def main() -> int:
    ap = argparse.ArgumentParser(description="Run every non-MATLAB check.")
    ap.add_argument("--skip-setup", action="store_true",
                    help="skip the dataset check (expected to fail without the corpora)")
    ap.add_argument("--verbose", action="store_true",
                    help="show each check's own output, not just the verdict")
    args = ap.parse_args()

    print(f"\n{BOLD}DRishti-AI — full non-MATLAB check{RESET}")
    print(f"{DIM}  MATLAB suite (57 cases in tests/) is not included; it needs MATLAB.{RESET}\n")

    failures, skipped = [], []
    for script, extra, blurb, needs_data in CHECKS:
        if needs_data and args.skip_setup:
            skipped.append(script)
            print(f"  {YELLOW}skip {RESET}  {script:<24} {DIM}{blurb}{RESET}")
            continue

        t0 = time.perf_counter()
        proc = subprocess.run(
            [sys.executable, str(TOOLS / script), *extra],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            cwd=REPO_ROOT,
        )
        dt = time.perf_counter() - t0
        ok = proc.returncode == 0
        tag = f"{GREEN}pass {RESET}" if ok else f"{RED}FAIL {RESET}"
        print(f"  {tag}  {script:<24} {DIM}{blurb}  ({dt:.1f}s){RESET}")

        if not ok:
            failures.append((script, proc))
        if args.verbose:
            for line in (proc.stdout or "").rstrip().splitlines():
                print(f"           {DIM}{line}{RESET}")

    if failures:
        print(f"\n{BOLD}Output from what failed{RESET}")
        for script, proc in failures:
            print(f"\n{RED}── {script} {'─' * max(0, 56 - len(script))}{RESET}")
            body = ((proc.stdout or "") + (proc.stderr or "")).rstrip()
            print(body if body else "(no output)")

    print()
    if failures:
        names = ", ".join(s for s, _ in failures)
        print(f"{RED}FAIL{RESET} - {len(failures)} of {len(CHECKS) - len(skipped)} "
              f"check(s) failed: {names}\n")
        return 1

    note = f" {DIM}({len(skipped)} skipped){RESET}" if skipped else ""
    print(f"{GREEN}ALL CLEAR{RESET} - {len(CHECKS) - len(skipped)} checks passed{note}.")
    print(f"{DIM}Remember the MATLAB suite: runtests('tests') where MATLAB exists.{RESET}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
