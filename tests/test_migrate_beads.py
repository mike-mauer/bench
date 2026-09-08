#!/usr/bin/env python3
"""Tests for plugins/bench/scripts/migrate-beads-to-issues.py.

Run: python3 -m unittest tests.test_migrate_beads -v   (from the repo root)
or:  python3 tests/test_migrate_beads.py

No network, no gh: only the dry-run code path (pure functions + `main()`
without --apply) is exercised.
"""
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "plugins" / "bench" / "scripts" / "migrate-beads-to-issues.py"
FIXTURE = REPO_ROOT / "tests" / "fixtures" / "beads-issues.sample.jsonl"

spec = importlib.util.spec_from_file_location("migrate_beads_to_issues", SCRIPT)
migrate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migrate)


class FieldMappingTests(unittest.TestCase):
    def test_issue_type_maps_to_github_labels(self):
        self.assertEqual(migrate.issue_type_label({"issue_type": "bug"}), "bug")
        self.assertEqual(migrate.issue_type_label({"issue_type": "feature"}), "enhancement")
        self.assertEqual(migrate.issue_type_label({"issue_type": "task"}), "task")
        self.assertEqual(migrate.issue_type_label({"issue_type": "chore"}), "chore")
        self.assertEqual(migrate.issue_type_label({"issue_type": "epic"}), "type:epic")
        self.assertEqual(migrate.issue_type_label({}), "task")  # default

    def test_priority_maps_to_priority_label(self):
        self.assertEqual(migrate.priority_label({"priority": 0}), "priority:p0")
        self.assertEqual(migrate.priority_label({"priority": 4}), "priority:p4")
        self.assertIsNone(migrate.priority_label({}))

    def test_beads_labels_pass_through(self):
        rec = {"issue_type": "bug", "priority": 2, "labels": ["plain", "lane:ui"]}
        labels = migrate.build_labels(rec)
        self.assertEqual(labels, ["bug", "priority:p2", "plain", "lane:ui"])

    def test_title_carried_verbatim(self):
        plan = migrate.build_plan(
            [{"id": "X-1", "status": "open", "title": "Fix the thing", "issue_type": "bug"}],
            include_closed=False,
        )
        self.assertEqual(plan[0]["title"], "Fix the thing")


class DependencyMappingTests(unittest.TestCase):
    def test_blocks_edge_becomes_blocked_by(self):
        records = [
            {"id": "A", "status": "open", "title": "a", "issue_type": "task"},
            {
                "id": "B", "status": "open", "title": "b", "issue_type": "task",
                "dependencies": [{"depends_on_id": "A", "type": "blocks"}],
            },
        ]
        plan = migrate.build_plan(records, include_closed=False)
        by_id = {p["beads_id"]: p for p in plan}
        self.assertEqual(by_id["B"]["blocked_by"], ["A"])
        self.assertIn("## Blocked by", by_id["B"]["body"])
        self.assertIn("- A", by_id["B"]["body"])

    def test_closed_blocker_is_dropped(self):
        records = [
            {"id": "A", "status": "closed", "title": "a", "issue_type": "task"},
            {
                "id": "B", "status": "open", "title": "b", "issue_type": "task",
                "dependencies": [{"depends_on_id": "A", "type": "blocks"}],
            },
        ]
        plan = migrate.build_plan(records, include_closed=False)
        by_id = {p["beads_id"]: p for p in plan}
        self.assertEqual(by_id["B"]["blocked_by"], [])
        self.assertNotIn("## Blocked by", by_id["B"]["body"])

    def test_related_and_discovered_from_are_not_blockers(self):
        records = [
            {"id": "A", "status": "open", "title": "a", "issue_type": "task"},
            {
                "id": "B", "status": "open", "title": "b", "issue_type": "task",
                "dependencies": [
                    {"depends_on_id": "A", "type": "related"},
                    {"depends_on_id": "A", "type": "discovered-from"},
                ],
            },
        ]
        plan = migrate.build_plan(records, include_closed=False)
        by_id = {p["beads_id"]: p for p in plan}
        self.assertEqual(by_id["B"]["blocked_by"], [])

    def test_parent_child_edge_sets_parent_not_blocked_by(self):
        records = [
            {"id": "P", "status": "open", "title": "parent", "issue_type": "epic"},
            {
                "id": "P.1", "status": "open", "title": "child", "issue_type": "task",
                "dependencies": [{"depends_on_id": "P", "type": "parent-child"}],
            },
        ]
        plan = migrate.build_plan(records, include_closed=False)
        by_id = {p["beads_id"]: p for p in plan}
        self.assertEqual(by_id["P.1"]["parent"], "P")
        self.assertEqual(by_id["P.1"]["blocked_by"], [])

    def test_dotted_id_falls_back_to_parent_when_no_edge(self):
        records = [
            {"id": "P", "status": "open", "title": "parent", "issue_type": "epic"},
            {"id": "P.2", "status": "open", "title": "child", "issue_type": "task"},
        ]
        plan = migrate.build_plan(records, include_closed=False)
        by_id = {p["beads_id"]: p for p in plan}
        self.assertEqual(by_id["P.2"]["parent"], "P")

    def test_parent_before_child_in_order(self):
        records = [
            {
                "id": "C", "status": "open", "title": "child", "issue_type": "task",
                "dependencies": [{"depends_on_id": "P", "type": "parent-child"}],
            },
            {"id": "P", "status": "open", "title": "parent", "issue_type": "epic"},
        ]
        plan = migrate.build_plan(records, include_closed=False)
        order = [p["beads_id"] for p in plan]
        self.assertLess(order.index("P"), order.index("C"))


class DryRunAndCliTests(unittest.TestCase):
    def _run(self, *extra_args):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--file", str(FIXTURE), *extra_args],
            capture_output=True, text=True, check=True,
        )
        return json.loads(result.stdout)

    def test_dry_run_is_the_default_and_prints_json_plan(self):
        plan = self._run()
        self.assertIsInstance(plan, list)
        self.assertGreater(len(plan), 0)
        for item in plan:
            self.assertEqual(
                set(item.keys()),
                {"beads_id", "title", "labels", "body", "blocked_by", "parent"},
            )
            self.assertIsInstance(item["labels"], list)
            self.assertIsInstance(item["blocked_by"], list)
            self.assertIsInstance(item["body"], str)

    def test_dry_run_excludes_closed_by_default(self):
        plan = self._run()
        ids = {item["beads_id"] for item in plan}
        # Bench-rm4 is closed in the fixture and must be excluded by default.
        self.assertNotIn("Bench-rm4", ids)
        self.assertIn("Bench-cz6", ids)  # in_progress — included

    def test_include_closed_adds_closed_records(self):
        plan = self._run("--include-closed")
        ids = {item["beads_id"] for item in plan}
        self.assertIn("Bench-rm4", ids)

    def test_missing_file_exits_nonzero(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--file", "/no/such/file.jsonl"],
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
