#!/usr/bin/env bash
# helpers/drain-audit-spool.sh
# FEAT-051 — drain the local audit spool to the database out-of-band.
#
# pre-tool-use.sh / post-tool-use.sh append Track-3 audit statements to
# .juvant/audit-spool.sql via juvant_db_exec_async (a local, network-free,
# hang-impossible append) instead of executing them on the tool gating
# path. This drainer flushes the spool to the configured backend (Turso /
# Local SQLite) where the audit log (agent_actions_log) actually lives.
#
# Ordering: the spool is append-only and drained in file order, so a
# pre-tool-use INSERT ('pending') is always applied before the matching
# post-tool-use UPDATE that finalizes it.
#
# Self-bootstrapping: launched in the background from session-start.sh on
# every session start, so the spool flushes without requiring cron. Also
# registered in helpers/install-schedules.sh for long-running sessions.
#
# Crash-safety: the current spool is atomically claimed (renamed) before
# draining, so writers starting a fresh spool never race the drain.
# Statements are applied one at a time, in order; on failure only the
# UNAPPLIED tail is re-queued ahead of any new appends — nothing is lost,
# nothing is applied twice (so no duplicate audit rows on a mid-batch
# failure), and a flaky/offline backend simply defers the remainder to the
# next run (eventual consistency; Track-3 is forensic, not real-time).

set -euo pipefail

# launchd / cron provide a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin) —
# APPEND the Homebrew dirs so turso/jq are found there, without shadowing
# a turso the caller deliberately put first on PATH (e.g. the fake-turso
# shim in tests/hooks/run-tests.sh). Append, not prepend, on purpose.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# db.sh expects SCRIPT_DIR to point at the hooks dir for path resolution.
SCRIPT_DIR="$REPO_ROOT/hooks"
# shellcheck disable=SC1091
. "$REPO_ROOT/hooks/lib/db.sh"
# Disable juvant_db_exec's own spool fallback: this script is the drain and
# is the single source of re-queueing (REMAINING+merge). Two spoolers on the
# same statement produce duplicate audit rows — the invariant this script is
# designed to prevent.
export JUVANT_DB_EXEC_NO_SPOOL=1

# Single source of truth for the spool path (honors JUVANT_SPOOL).
SPOOL="$(juvant_spool_path)"

# ── decisions#303 R3: drain statement allowlist ──────────────────────────────
# The spool is a plain file in an agent-writable directory, and every line of it
# is executed with the HOOK's DB credentials — so, unchecked, it is an SQL
# injection channel (e.g. a planted `INSERT INTO decisions (…approved_by…)`).
# Every line is therefore matched STRICTLY against the closed set of statement
# shapes the framework itself writes to the spool, before it is executed:
# statement type + target table + exact column list (+ for UPDATEs the exact SET
# columns and WHERE skeleton). Every value position admits only an SQL literal —
# a quoted string with '' escaping, a number, or NULL (and, where the writer
# emits a constant, only that constant). A subquery, a function call, an
# operator, a comment or a second statement can never sit in a value position,
# and the anchored `;…$` tail rejects anything stacked after the statement.
#
# Shapes (one line == one statement: both spool writers in hooks/lib/db.sh
# collapse newlines to spaces, so the patterns allow arbitrary whitespace runs):
#   aal-insert        hooks/pre-tool-use.sh (Track 3 INSERT; ±started_at, ±spec_id
#                     — the ± forms cover rows spooled by older framework versions)
#                     and hooks/session-start.sh (HooksIntegrity row)
#   aal-config        hooks/config-change.sh (sync; spooled on transport failure)
#   aal-success       hooks/post-tool-use.sh (±args_hash — AskUserQuestion omits it)
#   aal-failure       hooks/post-tool-use-failure.sh (sync)
#   sal-incident      hooks/pre-tool-use.sh Track 2e + Track 2g
#   agents-session    hooks/session-start.sh (sync, with session_id)
#   agents-status     hooks/session-start.sh, subagent-start.sh, subagent-stop.sh,
#                     session-end.sh (sync)
#   snapshot          hooks/pre-compact.sh (sync)
#   msg-wrap          hooks/session-end.sh wrap-up reminder (sync)
#   msg-cso           helpers/cso-weekly-audit.sh escalation (sync)
#   atu-main          hooks/lib/track-tokens.sh main-session UPSERT (sync)
#   atu-subagent      hooks/lib/track-tokens.sh subagent INSERT (sync)
# The one other juvant_db_exec write that could reach the spool, audit-reconcile's
# `UPDATE decisions … status='executed'`, is now never spooled (it re-runs on its
# schedule), so NO write to the decisions table is ever accepted from the spool.
#
# A line that matches no shape is NOT executed: it is appended to the quarantine
# file next to the spool, and one high-severity security_audit_log row
# (category 'spool-injection') + one alert are emitted per run (see
# _quarantine_report). Matching runs in the C locale so a multi-byte or invalid
# UTF-8 byte in a free-text literal never fails `[^']` (UTF-8 never encodes 0x27
# inside a multi-byte sequence, so byte-wise matching is exact).
export LC_ALL=C
_Q_W='[[:space:]]*'
_Q_W1='[[:space:]]+'
_Q_S="'([^']|'')*'"                       # string literal, '' escaping
_Q_SN="(${_Q_S}|NULL)"
_Q_N='-?[0-9]+(\.[0-9]+)?'                # numeric literal
_Q_NN="(${_Q_N}|[Nn][Uu][Ll][Ll])"        # jq -r can emit a bare `null`
_Q_I='[0-9]+'
_Q_END="${_Q_W};${_Q_W}\$"
# _q_list <item>... → "(item, item, …)" with free whitespace around separators.
_q_list() {
  local _o="\\(${_Q_W}" _x _first=1
  for _x in "$@"; do
    [[ "$_first" -eq 1 ]] || _o+="${_Q_W},${_Q_W}"
    _o+="$_x"; _first=0
  done
  printf '%s' "${_o}${_Q_W}\\)"
}
# _q_eq <col> <value-regex> → "col = value"
_q_eq() { printf '%s' "${1}${_Q_W}=${_Q_W}${2}"; }
# _q_insert <table> <ncols> <col>... <val>... → full anchored INSERT pattern.
_q_insert() {
  local _t="$1" _n="$2"; shift 2
  printf '%s' "^${_Q_W}INSERT${_Q_W1}INTO${_Q_W1}${_t}${_Q_W}$(_q_list "${@:1:$_n}")${_Q_W}VALUES${_Q_W}$(_q_list "${@:$((_n + 1))}")"
}

_ALLOW_NAME=(); _ALLOW_RE=()
_q_add() { _ALLOW_NAME+=("$1"); _ALLOW_RE+=("$2"); }

# agent_actions_log INSERT (pre-tool-use.sh / session-start.sh).
_AAL_C=(session_id agent tool_name args_hash status deny_reason input_summary)
_AAL_V=("$_Q_SN" "$_Q_S" "$_Q_S" "$_Q_S" "'(pending|denied|failed)'" "$_Q_SN" "$_Q_S")
_q_add aal-insert "$(_q_insert agent_actions_log 7 "${_AAL_C[@]}" "${_AAL_V[@]}")${_Q_END}"
_q_add aal-insert "$(_q_insert agent_actions_log 8 "${_AAL_C[@]}" started_at "${_AAL_V[@]}" "$_Q_S")${_Q_END}"
_q_add aal-insert "$(_q_insert agent_actions_log 8 "${_AAL_C[@]}" spec_id "${_AAL_V[@]}" "$_Q_I")${_Q_END}"
_q_add aal-insert "$(_q_insert agent_actions_log 9 "${_AAL_C[@]}" started_at spec_id "${_AAL_V[@]}" "$_Q_S" "$_Q_I")${_Q_END}"

# agent_actions_log INSERT (config-change.sh).
_q_add aal-config "$(_q_insert agent_actions_log 8 \
  session_id agent tool_name args_hash status input_summary started_at ended_at \
  "$_Q_SN" "'system'" "'ConfigChange'" "$_Q_S" "'success'" "$_Q_S" "$_Q_S" "$_Q_S")${_Q_END}"

# agent_actions_log finalizing UPDATEs (post-tool-use.sh / post-tool-use-failure.sh).
_AAL_SUBQ_HEAD="${_Q_W1}WHERE${_Q_W1}id${_Q_W}=${_Q_W}\\(${_Q_W}SELECT${_Q_W1}id${_Q_W1}FROM${_Q_W1}agent_actions_log${_Q_W1}WHERE${_Q_W1}$(_q_eq session_id "$_Q_S")${_Q_W1}AND${_Q_W1}$(_q_eq agent "$_Q_S")${_Q_W1}AND${_Q_W1}$(_q_eq tool_name "$_Q_S")"
_AAL_SUBQ_TAIL="${_Q_W1}ORDER${_Q_W1}BY${_Q_W1}started_at${_Q_W1}DESC${_Q_W1}LIMIT${_Q_W1}1${_Q_W}\\)${_Q_END}"
_q_add aal-success "^${_Q_W}UPDATE${_Q_W1}agent_actions_log${_Q_W1}SET${_Q_W1}$(_q_eq status "'success'")${_Q_W},${_Q_W}$(_q_eq result_hash "$_Q_S")${_Q_W},${_Q_W}$(_q_eq ended_at "$_Q_S")${_AAL_SUBQ_HEAD}${_Q_W1}AND${_Q_W1}$(_q_eq status "'pending'")(${_Q_W1}AND${_Q_W1}$(_q_eq args_hash "$_Q_S"))?${_AAL_SUBQ_TAIL}"
_q_add aal-failure "^${_Q_W}UPDATE${_Q_W1}agent_actions_log${_Q_W1}SET${_Q_W1}$(_q_eq status "'failure'")${_Q_W},${_Q_W}$(_q_eq ended_at "$_Q_S")${_AAL_SUBQ_HEAD}${_Q_W1}AND${_Q_W1}$(_q_eq args_hash "$_Q_S")${_Q_W1}AND${_Q_W1}$(_q_eq status "'pending'")${_AAL_SUBQ_TAIL}"

# security_audit_log incident row (pre-tool-use.sh Track 2e / Track 2g).
_q_add sal-incident "$(_q_insert security_audit_log 8 \
  auditor scope audit_type layer finding severity category status \
  "'hook:pre-tool-use'" "'company'" "'incident'" "'agents'" "$_Q_S" "'(high|info)'" "$_Q_S" "'open'")${_Q_END}"

# agents status UPDATEs (session-start / subagent-start / subagent-stop / session-end).
_q_add agents-session "^${_Q_W}UPDATE${_Q_W1}agents${_Q_W1}SET${_Q_W1}$(_q_eq status "'active'")${_Q_W},${_Q_W}$(_q_eq session_id "$_Q_S")${_Q_W},${_Q_W}$(_q_eq updated_at "$_Q_S")${_Q_W1}WHERE${_Q_W1}$(_q_eq role "$_Q_S")${_Q_END}"
_q_add agents-status "^${_Q_W}UPDATE${_Q_W1}agents${_Q_W1}SET${_Q_W1}$(_q_eq status "'(active|inactive)'")${_Q_W},${_Q_W}$(_q_eq updated_at "$_Q_S")${_Q_W1}WHERE${_Q_W1}$(_q_eq role "$_Q_S")${_Q_END}"

# session_snapshots INSERT (pre-compact.sh; snapshot is base64).
_q_add snapshot "$(_q_insert session_snapshots 4 agent snapshot session_id created_at \
  "$_Q_S" "'[A-Za-z0-9+/=]*'" "$_Q_S" "$_Q_S")${_Q_END}"

# messages INSERTs (session-end.sh wrap-up reminder / cso-weekly-audit.sh escalation).
_q_add msg-wrap "$(_q_insert messages 6 from_agent to_agent type content priority notify_ceo \
  "'cos'" "'cos'" "'session-wrap-reminder'" "$_Q_S" "'high'" "1")${_Q_END}"
_q_add msg-cso "$(_q_insert messages 7 from_agent to_agent type content priority notify_ceo created_at \
  "'cso-weekly-audit'" "'cos'" "'escalation'" "$_Q_S" "'critical'" "1" "$_Q_S")${_Q_END}"

# agent_token_usage INSERTs (hooks/lib/track-tokens.sh).
_ATU_C=(id session_id parent_session_id agent_name principal_id project_slug model
        input_tokens output_tokens cache_write_tokens cache_read_tokens
        started_at ended_at computed_cost_usd)
_ATU_UPSERT="${_Q_W1}ON${_Q_W1}CONFLICT${_Q_W}\\(${_Q_W}id${_Q_W}\\)${_Q_W1}DO${_Q_W1}UPDATE${_Q_W1}SET${_Q_W1}"
_first=1
for _c in input_tokens output_tokens cache_write_tokens cache_read_tokens ended_at computed_cost_usd; do
  [[ "$_first" -eq 1 ]] || _ATU_UPSERT+="${_Q_W},${_Q_W}"
  _ATU_UPSERT+="$(_q_eq "$_c" "excluded\\.${_c}")"; _first=0
done
unset _first _c
_q_add atu-main "$(_q_insert agent_token_usage 14 "${_ATU_C[@]}" \
  "$_Q_S" "$_Q_S" "NULL" "'main'" "$_Q_SN" "$_Q_SN" "$_Q_S" \
  "$_Q_NN" "$_Q_NN" "$_Q_NN" "$_Q_NN" "$_Q_S" "$_Q_SN" "$_Q_NN")${_ATU_UPSERT}${_Q_END}"
_q_add atu-subagent "$(_q_insert agent_token_usage 14 "${_ATU_C[@]}" \
  "$_Q_S" "$_Q_S" "$_Q_S" "$_Q_S" "$_Q_SN" "$_Q_SN" "$_Q_S" \
  "$_Q_NN" "$_Q_NN" "$_Q_NN" "$_Q_NN" "$_Q_S" "$_Q_S" "$_Q_NN")${_Q_END}"

# 0 (and the shape name in _ALLOW_HIT) if the line is an allowlisted statement.
_stmt_allowed() {
  local _i
  _ALLOW_HIT=""
  for _i in "${!_ALLOW_RE[@]}"; do
    if [[ "$1" =~ ${_ALLOW_RE[$_i]} ]]; then
      _ALLOW_HIT="${_ALLOW_NAME[$_i]}"
      return 0
    fi
  done
  return 1
}

# Quarantine file: same directory as the spool (honors JUVANT_SPOOL), e.g.
# .juvant/audit-spool.sql → .juvant/audit-spool.quarantine.
_SPOOL_BASE="$(basename "$SPOOL")"
QUARANTINE="$(dirname "$SPOOL")/${_SPOOL_BASE%.sql}.quarantine"
_Q_COUNT=0; _Q_STALE=0; _Q_KEPT=0; _Q_FIRST_HASH=""; _Q_FIRST_EXCERPT=""

_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else echo "no-hash"; fi
}

# Append one non-matching line to the quarantine file (never executed).
# $1 = statement, $2 = source file name, $3 = 1 if from a stranded batch.
# Returns 1 if the quarantine write failed — the caller must then keep the line
# (re-queue it) rather than drop it: unexecuted AND preserved, never lost.
_quarantine() {
  local _h _ex _rc=0
  _h=$(printf '%s' "$1" | _sha256)
  if { printf -- '-- quarantined %s source=%s sha256=%s (decisions#303 R3: not in the drain statement allowlist; NOT executed)\n' \
         "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$_h"
       printf '%s\n' "$1"
     } >> "$QUARANTINE" 2>/dev/null; then
    chmod 600 "$QUARANTINE" 2>/dev/null || true
    _Q_COUNT=$(( _Q_COUNT + 1 ))
    [[ "${3:-0}" == "1" ]] && _Q_STALE=$(( _Q_STALE + 1 ))
    echo "[drain-audit-spool] SECURITY: quarantined a non-allowlisted spool statement from $2 (sha256=${_h}) — not executed" >&2
  else
    # Still an incident: report it, keep the line (unexecuted) for the next run.
    _Q_KEPT=$(( _Q_KEPT + 1 ))
    _rc=1
    echo "[drain-audit-spool] SECURITY: could not write quarantine file $QUARANTINE; non-allowlisted statement from $2 (sha256=${_h}) kept unexecuted for the next run" >&2
  fi
  if [[ -z "$_Q_FIRST_HASH" ]]; then
    _Q_FIRST_HASH="$_h"
    # Short, sanitised excerpt only: quotes and every other non-allowlisted
    # character become '?', so neither the DB row nor the alert can carry the
    # raw quarantined SQL (or anything that re-parses as SQL / markup).
    _ex=$(printf '%s' "$1" | tr -c 'A-Za-z0-9 _(),.=*-' '?' | tr -s ' ' | cut -c1-80)
    _Q_FIRST_EXCERPT="$_ex"
  fi
  return "$_rc"
}

# One high-severity security_audit_log row (written SYNCHRONOUSLY — never via
# the spool it is reporting on) + one fire-and-forget alert per run. Runs on
# EXIT so every exit path of the drain reports what it quarantined.
# SC2329 (newer shellcheck) / SC2317 (older, e.g. the CI runner's): the body is
# reached only via `trap … EXIT`, which neither version can see.
# shellcheck disable=SC2317,SC2329
_quarantine_report() {
  [[ $(( _Q_COUNT + _Q_KEPT )) -gt 0 ]] || return 0
  local _finding _cfg _msg _hook _card _tg_token _tg_chat _kept=""
  [[ "$_Q_KEPT" -gt 0 ]] && _kept="; ${_Q_KEPT} more kept UNEXECUTED in the spool because the quarantine file could not be written"
  _finding="audit-spool injection: ${_Q_COUNT} spooled statement(s) outside the drain statement allowlist were quarantined and NOT executed (${_Q_STALE} from stranded batches)${_kept}; quarantine=$(basename "$QUARANTINE"); first sha256=${_Q_FIRST_HASH}; first excerpt (sanitised): ${_Q_FIRST_EXCERPT} (decisions#303 R3)"
  juvant_db_exec "INSERT INTO security_audit_log
    (auditor, scope, audit_type, layer, finding, severity, category, status)
    VALUES
    ('helper:drain-audit-spool', 'company', 'incident', 'agents',
     '$(printf '%s' "$_finding" | sed "s/'/''/g")', 'high', 'spool-injection', 'open');" \
    || echo "[drain-audit-spool] WARN: failed to write the spool-injection security_audit_log row (quarantine file is the durable record)" >&2

  _msg="[SECURITY ALERT] audit spool injection: $(( _Q_COUNT + _Q_KEPT )) statement(s) outside the allowlist, not executed (drain-audit-spool, decisions#303 R3). First excerpt: ${_Q_FIRST_EXCERPT} — review $(basename "$QUARANTINE") with the CSO."
  _cfg="${JUVANT_CONFIG:-$REPO_ROOT/.juvant/config.json}"
  if [[ -f "$_cfg" ]] && command -v jq >/dev/null 2>&1; then
    # Same notification path as pre-tool-use.sh Track 2e; fire-and-forget.
    _hook=$(jq -r '.notifications.teams_webhooks.approvals // ""' "$_cfg" 2>/dev/null || echo "")
    if [[ -n "$_hook" ]]; then
      _card=$(jq -n --arg msg "$_msg" '{type:"AdaptiveCard","$schema":"http://adaptivecards.io/schemas/adaptive-card.json",version:"1.4",body:[{type:"TextBlock",text:$msg,wrap:true}]}')
      curl -s --connect-timeout 5 --max-time 10 -X POST "$_hook" \
        -H "Content-Type: application/json" -d "$_card" >/dev/null 2>&1 &
    fi
    _tg_token=$(jq -r '.notifications.telegram_bot_token // ""' "$_cfg" 2>/dev/null || echo "")
    _tg_chat=$(jq -r '.notifications.telegram_chat_id // ""' "$_cfg" 2>/dev/null || echo "")
    if [[ -n "$_tg_token" && -n "$_tg_chat" ]]; then
      curl -s --connect-timeout 5 --max-time 10 -X POST \
        "https://api.telegram.org/bot${_tg_token}/sendMessage" \
        -d "chat_id=${_tg_chat}" --data-urlencode "text=${_msg}" >/dev/null 2>&1 &
    fi
  fi
  return 0
}

# ── decisions#298 (L1-F1): re-claim stranded batches ─────────────────────────
# A drain killed mid-loop (sleep, SIGKILL, session exit) leaves its claimed
# batch behind as "$SPOOL.draining.<pid>" (or "$SPOOL.merge.<pid>" if killed
# while re-queueing). Nothing ever claimed those names again, so the audit
# rows inside were silently stranded. Every run now looks for them first.
#
# A file is STALE when its owner pid is gone (a live drain's file is never
# touched) or when it is older than DRAIN_STALE_MAX_AGE_MIN (default 60) — a
# drain that long is stuck, and a recycled pid must not shelter a file forever.
# Stale files are applied BEFORE the live spool (they are older; file order is
# audit order) with an idempotence guard (see _guard_reclaimed) because a killed
# drain may already have committed part of its batch.
_STALE_MAX_AGE_MIN="${DRAIN_STALE_MAX_AGE_MIN:-60}"
_stale_files() {
  local _f _pid
  for _f in "$SPOOL".draining.* "$SPOOL".merge.*; do
    [[ -f "$_f" ]] || continue
    _pid="${_f##*.}"
    [[ "$_pid" =~ ^[0-9]+$ ]] || continue
    [[ "$_pid" == "$$" ]] && continue
    if kill -0 "$_pid" 2>/dev/null; then
      # Owner alive: only stale if older than the max age.
      [[ -n "$(find "$_f" -mmin "+$_STALE_MAX_AGE_MIN" 2>/dev/null)" ]] || continue
    fi
    printf '%s\n' "$_f"
  done
}
STALE_LIST="$(_stale_files)"

# Nothing spooled and nothing stranded — no-op (fast, common path).
[[ -s "$SPOOL" || -n "$STALE_LIST" ]] || exit 0

juvant_db_resolve
if [[ -z "$JUVANT_DB_PROVIDER" ]]; then
  echo "[drain-audit-spool] WARN: no db.provider configured; leaving spool intact" >&2
  exit 0
fi
# decisions#303 R3: report anything quarantined below, whatever exit path we take.
trap '_quarantine_report' EXIT

# Rewrite one spooled agent_actions_log INSERT into an idempotent form, so that
# replaying a batch that was partially applied before the drain died does not
# duplicate rows. Key: session_id + agent + tool_name + args_hash, plus the
# explicit started_at when the row carries one (rows written since decisions#298
# do, which makes the key exact). Legacy rows without started_at are keyed
# without time, so a legitimately repeated identical command in the SAME session
# can be collapsed — a deliberate bias toward "no duplicate audit rows" for
# batches that are already known-damaged. Anything not matching the expected
# shape (UPDATEs are idempotent; other statements) is passed through unchanged.
# Only ever called on a line that already passed _stmt_allowed (decisions#303
# R3), so every captured value is a plain SQL literal.
_guard_reclaimed() {
  local _s="$1"
  local _re_stmt='^INSERT INTO agent_actions_log[[:space:]]*\(([^)]*)\)[[:space:]]*VALUES[[:space:]]*\((.*)\);[[:space:]]*$'
  local _re_key="^'([^']*)', '([^']*)', '([^']*)', '([0-9a-f]{64})', '"
  local _re_ts="'([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})'(, [0-9]+)?\$"
  local _cols _vals _key
  if [[ "$_s" =~ $_re_stmt ]]; then
    _cols="${BASH_REMATCH[1]}"; _vals="${BASH_REMATCH[2]}"
    if [[ "$_vals" =~ $_re_key ]]; then
      _key="session_id='${BASH_REMATCH[1]}' AND agent='${BASH_REMATCH[2]}' AND tool_name='${BASH_REMATCH[3]}' AND args_hash='${BASH_REMATCH[4]}'"
      if [[ "$_cols" == *started_at* && "$_vals" =~ $_re_ts ]]; then
        _key="$_key AND started_at='${BASH_REMATCH[1]}'"
      fi
      printf 'INSERT INTO agent_actions_log (%s) SELECT %s WHERE NOT EXISTS (SELECT 1 FROM agent_actions_log WHERE %s);' \
        "$_cols" "$_vals" "$_key"
      return 0
    fi
  fi
  printf '%s' "$_s"
}

# Apply one stranded batch. Statements already in the DB are skipped by the
# guard; an unapplied tail (backend failure) is re-queued ahead of the live
# spool, exactly like the main path. The original is copied aside first and
# removed only once every statement is applied or safely re-queued.
# Returns 0 if the batch was fully applied, 1 if a tail was re-queued.
_reclaim_one() {
  local _f="$1" _stmt _a=0 _failed=0 _rem="" _mt _age_min=0
  _mt=$(stat -f %m "$_f" 2>/dev/null || stat -c %Y "$_f" 2>/dev/null || echo 0)
  [[ "$_mt" =~ ^[0-9]+$ && "$_mt" -gt 0 ]] && _age_min=$(( ( $(date +%s) - _mt ) / 60 ))
  echo "[drain-audit-spool] WARN: re-claiming stranded batch $(basename "$_f") (age ${_age_min}m, $(grep -c . "$_f" || true) statement(s))" >&2
  local _kdir="${JUVANT_BACKUP_DIR:-$(dirname "$SPOOL")/backups}"
  if mkdir -p "$_kdir" 2>/dev/null; then
    cp "$_f" "$_kdir/audit-stale.$(date -u +%Y%m%dT%H%M%SZ).$(basename "$_f").sql" 2>/dev/null || {
      echo "[drain-audit-spool] WARN: could not preserve $(basename "$_f"); leaving it in place" >&2
      return 1
    }
  else
    echo "[drain-audit-spool] WARN: cannot create backup dir $_kdir; leaving $(basename "$_f") in place" >&2
    return 1
  fi
  # shellcheck disable=SC2094  # $_f is only read here; basename "$_f" is a label
  while IFS= read -r _stmt || [[ -n "$_stmt" ]]; do
    [[ "$_stmt" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$_failed" -eq 1 ]]; then _rem+="$_stmt"$'\n'; continue; fi
    # decisions#303 R3: same allowlist as the live spool — a stranded batch is
    # just as agent-writable, so no unknown statement is ever passed through.
    if ! _stmt_allowed "$_stmt"; then
      _quarantine "$_stmt" "$(basename "$_f")" 1 && continue
      _failed=1; _rem+="$_stmt"$'\n'; continue
    fi
    if juvant_db_exec "$(_guard_reclaimed "$_stmt")"; then
      _a=$(( _a + 1 ))
    else
      _failed=1; _rem+="$_stmt"$'\n'
    fi
  done < "$_f"
  if [[ "$_failed" -eq 1 ]]; then
    if [[ -s "$SPOOL" ]]; then
      { printf '%s' "$_rem"; cat "$SPOOL"; } > "$SPOOL.reclaim.$$" && mv "$SPOOL.reclaim.$$" "$SPOOL"
    else
      printf '%s' "$_rem" > "$SPOOL"
    fi
    rm -f "$_f"
    echo "[drain-audit-spool] WARN: stranded batch applied $_a then failed; $(printf '%s' "$_rem" | grep -c . || true) statement(s) re-queued" >&2
    return 1
  fi
  rm -f "$_f"
  echo "[drain-audit-spool] reclaimed $(basename "$_f"): $_a statement(s) applied (duplicates skipped)"
  return 0
}

_RECLAIM_FAILED=0
if [[ -n "$STALE_LIST" ]]; then
  while IFS= read -r _sf; do
    [[ -z "$_sf" ]] && continue
    _reclaim_one "$_sf" || { _RECLAIM_FAILED=1; break; }
  done <<< "$STALE_LIST"
  # Keep the preserved copies bounded (newest 20).
  # shellcheck disable=SC2012
  ls -1t "${JUVANT_BACKUP_DIR:-$(dirname "$SPOOL")/backups}"/audit-stale.*.sql 2>/dev/null \
    | tail -n +21 | while IFS= read -r _old; do rm -f "$_old"; done
fi
# Backend failed while reclaiming: the tail is re-queued; stop here, retry next run.
[[ "$_RECLAIM_FAILED" -eq 0 ]] || exit 1
# Reclaim may have been the only work (live spool empty).
[[ -s "$SPOOL" ]] || exit 0

# Pre-drain backup: timestamped copy before the atomic rename so that a
# mid-drain failure (SIGKILL, disk-full on apply, hung backend) leaves a
# recoverable snapshot.  Fail-closed: if the backup directory cannot be
# created, the copy fails, or the integrity check fails, leave the spool
# intact and defer to the next run rather than risking silent loss of
# queued audit rows.  Override JUVANT_BACKUP_DIR to redirect backups
# (useful in tests).  Override DRAIN_BACKUP_RETAIN to change the
# retention window (default: 7 most-recent backups).
_BACKUP_DIR="${JUVANT_BACKUP_DIR:-$(dirname "$SPOOL")/backups}"
mkdir -p "$_BACKUP_DIR" 2>/dev/null || {
  echo "[drain-audit-spool] WARN: cannot create backup dir $_BACKUP_DIR; aborting drain" >&2
  exit 0
}
_BACKUP="$_BACKUP_DIR/audit-spool.$(date -u +%Y%m%dT%H%M%SZ).sql"
cp "$SPOOL" "$_BACKUP" 2>/dev/null || {
  echo "[drain-audit-spool] WARN: backup failed ($SPOOL → $_BACKUP); aborting drain" >&2
  exit 0
}
# Integrity check: line counts of source and backup must agree.
# tr strips the leading whitespace that BSD/macOS wc -l pads into its output.
_SRC_LINES=$(wc -l < "$SPOOL"    | tr -d '[:space:]')
_BAK_LINES=$(wc -l < "$_BACKUP"  | tr -d '[:space:]')
if [[ "$_SRC_LINES" -ne "$_BAK_LINES" ]]; then
  echo "[drain-audit-spool] WARN: backup integrity check failed (src=${_SRC_LINES} bak=${_BAK_LINES}); aborting drain" >&2
  rm -f "$_BACKUP"
  exit 0
fi
# Retention prune: keep the most-recent N backups; delete anything older.
_BACKUP_RETAIN="${DRAIN_BACKUP_RETAIN:-7}"
# ls -1t lists newest-first; tail skips the N we keep and feeds the rest to rm.
# shellcheck disable=SC2012
ls -1t "$_BACKUP_DIR"/audit-spool.*.sql 2>/dev/null \
  | tail -n "+$(( _BACKUP_RETAIN + 1 ))" \
  | while IFS= read -r _old; do rm -f "$_old"; done

# Atomically claim the current batch so concurrent writers (which open the
# spool fresh per append) start a new file instead of racing the drain.
WORK="$SPOOL.draining.$$"
mv "$SPOOL" "$WORK" 2>/dev/null || exit 0

# Apply the claimed batch one statement per line, in order. The async
# writer (juvant_db_exec_async) collapses every statement to a single
# physical line, so a line == a statement. Incremental apply is what makes
# a PARTIAL failure safe: if the backend drops after N statements have
# already auto-committed, the old single-stream path re-queued the WHOLE
# batch — re-applying those N already-committed INSERTs on the next run and
# DUPLICATING those audit rows. Here only the unapplied tail is re-queued.
APPLIED=0
FAILED=0
REMAINING=""
while IFS= read -r _stmt || [[ -n "$_stmt" ]]; do
  [[ "$_stmt" =~ ^[[:space:]]*$ ]] && continue
  if [[ "$FAILED" -eq 1 ]]; then
    REMAINING+="$_stmt"$'\n'           # already failed — defer the rest in order
    continue
  fi
  # decisions#303 R3: never execute a line outside the statement allowlist.
  if ! _stmt_allowed "$_stmt"; then
    _quarantine "$_stmt" "$_SPOOL_BASE" 0 && continue
    FAILED=1                           # could not quarantine: keep it, unexecuted
    REMAINING+="$_stmt"$'\n'
    continue
  fi
  if juvant_db_exec "$_stmt"; then
    APPLIED=$(( APPLIED + 1 ))
  else
    FAILED=1
    REMAINING+="$_stmt"$'\n'
  fi
done < "$WORK"
rm -f "$WORK"

if [[ "$FAILED" -eq 0 ]]; then
  _QMSG=""; [[ "$_Q_COUNT" -gt 0 ]] && _QMSG=" ($_Q_COUNT non-allowlisted statement(s) quarantined, not executed)"
  echo "[drain-audit-spool] drained $APPLIED statement(s) to $JUVANT_DB_PROVIDER${_QMSG}"

  # BUG-052: finalize orphaned 'pending' rows the PostToolUse UPDATE never
  # closed. Two sources: (1) async / fire-and-forget tools (SendMessage,
  # ExitPlanMode) for which Claude Code emits no synchronous PostToolUse, so
  # the finalizing UPDATE in post-tool-use.sh never matches; (2) spool
  # tail-loss on SIGKILL / hook-timeout. This reconcile runs HERE — right after
  # a successful drain, the one point where every spooled INSERT ('pending')
  # and UPDATE ('success'/'failure') is in the DB and true orphans are visible.
  # It deliberately does NOT live in session-end.sh / subagent-stop.sh: there
  # the current session's audit rows are still in the spool (drained only at
  # the NEXT session-start), so a DB sweep there would miss exactly the rows it
  # must close. Threshold 1h == audit-reconcile's stuck-pending definition and
  # is far longer than any real in-flight tool call, so a live action of the
  # just-started session is never swept. (Edge case: a concurrent session with
  # a genuine >1h in-flight action would be marked 'terminated'; benign — this
  # is forensic telemetry, and a late PostToolUse UPDATE simply no-ops against
  # the already-closed row since it targets status='pending'.)
  _NOW=$(date -u +"%Y-%m-%d %H:%M:%S")
  juvant_db_exec "UPDATE agent_actions_log
    SET status='terminated', ended_at='$_NOW'
    WHERE status='pending'
      AND started_at < datetime('now','-1 hour');" \
    || echo "[drain-audit-spool] WARN: orphaned-pending reconcile failed" >&2

  exit 0
fi

# Re-queue ONLY the unapplied tail, ahead of any rows appended while we were
# draining, preserving order. The $APPLIED already-committed statements are
# not re-queued → no duplicate audit rows.
_REQ=$(printf '%s' "$REMAINING" | grep -c . || true)
if [[ -s "$SPOOL" ]]; then
  { printf '%s' "$REMAINING"; cat "$SPOOL"; } > "$SPOOL.merge.$$" && mv "$SPOOL.merge.$$" "$SPOOL"
else
  printf '%s' "$REMAINING" > "$SPOOL"
fi
echo "[drain-audit-spool] WARN: drain failed after $APPLIED applied; ${_REQ} statement(s) re-queued for next run" >&2
exit 1
