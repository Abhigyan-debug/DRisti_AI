#!/usr/bin/env python3
"""
Prove the claim checker still catches things.

A linter that has quietly stopped matching anything passes every run and reports
CLEAN forever, which is strictly worse than having no linter - it manufactures
confidence. So every rule gets two cases here: text that MUST trip it, and text
that MUST NOT.

The "must trip" cases are not invented. They are the actual sentences that were
sitting in this repository on the morning of 2026-09-13, after the calibration
correction had been applied to eight files and missed in three. If a future edit
to config/claim_rules.json stops catching them, this test fails and says so.

Runs without MATLAB and without touching a dataset.

Usage
    python tools/test_check_claims.py          # exit 0 = the checker works
    python -m unittest discover -s tools       # same, via unittest
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_claims as cc  # noqa: E402

CFG = json.loads(cc.RULES.read_text(encoding="utf-8"))


def findings(text: str, filename: str = "sample.md") -> list[str]:
    """Rule ids that fire on a snippet, as the checker would see it in a file."""
    bs = cc.blocks(text)
    out = cc.check_rules(CFG, Path(filename), bs)
    return [f.rule_id for f in out]


def protocol_findings(text: str) -> list[str]:
    return [f.rule_id for f in cc.check_protocol(CFG, Path("sample.md"), cc.blocks(text))]


class MustCatch(unittest.TestCase):
    """Text that was really in the repo, or a near miss of it."""

    def test_the_sentence_that_was_missed(self):
        # docs/speaking_script.md, as it stood until 2026-09-13.
        text = ("The fix is per-site calibration. About 200 locally labelled images "
                "from that specific centre. Sensitivity goes from 31% back up to 90%.")
        self.assertIn("calibration-reaches-90", findings(text))

    def test_claim_wrapped_across_lines(self):
        # The same claim as it was actually typeset - the wrap is the whole
        # reason this checker matches blocks instead of lines.
        text = ("> The fix is per-site calibration. About 200 locally labelled images from that\n"
                "> specific centre. Sensitivity goes from 31% back up\n"
                "> to 90%.\n")
        self.assertIn("calibration-reaches-90", findings(text))

    def test_restores_90_in_qa_answer(self):
        text = ("We measured it, diagnosed it as a calibration problem and not a model "
                "problem, and the fix restores 90%.")
        self.assertIn("calibration-reaches-90", findings(text))

    def test_arrow_form(self):
        text = "Per-site calibration on ~200 local images: **31.2% -> 90.0%** on Messidor-2."
        self.assertIn("messidor-31-to-90-arrow", findings(text))

    def test_deployment_pull_quote(self):
        # docs/phase3_results.md section 3b, caught by this tool on its first run.
        text = ("used to fit the operating point, frozen before clinical use, and never "
                "reused for evaluation. That recovers 90% sensitivity on the benchmark "
                "where the uncalibrated system reached 31%.")
        self.assertIn("calibration-reaches-90", findings(text))

    def test_superseded_lesion_figures(self):
        for snippet, rule in [
            ("Microaneurysm detection reaches precision 0.046 on the held-out split.",
             "ma-precision-pre-rebuild"),
            ("Haemorrhage precision 0.130 against expert masks.",
             "he-precision-pre-rebuild"),
        ]:
            with self.subTest(rule=rule):
                self.assertIn(rule, findings(snippet))

    def test_sub_30_second_review_claimed_as_achieved(self):
        text = "The report format achieves sub-30-second review by a trained grader."
        self.assertIn("sub-30-second-review-achieved", findings(text))

    def test_validated_explainability(self):
        text = "Module 4 ships validated explainability via Grad-CAM overlays."
        self.assertIn("validated-explainability", findings(text))

    def test_research_paper_as_benchmark(self):
        text = "We compare against the benchmark in Research Paper.pdf, which reports 94.3%."
        self.assertIn("research-paper-as-benchmark", findings(text))

    def test_unverified_citation_presented_as_a_source(self):
        # simulink/screening_params.m carried these under the heading
        # "Sources & literature grounding" until 2026-09-13 (blocker B11).
        text = ("Sources: Sankara Nethralaya Rural Tele-screening Model "
                "(Rani et al., Eye 2021): PHC non-mydriatic screening.")
        self.assertIn("unverified-telemedicine-citations", findings(text))

    def test_metric_without_protocol(self):
        text = "Referable DR: sensitivity 90.3%, specificity 95.9%."
        self.assertIn("metric-without-protocol", protocol_findings(text))


class MustNotCatch(unittest.TestCase):
    """Correct writing must pass, or people will learn to ignore the tool."""

    def test_a_passage_that_disowns_the_claim(self):
        # docs/site_calibration.md section 4 - names the banned figure to ban it.
        text = ("**May NOT be said.** That calibration takes Messidor-2 from 31.2% to "
                "90.0%. That 90.0% / 57.9% pair comes from a post-hoc demonstration on "
                "Messidor-2 itself.")
        self.assertEqual([], findings(text))

    def test_negated_explainability(self):
        text = "Grad-CAM enrichment is 1.51x - above chance, *not* validated explainability."
        self.assertEqual([], findings(text))

    def test_negation_split_across_fprintf_calls(self):
        # demo/run_demo.m prints this as one sentence across two fprintf calls.
        text = ("    fprintf('      - Grad-CAM lesion enrichment 1.51x: above chance, NOT\\n');\n"
                "    fprintf('        validated explainability. No ophthalmologist has rated it.\\n');\n")
        self.assertEqual([], findings(text, "run_demo.m"))

    def test_superseded_figure_with_a_marker(self):
        text = "MA precision was previously 0.046; it is 0.028 after the rebuild."
        self.assertEqual([], findings(text))

    def test_superseded_table_with_caveat_in_the_next_block(self):
        # phase3_results.md section 3e - the caveat sits UNDER the table.
        text = ("| Microaneurysms | + classifier (threshold 0.5) | 0.135 | 0.054 | 2.6x |\n"
                "\n"
                "> **Update 2026-09-13 - the table above is SUPERSEDED; do not quote it.**\n")
        self.assertEqual([], findings(text))

    def test_no_context_bleed_between_table_rows(self):
        # A haemorrhage row must not trip a microaneurysm rule just because an
        # earlier row in the same table said "microaneurysms".
        text = ("| microaneurysms | precision | 0.028 | ok |\n"
                "| haemorrhages | precision | 0.164 | ok |\n")
        self.assertEqual([], findings(text))

    def test_a_blocker_entry_may_name_the_bad_citation(self):
        # docs/PROJECT_STATUS.md B11 exists precisely to name these.
        text = ('- *"Rani et al., Eye 2021"* (Sankara Nethralaya) - not found. '
                "The real Sankara Nethralaya paper appears to be John et al., 2012.")
        self.assertEqual([], findings(text))

    def test_target_language_is_not_a_claim(self):
        text = "Target Sens > 90%, Spec > 85% - deliberately above the IDx-DR point."
        self.assertEqual([], findings(text))

    def test_in_domain_90_is_not_the_calibration_claim(self):
        text = "On in-domain APTOS validation the grader reaches 90.3% sensitivity (n=733)."
        self.assertEqual([], findings(text))
        self.assertEqual([], protocol_findings(text))


class RulebookIntegrity(unittest.TestCase):
    """The rules file is a contract; keep it loadable and well-formed."""

    def test_every_rule_has_a_reason_and_a_remedy(self):
        for category in ("forbidden", "superseded"):
            for rule in CFG[category]:
                with self.subTest(rule=rule.get("id")):
                    self.assertTrue(rule.get("id"))
                    self.assertTrue(rule.get("reason"), "a rule must say why")
                    self.assertTrue(rule.get("instead"), "a rule must say what to say instead")

    def test_every_pattern_compiles(self):
        import re
        pats = ([r["pattern"] for r in CFG["forbidden"]]
                + [r["pattern"] for r in CFG["superseded"]]
                + [r.get("context") for r in CFG["superseded"]]
                + CFG["disavowal_markers"] + CFG["supersession_markers"]
                + CFG["protocol_check"]["protocol_tokens"])
        for p in [p for p in pats if p]:
            with self.subTest(pattern=p):
                re.compile(p)

    def test_no_marker_lost_its_backslashes(self):
        # JSON escapes \b as backspace. A marker carrying a literal backspace is
        # a word-boundary regex that got mangled on a round-trip through a
        # json.dumps, and it will silently never match.
        for m in CFG["disavowal_markers"] + CFG["supersession_markers"]:
            with self.subTest(marker=m):
                self.assertNotIn("\b", m)

    def test_rule_ids_are_unique(self):
        ids = [r["id"] for r in CFG["forbidden"]] + [r["id"] for r in CFG["superseded"]]
        self.assertEqual(len(ids), len(set(ids)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
