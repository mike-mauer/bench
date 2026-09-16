#!/usr/bin/env bats
# Tests the tool grants in the role agents' frontmatter (#32).
#
# The protocol's contract, not a style preference:
#   • §6 — "every role posts its own `## Handoff from <role>` before it terminates",
#     and the role handing off moves the `gate:*` label. That needs issue_read,
#     add_issue_comment and issue_write in EVERY role, gate or builder.
#   • §6 — builders open the draft PR, so they additionally need create_pull_request.
#
# Roles have Bash and could shell out to `gh`, but `gh` is absent from plenty of
# environments Bench targets — cloud-install.sh exists precisely for a plain
# container with no Claude CLI. Without the MCP grant such a role is hard-blocked
# there, while its siblings degrade fine. The prompts already name these tools;
# this pins the frontmatter to match.

AGENTS="$BATS_TEST_DIRNAME/../plugins/bench/agents"
OPTIONAL="$BATS_TEST_DIRNAME/../plugins/bench/agents-optional"

# grants <file> — the frontmatter `tools:` line.
grants() { awk '/^tools:/{print; exit}' "$1"; }

# is_builder <file> — builders write code, so they carry Edit/Write.
is_builder() { grants "$1" | grep -q 'Write'; }

all_roles() { ls "$AGENTS"/*.md "$OPTIONAL"/*.md; }

@test "every role can read an issue, comment on it, and move its labels" {
  for f in $(all_roles); do
    g="$(grants "$f")"
    for t in issue_read add_issue_comment issue_write get_me; do
      if ! echo "$g" | grep -q "mcp__github__$t"; then
        echo "FAIL $(basename "$f" .md): missing mcp__github__$t" >&2
        echo "  tools: $g" >&2
        false
      fi
    done
  done
}

@test "every builder can open a draft PR" {
  for f in $(all_roles); do
    is_builder "$f" || continue
    g="$(grants "$f")"
    for t in create_pull_request update_pull_request; do
      if ! echo "$g" | grep -q "mcp__github__$t"; then
        echo "FAIL $(basename "$f" .md) is a builder but is missing mcp__github__$t" >&2
        false
      fi
    done
  done
}

@test "a role whose prompt names an MCP tool is granted it" {
  for f in $(all_roles); do
    g="$(grants "$f")"
    # tools named in the prompt body as `backticked_identifiers`
    for t in $(sed '1,/^---$/d' "$f" | grep -oE '`(issue_read|issue_write|add_issue_comment|create_pull_request|sub_issue_write|pull_request_read|update_pull_request)`' | tr -d '`' | sort -u); do
      if ! echo "$g" | grep -q "mcp__github__$t"; then
        echo "FAIL $(basename "$f" .md): prompt names \`$t\` but frontmatter does not grant it" >&2
        false
      fi
    done
  done
}
