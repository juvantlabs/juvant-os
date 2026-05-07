#!/usr/bin/env bash
# hooks/lib/track-tokens.sh
# Token-usage capture library for FEAT-024.
#
# Reads a Claude Code session transcript JSONL, aggregates assistant-turn
# `usage` per model, looks up `model_pricing` in Turso, computes
# denormalized cost_usd, and UPSERTs into agent_token_usage.
#
# Two entry points:
#   track_main_session_usage   — UPSERT one row per (session, 'main', model)
#   track_subagent_invocation  — INSERT one row per subagent invocation
#
# Both are no-ops when Turso credentials are missing or the transcript
# path is unreadable. Never blocks the calling hook.

set -euo pipefail

# ---------- internal helpers ----------

# Aggregate usage from a transcript JSONL, grouped by model.
# Echoes a JSON array: [{model, input, output, cache_write, cache_read}, ...]
# Echoes "[]" if file missing or jq unavailable.
_aggregate_usage_by_model() {
  local transcript="$1"
  if [[ -z "$transcript" || ! -f "$transcript" ]]; then
    echo "[]"
    return 0
  fi
  if ! command -v jq &>/dev/null; then
    echo "[]"
    return 0
  fi
  jq -s '
    [
      .[]
      | select(.type=="assistant")
      | select(.message.usage != null)
      | {
          model: (.message.model // "unknown"),
          input:       (.message.usage.input_tokens // 0),
          output:      (.message.usage.output_tokens // 0),
          cache_write: (.message.usage.cache_creation_input_tokens // 0),
          cache_read:  (.message.usage.cache_read_input_tokens // 0)
        }
    ]
    | group_by(.model)
    | map({
        model: .[0].model,
        input:       (map(.input)       | add),
        output:      (map(.output)      | add),
        cache_write: (map(.cache_write) | add),
        cache_read:  (map(.cache_read)  | add)
      })
  ' < "$transcript" 2>/dev/null || echo "[]"
}

# Look up pricing for a model from Turso. Echoes 4 space-separated values:
# input_per_mtok output_per_mtok cache_write_per_mtok cache_read_per_mtok
# Echoes "0 0 0 0" if no row found (cost will be 0; CSO audit catches gap).
_lookup_pricing() {
  local model="$1"
  local row
  row=$(turso db shell "$TURSO_URL" --output csv \
    "SELECT input_per_mtok_usd, output_per_mtok_usd,
            cache_write_per_mtok_usd, cache_read_per_mtok_usd
     FROM model_pricing
     WHERE model='$model'
       AND effective_from <= DATE('now')
       AND (effective_to IS NULL OR effective_to > DATE('now'))
     ORDER BY effective_from DESC LIMIT 1;" 2>/dev/null \
    | tail -n +2 | head -1)
  if [[ -z "$row" ]]; then
    echo "0 0 0 0"
  else
    echo "$row" | tr ',' ' '
  fi
}

# Compute USD cost from token counts and per-Mtok prices.
_compute_cost() {
  local input="$1" output="$2" cache_write="$3" cache_read="$4"
  local p_in="$5" p_out="$6" p_cw="$7" p_cr="$8"
  awk -v i="$input" -v o="$output" -v cw="$cache_write" -v cr="$cache_read" \
      -v pi="$p_in" -v po="$p_out" -v pcw="$p_cw" -v pcr="$p_cr" \
    'BEGIN { printf "%.6f", (i*pi + o*po + cw*pcw + cr*pcr) / 1000000 }'
}

# Quote a value for SQL embedding. Empty → NULL literal.
# bash 3.2 (macOS) mis-handles ${v//\'/\'\'}; sed sidesteps the issue.
_sql_quote() {
  local v="$1"
  if [[ -z "$v" ]]; then
    printf 'NULL'
  else
    local esc
    esc=$(printf '%s' "$v" | sed "s/'/''/g")
    printf "'%s'" "$esc"
  fi
}

# Stable id for a (session, agent, model) triple — used by main-session UPSERT.
_main_row_id() {
  local session="$1" agent="$2" model="$3"
  printf '%s' "${session}-${agent}-${model}"
}

# ---------- public entry points ----------

# UPSERT cumulative usage for a main session. Idempotent: callable on every
# Stop event without producing duplicate rows.
#
# Args:
#   $1 transcript_path
#   $2 session_id
#   $3 started_at  (ISO 8601 UTC, used only on first INSERT)
#   $4 principal_id   (may be empty)
#   $5 project_slug   (may be empty)
#   $6 ended_at_or_empty   ("" → leave NULL → still in-flight)
track_main_session_usage() {
  local transcript="$1" session_id="$2" started_at="$3"
  local principal_id="$4" project_slug="$5" ended_at="$6"

  if [[ -z "${TURSO_URL:-}" ]]; then return 0; fi
  if [[ -z "$transcript" || ! -f "$transcript" ]]; then return 0; fi

  local rows
  rows=$(_aggregate_usage_by_model "$transcript")
  local n
  n=$(echo "$rows" | jq 'length' 2>/dev/null || echo "0")
  if [[ "$n" == "0" ]]; then return 0; fi

  local i=0
  while [[ $i -lt $n ]]; do
    local model input output cache_write cache_read
    model=$(echo "$rows"       | jq -r ".[$i].model")
    input=$(echo "$rows"       | jq -r ".[$i].input")
    output=$(echo "$rows"      | jq -r ".[$i].output")
    cache_write=$(echo "$rows" | jq -r ".[$i].cache_write")
    cache_read=$(echo "$rows"  | jq -r ".[$i].cache_read")

    local pricing p_in p_out p_cw p_cr
    pricing=$(_lookup_pricing "$model")
    read -r p_in p_out p_cw p_cr <<<"$pricing"

    local cost
    cost=$(_compute_cost "$input" "$output" "$cache_write" "$cache_read" \
                         "$p_in" "$p_out" "$p_cw" "$p_cr")

    local id ended_sql principal_sql project_sql
    id=$(_main_row_id "$session_id" "main" "$model")
    ended_sql=$(_sql_quote "$ended_at")
    principal_sql=$(_sql_quote "$principal_id")
    project_sql=$(_sql_quote "$project_slug")

    turso db shell "$TURSO_URL" \
      "INSERT INTO agent_token_usage
        (id, session_id, parent_session_id, agent_name, principal_id,
         project_slug, model, input_tokens, output_tokens,
         cache_write_tokens, cache_read_tokens,
         started_at, ended_at, computed_cost_usd)
       VALUES
        ('$id', '$session_id', NULL, 'main', $principal_sql,
         $project_sql, '$model', $input, $output,
         $cache_write, $cache_read,
         '$started_at', $ended_sql, $cost)
       ON CONFLICT(id) DO UPDATE SET
         input_tokens       = excluded.input_tokens,
         output_tokens      = excluded.output_tokens,
         cache_write_tokens = excluded.cache_write_tokens,
         cache_read_tokens  = excluded.cache_read_tokens,
         ended_at           = excluded.ended_at,
         computed_cost_usd  = excluded.computed_cost_usd;" \
      2>/dev/null || true

    i=$((i+1))
  done
}

# INSERT a fresh row for a subagent invocation that just completed.
# Each invocation is a new row (no UPSERT — SubagentStop fires once per
# invocation).
#
# Args:
#   $1 transcript_path  (subagent's transcript; falls back to parent if same path)
#   $2 parent_session_id
#   $3 agent_name        (e.g. 'cco', 'cfo')
#   $4 started_at        (ISO 8601 UTC)
#   $5 ended_at          (ISO 8601 UTC)
#   $6 principal_id      (may be empty)
#   $7 project_slug      (may be empty)
track_subagent_invocation() {
  local transcript="$1" parent="$2" agent="$3"
  local started_at="$4" ended_at="$5"
  local principal_id="$6" project_slug="$7"

  if [[ -z "${TURSO_URL:-}" ]]; then return 0; fi
  if [[ -z "$transcript" || ! -f "$transcript" ]]; then return 0; fi
  if [[ -z "$agent" ]]; then return 0; fi

  local rows
  rows=$(_aggregate_usage_by_model "$transcript")
  local n
  n=$(echo "$rows" | jq 'length' 2>/dev/null || echo "0")
  if [[ "$n" == "0" ]]; then return 0; fi

  local i=0
  while [[ $i -lt $n ]]; do
    local model input output cache_write cache_read
    model=$(echo "$rows"       | jq -r ".[$i].model")
    input=$(echo "$rows"       | jq -r ".[$i].input")
    output=$(echo "$rows"      | jq -r ".[$i].output")
    cache_write=$(echo "$rows" | jq -r ".[$i].cache_write")
    cache_read=$(echo "$rows"  | jq -r ".[$i].cache_read")

    local pricing p_in p_out p_cw p_cr
    pricing=$(_lookup_pricing "$model")
    read -r p_in p_out p_cw p_cr <<<"$pricing"

    local cost
    cost=$(_compute_cost "$input" "$output" "$cache_write" "$cache_read" \
                         "$p_in" "$p_out" "$p_cw" "$p_cr")

    local id principal_sql project_sql
    id=$(uuidgen 2>/dev/null || echo "$(date +%s%N)-$RANDOM")
    principal_sql=$(_sql_quote "$principal_id")
    project_sql=$(_sql_quote "$project_slug")

    turso db shell "$TURSO_URL" \
      "INSERT INTO agent_token_usage
        (id, session_id, parent_session_id, agent_name, principal_id,
         project_slug, model, input_tokens, output_tokens,
         cache_write_tokens, cache_read_tokens,
         started_at, ended_at, computed_cost_usd)
       VALUES
        ('$id', '$parent', '$parent', '$agent', $principal_sql,
         $project_sql, '$model', $input, $output,
         $cache_write, $cache_read,
         '$started_at', '$ended_at', $cost);" \
      2>/dev/null || true

    i=$((i+1))
  done
}
