#!/usr/bin/env bash
# scripts/run-testco-batch.sh
#
# Batch testco driver. Drives the JUVANT_OS Skill in batch mode end-to-end:
# stages a /tmp company instance, renders batch-inputs from the fixture,
# spawns Claude Code with the activation prompt, parses the [BATCH] event
# stream from the Skill, renders a live progress board, and runs post-run
# assertions against the fixture's `expect:` block.
#
# Usage:
#   bash scripts/run-testco-batch.sh <fixture.yaml> [flags]
#
# Flags:
#   --keep-tmp          Retain the staged /tmp/testco-batch-<slug>/ for debug.
#   --dry-run           Validate + stage; do not spawn claude.
#   --no-render         Suppress live progress board (still emits events to log).
#   --skill-version=<sha>
#                       Override the Skill version label in run_start event.
#                       Defaults to `git rev-parse HEAD`.
#
# Exit codes:
#   0   batch run complete and all assertions passed
#   1   missing tooling / fixture not found
#   2   fixture schema validation failed
#   3   stage / render failure
#   4   Skill failed to complete (no run_complete event)
#   5   one or more post-run assertions failed
#
# Outputs:
#   tests/fixtures/testco/results/<date>-<scenario>.jsonl
#   tests/fixtures/testco/results/<date>-<scenario>.md
#   /tmp/testco-batch-<slug>/.juvant/state.db          (with --keep-tmp)
#
# Per ADR 0012 (Batch testco mode + CI integration).

set -euo pipefail

# Ensure common Mac + Linux tool paths are visible to subshells we spawn.
# When invoked via a wrapper that strips the user's shell PATH (e.g.
# Claude Code background tasks, some CI runners), `claude` and `yq`
# under /opt/homebrew/bin or /usr/local/bin are otherwise not found
# inside the `( cd "$TMP_DIR"; claude --print ... )` subshell.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

# ─── flag parsing ──────────────────────────────────────────────────────
FIXTURE=""
KEEP_TMP=0
DRY_RUN=0
RENDER=1
SKILL_VERSION=""
# Default to Opus 4.7 for batch runs. Sonnet 4.6 was tested
# 2026-05-10 and does not recognize the JUVANT_OS Skill's batch-mode
# activation trigger ("Initialize Juvant OS using batch inputs from
# <path>") — it routes the prompt to a generic "explore codebase and
# write CLAUDE.md" pattern instead of entering the wizard. The Skill
# design assumes Opus reasoning capacity for prompt routing, fixture
# parsing, and step orchestration. Cost optimization via model
# downshift requires Skill restructuring (smaller modular skill files,
# tighter activation language, fewer simultaneous instructions) — a
# v0.8.x architectural concern, not a v0.7.x driver flag flip.
#
# Override via --model=<id> per-run for experimentation (e.g.
# claude-haiku-4-5 for cheapest-possible regression sanity, or future
# Sonnet versions once the Skill has been refactored).
MODEL="${JUVANT_BATCH_MODEL:-claude-opus-4-7}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-tmp) KEEP_TMP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-render) RENDER=0; shift ;;
    --skill-version=*) SKILL_VERSION="${1#--skill-version=}"; shift ;;
    --model=*) MODEL="${1#--model=}"; shift ;;
    -h|--help)
      sed -n '/^# Usage:/,/^# Per/p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    -*) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
    *) FIXTURE="$1"; shift ;;
  esac
done

if [[ -z "$FIXTURE" ]]; then
  echo "ERROR: missing fixture path." >&2
  exit 1
fi

# ─── tooling checks ────────────────────────────────────────────────────
for tool in jq yq sqlite3 git; do
  if ! command -v "$tool" >/dev/null; then
    echo "ERROR: $tool required (brew install $tool)." >&2
    exit 1
  fi
done

CLAUDE_BIN=""
if [[ "$DRY_RUN" != "1" ]]; then
  # Resolve absolute path to claude once and verify it's exec-able.
  # We deliberately KEEP the symlink path (do not realpath-dereference)
  # — some sandboxed exec contexts on macOS allow exec via the
  # /opt/homebrew/bin/claude symlink but deny exec on the realpath
  # target /opt/homebrew/lib/node_modules/.../claude.exe directly.
  CLAUDE_BIN=$(command -v claude || true)
  if [[ -z "$CLAUDE_BIN" ]]; then
    for candidate in /opt/homebrew/bin/claude /usr/local/bin/claude /usr/bin/claude; do
      [[ -x "$candidate" ]] && CLAUDE_BIN="$candidate" && break
    done
  fi
  if [[ -z "$CLAUDE_BIN" ]]; then
    echo "ERROR: claude CLI not found on PATH or at /opt/homebrew/bin, /usr/local/bin, /usr/bin." >&2
    exit 1
  fi
  if [[ ! -x "$CLAUDE_BIN" ]]; then
    echo "ERROR: claude CLI resolved to '$CLAUDE_BIN' but the file is not executable." >&2
    exit 1
  fi
  echo "▶ Using claude binary: $CLAUDE_BIN"
fi

# ─── repo root ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "$SKILL_VERSION" ]]; then
  SKILL_VERSION=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi

# ─── fixture validation ────────────────────────────────────────────────
echo "▶ Validating fixture schema..."
if ! bash "$SCRIPT_DIR/validate-batch-fixture.sh" "$FIXTURE"; then
  echo "ERROR: fixture schema validation failed." >&2
  exit 2
fi

SCENARIO=$(yq -r '.scenario' "$FIXTURE")
SLUG="$SCENARIO"
COMPANY_SLUG=$(yq -r '.inputs.identity.company_slug' "$FIXTURE")
DB_PROVIDER=$(yq -r '.inputs.database.provider' "$FIXTURE")
RUN_DATE=$(date -u +%Y-%m-%d)
RUN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ─── stage /tmp instance ───────────────────────────────────────────────
TMP_DIR="/tmp/testco-batch-$SLUG"
ORIGIN_DIR="${TMP_DIR}-origin.git"
LOG_FILE="$TMP_DIR/session.log"
EVENT_FILE="$TMP_DIR/events.jsonl"

cleanup() {
  if [[ "$KEEP_TMP" == "1" ]]; then
    echo ""
    echo "Tmp retained: $TMP_DIR"
  else
    rm -rf "$TMP_DIR" "$ORIGIN_DIR"
  fi
}
trap cleanup EXIT

echo "▶ Staging /tmp instance at $TMP_DIR..."
rm -rf "$TMP_DIR" "$ORIGIN_DIR"
git init --quiet --bare "$ORIGIN_DIR"
git -C "$ROOT" worktree remove --force "$TMP_DIR" 2>/dev/null || true
# Use clone (not worktree) so the test instance is fully detached.
git clone --quiet --no-local "$ROOT" "$TMP_DIR"
git -C "$TMP_DIR" remote set-url origin "$ORIGIN_DIR"

# Render batch-inputs (strip expect block — Skill never sees it).
mkdir -p "$TMP_DIR/.juvant"
yq 'del(.expect) | del(.description)' "$FIXTURE" -o yaml > "$TMP_DIR/.juvant/batch-inputs.yaml"

# Pre-stage minimal config.json so migrate.sh can run before the Skill writes.
cat > "$TMP_DIR/.juvant/config.json" <<JSON
{
  "company": { "name": "$(yq -r '.inputs.identity.company_name' "$FIXTURE")",
               "slug": "$COMPANY_SLUG",
               "domain": "$(yq -r '.inputs.identity.company_domain' "$FIXTURE")" },
  "db": { "provider": "$DB_PROVIDER",
          "url": "$(yq -r '.inputs.database.url' "$FIXTURE")" },
  "_batch_mode": true
}
JSON

echo "▶ Running migration..."
( cd "$TMP_DIR" && bash scripts/migrate.sh ) >/dev/null

mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"
: > "$EVENT_FILE"

if [[ "$DRY_RUN" == "1" ]]; then
  echo ""
  echo "Dry run complete. Tmp staged at $TMP_DIR."
  KEEP_TMP=1
  exit 0
fi

# ─── live progress board (renderer) ────────────────────────────────────
# Renders an ANSI board on TTY, plain stream on non-TTY. Reads events
# from $EVENT_FILE in a tail loop.
declare -a STEP_ORDER=(
  "1:Identity"
  "1.5:Doc storage"
  "1.5b:Mailboxes"
  "1.6:GitHub user map"
  "2:Database"
  "3:Bank"
  "4:Notifications"
  "4.5:Guardrails"
  "5:Counterparties"
  "6:Agent names + CRO"
  "7:Compile templates"
  "7.5/6:Render infra + rewrite meta"
  "8:Seed matrix"
  "8.5:Cross-check"
  "9:Bootstrap protocol"
  "10:Initial commit"
  "10.5:Branch protection"
)

render_board() {
  # No-op if --no-render or not a TTY.
  [[ "$RENDER" == "1" ]] || return 0
  [[ -t 1 ]] || return 0

  local jsonl="$1"
  # Compute per-step status from the event stream.
  local board=""
  local cumul_dur="0" cumul_in="0" cumul_out="0"

  for entry in "${STEP_ORDER[@]}"; do
    local step="${entry%%:*}" name="${entry#*:}"
    local started done_evt icon dur_s tok_in tok_out check
    started=$(jq -r --arg s "$step" 'select(.event=="step_start" and .step==$s) | .ts' "$jsonl" 2>/dev/null | tail -1)
    done_evt=$(jq -c --arg s "$step" 'select(.event=="step_done" and .step==$s)' "$jsonl" 2>/dev/null | tail -1)
    check=$(jq -c --arg s "$step" 'select(.event=="checkpoint" and .step==$s)' "$jsonl" 2>/dev/null | tail -1)

    if [[ -n "$done_evt" ]]; then
      icon=$'\033[32m✓\033[0m'
      dur_s=$(jq -r '.duration_s // "?"' <<<"$done_evt")
      tok_in=$(jq -r '.tokens_in // 0' <<<"$done_evt")
      tok_out=$(jq -r '.tokens_out // 0' <<<"$done_evt")
      cumul_dur=$(awk -v a="$cumul_dur" -v b="$dur_s" 'BEGIN{printf "%.1f", a+b}')
      cumul_in=$((cumul_in + tok_in))
      cumul_out=$((cumul_out + tok_out))
    elif [[ -n "$started" ]]; then
      icon=$'\033[33m▶\033[0m'
      dur_s="..."
      tok_in="-"
      tok_out="-"
    else
      icon=$'\033[2m·\033[0m'
      dur_s="-"
      tok_in="-"
      tok_out="-"
    fi

    local check_str=""
    if [[ -n "$check" ]]; then
      check_str=" $(jq -r '.detail // ""' <<<"$check")"
    fi
    board+=$(printf "  %b Step %-7s %-30s %8ss %6s→%-6s tok%s\n" \
      "$icon" "$step" "$name" "$dur_s" "$tok_in" "$tok_out" "$check_str")$'\n'
  done

  # Clear screen + redraw.
  printf "\033[2J\033[H"
  echo "Juvant OS testco batch — scenario: $SCENARIO"
  echo "Skill version: $SKILL_VERSION   Run: $RUN_TS"
  echo ""
  printf '%b' "$board"
  echo ""
  printf "Cumulative: %ss · %s→%s tok\n" "$cumul_dur" "$cumul_in" "$cumul_out"
}

# Spawn renderer in background, watching the event file.
if [[ "$RENDER" == "1" ]] && [[ -t 1 ]]; then
  (
    while true; do
      render_board "$EVENT_FILE"
      sleep 1
      # Stop once run_complete event present.
      if grep -q '"event":"run_complete"' "$EVENT_FILE" 2>/dev/null; then
        render_board "$EVENT_FILE"
        break
      fi
    done
  ) &
  RENDERER_PID=$!
fi

# ─── spawn claude ──────────────────────────────────────────────────────
echo "▶ Spawning Skill in batch mode (model=$MODEL, stream-json + hook events + budget cap)..."

ACTIVATION_PROMPT="Initialize Juvant OS using batch inputs from .juvant/batch-inputs.yaml"

# v0.7.0 transport: --output-format stream-json gives us a structured
# JSON-Lines event stream covering hook lifecycle, assistant messages,
# tool calls, tool results, and a final result event with total cost +
# token usage. This replaces the text-mode buffering issue from the
# 2026-05-09 baseline run (Markdown summary substituted for [BATCH]
# events) — under stream-json each tool_use and hook event arrives as
# its own line, so the driver gets live progress signal even when the
# Skill itself does not emit [BATCH] events.
#
# --include-hook-events: surfaces every PreToolUse/PostToolUse event
#                        (Track 3 audit log fires visible in real time).
# --verbose: required by --output-format=stream-json per claude --help.
# --max-budget-usd: safety cap on a misbehaving Skill loop. $5 covers
#                   single-company (~$2 observed) AND single-project
#                   (~$3 observed; the project-init phase adds ~$1 net
#                   of cache-reuse benefit) with margin. Reduce per-
#                   scenario in a fork if the budget is too generous;
#                   keep margin for unexpected Skill recon overhead on
#                   first-time runs against a new fixture.
STREAM_FILE="$TMP_DIR/stream.jsonl"
: > "$STREAM_FILE"

(
  cd "$TMP_DIR"
  "$CLAUDE_BIN" --print \
    --model "$MODEL" \
    --permission-mode bypassPermissions \
    --output-format stream-json \
    --verbose \
    --include-hook-events \
    --include-partial-messages \
    --max-budget-usd 6.5 \
    "$ACTIVATION_PROMPT" 2>&1
) | tee "$LOG_FILE" | while IFS= read -r line; do
  # Three sinks:
  # 1) Skill-emitted [BATCH] {...} lines (from agent text, embedded
  #    inside assistant message content). These rarely surface as
  #    standalone lines under stream-json, but we keep the parse path
  #    for forward-compat.
  # 2) Stream-json events (one JSON object per line, .type set).
  # 3) Other (driver / shell noise) — discard.
  if [[ "$line" == "[BATCH] "* ]]; then
    payload="${line#[BATCH] }"
    if jq -e '.event' >/dev/null 2>&1 <<<"$payload"; then
      printf '%s\n' "$payload" >> "$EVENT_FILE"
    fi
  elif jq -e '.type' >/dev/null 2>&1 <<<"$line"; then
    printf '%s\n' "$line" >> "$STREAM_FILE"
  fi
done || true

# Wait for renderer to wrap up.
if [[ -n "${RENDERER_PID:-}" ]]; then
  wait "$RENDERER_PID" 2>/dev/null || true
fi

# ─── merge file-persisted events into the canonical stream ────────────
# The Skill writes [BATCH] events to .juvant/batch-events.jsonl via
# Bash appends (mandatory per JUVANT_OS.md § Batch mode persistence
# requirement, v0.7.0+). This survives `claude --print` stdout
# buffering — events flushed to disk as the wizard runs, not all at
# end-of-run. Merge into the stdout-parsed stream now.
PERSISTED_EVENTS="$TMP_DIR/.juvant/batch-events.jsonl"
if [[ -f "$PERSISTED_EVENTS" ]]; then
  cat "$PERSISTED_EVENTS" >> "$EVENT_FILE"
fi

# ─── extract [BATCH] events embedded in assistant text content ────────
# Even when the Skill doesn't write to .juvant/batch-events.jsonl, it
# may still emit [BATCH] {...} lines as text in its agent messages.
# Under stream-json those land inside .message.content[].text on
# type=assistant events. Surface them into the canonical stream.
if [[ -s "$STREAM_FILE" ]]; then
  jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' \
    "$STREAM_FILE" 2>/dev/null \
    | grep -E '^\[BATCH\] ' \
    | sed 's/^\[BATCH\] //' \
    | while IFS= read -r payload; do
        if jq -e '.event' >/dev/null 2>&1 <<<"$payload"; then
          printf '%s\n' "$payload" >> "$EVENT_FILE"
        fi
      done || true
fi

# ─── derive run analytics from stream-json ────────────────────────────
# Even if no [BATCH] events were emitted, the stream gives us:
# - per-tool-call counts (Bash, Read, Write, Agent, etc.)
# - hook event counts (PreToolUse / PostToolUse / SubagentStart…)
# - cumulative tokens (input / output / cache)
# - total cost in USD
# - number of turns
ANALYTICS_FILE="$TMP_DIR/analytics.json"
if [[ -s "$STREAM_FILE" ]]; then
  jq -s '
    def tool_use_blocks: map(select(.type=="assistant") | .message.content[]? | select(.type=="tool_use"));
    def hook_events: map(select(.type=="system" and .subtype=="hook_started"));
    def result_event: map(select(.type=="result"))[0];

    {
      tool_calls_by_name: (tool_use_blocks | group_by(.name) | map({(.[0].name): length}) | add // {}),
      tool_calls_total: (tool_use_blocks | length),
      hook_events_by_type: (hook_events | group_by(.hook_event) | map({(.[0].hook_event): length}) | add // {}),
      hook_events_total: (hook_events | length),
      assistant_turns: (map(select(.type=="assistant")) | length),
      total_cost_usd: (result_event.total_cost_usd // null),
      duration_ms: (result_event.duration_ms // null),
      duration_api_ms: (result_event.duration_api_ms // null),
      num_turns: (result_event.num_turns // null),
      stop_reason: (result_event.stop_reason // null),
      is_error: (result_event.is_error // false),
      errors: (result_event.errors // []),
      model_usage: (result_event.modelUsage // {}),
      permission_denials: (result_event.permission_denials // [])
    }
  ' "$STREAM_FILE" > "$ANALYTICS_FILE"

  echo ""
  echo "▶ Run analytics:"
  jq -r '
    "  - tool calls: \(.tool_calls_total) total, breakdown: \(.tool_calls_by_name)",
    "  - hook events: \(.hook_events_total) total, breakdown: \(.hook_events_by_type)",
    "  - assistant turns: \(.assistant_turns)",
    "  - cost: $\(.total_cost_usd // "?") (api duration \(.duration_api_ms // "?")ms)",
    "  - stop_reason: \(.stop_reason // "?"), is_error: \(.is_error)"
  ' "$ANALYTICS_FILE"
  if [[ "$(jq -r '.is_error' "$ANALYTICS_FILE")" == "true" ]]; then
    echo "  - errors:" >&2
    jq -r '.errors[]' "$ANALYTICS_FILE" | sed 's/^/    /' >&2
  fi
fi

DB="$TMP_DIR/.juvant/state.db"

# ─── completion check ──────────────────────────────────────────────────
# Two-layer completion detection:
#   Layer 1 (preferred): run_complete event in the [BATCH] stream.
#   Layer 2 (fallback):  state.db sniff. If bootstrap_audit_verdict is
#                        recorded in master_context, the bootstrap
#                        completed structurally even if the Skill did
#                        not emit [BATCH] events (claude --print
#                        buffers all output and an LLM-driven Skill
#                        may compose a Markdown summary instead of
#                        the structured event line, observed first on
#                        the v0.7.0 baseline batch run on 2026-05-09).
#
# The fallback synthesizes a run_complete event so downstream
# assertion / rendering logic is uniform.
if ! grep -q '"event":"run_complete"' "$EVENT_FILE"; then
  fallback_verdict=$(sqlite3 "$DB" "SELECT value FROM master_context WHERE key='bootstrap_audit_verdict';" 2>/dev/null || echo "")
  fallback_completed_at=$(sqlite3 "$DB" "SELECT value FROM master_context WHERE key='bootstrap_completed_at';" 2>/dev/null || echo "")
  if [[ -n "$fallback_verdict" ]]; then
    echo "" >&2
    echo "WARN: Skill did not emit run_complete event in [BATCH] stream;" >&2
    echo "      falling back to state.db sniff (bootstrap_audit_verdict='$fallback_verdict' present)." >&2
    echo "      Synthesizing run_complete from DB state for assertion phase." >&2
    printf '{"ts":"%s","event":"run_complete","verdict":"%s","completed_at":"%s","source":"state_db_fallback"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$fallback_verdict" \
      "$fallback_completed_at" >> "$EVENT_FILE"
  else
    echo "" >&2
    echo "ERROR: Skill did not emit run_complete AND state.db has no bootstrap_audit_verdict." >&2
    echo "       This indicates a real Skill-side failure mid-bootstrap." >&2
    echo "Last 30 lines of session log:" >&2
    tail -30 "$LOG_FILE" >&2
    KEEP_TMP=1
    exit 4
  fi
fi

# ─── persist results ───────────────────────────────────────────────────
mkdir -p "$ROOT/tests/fixtures/testco/results"
RESULTS_JSONL="$ROOT/tests/fixtures/testco/results/${RUN_DATE}-${SCENARIO}.jsonl"
RESULTS_MD="$ROOT/tests/fixtures/testco/results/${RUN_DATE}-${SCENARIO}.md"
cp "$EVENT_FILE" "$RESULTS_JSONL"

# ─── post-run assertions ──────────────────────────────────────────────
echo ""
echo "▶ Running post-run assertions..."

fail=0
assert_fail() {
  echo "  ✗ ASSERT FAIL: $1" >&2
  fail=$((fail+1))
}
assert_ok() {
  echo "  ✓ $1"
}

# bootstrap_verdict
expected_verdicts=$(yq -o=json '.expect.bootstrap_verdict_acceptable // [.expect.bootstrap_verdict]' "$FIXTURE")
actual_verdict=$(sqlite3 "$DB" "SELECT value FROM master_context WHERE key='bootstrap_audit_verdict';" 2>/dev/null || echo "")
if jq -e --arg v "$actual_verdict" '. | index($v)' >/dev/null <<<"$expected_verdicts"; then
  assert_ok "bootstrap_verdict=$actual_verdict (acceptable)"
else
  assert_fail "bootstrap_verdict=$actual_verdict (expected one of: $expected_verdicts)"
fi

# manifests_count
expected_manifests=$(yq -r '.expect.manifests_count' "$FIXTURE")
actual_manifests=$(sqlite3 "$DB" "SELECT COUNT(*) FROM manifests;" 2>/dev/null || echo "0")
if [[ "$actual_manifests" == "$expected_manifests" ]]; then
  assert_ok "manifests_count=$actual_manifests"
else
  assert_fail "manifests_count=$actual_manifests (expected $expected_manifests)"
fi

# Project-init phase assertions (only when fixture defines a project block).
has_project=$(yq -r '.inputs.project // null | type' "$FIXTURE")
if [[ "$has_project" == "!!map" || "$has_project" == "object" ]]; then
  expected_projects=$(yq -r '.expect.project_phase.projects_count // 1' "$FIXTURE")
  actual_projects=$(sqlite3 "$DB" "SELECT COUNT(*) FROM projects;" 2>/dev/null || echo "0")
  if [[ "$actual_projects" -ge "$expected_projects" ]]; then
    assert_ok "projects_count=$actual_projects (≥$expected_projects)"
  else
    assert_fail "projects_count=$actual_projects (expected ≥$expected_projects)"
  fi

  proj_slug=$(yq -r '.inputs.project.slug' "$FIXTURE")
  expected_proj_agents=$(yq -r '.expect.project_phase.project_agents_count // 9' "$FIXTURE")
  actual_proj_agents=$(sqlite3 "$DB" "SELECT COUNT(*) FROM agents WHERE project_id='$proj_slug';" 2>/dev/null || echo "0")
  if [[ "$actual_proj_agents" -ge "$expected_proj_agents" ]]; then
    assert_ok "project_agents_count[$proj_slug]=$actual_proj_agents (≥$expected_proj_agents)"
  else
    assert_fail "project_agents_count[$proj_slug]=$actual_proj_agents (expected ≥$expected_proj_agents)"
  fi

  proj_audit=$(sqlite3 "$DB" "SELECT COUNT(*) FROM security_audit_log WHERE auditor='cso' AND audit_type='bootstrap_baseline' AND scope='$proj_slug';" 2>/dev/null || echo "0")
  if [[ "$proj_audit" -ge 1 ]]; then
    assert_ok "project CSO bootstrap_baseline audit fired ($proj_audit findings)"
  else
    assert_fail "project CSO bootstrap_baseline audit absent (scope=$proj_slug)"
  fi
fi

# decisions_count
expected_decisions=$(yq -r '.expect.decisions_count' "$FIXTURE")
actual_decisions=$(sqlite3 "$DB" "SELECT COUNT(*) FROM decisions;" 2>/dev/null || echo "0")
if [[ "$actual_decisions" -ge "$expected_decisions" ]]; then
  assert_ok "decisions_count=$actual_decisions (≥$expected_decisions)"
else
  assert_fail "decisions_count=$actual_decisions (expected ≥$expected_decisions)"
fi

# matrix_rows_count
expected_matrix=$(yq -r '.expect.matrix_rows_count' "$FIXTURE")
actual_matrix=$(sqlite3 "$DB" "SELECT COUNT(*) FROM agent_tool_matrix;" 2>/dev/null || echo "0")
if [[ "$actual_matrix" == "$expected_matrix" ]]; then
  assert_ok "matrix_rows_count=$actual_matrix"
else
  assert_fail "matrix_rows_count=$actual_matrix (expected $expected_matrix)"
fi

# audit_findings caps
p1_max=$(yq -r '.expect.audit_findings.p1_max' "$FIXTURE")
p2_max=$(yq -r '.expect.audit_findings.p2_max' "$FIXTURE")
p1_actual=$(sqlite3 "$DB" "SELECT COUNT(*) FROM security_audit_log WHERE severity='P1';" 2>/dev/null || echo "0")
p2_actual=$(sqlite3 "$DB" "SELECT COUNT(*) FROM security_audit_log WHERE severity='P2';" 2>/dev/null || echo "0")
if [[ "$p1_actual" -le "$p1_max" ]]; then
  assert_ok "audit_findings.p1=$p1_actual (≤$p1_max)"
else
  assert_fail "audit_findings.p1=$p1_actual (expected ≤$p1_max)"
fi
if [[ "$p2_actual" -le "$p2_max" ]]; then
  assert_ok "audit_findings.p2=$p2_actual (≤$p2_max)"
else
  assert_fail "audit_findings.p2=$p2_actual (expected ≤$p2_max)"
fi

# pending_orphan_assertions (F-22 verification)
orphan_aq=$(yq -r '.expect.pending_orphan_assertions.AskUserQuestion' "$FIXTURE")
actual_orphan_aq=$(sqlite3 "$DB" "SELECT COUNT(*) FROM agent_actions_log WHERE status='pending' AND tool_name='AskUserQuestion';" 2>/dev/null || echo "0")
if [[ "$actual_orphan_aq" == "$orphan_aq" ]]; then
  assert_ok "pending_orphan AskUserQuestion=$actual_orphan_aq"
else
  assert_fail "pending_orphan AskUserQuestion=$actual_orphan_aq (expected $orphan_aq) — F-22 regression"
fi

# matrix_row_assertions (per-row spot checks)
row_count=$(yq -r '.expect.matrix_row_assertions | length' "$FIXTURE")
for i in $(seq 0 $((row_count-1))); do
  role=$(yq -r ".expect.matrix_row_assertions[$i].role" "$FIXTURE")
  required=$(yq -o=json ".expect.matrix_row_assertions[$i]" "$FIXTURE")
  actual_row=$(sqlite3 "$DB" "SELECT mcp_servers||'|'||channels FROM agent_tool_matrix WHERE role='$role';" 2>/dev/null || echo "")
  if [[ -z "$actual_row" ]]; then
    assert_fail "matrix row missing: role=$role"
    continue
  fi
  # mcp_servers_includes
  for inc in $(jq -r '.mcp_servers_includes[]? // empty' <<<"$required"); do
    if [[ "$actual_row" != *"\"$inc\""* ]]; then
      assert_fail "$role mcp_servers missing: $inc (actual: $actual_row)"
    fi
  done
  # channels_includes
  for inc in $(jq -r '.channels_includes[]? // empty' <<<"$required"); do
    if [[ "$actual_row" != *"\"$inc\""* ]]; then
      assert_fail "$role channels missing: $inc (actual: $actual_row)"
    fi
  done
done

# filesystem_assertions
fs_count=$(yq -r '.expect.filesystem_assertions | length' "$FIXTURE")
for i in $(seq 0 $((fs_count-1))); do
  fs_path=$(yq -r ".expect.filesystem_assertions[$i].path" "$FIXTURE")
  must_contain=$(yq -r ".expect.filesystem_assertions[$i].must_contain // \"\"" "$FIXTURE")
  must_not_contain=$(yq -r ".expect.filesystem_assertions[$i].must_not_contain // \"\"" "$FIXTURE")
  must_not_exist=$(yq -r ".expect.filesystem_assertions[$i].must_not_exist // \"\"" "$FIXTURE")
  must_exist=$(yq -r ".expect.filesystem_assertions[$i].must_exist // \"\"" "$FIXTURE")

  full_path="$TMP_DIR/$fs_path"
  # Glob support for must_not_exist (e.g. docs/adr/0001-*.md).
  if [[ "$must_not_exist" == "true" ]]; then
    if compgen -G "$full_path" >/dev/null; then
      assert_fail "filesystem: $fs_path should not exist but does"
    else
      assert_ok "filesystem: $fs_path absent (as expected)"
    fi
    continue
  fi
  if [[ "$must_exist" == "true" ]]; then
    if [[ ! -e "$full_path" ]]; then
      assert_fail "filesystem: $fs_path should exist but doesn't"
    else
      assert_ok "filesystem: $fs_path exists"
    fi
    continue
  fi
  if [[ ! -f "$full_path" ]]; then
    assert_fail "filesystem: $fs_path missing"
    continue
  fi
  if [[ -n "$must_contain" ]] && ! grep -q -F "$must_contain" "$full_path"; then
    assert_fail "filesystem: $fs_path missing required substring '$must_contain'"
  fi
  if [[ -n "$must_not_contain" ]] && grep -q -F "$must_not_contain" "$full_path"; then
    assert_fail "filesystem: $fs_path contains forbidden substring '$must_not_contain'"
  fi
done

# ─── render Markdown summary ──────────────────────────────────────────
{
  echo "# Batch testco run — $SCENARIO ($RUN_DATE)"
  echo ""
  echo "- Skill version: \`$SKILL_VERSION\`"
  echo "- Fixture version: $(yq -r '.fixture_version' "$FIXTURE")"
  echo "- Run timestamp (UTC): $RUN_TS"
  echo "- Verdict: \`$actual_verdict\`"
  echo "- Assertions: $((row_count + fs_count + 7)) total, $fail failed"
  echo ""
  if [[ -s "$ANALYTICS_FILE" ]]; then
    echo "## Run analytics (from stream-json)"
    echo ""
    jq -r '
      "- Total cost: $\(.total_cost_usd // "?")",
      "- API duration: \(.duration_api_ms // "?") ms",
      "- Wall duration: \(.duration_ms // "?") ms",
      "- Assistant turns: \(.assistant_turns)",
      "- Stop reason: \(.stop_reason // "?"), errors: \(.errors | length)"
    ' "$ANALYTICS_FILE"
    echo ""
    echo "### Tool calls"
    echo ""
    echo "| Tool | Count |"
    echo "|------|-------|"
    jq -r '.tool_calls_by_name | to_entries[] | "| \(.key) | \(.value) |"' "$ANALYTICS_FILE"
    echo ""
    echo "### Hook events"
    echo ""
    echo "| Event | Count |"
    echo "|-------|-------|"
    jq -r '.hook_events_by_type | to_entries[] | "| \(.key) | \(.value) |"' "$ANALYTICS_FILE"
    echo ""
    echo "### Token + cost breakdown by model"
    echo ""
    jq -r '
      .model_usage | to_entries[] |
      "- **\(.key)**: input=\(.value.inputTokens), output=\(.value.outputTokens), cache_read=\(.value.cacheReadInputTokens), cache_create=\(.value.cacheCreationInputTokens), cost=$\(.value.costUSD)"
    ' "$ANALYTICS_FILE"
    echo ""
  fi
  if grep -q '"event":"step_done"' "$EVENT_FILE" 2>/dev/null; then
    echo "## Per-step durations + tokens (from [BATCH] event stream)"
    echo ""
    echo "| Step | Duration | Tokens in | Tokens out |"
    echo "|------|----------|-----------|------------|"
    jq -r 'select(.event=="step_done") | "| \(.step) | \(.duration_s)s | \(.tokens_in // "-") | \(.tokens_out // "-") |"' "$EVENT_FILE"
    echo ""
  else
    echo "## Per-step durations"
    echo ""
    echo "_No [BATCH] step_done events emitted; Skill produced final summary instead._"
    echo "_(Event protocol persistence: file-persistence rule per JUVANT_OS.md § Batch mode.)_"
    echo ""
  fi
} > "$RESULTS_MD"

echo ""
echo "▶ Results persisted:"
echo "  - $RESULTS_JSONL"
echo "  - $RESULTS_MD"

if [[ "$fail" -gt 0 ]]; then
  echo ""
  echo "BATCH RUN FAILED: $fail assertion(s) violated." >&2
  KEEP_TMP=1
  exit 5
fi

echo ""
echo "BATCH RUN PASS: scenario $SCENARIO complete, all assertions satisfied."
