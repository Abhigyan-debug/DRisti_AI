#!/usr/bin/env python3
"""
Enforce the honesty rules in CLAUDE.md mechanically.

WHY THIS EXISTS
---------------
On 2026-09-13 the calibration result was corrected everywhere - CLAUDE.md,
PROJECT_STATUS.md, site_calibration.md, three phase write-ups and the README -
and the presentation script was missed. It still told a presenter to say
"sensitivity goes from 31% back up to 90%", which is the one sentence the
project had explicitly banned. Three source files were also still quoting
lesion precisions that had been re-measured hours earlier.

Nothing was careless about that. It is what happens when a rule lives only in
prose: propagating a correction by hand across 40 files is a task humans lose,
and the file that gets missed is the one nobody re-reads - which, for a
presentation script, is the worst possible one to miss.

So the rules are data now, in config/claim_rules.json, and this checks them.

THE ENGINE IN ONE SENTENCE
--------------------------
A banned or superseded number may appear only inside a passage that disowns it.

That is the policy a careful writer already follows, so the checker agrees with
good prose instead of fighting it: section 4 of docs/site_calibration.md names
the banned 90.0% figure repeatedly and passes clean, because every mention is a
prohibition. A slide that quotes it as an achievement does not.

Matching is per BLOCK - a blank-line-separated paragraph or comment run,
whitespace-normalised - so a claim that wraps across two lines is still caught.
That is not a detail: the sentence that started all this wrapped mid-claim.

WHAT IT DOES NOT DO
-------------------
It reads repository text. It never opens a dataset, so it cannot burn the
held-out benchmark, and it needs no MATLAB. It cannot tell you whether a number
is TRUE - only whether it is one this project has already retired or banned.
Re-measuring is still the human's job; remembering is not.

Exit code 0 = clean, 1 = at least one violation. Safe to wire into CI.

Usage
    python tools/check_claims.py               # errors fail, protocol gaps warn
    python tools/check_claims.py --strict      # protocol gaps fail too
    python tools/check_claims.py --rules       # print the rulebook and exit
    python tools/check_claims.py --path docs   # check one subtree
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
RULES = REPO_ROOT / "config" / "claim_rules.json"

GREEN, RED, YELLOW, DIM, BOLD, RESET = (
    "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[1m", "\033[0m"
)
if os.name == "nt" and not os.environ.get("WT_SESSION"):
    os.system("")  # enable ANSI on legacy Windows terminals

# The claims we police are full of arrows and warning signs. A Windows console
# defaulting to cp1252 would crash the checker on its own output, which is a
# silly way for an honesty tool to fail closed.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

# A claim IMMEDIATELY preceded by a negation is not that claim - "NOT validated
# explainability" is the project saying the right thing, and flagging it would
# train everyone to ignore the checker.
#
# The window is deliberately tight, and no clause boundary may intervene. An
# earlier draft allowed 40 characters and any punctuation but a full stop, which
# let "diagnosed it as a calibration problem and not a model problem, and the fix
# restores 90%" off entirely - the "not" there negates "a model problem", not the
# claim. A negation that reaches across a comma is negating something else.
NEGATION = re.compile(
    r"\b(not|never|no|non|without|isn'?t|aren'?t|wasn'?t|doesn'?t|didn'?t|don'?t|"
    r"cannot|can'?t|fails?\s+to|far\s+from|rather\s+than|instead\s+of|"
    r"short\s+of|nor)\b[^.;,)]{0,25}$",
    re.IGNORECASE,
)


# --------------------------------------------------------------------------
# Blocks
# --------------------------------------------------------------------------

def join_printf_strings(text: str) -> str:
    """Glue a sentence that a MATLAB fprintf chain split across calls.

    run_demo.m prints 'above chance, NOT\\n' and then, in the very next call,
    'validated explainability'. A reader sees one sentence with a negation in
    it; a naive checker sees a banned phrase with a ');' in the way. Normalising
    the scaffolding away puts the checker at the level the CLINICIAN reads, which
    is the only level where the honesty rules mean anything.
    """
    # ...NOT\n'); fprintf('   validated...   ->   ...NOT validated...
    text = re.sub(r"\\n?'\s*\)\s*;?\s*\n?\s*fprintf\s*\(\s*'", " ", text)
    # ...NOT\n' ...   ->   trailing escape and quote before a line break
    text = re.sub(r"\\n'\s*\.\.\.\s*\n\s*'", " ", text)
    return text


def blocks(text: str) -> list[tuple[int, str]]:
    """Split into blank-line-separated blocks, whitespace-normalised.

    Returns (1-based start line, joined text). Claims wrap across lines in both
    prose and MATLAB comment banners, so a line-at-a-time checker would miss
    exactly the ones that matter. Leading comment and quote markers are stripped
    so that '> ' in a speaking script and '%   ' in a .m header normalise to the
    same shape.
    """
    text = join_printf_strings(text)
    out: list[tuple[int, str]] = []
    start, buf = 1, []
    for i, raw in enumerate(text.splitlines(), start=1):
        stripped = re.sub(r"^\s*([%#>]+|//|\*)\s?", "", raw).strip()
        if stripped:
            if not buf:
                start = i
            buf.append(stripped)
        elif buf:
            out.append((start, " ".join(buf)))
            buf = []
    if buf:
        out.append((start, " ".join(buf)))
    return out


def any_match(patterns: list[str], text: str) -> bool:
    return any(re.search(p, text, re.IGNORECASE) for p in patterns)


# How far either side of a match to look for the rule's context and for a
# marker. A whole block is too coarse for a markdown table: every row of the
# before/after table in phase2_results.md section 2a would otherwise inherit the
# word "microaneurysms" from the first row and match the wrong lesion's rule.
WINDOW = 150

# A table header or a lead-in sentence sits at the top of the block and governs
# every row under it, so markers are honoured there too.
LEAD_IN = 260


def violations(pattern: str, context: str | None, markers: list[str],
               extra_markers: list[str], text: str, neighbourhood: str = ""):
    """Yield each match of `pattern` in `text` that is a genuine violation.

    A match is excused when any of four things is true: a negation immediately
    precedes it, a marker sits in the local window around it, a marker sits in
    the block's lead-in, or a marker sits in an adjacent block. That is the
    policy in one function - you may name a banned number while disowning it,
    and only while disowning it.

    The adjacent-block allowance matters more than it sounds. Section 3e of
    phase3_results.md prints a superseded table and then, in the blockquote
    directly beneath it, says "the table above is SUPERSEDED; do not quote it".
    A caveat under a table governs that table - any checker that disagreed with
    that would be teaching people to write worse documents.
    """
    all_markers = markers + extra_markers
    for m in re.finditer(pattern, text, re.IGNORECASE):
        lo, hi = max(0, m.start() - WINDOW), min(len(text), m.end() + WINDOW)
        local = text[lo:hi]
        if context and not re.search(context, local, re.IGNORECASE):
            continue
        if NEGATION.search(text[max(0, m.start() - 70):m.start()]):
            continue
        if (any_match(all_markers, local)
                or any_match(all_markers, text[:LEAD_IN])
                or any_match(all_markers, neighbourhood)):
            continue
        yield m


# --------------------------------------------------------------------------
# File discovery
# --------------------------------------------------------------------------

def candidate_files(cfg: dict, root: Path) -> list[Path]:
    """Every text file the rules apply to, skipping data and generated trees."""
    scan = cfg["scan"]
    excl_dirs = {d.replace("/", os.sep) for d in scan["exclude_dirs"]}
    excl_files = set(scan["exclude_files"])
    found: list[Path] = []

    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = Path(dirpath).relative_to(REPO_ROOT).as_posix()
        # Prune: a junction into the dataset root must never be descended into.
        dirnames[:] = [
            d for d in dirnames
            if d not in excl_dirs
            and f"{rel_dir}/{d}".lstrip("./") not in {e.replace(os.sep, "/") for e in excl_dirs}
        ]
        for name in filenames:
            if not any(fnmatch.fnmatch(name, g) for g in scan["include_globs"]):
                continue
            p = Path(dirpath) / name
            rel = p.relative_to(REPO_ROOT).as_posix()
            if rel in excl_files:
                continue
            found.append(p)
    return sorted(found)


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

class Finding:
    def __init__(self, path: Path, line: int, rule_id: str, severity: str,
                 excerpt: str, reason: str, instead: str):
        self.path, self.line, self.rule_id = path, line, rule_id
        self.severity, self.excerpt = severity, excerpt
        self.reason, self.instead = reason, instead


def excerpt_at(text: str, m: re.Match, width: int = 96) -> str:
    """The matched claim plus a little context, so the message is actionable."""
    lo = max(0, m.start() - width // 3)
    hi = min(len(text), m.end() + width // 2)
    return ("..." if lo else "") + text[lo:hi].strip() + ("..." if hi < len(text) else "")


def excerpt_for(text: str, pattern: str, width: int = 96) -> str:
    """Excerpt around the first match of a pattern."""
    m = re.search(pattern, text, re.IGNORECASE)
    return excerpt_at(text, m, width) if m else text[:width]


def check_rules(cfg: dict, path: Path, bs: list[tuple[int, str]]) -> list[Finding]:
    found: list[Finding] = []
    disavowals = cfg["disavowal_markers"]
    supersessions = cfg["supersession_markers"]

    for category, markers, severity in (
        ("forbidden", disavowals, "error"),
        ("superseded", supersessions, "error"),
    ):
        for rule in cfg[category]:
            pat, ctx = rule["pattern"], rule.get("context")
            extra = rule.get("allowed_when", [])
            for i, (line, text) in enumerate(bs):
                # A caveat one block above or two below still governs this text.
                near = " ".join(t for _, t in bs[max(0, i - 1):i + 3] if t is not text)
                for m in violations(pat, ctx, markers, extra, text, near):
                    found.append(Finding(
                        path, line, rule["id"], severity,
                        excerpt_at(text, m), rule["reason"], rule["instead"],
                    ))
                    break  # one report per rule per block is enough to act on
    return found


def check_protocol(cfg: dict, path: Path, bs: list[tuple[int, str]]) -> list[Finding]:
    """Hard rule 3: a metric without its evaluation protocol is incomplete."""
    pc = cfg["protocol_check"]
    found: list[Finding] = []
    for i, (line, text) in enumerate(bs):
        if not re.search(pc["metric_pattern"], text, re.IGNORECASE):
            continue
        if not re.search(pc["number_pattern"], text):
            continue
        # A table's protocol is usually stated in the sentence or heading that
        # introduces it, not repeated in every row.
        near = " ".join(t for _, t in bs[max(0, i - 2):i + 2] if t is not text)
        if any_match(pc["protocol_tokens"], text) or any_match(pc["protocol_tokens"], near):
            continue
        found.append(Finding(
            path, line, "metric-without-protocol", "warning",
            excerpt_for(text, pc["number_pattern"]),
            "A metric is quoted with no split, dataset, n or threshold rule in the "
            "same passage. Published DRIVE numbers are famously incomparable for "
            "exactly this reason.",
            "Name the dataset and split, e.g. 'IDRiD segmentation TEST split, n=27, "
            "micro-averaged', or move the number next to a table header that does.",
        ))
    return found


# --------------------------------------------------------------------------

def print_rulebook(cfg: dict) -> int:
    print(f"\n{BOLD}Claim rulebook{RESET}  {DIM}config/claim_rules.json "
          f"v{cfg['version']}, updated {cfg['updated']}{RESET}\n")
    print(f"{BOLD}Claims that may only appear while being disowned{RESET}")
    for r in cfg["forbidden"]:
        print(f"  {RED}x{RESET} {BOLD}{r['id']}{RESET}\n    {DIM}{r['reason']}{RESET}\n"
              f"    {GREEN}instead:{RESET} {r['instead']}\n")
    print(f"{BOLD}Superseded figures - only with a marker saying they are old{RESET}")
    for r in cfg["superseded"]:
        print(f"  {YELLOW}~{RESET} {BOLD}{r['id']}{RESET}\n    {DIM}{r['reason']}{RESET}\n"
              f"    {GREEN}instead:{RESET} {r['instead']}\n")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--strict", action="store_true",
                    help="treat missing evaluation protocol as a failure too")
    ap.add_argument("--rules", action="store_true", help="print the rulebook and exit")
    ap.add_argument("--path", type=Path, default=None,
                    help="limit the scan to one file or subtree")
    ap.add_argument("--no-protocol", action="store_true",
                    help="skip the protocol check entirely")
    args = ap.parse_args()

    cfg = json.loads(RULES.read_text(encoding="utf-8"))
    if args.rules:
        return print_rulebook(cfg)

    root = (REPO_ROOT / args.path) if args.path and not args.path.is_absolute() else args.path
    root = root or REPO_ROOT

    print(f"\n{BOLD}DRishti-AI claim check{RESET}")
    print(f"  rules : {RULES.relative_to(REPO_ROOT)} "
          f"{DIM}(v{cfg['version']}, {cfg['updated']}){RESET}")
    print(f"  scope : {root if root != REPO_ROOT else 'whole repository'}\n")

    if root.is_file():
        files = [root]
    else:
        files = candidate_files(cfg, root)

    findings: list[Finding] = []
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        bs = blocks(text)
        findings += check_rules(cfg, path, bs)
        if not args.no_protocol:
            findings += check_protocol(cfg, path, bs)

    errors = [f for f in findings if f.severity == "error"]
    warnings = [f for f in findings if f.severity == "warning"]

    for f in errors + (warnings if args.strict else []):
        rel = f.path.relative_to(REPO_ROOT).as_posix()
        tag = f"{RED}CLAIM  {RESET}" if f.severity == "error" else f"{YELLOW}PROTOCOL{RESET}"
        print(f"  {tag}  {rel}:{f.line}  {DIM}[{f.rule_id}]{RESET}")
        print(f"           {f.excerpt}")
        print(f"           {DIM}why:{RESET} {f.reason}")
        print(f"           {GREEN}say:{RESET} {f.instead}\n")

    print(f"  {DIM}{len(files)} files checked{RESET}")

    if errors:
        print(f"\n{RED}FAIL{RESET} - {len(errors)} banned or superseded claim(s). "
              f"Fix the text, or add a marker if the passage is disowning the claim.")
        print(f"{DIM}Rulebook: python tools/check_claims.py --rules{RESET}\n")
        return 1

    if warnings and args.strict:
        print(f"\n{RED}FAIL{RESET} - {len(warnings)} metric(s) quoted without a protocol "
              f"(--strict).\n")
        return 1

    if warnings:
        print(f"\n{YELLOW}CLEAN{RESET} of banned claims, with {len(warnings)} protocol "
              f"warning(s). {DIM}Run --strict to see them.{RESET}\n")
        return 0

    print(f"\n{GREEN}CLEAN{RESET} - no banned or superseded claims, "
          f"every metric carries a protocol.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
