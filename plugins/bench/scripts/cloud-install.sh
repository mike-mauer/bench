#!/usr/bin/env bash
# scripts/cloud-install.sh — bootstrap the Bench harness into a project from a
# Claude Code cloud/web session (or any fresh container), with no local
# `claude plugin install` and no `/bench:init` available.
#
# Why this exists
#   `claude plugin install bench@bench` records enablement in USER scope
#   (~/.claude/settings.json). A cloud/web session is a fresh container that
#   clones only the repo, so user scope never travels: no Bench plugin, no
#   planner/engineer/qa/reviewer subagent identities, and no SessionStart hooks
#   (so no `bd` either). The durable fix is repo-scoped, committed config — but
#   `/bench:init`, which writes it, ships INSIDE the plugin that isn't loaded.
#   That is the chicken-and-egg this script breaks: it writes the repo-scoped
#   config directly, from a plain shell, over curl.
#
#     curl -fsSL https://raw.githubusercontent.com/mike-mauer/bench/main/plugins/bench/scripts/cloud-install.sh | bash
#     # with options:  ... | bash -s -- --with data-eng,design-reviewer
#
# What it does — every step idempotent, repo-scoped, and re-runnable:
#   1. `.claude/settings.json` — `extraKnownMarketplaces` + `enabledPlugins` for
#      `bench` and its `beads` dependency, MERGED into the existing file
#      (unrelated keys untouched, entries never duplicated).
#   2. `bd` — installs the pinned beads CLI into ~/.local/bin so the CURRENT
#      session has it; the SessionStart hook only runs from the next one.
#   3. `CLAUDE.md` — injects/refreshes the managed orchestrator block using the
#      same marker + hash as `/bench:init` and the drift-check hook (the hash is
#      computed by the canonical `scripts/bench-hash.sh`, never re-implemented).
#   4. `.beads/.gitattributes` — `*.jsonl merge=union` when a board is present.
#   5. `--with data-eng,design-reviewer` — installs the optional role agents.
#
#   It does NOT initialize the beads board (`bd init` needs an issue prefix and a
#   judgement call about the Dolt remote) and it does NOT commit. Run
#   `/bench:init` in the next session for the board, and review + commit yourself.
#
# NOT a hook. The other scripts in this directory are wired to hooks.json and so
# must always exit 0; this one is user-invoked and reports real exit codes
# (0 = success, 1 = failure), while still never touching user scope, never
# committing, and never overwriting config it did not write.
set -uo pipefail

BENCH_REPO="${BENCH_REPO:-mike-mauer/bench}"     # marketplace source (change for a fork)
BENCH_REF="${BENCH_REF:-main}"                   # ref to fetch plugin files from
BEADS_REPO="${BEADS_REPO:-gastownhall/beads}"    # the beads marketplace Bench depends on
BD_VERSION_FALLBACK="1.1.0"                      # used only if plugin.json can't be read
BIN_DIR="${BENCH_BIN_DIR:-$HOME/.local/bin}"

PROJECT_DIR=""
WITH_ROLES=""
DO_BD=1
DO_CLAUDEMD=1
DRY_RUN=0
CHANGED=0
SETTINGS_FAILED=0

log()  { printf '[bench-cloud-install] %s\n' "$*" >&2; }
warn() { printf '[bench-cloud-install] WARNING: %s\n' "$*" >&2; }
die()  { printf '[bench-cloud-install] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
bench cloud-install — install the Bench harness into this project from a cloud session.

Usage:
  curl -fsSL https://raw.githubusercontent.com/mike-mauer/bench/main/plugins/bench/scripts/cloud-install.sh | bash
  curl -fsSL <same url> | bash -s -- [options]
  bash plugins/bench/scripts/cloud-install.sh [options]      # from a bench checkout

Options:
  --project-dir <path>   Project to install into (default: git toplevel, else $PWD).
  --with <roles>         Comma-separated optional roles: data-eng, design-reviewer.
  --no-bd                Skip installing the beads (bd) CLI.
  --no-claudemd          Skip injecting the CLAUDE.md orchestrator block.
  --dry-run              Report what would change; write nothing.
  -h, --help             This help.

Environment:
  BENCH_REPO   marketplace repo (default mike-mauer/bench) — set for a fork.
  BENCH_REF    ref to fetch plugin files from (default main).
  BEADS_REPO   beads marketplace repo (default gastownhall/beads).
  BENCH_BIN_DIR  where to install bd (default ~/.local/bin).

Afterwards: commit the changes, start a new session so the plugin loads, then run
/bench:init (beads board + per-project setup) and /bench:doctor.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project-dir) PROJECT_DIR="${2:-}"; [ -n "$PROJECT_DIR" ] || die "--project-dir needs a path"; shift 2 ;;
    --project-dir=*) PROJECT_DIR="${1#*=}"; shift ;;
    --with) WITH_ROLES="${2:-}"; [ -n "$WITH_ROLES" ] || die "--with needs a role list"; shift 2 ;;
    --with=*) WITH_ROLES="${1#*=}"; shift ;;
    --no-bd) DO_BD=0; shift ;;
    --no-claudemd) DO_CLAUDEMD=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

# ── Where are we installing? ──────────────────────────────────────────────────
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$PROJECT_DIR" ] || PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
fi
[ -d "$PROJECT_DIR" ] || die "project dir does not exist: $PROJECT_DIR"
cd "$PROJECT_DIR" || die "cannot cd into $PROJECT_DIR"
PROJECT_DIR="$PWD"
log "project: $PROJECT_DIR"
[ "$DRY_RUN" -eq 1 ] && log "DRY RUN — nothing will be written."

# ── Where do plugin files come from? ──────────────────────────────────────────
# Local mode when the script is run from a bench checkout (its own ../templates
# exists); otherwise remote mode, fetching from raw.githubusercontent per-file.
# Both modes resolve through plugin_file(), so no step ever re-implements a
# bundled asset (notably bench-hash.sh — the CLAUDE.md marker hash must match
# /bench:init and the drift-check hook exactly, or every session warns "stale").
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
PLUGIN_ROOT=""
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/../templates/CLAUDE.bench.md" ]; then
  PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  log "using local plugin checkout: $PLUGIN_ROOT"
else
  log "fetching plugin files from $BENCH_REPO@$BENCH_REF"
fi

FETCH_DIR=""
# shellcheck disable=SC2329  # invoked indirectly, via the EXIT trap below
cleanup() { [ -n "$FETCH_DIR" ] && rm -rf "$FETCH_DIR"; }
trap cleanup EXIT

fetch() { # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1" 2>/dev/null
  else return 1; fi
}

# plugin_file <path-relative-to-plugins/bench> → echoes a readable local path.
plugin_file() {
  rel="$1"
  if [ -n "$PLUGIN_ROOT" ]; then
    [ -f "$PLUGIN_ROOT/$rel" ] || return 1
    printf '%s\n' "$PLUGIN_ROOT/$rel"; return 0
  fi
  [ -n "$FETCH_DIR" ] || FETCH_DIR="$(mktemp -d)" || return 1
  dest="$FETCH_DIR/$rel"
  if [ ! -s "$dest" ]; then
    mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
    fetch "https://raw.githubusercontent.com/$BENCH_REPO/$BENCH_REF/plugins/bench/$rel" "$dest" || return 1
    [ -s "$dest" ] || return 1
  fi
  printf '%s\n' "$dest"
}

# ── Step 1 — .claude/settings.json (the step that actually enables Bench) ─────
# Web sessions load plugins ONLY from the repo's committed .claude/settings.json.
# The merge is done by python3 (preferred) or jq — never by hand-rolled text
# munging, which would corrupt a settings file holding hooks/permissions.
settings_merge() {
  out="$1"   # path to write the merged JSON to ("-" prints to stdout)
  if command -v python3 >/dev/null 2>&1; then
    SETTINGS_IN="$SETTINGS" SETTINGS_OUT="$out" BENCH_REPO="$BENCH_REPO" BEADS_REPO="$BEADS_REPO" \
    python3 - <<'PY'
import json, os, sys

src, dst = os.environ["SETTINGS_IN"], os.environ["SETTINGS_OUT"]
bench_repo, beads_repo = os.environ["BENCH_REPO"], os.environ["BEADS_REPO"]

try:
    with open(src) as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {}
except (ValueError, OSError) as exc:
    sys.stderr.write("cannot parse %s: %s\n" % (src, exc))
    sys.exit(4)
if not isinstance(data, dict):
    sys.stderr.write("%s is not a JSON object\n" % src)
    sys.exit(4)

before = json.dumps(data, sort_keys=True)

markets = data.get("extraKnownMarketplaces") or {}
if not isinstance(markets, dict):
    sys.stderr.write("extraKnownMarketplaces is not an object — refusing to overwrite it\n")
    sys.exit(4)
markets["bench"] = {"source": {"source": "github", "repo": bench_repo}}
markets.setdefault("beads-marketplace", {"source": {"source": "github", "repo": beads_repo}})
data["extraKnownMarketplaces"] = markets

wanted = [{"marketplace": "beads-marketplace", "plugin": "beads"},
          {"marketplace": "bench", "plugin": "bench"}]
enabled = data.get("enabledPlugins")
if enabled is None:
    enabled = []
if not isinstance(enabled, list):
    # Some Claude Code versions store enabledPlugins as an object keyed
    # "plugin@marketplace". Don't guess at a shape we didn't write: leave it and
    # let the caller print the snippet for a human to merge.
    sys.stderr.write("enabledPlugins is not an array — refusing to rewrite it\n")
    sys.exit(4)
for entry in wanted:
    if not any(isinstance(e, dict) and e.get("marketplace") == entry["marketplace"]
               and e.get("plugin") == entry["plugin"] for e in enabled):
        enabled.append(entry)
data["enabledPlugins"] = enabled

if json.dumps(data, sort_keys=True) == before:
    sys.exit(3)  # already correct — nothing to write

text = json.dumps(data, indent=2) + "\n"
if dst == "-":
    sys.stdout.write(text)
else:
    with open(dst, "w") as fh:
        fh.write(text)
PY
    return $?
  fi

  if command -v jq >/dev/null 2>&1; then
    [ -f "$SETTINGS" ] || printf '{}\n' > "$FETCH_DIR/empty.json"
    src="$SETTINGS"; [ -f "$src" ] || src="$FETCH_DIR/empty.json"
    kind="$(jq -r 'if type != "object" then "bad"
                   elif (.extraKnownMarketplaces? // {} | type) != "object" then "bad"
                   elif (.enabledPlugins? // [] | type) != "array" then "bad"
                   else "ok" end' "$src" 2>/dev/null)" || return 4
    [ "$kind" = "ok" ] || return 4
    merged="$(jq --arg br "$BENCH_REPO" --arg dr "$BEADS_REPO" '
      .extraKnownMarketplaces = ((.extraKnownMarketplaces // {})
        | .["beads-marketplace"] = (.["beads-marketplace"] // {source:{source:"github",repo:$dr}})
        | .bench = {source:{source:"github",repo:$br}})
      | .enabledPlugins = ((.enabledPlugins // [])
        + [{marketplace:"beads-marketplace",plugin:"beads"},{marketplace:"bench",plugin:"bench"}]
        | reduce .[] as $e ([]; if any(.[]; . == $e) then . else . + [$e] end))
    ' "$src" 2>/dev/null)" || return 1
    [ -n "$merged" ] || return 1
    if [ -f "$SETTINGS" ] && [ "$(jq -S . "$SETTINGS" 2>/dev/null)" = "$(printf '%s' "$merged" | jq -S . 2>/dev/null)" ]; then
      return 3
    fi
    if [ "$out" = "-" ]; then printf '%s\n' "$merged"; else printf '%s\n' "$merged" > "$out"; fi
    return 0
  fi

  return 2   # no JSON tool available
}

SETTINGS="$PROJECT_DIR/.claude/settings.json"
[ -n "$FETCH_DIR" ] || FETCH_DIR="$(mktemp -d)"
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$PROJECT_DIR/.claude" 2>/dev/null || die "cannot create $PROJECT_DIR/.claude"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  settings_merge "-" >/dev/null 2>&1; rc=$?
else
  tmp_settings="$FETCH_DIR/settings.json"
  settings_merge "$tmp_settings"; rc=$?
  [ "$rc" -eq 0 ] && { mv -f "$tmp_settings" "$SETTINGS" || rc=1; }
fi

case "$rc" in
  0) if [ "$DRY_RUN" -eq 1 ]; then
       log "settings: would enable bench + beads in .claude/settings.json (the step cloud sessions need)."
     else
       log "settings: .claude/settings.json — enabled bench + beads for cloud sessions."; CHANGED=1
     fi ;;
  3) log "settings: .claude/settings.json already enables bench + beads — unchanged." ;;
  2) warn "settings: neither python3 nor jq is available — cannot merge JSON safely." ;;
  4) warn "settings: .claude/settings.json holds a shape this script did not write (unparseable, or an object-shaped enabledPlugins / extraKnownMarketplaces) — refusing to rewrite it." ;;
  *) warn "settings: could not update .claude/settings.json automatically." ;;
esac
if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
  SETTINGS_FAILED=1
  warn "Merge this into .claude/settings.json by hand — WITHOUT it, cloud sessions have no Bench:"
  cat >&2 <<JSON
  {
    "extraKnownMarketplaces": {
      "bench": { "source": { "source": "github", "repo": "$BENCH_REPO" } },
      "beads-marketplace": { "source": { "source": "github", "repo": "$BEADS_REPO" } }
    },
    "enabledPlugins": [
      { "marketplace": "beads-marketplace", "plugin": "beads" },
      { "marketplace": "bench", "plugin": "bench" }
    ]
  }
JSON
fi

# ── Step 2 — the pinned bd binary, installed synchronously ────────────────────
# The SessionStart install-bd hook can't help yet (the plugin isn't loaded until
# the next session), so install bd here for the session running this script. The
# pin is read from the plugin manifest so it can never drift from the hook's.
bd_pin() {
  pj="$(plugin_file '.claude-plugin/plugin.json' 2>/dev/null)" || { printf '%s\n' "$BD_VERSION_FALLBACK"; return; }
  v="$(grep -A4 '"bd_version"' "$pj" 2>/dev/null | grep -o '"default"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
  printf '%s\n' "${v:-$BD_VERSION_FALLBACK}"
}

install_bd() {
  if command -v bd >/dev/null 2>&1; then
    log "bd: already on PATH ($(bd version 2>/dev/null | head -1)) — leaving it alone."
    return 0
  fi
  version="$(bd_pin)"; version="${version#v}"
  if [ "$DRY_RUN" -eq 1 ]; then log "bd: would install v$version into $BIN_DIR."; return 0; fi

  case "$(uname -s)" in Darwin) os=darwin;; Linux) os=linux;; FreeBSD) os=freebsd;; *) os="$(uname -s)";; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; *) arch="$(uname -m)";; esac

  mkdir -p "$BIN_DIR" 2>/dev/null || { warn "bd: cannot create $BIN_DIR"; return 1; }
  tmp="$(mktemp -d)"
  url="https://github.com/$BEADS_REPO/releases/download/v${version}/beads_${version}_${os}_${arch}.tar.gz"
  if fetch "$url" "$tmp/bd.tgz" && tar -xzf "$tmp/bd.tgz" -C "$tmp" 2>/dev/null; then
    found="$(find "$tmp" -type f -name bd | head -1)"
    [ -n "$found" ] && install -m 0755 "$found" "$BIN_DIR/bd" 2>/dev/null
  fi
  rm -rf "$tmp"

  # Fallback: pinned `go install`. The module path is still steveyegge/beads —
  # the repo moved to gastownhall/beads but go.mod kept the original path.
  if [ ! -x "$BIN_DIR/bd" ] && command -v go >/dev/null 2>&1; then
    GOBIN="$BIN_DIR" CGO_ENABLED=1 GOFLAGS="-tags=gms_pure_go" go install "github.com/steveyegge/beads/cmd/bd@v${version}" 2>/dev/null \
      || GOBIN="$BIN_DIR" CGO_ENABLED=0 go install "github.com/steveyegge/beads/cmd/bd@v${version}" 2>/dev/null
  fi

  if [ ! -x "$BIN_DIR/bd" ]; then
    warn "bd: install failed — the SessionStart install-bd hook will retry once the plugin loads."
    return 1
  fi
  log "bd: installed v$version → $BIN_DIR/bd"
  CHANGED=1
  # Make it usable immediately: this session's env file if Claude Code provided
  # one, and a PATH hint for the shell otherwise.
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
  fi
  case ":$PATH:" in *":$BIN_DIR:"*) : ;; *) log "bd: add it to PATH for this shell — export PATH=\"$BIN_DIR:\$PATH\"" ;; esac
  return 0
}
[ "$DO_BD" -eq 1 ] && install_bd

# ── Step 3 — the managed CLAUDE.md orchestrator block ─────────────────────────
inject_claudemd() {
  tpl="$(plugin_file 'templates/CLAUDE.bench.md')" || { warn "CLAUDE.md: could not read templates/CLAUDE.bench.md — skipped."; return 1; }
  hasher="$(plugin_file 'scripts/bench-hash.sh')"  || { warn "CLAUDE.md: could not read scripts/bench-hash.sh — skipped."; return 1; }
  h="$(bash "$hasher" "$tpl" 2>/dev/null)"
  [ -n "$h" ] || { warn "CLAUDE.md: could not compute the template hash — skipped."; return 1; }

  target="$PROJECT_DIR/CLAUDE.md"
  block="$FETCH_DIR/block.md"
  { printf '<!-- BEGIN BENCH v:1 hash:%s -->\n' "$h"; cat "$tpl"; printf '<!-- END BENCH -->\n'; } > "$block"

  # Match markers ONLY at the start of a line. /bench:init writes them on their
  # own line, while prose that merely MENTIONS the marker (this repo's own
  # CLAUDE.md documents it inside backticks, mid-sentence) never starts a line
  # with it. Without the anchor, the awk below treats that prose line as the
  # block start and eats every line from it to the END marker.
  have_begin=0; have_end=0
  if [ -f "$target" ]; then
    grep -q '^<!-- BEGIN BENCH' "$target" && have_begin=1
    grep -q '^<!-- END BENCH -->' "$target" && have_end=1
  fi

  if [ "$have_begin" -eq 1 ] && [ "$have_end" -eq 0 ]; then
    warn "CLAUDE.md: has a BEGIN BENCH marker but no END BENCH — refusing to touch it. Fix the markers, then re-run."
    return 1
  fi

  if [ "$have_begin" -eq 1 ]; then
    cur="$(grep -o '^<!-- BEGIN BENCH[^>]*hash:[0-9a-f]*' "$target" 2>/dev/null | grep -o 'hash:[0-9a-f]*' | head -1 | cut -d: -f2)"
    if [ "$cur" = "$h" ]; then log "CLAUDE.md: orchestrator block already current (hash:$h)."; return 0; fi
    if [ "$DRY_RUN" -eq 1 ]; then log "CLAUDE.md: would refresh the orchestrator block (hash:${cur:-none} → $h)."; return 0; fi
    # Replace the existing block in place; everything else in the file survives,
    # including any BEADS INTEGRATION block.
    if awk -v bf="$block" '
      /^<!-- BEGIN BENCH/ && !replaced { while ((getline line < bf) > 0) print line; close(bf); skip=1; replaced=1; next }
      skip && /^<!-- END BENCH -->/ { skip=0; next }
      !skip { print }
    ' "$target" > "$FETCH_DIR/claude.md.new"; then
      mv -f "$FETCH_DIR/claude.md.new" "$target" || { warn "CLAUDE.md: rewrite failed — left untouched."; return 1; }
    else
      warn "CLAUDE.md: rewrite failed — left untouched."; return 1
    fi
    log "CLAUDE.md: refreshed the orchestrator block (hash:${cur:-none} → $h)."
    CHANGED=1; return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then log "CLAUDE.md: would add the orchestrator block (hash:$h)."; return 0; fi
  if [ -f "$target" ]; then printf '\n' >> "$target"; fi
  cat "$block" >> "$target" || { warn "CLAUDE.md: could not write $target."; return 1; }
  log "CLAUDE.md: added the orchestrator block (hash:$h)."
  CHANGED=1
}
[ "$DO_CLAUDEMD" -eq 1 ] && inject_claudemd

# ── Step 4 — .beads/.gitattributes (only when a board is already present) ─────
# Same union-merge fix the SessionStart bootstrap applies: the JSONL are one-way
# derived exports, and ephemeral cloud containers each re-export them.
if [ -d "$PROJECT_DIR/.beads" ]; then
  ga="$PROJECT_DIR/.beads/.gitattributes"
  if grep -q 'merge=union' "$ga" 2>/dev/null; then
    log "beads: .beads/.gitattributes already sets merge=union."
  elif [ "$DRY_RUN" -eq 1 ]; then
    log "beads: would write .beads/.gitattributes (*.jsonl merge=union)."
  else
    if {
         printf '# beads JSONL are one-way DERIVED exports of the Dolt board (source of truth:\n'
         printf '# refs/dolt/data, which cell-merges). merge=union keeps both sides instead of\n'
         # shellcheck disable=SC2016  # backticks are literal text in the comment we emit
         printf '# conflicting; the next `bd export` rewrites clean. Never hand-resolve.\n'
         printf '*.jsonl merge=union\n'
       } >> "$ga" 2>/dev/null; then
      log "beads: wrote .beads/.gitattributes (*.jsonl merge=union)."; CHANGED=1
    else
      warn "beads: could not write $ga."
    fi
  fi
else
  log "beads: no .beads/ yet — run /bench:init in the next session to create the board."
fi

# ── Step 5 — optional roles ───────────────────────────────────────────────────
if [ -n "$WITH_ROLES" ]; then
  mkdir -p "$PROJECT_DIR/.claude/agents" 2>/dev/null || warn "roles: cannot create .claude/agents"
  IFS=','
  for role in $WITH_ROLES; do
    unset IFS
    role="$(printf '%s' "$role" | tr -d '[:space:]')"
    [ -n "$role" ] || continue
    dest="$PROJECT_DIR/.claude/agents/$role.md"
    if [ -f "$dest" ]; then log "roles: $role already installed — left as is."; IFS=','; continue; fi
    src="$(plugin_file "agents-optional/$role.md" 2>/dev/null)" \
      || { warn "roles: unknown or unavailable role '$role' (have: data-eng, design-reviewer)."; IFS=','; continue; }
    if [ "$DRY_RUN" -eq 1 ]; then log "roles: would install $role → .claude/agents/$role.md"; IFS=','; continue; fi
    if cp -f "$src" "$dest" 2>/dev/null; then
      log "roles: installed $role → .claude/agents/$role.md (fill its <<FILL: ...>> placeholders)."; CHANGED=1
    else
      warn "roles: could not install $role."
    fi
    IFS=','
  done
  unset IFS
fi

# ── Report ────────────────────────────────────────────────────────────────────
echo >&2
if [ "$DRY_RUN" -eq 1 ]; then
  log "dry run complete — nothing was written."
elif [ "$CHANGED" -eq 1 ]; then
  log "done. Next steps:"
  log "  1. Review, then commit:  git add .claude CLAUDE.md .beads 2>/dev/null; git commit -m 'Enable the Bench harness'"
  log "  2. Start a NEW session (cloud sessions load plugins only from committed .claude/settings.json)."
  log "     That registers the planner/engineer/qa/reviewer roles and fires the SessionStart hooks."
  log "  3. In that session: /bench:init   (beads board + per-project setup), then /bench:doctor to verify."
else
  log "done — everything was already in place."
fi

# The settings step is the whole point of this script — a cloud session without it
# has no Bench at all. Everything else is best-effort and only warns.
if [ "$SETTINGS_FAILED" -eq 1 ]; then
  die "could not enable Bench in .claude/settings.json — merge the snippet above by hand."
fi
exit 0
