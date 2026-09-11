#!/usr/bin/env python3
"""
R3 - measure what a DR-only referral rule would miss.

Cross-tabulates IDRiD's 'Retinopathy grade' against 'Risk of macular edema' and
reports how many patients are referable under the DME clause but NOT under the
DR clause. That number is the empirical cost of excluding DME from the referable
definition - the open item in docs/clinical_definitions.md section 5.

Reads two ~24 KB CSVs. No images, no MATLAB, no toolboxes.

Usage
    python tools/idrid_dme_crosstab.py
    python tools/idrid_dme_crosstab.py --data-root D:/DRishti_AI_data --markdown
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_setup import REPO_ROOT, resolve_data_root  # noqa: E402

DEFS = REPO_ROOT / "config" / "clinical_definitions.json"

SPLITS = {
    "train": "idrid/grading/2. Groundtruths/a. IDRiD_Disease Grading_Training Labels.csv",
    "test": "idrid/grading/2. Groundtruths/b. IDRiD_Disease Grading_Testing Labels.csv",
}


def find_column(fieldnames: list[str], *needles: str) -> str:
    """IDRiD's headers carry stray whitespace and inconsistent casing - match loosely."""
    for name in fieldnames:
        if name and any(n in name.lower() for n in needles):
            return name
    raise KeyError(f"no column matching {needles} in {fieldnames}")


def load(path: Path) -> list[tuple[int, int]]:
    """Return (dr_grade, dme_grade) pairs, skipping blank trailing rows."""
    with path.open(encoding="utf-8-sig", newline="") as fh:
        reader = csv.DictReader(fh)
        dr_col = find_column(reader.fieldnames or [], "retinopathy")
        dme_col = find_column(reader.fieldnames or [], "edema", "oedema", "macular")
        pairs = []
        for row in reader:
            dr, dme = (row.get(dr_col) or "").strip(), (row.get(dme_col) or "").strip()
            if dr and dme:
                pairs.append((int(dr), int(dme)))
    return pairs


def report(split: str, pairs: list[tuple[int, int]], dme_referable: int, markdown: bool) -> dict:
    n = len(pairs)
    ct = Counter(pairs)
    dr_only = sum(v for (dr, _), v in ct.items() if dr >= 2)
    dme_pos = sum(v for (_, dme), v in ct.items() if dme >= dme_referable)
    both = sum(v for (dr, dme), v in ct.items() if dr >= 2 and dme >= dme_referable)
    missed = dme_pos - both          # referable via DME, invisible to a DR-only rule
    combined = dr_only + missed

    bar = "|" if markdown else " "
    print(f"\n### IDRiD {split} (n={n})\n" if markdown else f"\n--- IDRiD {split} (n={n}) ---")
    head = ["DR grade", "DME 0", "DME 1", "DME 2", "total"]
    print(f"{bar} " + f" {bar} ".join(head) + f" {bar}" if markdown else "  ".join(f"{h:>9}" for h in head))
    if markdown:
        print("|" + "---|" * len(head))
    for dr in range(5):
        cells = [ct.get((dr, dme), 0) for dme in range(3)]
        row = [str(dr), *(str(c) for c in cells), str(sum(cells))]
        print(f"{bar} " + f" {bar} ".join(row) + f" {bar}" if markdown else "  ".join(f"{c:>9}" for c in row))

    pct = lambda x: f"{100 * x / n:.1f}%" if n else "-"
    print()
    rows = [
        (f"referable, DR-only rule (DR>=2)", dr_only),
        (f"DME-referable (DME>={dme_referable})", dme_pos),
        ("both", both),
        (">> MISSED by a DR-only rule (DME-only referrals)", missed),
        (f"referable, combined rule (DR>=2 OR DME>={dme_referable})", combined),
    ]
    width = max(len(label) for label, _ in rows)
    for label, value in rows:
        print(f"  {label:<{width}} : {value:4d}  ({pct(value)})")

    return {"n": n, "dr_only": dr_only, "dme_referable": dme_pos,
            "both": both, "missed_by_dr_only": missed, "combined": combined}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-root", type=Path, default=None)
    ap.add_argument("--markdown", action="store_true", help="emit tables ready to paste into docs/")
    args = ap.parse_args()

    # The DME grade that counts as referable comes from the frozen clinical contract,
    # never from a literal here - see project hard rule 3.
    rule = json.loads(DEFS.read_text(encoding="utf-8"))["endpoints"]["primary_referable"]["rule"]
    dme_referable = int(rule.split("dme_grade >=")[1].strip().rstrip(")")) if "dme_grade >=" in rule else 2
    print(f"referable rule (from config/clinical_definitions.json): {rule}")

    root = resolve_data_root(args.data_root)
    results = {}
    for split, rel in SPLITS.items():
        path = root / rel
        if not path.is_file():
            print(f"\nMISSING: {path}\n"
                  f"  IDRiD grading labels are not on this machine. This script needs only\n"
                  f"  that one CSV - no images. See docs/datasets.md section 1.", file=sys.stderr)
            return 1
        results[split] = report(split, load(path), dme_referable, args.markdown)

    total_missed = sum(r["missed_by_dr_only"] for r in results.values())
    total_n = sum(r["n"] for r in results.values())
    print(f"\nAcross both splits: {total_missed}/{total_n} "
          f"({100 * total_missed / total_n:.1f}%) of patients are referable ONLY via DME.")
    print("Paste the tables above into docs/clinical_definitions.md section 5.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
