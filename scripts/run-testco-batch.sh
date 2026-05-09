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

# ─── flag parsing ──────────────────────────────────────────────────────
FIXTURE=""
KEEP_TMP=0
DRY_RUN=0
RENDER=1
SKILL_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-tmp) KEEP_TMP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-render) RENDER=0; shift ;;
    --skill-version=*) SKILL_VERSION="${1#--skill-version=}"; shift ;;
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

if [[ "$DRY_RUN" != "1" ]] && ! command -v claude >/dev/null; then
  echo "ERROR: claude CLI not on PATH." >&2
  exit 1
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
  local cumul_bash="0" cumul_agent="0" cumul_orphans="0"

  for entry in "${STEP_ORDER[@]}"; do
    local step="${entry%%:*}" name="${entry#*:}"
    local started done_evt status icon dur_s tok_in tok_out check
    started=$(jq -r --arg s "$step" 'select(.event=="step_start" and .step==$s) | .ts' "$jsonl" 2>/dev/null | tail -1)
    done_evt=$(jq -c --arg s "$step" 'select(.event=="step_done" and .step==$s)' "$jsonl" 2>/dev/null | tail -1)
    check=$(jq -c --arg s "$step" 'select(.event=="checkpoint" and .step==$s)' "$jsonl" 2>/dev/null | tail -1)

    if [[ -n "$done_evt" ]]; then
      status="done"
      icon=$'\033[32m✓\033[0m'
      dur_s=$(jq -r '.duration_s // "?"' <<<"$done_evt")
      tok_in=$(jq -r '.tokens_in // 0' <<<"$done_evt")
      tok_out=$(jq -r '.tokens_out // 0' <<<"$done_evt")
      cumul_dur=$(awk -v a="$cumul_dur" -v b="$dur_s" 'BEGIN{printf "%.1f", a+b}')
      cumul_in=$((cumul_in + tok_in))
      cumul_out=$((cumul_out + tok_out))
    elif [[ -n "$started" ]]; then
      status="running"
      icon=$'\033[33m▶\033[0m'
      dur_s="..."
      tok_in="-"
      tok_out="-"
    else
      status="pending"
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
echo "▶ Spawning Skill in batch mode..."

ACTIVATION_PROMPT="Initialize Juvant OS using batch inputs from .juvant/batch-inputs.yaml"

# Run claude headless. Pipe stdout to both session.log and the parser
# that splits [BATCH] events into events.jsonl.
(
  cd "$TMP_DIR"
  claude --print --permission-mode bypassPermissions "$ACTIVATION_PROMPT" 2>&1
) | tee "$LOG_FILE" | while IFS= read -r line; do
  # Capture [BATCH] events into the jsonl stream.
  if [[ "$line" == "[BATCH] "* ]]; then
    payload="${line#[BATCH] }"
    # Validate payload is JSON before appending.
    if jq -e '.event' >/dev/null 2>&1 <<<"$payload"; then
      printf '%s\n' "$payload" >> "$EVENT_FILE"
    fi
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
  # Append file events to event_file, preserving any stdout-parsed events
  # that landed first. Dedupe on (event, step, ts) — same logical event
  # may arrive twice (once via stdout, once via file).
  cat "$PERSISTED_EVENTS" >> "$EVENT_FILE"
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
  must_contain=$(yq -r ".expect.filesystem_assertions[$i].must_contain // empty" "$FIXTURE")
  must_not_contain=$(yq -r ".expect.filesystem_assertions[$i].must_not_contain // empty" "$FIXTURE")
  must_not_exist=$(yq -r ".expect.filesystem_assertions[$i].must_not_exist // empty" "$FIXTURE")
  must_exist=$(yq -r ".expect.filesystem_assertions[$i].must_exist // empty" "$FIXTURE")

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
  echo "## Per-step durations + tokens"
  echo ""
  echo "| Step | Duration | Tokens in | Tokens out |"
  echo "|------|----------|-----------|------------|"
  jq -r 'select(.event=="step_done") | "| \(.step) | \(.duration_s)s | \(.tokens_in // "-") | \(.tokens_out // "-") |"' "$EVENT_FILE"
  echo ""
  echo "## Total budget"
  echo ""
  jq -s '
    map(select(.event=="step_done")) |
    {
      duration_s: (map(.duration_s) | add),
      tokens_in: (map(.tokens_in // 0) | add),
      tokens_out: (map(.tokens_out // 0) | add),
      step_count: length
    }' "$EVENT_FILE" | jq -r '"- Total duration: \(.duration_s)s\n- Total tokens in: \(.tokens_in)\n- Total tokens out: \(.tokens_out)\n- Steps completed: \(.step_count)"'
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
