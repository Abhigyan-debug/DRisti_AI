#!/usr/bin/env python3
"""
Prove the freeze checker still detects tampering.

Same argument as tools/test_check_claims.py: a verifier that has quietly stopped
comparing anything reports FROZEN forever, which is worse than no verifier
because it launders an unchecked claim into a checked-looking one.

The decisive case is the one this project would actually suffer: someone lowers
the lesion display gate from 0.50 precision to 0.10 so the three hidden channels
would pass it. That is a one-character edit to a JSON file, it changes no code,
it breaks no test, and it would put microaneurysm counts at 0.028 precision in
front of a clinician. The freeze check must catch it.

Runs without MATLAB and without touching a dataset. Works on a copy in a temp
directory - it never writes to the real config/.

Usage
    python tools/test_verify_freeze.py
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify_freeze as vf  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[1]


class FreezeVerification(unittest.TestCase):

    def setUp(self):
        self.manifest = json.loads(vf.MANIFEST.read_text(encoding="utf-8"))
        self.tmp = Path(tempfile.mkdtemp(prefix="drishti-freeze-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def copy_of(self, rel: str) -> Path:
        dst = self.tmp / Path(rel).name
        shutil.copyfile(REPO_ROOT / rel, dst)
        return dst

    # -- the real thing ----------------------------------------------------

    def test_every_artifact_matches_its_recorded_hash(self):
        for art in self.manifest["artifacts"]:
            with self.subTest(path=art["path"]):
                path = REPO_ROOT / art["path"]
                self.assertTrue(path.is_file(), f"{art['path']} is missing")
                self.assertEqual(
                    art["sha256"], vf.sha256_of(path),
                    f"{art['path']} does not match its recorded hash. Line endings "
                    f"are part of the hash - check .gitattributes before anything else.",
                )

    def test_paired_artifacts_are_byte_identical(self):
        for art in self.manifest["artifacts"]:
            twin = art.get("must_match")
            if not twin:
                continue
            with self.subTest(pair=(art["path"], twin)):
                self.assertEqual(vf.sha256_of(REPO_ROOT / art["path"]),
                                 vf.sha256_of(REPO_ROOT / twin))

    # -- tampering must be detected ---------------------------------------

    def test_loosening_the_display_gate_is_detected(self):
        # The failure this tool exists for: drop the precision bar so the three
        # hidden lesion channels would pass it.
        rel = "config/lesion_validation_thresholds.json"
        recorded = next(a["sha256"] for a in self.manifest["artifacts"]
                        if a["path"] == rel)
        copy = self.copy_of(rel)
        text = copy.read_text(encoding="utf-8")
        self.assertIn('"displayPrecisionMin": 0.50', text,
                      "the gate no longer reads 0.50 - update this test deliberately")
        copy.write_bytes(text.replace('"displayPrecisionMin": 0.50',
                                      '"displayPrecisionMin": 0.10').encode("utf-8"))
        self.assertNotEqual(recorded, vf.sha256_of(copy))

    def test_a_single_character_change_is_detected(self):
        rel = "config/clinical_definitions.json"
        recorded = next(a["sha256"] for a in self.manifest["artifacts"]
                        if a["path"] == rel)
        copy = self.copy_of(rel)
        copy.write_bytes(copy.read_bytes() + b" ")
        self.assertNotEqual(recorded, vf.sha256_of(copy))

    def test_line_ending_conversion_changes_the_hash(self):
        # Not a bug - a documented property, and the reason .gitattributes pins
        # config/*.json to eol=lf. If this ever stops being true the manifest's
        # line-ending warning is wrong and should be removed.
        rel = "config/lesion_validation_thresholds.json"
        copy = self.copy_of(rel)
        lf = copy.read_bytes()
        self.assertNotIn(b"\r\n", lf, "the repo copy should be LF; check .gitattributes")
        copy.write_bytes(lf.replace(b"\n", b"\r\n"))
        self.assertNotEqual(vf.sha256_of(copy), vf.sha256_of(REPO_ROOT / rel))

    # -- manifest integrity ------------------------------------------------

    def test_every_entry_says_why_it_matters(self):
        for art in self.manifest["artifacts"]:
            with self.subTest(path=art.get("path")):
                for field in ("path", "sha256", "frozen", "governs",
                              "why_it_must_not_move", "documented_in"):
                    self.assertTrue(art.get(field), f"{field} missing")
                self.assertEqual(64, len(art["sha256"]), "not a SHA-256 digest")

    def test_documented_in_targets_exist(self):
        for art in self.manifest["artifacts"]:
            with self.subTest(path=art["path"]):
                self.assertTrue((REPO_ROOT / art["documented_in"]).is_file(),
                                f"{art['documented_in']} does not exist")


if __name__ == "__main__":
    unittest.main(verbosity=2)
