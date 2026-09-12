#!/usr/bin/env python3
"""
Verify the pre-registration chain: has any frozen contract moved?

WHY THIS EXISTS
---------------
Most of this project's credibility is an ORDERING claim. The lesion display gate
was written down before the detectors were measured against it. The referable-DR
endpoint was frozen before Messidor-2 was read. The dark-lesion operating point
was selected on TRAIN before the TEST split certified it.

Each of those claims is what turns a reported number into a result rather than a
description of the numbers - and each is worthless if it cannot be checked. Until
now they were checkable only by a human reading a doc, finding a truncated hash
like `1c447a7428e4781a...`, and running sha256sum by hand. Nobody does that, and a
judge certainly cannot.

So: one command.

    python tools/verify_freeze.py

It is deliberately boring. It reads config/frozen_artifacts.json, hashes each
file named there, and reports any that differ from the recorded value. It knows
nothing about what the files mean.

WHAT A FAILURE MEANS
--------------------
Not automatically misconduct. A contract can legitimately be amended - the
clinical definitions were amended the same day they were frozen, for a real bug
(B12), and that amendment is logged. What must never happen is a gate edited to
fit a measurement after the measurement was seen.

So a failure here is a question, not a verdict: what changed, when, and was it
decided before or after someone saw the number it affects? If the answer is
"after", the honest move is to re-run the measurement, not to update the hash.

Exit code 0 = every frozen artifact matches, 1 = at least one moved. CI-safe.

Usage
    python tools/verify_freeze.py
    python tools/verify_freeze.py --verbose   # also print what each one governs
    python tools/verify_freeze.py --update    # rewrite hashes (asks for confirmation)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = REPO_ROOT / "config" / "frozen_artifacts.json"

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


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify frozen contracts have not moved.")
    ap.add_argument("--verbose", action="store_true",
                    help="print what each artifact governs")
    ap.add_argument("--update", action="store_true",
                    help="rewrite the manifest's hashes to match the files on disk")
    args = ap.parse_args()

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    artifacts = manifest["artifacts"]

    print(f"\n{BOLD}DRishti-AI freeze check{RESET}")
    print(f"  manifest : config/frozen_artifacts.json "
          f"{DIM}(v{manifest['version']}, verified {manifest['verified']}){RESET}")
    print(f"  artifacts: {len(artifacts)}\n")

    moved, missing, pairs = [], [], []
    actual: dict[str, str] = {}

    for art in artifacts:
        path = REPO_ROOT / art["path"]
        if not path.is_file():
            missing.append(art)
            print(f"  {RED}MISSING{RESET}  {art['path']}")
            continue

        digest = sha256_of(path)
        actual[art["path"]] = digest

        if digest == art["sha256"]:
            print(f"  {GREEN}frozen {RESET}  {art['path']}  {DIM}{digest[:16]}...{RESET}")
            if args.verbose:
                print(f"           {DIM}{art['governs']}{RESET}")
        else:
            moved.append((art, digest))
            print(f"  {RED}MOVED  {RESET}  {art['path']}")
            print(f"           {DIM}recorded:{RESET} {art['sha256'][:16]}...")
            print(f"           {DIM}on disk :{RESET} {digest[:16]}...")
            print(f"           {YELLOW}governs:{RESET} {art['governs']}")
            print(f"           {YELLOW}why it matters:{RESET} {art['why_it_must_not_move']}")

    # Some artifacts are asserted to be byte-identical to another file. That is a
    # claim in its own right - the "before ablation" snapshot is only evidence
    # while it still matches what shipped.
    for art in artifacts:
        twin = art.get("must_match")
        if not twin:
            continue
        a, b = actual.get(art["path"]), actual.get(twin)
        if a is None or b is None:
            continue
        if a == b:
            print(f"  {GREEN}paired {RESET}  {art['path']} {DIM}== {twin}{RESET}")
        else:
            pairs.append((art, twin))
            print(f"  {RED}DIVERGED{RESET} {art['path']} {DIM}!= {twin}{RESET}")
            print(f"           {YELLOW}{art['why_it_must_not_move']}{RESET}")

    if args.update:
        if not moved:
            print(f"\n{GREEN}Nothing to update.{RESET}\n")
            return 0
        print(f"\n{YELLOW}--update rewrites {len(moved)} recorded hash(es).{RESET}")
        print("Only do this for a change that was decided BEFORE anyone saw a result")
        print("it would flatter, and say what moved in the same commit.")
        reply = input("Type 'amend' to continue: ").strip()
        if reply != "amend":
            print(f"{DIM}Left unchanged.{RESET}\n")
            return 1
        for art, digest in moved:
            for entry in manifest["artifacts"]:
                if entry["path"] == art["path"]:
                    entry["sha256"] = digest
        MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                            encoding="utf-8")
        print(f"{YELLOW}Manifest updated. Record WHY in the commit message.{RESET}\n")
        return 0

    problems = len(moved) + len(missing) + len(pairs)
    if problems:
        print(f"\n{RED}FAIL{RESET} - {problems} frozen artifact(s) moved, missing or diverged.")
        print("This is a question, not a verdict: what changed, when, and was it")
        print("decided before or after someone saw the number it affects? If after,")
        print("re-run the measurement rather than updating the hash.\n")
        return 1

    print(f"\n{GREEN}FROZEN{RESET} - every pre-registered contract matches its "
          f"recorded hash.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
