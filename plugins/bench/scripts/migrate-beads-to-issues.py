#!/usr/bin/env python3
"""migrate-beads-to-issues.py — one-off migration from a beads issues.jsonl
export to GitHub Issues, per docs/factory-protocol.md §4. stdlib only.

Reads open/in_progress beads records (closed ones too with --include-closed)
and maps each to a GitHub issue (title, protocol-shaped body, labels). Beads
dependency edges become a `## Blocked by` body section plus parent/child
sub-issue links.

Modes:
  --dry-run (default)  print the plan as JSON, create nothing.
  --apply              create the issues with `gh issue create`, in
                       dependency order; write a beads-id -> issue-number
                       mapping file; then rewrite each body's `## Blocked by`
                       beads-ids to `#<number>` and set the native sub-issue /
                       blocked-by edges via scripts/gh-issue-dep.sh.

Mapping decisions (the beads schema leaves these open, so pin them here):
  - issue_type -> bug/enhancement/task/chore/type:epic (ISSUE_TYPE_LABELS).
  - priority (0-4) -> priority:pN.
  - beads `labels` are copied through verbatim as extra GitHub labels.
  - a dependency counts toward `## Blocked by` only when type == "blocks" and
    the blocker isn't itself closed (closed = not a live constraint anymore).
    "related" / "discovered-from" are informational and dropped.
  - parent: a "parent-child" dependency edge first, then an explicit `parent`
    field, then the dotted-id convention ("Bench-nfh.1" -> parent "Bench-nfh").
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ISSUE_TYPE_LABELS = {
    "bug": "bug",
    "feature": "enhancement",
    "enhancement": "enhancement",
    "task": "task",
    "chore": "chore",
    "epic": "type:epic",
}

OPEN_STATUSES = {"open", "in_progress"}


def load_records(path: Path) -> list[dict]:
    records = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            if rec.get("_type") == "issue" or "id" in rec:
                records.append(rec)
    return records


def select_records(records: list[dict], include_closed: bool) -> list[dict]:
    out = []
    for rec in records:
        status = (rec.get("status") or "").lower()
        if status in OPEN_STATUSES or (include_closed and status == "closed"):
            out.append(rec)
    return out


def issue_type_label(rec: dict) -> str:
    t = (rec.get("issue_type") or "task").lower()
    return ISSUE_TYPE_LABELS.get(t, "task")


def priority_label(rec: dict) -> str | None:
    p = rec.get("priority")
    if p is None:
        return None
    try:
        return f"priority:p{int(p)}"
    except (TypeError, ValueError):
        return None


def build_labels(rec: dict) -> list[str]:
    labels = [issue_type_label(rec)]
    pl = priority_label(rec)
    if pl:
        labels.append(pl)
    for extra in rec.get("labels") or []:
        if extra and extra not in labels:
            labels.append(extra)
    return labels


def record_parent(rec: dict, by_id: dict[str, dict]) -> str | None:
    for dep in rec.get("dependencies") or []:
        if dep.get("type") == "parent-child" and dep.get("depends_on_id"):
            return dep["depends_on_id"]
    if rec.get("parent"):
        return rec["parent"]
    rid = rec.get("id", "")
    if "." in rid:
        candidate = rid.rsplit(".", 1)[0]
        if candidate in by_id:
            return candidate
    return None


def record_blocked_by(rec: dict, by_id: dict[str, dict]) -> list[str]:
    out = []
    for dep in rec.get("dependencies") or []:
        if dep.get("type") != "blocks":
            continue
        target = dep.get("depends_on_id")
        if not target:
            continue
        blocker = by_id.get(target)
        blocker_status = (blocker or {}).get("status", "").lower()
        if blocker_status == "closed":
            continue  # already satisfied; not a live constraint
        if target not in out:
            out.append(target)
    return out


def build_body(rec: dict, blocked_by: list[str]) -> str:
    lines = ["## Source", f"Migrated from beads issue `{rec.get('id')}`.", ""]

    lines.append("## Acceptance criteria (red-test list — write these as failing tests first)")
    acceptance = rec.get("acceptance_criteria") or rec.get("acceptance")
    if isinstance(acceptance, str):
        acceptance = [acceptance]
    if not acceptance:
        desc = (rec.get("description") or "").strip()
        acceptance = [desc.splitlines()[0] if desc else rec.get("title", "")]
    lines += [f"- [ ] {item}" for item in acceptance] + [""]

    lines.append("## Out of scope")
    out_of_scope = rec.get("out_of_scope")
    if out_of_scope and not isinstance(out_of_scope, list):
        out_of_scope = [out_of_scope]
    lines += [f"- {item}" for item in (out_of_scope or ["(not recorded in the beads issue)"])] + [""]

    lines.append("## Notes for the builder")
    desc = (rec.get("description") or "").strip()
    notes = rec.get("notes")
    body_notes = [n for n in (desc, notes) if n] or ["(no further detail in the beads record)"]
    lines += body_notes + [""]

    if blocked_by:
        lines += ["## Blocked by"] + [f"- {bid}" for bid in blocked_by] + [""]

    return "\n".join(lines).rstrip() + "\n"


def topo_order(records: list[dict], by_id: dict[str, dict]) -> list[str]:
    """Order so a record's parent and blockers (among the migrated set) come
    before it. Falls back to file order for ties and for cycles."""
    ids = [r["id"] for r in records]
    index = {rid: i for i, rid in enumerate(ids)}
    deps: dict[str, set[str]] = {}
    for rec in records:
        rid = rec["id"]
        parent = record_parent(rec, by_id)
        blockers = record_blocked_by(rec, by_id)
        deps[rid] = {d for d in [parent, *blockers] if d in index}

    ordered: list[str] = []
    placed: set[str] = set()
    remaining = list(ids)
    while remaining:
        ready = [rid for rid in remaining if deps[rid] <= placed]
        if not ready:  # cycle (or self-loop): emit what's left in file order.
            ordered.extend(sorted(remaining, key=lambda r: index[r]))
            break
        ordered.extend(ready)
        placed.update(ready)
        remaining = [rid for rid in remaining if rid not in placed]
    return ordered


def build_plan(records: list[dict], include_closed: bool) -> list[dict]:
    selected = select_records(records, include_closed)
    by_id = {r["id"]: r for r in records}  # full set, so blockers outside the
    # selection (e.g. a closed blocker skipped without --include-closed) still
    # resolve for the "is it closed" check above.
    order = topo_order(selected, by_id)
    by_selected_id = {r["id"]: r for r in selected}

    plan = []
    for rid in order:
        rec = by_selected_id[rid]
        blocked_by = record_blocked_by(rec, by_id)
        parent = record_parent(rec, by_id)
        plan.append({
            "beads_id": rid,
            "title": rec.get("title", ""),
            "labels": build_labels(rec),
            "body": build_body(rec, blocked_by),
            "blocked_by": blocked_by,
            "parent": parent,
        })
    return plan


# ── --apply: everything below shells out to gh; not exercised by unit tests ──

def gh_issue_create(repo: str, title: str, body: str, labels: list[str]) -> int:
    tmp = Path("/tmp") / "bench-migrate-body.md"
    tmp.write_text(body, encoding="utf-8")
    cmd = ["gh", "issue", "create", "--repo", repo, "--title", title, "--body-file", str(tmp)]
    for label in labels:
        cmd += ["--label", label]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    url = result.stdout.strip().splitlines()[-1]
    return int(url.rstrip("/").rsplit("/", 1)[-1])


def gh_issue_dep(script: Path, repo: str, *args: str) -> None:
    subprocess.run(["bash", str(script), "--repo", repo, *args], check=False)


def apply_plan(plan: list[dict], repo: str, map_file: Path, dep_script: Path) -> dict[str, int]:
    mapping: dict[str, int] = {}
    for item in plan:
        number = gh_issue_create(repo, item["title"], item["body"], item["labels"])
        mapping[item["beads_id"]] = number
        print(f"created {item['beads_id']} -> #{number}", file=sys.stderr)

    map_file.write_text(json.dumps(mapping, indent=2) + "\n", encoding="utf-8")

    for item in plan:
        number = mapping[item["beads_id"]]
        if item["parent"] and item["parent"] in mapping:
            gh_issue_dep(dep_script, repo, "child", str(mapping[item["parent"]]), str(number))
        rewritten = item["body"]
        for bid in item["blocked_by"]:
            if bid in mapping:
                rewritten = rewritten.replace(f"- {bid}\n", f"- #{mapping[bid]}\n")
                gh_issue_dep(dep_script, repo, "block", str(number), str(mapping[bid]))
        if rewritten != item["body"]:
            tmp = Path("/tmp") / "bench-migrate-body.md"
            tmp.write_text(rewritten, encoding="utf-8")
            subprocess.run(["gh", "issue", "edit", str(number), "--repo", repo,
                             "--body-file", str(tmp)], check=False)
    return mapping


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", default=".beads/issues.jsonl", type=Path)
    parser.add_argument("--include-closed", action="store_true")
    parser.add_argument("--apply", action="store_true", help="create issues (default: dry-run)")
    parser.add_argument("--repo", default=None, help="owner/name (default: gh repo view)")
    parser.add_argument("--map-file", default=Path("beads-to-issues-map.json"), type=Path)
    args = parser.parse_args(argv)

    if not args.file.exists():
        print(f"migrate-beads-to-issues: no such file: {args.file}", file=sys.stderr)
        return 1

    records = load_records(args.file)
    plan = build_plan(records, args.include_closed)

    if not args.apply:
        print(json.dumps(plan, indent=2))
        return 0

    repo = args.repo
    if not repo:
        result = subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner",
                                  "--jq", ".nameWithOwner"], capture_output=True, text=True)
        repo = result.stdout.strip()
    if not repo:
        print("migrate-beads-to-issues: could not determine --repo", file=sys.stderr)
        return 1

    dep_script = Path(__file__).resolve().parent / "gh-issue-dep.sh"
    apply_plan(plan, repo, args.map_file, dep_script)
    return 0


if __name__ == "__main__":
    sys.exit(main())
