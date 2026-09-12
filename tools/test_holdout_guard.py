#!/usr/bin/env python3
"""
Check statically that every entry point still guards the held-out benchmark.

WHY A PYTHON TEST FOR MATLAB CODE
---------------------------------
The MATLAB suite can only run where MATLAB is installed, which is one machine.
This invariant is too important to be checked only there - and it is a property
of the SOURCE, not of a run, so reading the files is a legitimate way to check
it. R3 and R5 can run this; so can CI.

WHAT IT PROTECTS
----------------
Messidor-2 is the held-out external benchmark and the whole headline claim rests
on it having been read exactly once. It was read on 2026-09-12. A held-out set
is not destroyed by intent, it is destroyed by ACCESS - silently, with no error,
no failing test and no visible symptom. The only defence is that every path
reaching IMREAD passes a guard first.

That defence has already failed once in this repository. RUNDRISHTISYSTEM
guarded the batch it was about to process and then called RUNDRISHTIPIPELINE,
which is itself a public entry point ("image in, screening decision out") and
reached IMREAD with nothing in the way. A direct call with a Messidor-2 path
would have read the benchmark. ASSERTNOTHOLDOUT's own docstring listed
RUNDRISHTIPIPELINE under "See also" as though it were covered.

So this test enumerates the guarded entry points explicitly. Adding a new one
means adding it here, which is the point: the list is the contract.

Runs without MATLAB and without touching a dataset - it never opens the images
it is protecting.

Usage
    python tools/test_holdout_guard.py
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

# Every function that can be handed an arbitrary image path by a user, directly
# or through a file picker. Each must call ASSERTNOTHOLDOUT before it reads.
GUARDED_ENTRY_POINTS = [
    "src/runDrishtiPipeline.m",   # single image - "the whole system"
    "src/runDrishtiSystem.m",     # batch
    "src/app/drishtiDashboard.m",  # file picker: two clicks into the dataset
    "src/app/drishtiServeLoop.m",  # web upload queue
]

GUARD = "assertNotHoldout"
SPENT_RESULT = "messidor2_external_validation.mat"


def source(rel: str) -> str:
    return (REPO_ROOT / rel).read_text(encoding="utf-8", errors="replace")


def strip_comments(text: str) -> str:
    """Drop MATLAB comment lines, so a mention in a docstring never counts."""
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("%"))


class HoldoutGuard(unittest.TestCase):

    def test_every_entry_point_calls_the_guard(self):
        for rel in GUARDED_ENTRY_POINTS:
            with self.subTest(entry_point=rel):
                path = REPO_ROOT / rel
                self.assertTrue(path.is_file(), f"{rel} is missing")
                code = strip_comments(source(rel))
                self.assertIn(
                    GUARD, code,
                    f"{rel} can receive a user-supplied image path but never calls "
                    f"{GUARD}. A Messidor-2 path would reach imread unguarded, and "
                    f"the holdout would be spent silently.",
                )

    def test_the_guard_runs_before_the_read(self):
        # Guarding after imread would be theatre: the bytes are already read.
        for rel in GUARDED_ENTRY_POINTS:
            code = strip_comments(source(rel))
            if "imread(" not in code:
                continue  # dispatches to another guarded function
            with self.subTest(entry_point=rel):
                self.assertLess(
                    code.index(GUARD), code.index("imread("),
                    f"In {rel} the first {GUARD} call comes after the first "
                    f"imread. Guard before reading, not after.",
                )

    def test_the_guard_itself_matches_messidor_paths(self):
        code = source("src/utils/assertNotHoldout.m")
        self.assertIn("messidor", code.lower())
        self.assertIn("error(", code, "the guard must raise, not warn")

    def test_the_one_shot_evaluator_knows_the_shot_is_spent(self):
        # evaluateMessidor2's original `confirm` flag meant "are you sure you
        # want to spend this?" - which stopped meaning anything on 2026-09-12,
        # when it was spent. It must now refuse on the EVIDENCE of the read,
        # not on anyone remembering that it happened.
        code = strip_comments(source("src/grading/evaluateMessidor2.m"))
        self.assertIn(SPENT_RESULT, code,
                      "evaluateMessidor2 does not check whether the saved result "
                      "already exists, so confirm:true would spend the holdout twice")
        self.assertIn("isfile(", code)
        self.assertRegex(code, r"error\(\s*'drishti:holdoutAlreadySpent'",
                         "the already-spent refusal is missing")

    def test_analysis_path_exists_and_does_no_inference(self):
        # The refusal above is only reasonable because there is a supported way
        # to study that run without re-reading the images.
        code = source("src/grading/analyseFailureCases.m")
        self.assertIn(SPENT_RESULT, code)
        stripped = strip_comments(code)
        self.assertNotIn("imread(", stripped,
                         "analyseFailureCases must read saved scores, never images")
        self.assertNotIn("predict(", stripped,
                         "analyseFailureCases must perform no inference")

    def test_no_entry_point_hardcodes_a_messidor_path(self):
        for rel in GUARDED_ENTRY_POINTS + ["src/grading/analyseFailureCases.m"]:
            with self.subTest(file=rel):
                code = strip_comments(source(rel))
                # A literal quoted path into the dataset would bypass the intent
                # of the guard entirely. Match only a real path fragment - the
                # separator must follow "messidor" almost immediately, and the
                # literal may not span a line. A looser pattern matched prose
                # like "not a Messidor-2 result.</span>" on the strength of the
                # slash in a closing HTML tag.
                self.assertIsNone(
                    re.search(r"messidor[^'\"\n]{0,3}[/\\]", code, re.IGNORECASE),
                    f"{rel} appears to hardcode a path inside the Messidor-2 tree",
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
