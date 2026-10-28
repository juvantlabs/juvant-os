#!/usr/bin/env bash
# hooks/lib/pause-windows.sh
# Declared pause-window ("halt window") consumption, SHARED by every audit
# surface that measures silence (decisions#300 item 15; closes decisions#269 /
# decisions#270):
#   scripts/audit-bootstrap-baseline.sh  (CSO Layer 1 continuity predicate)
#   helpers/cso-weekly-audit.sh          (weekly cadence gate)
#   helpers/audit-reconcile.sh           (Track-3 reconcile continuity line)
#
# Before this lib the window logic lived inline in audit-bootstrap-baseline.sh
# only; the two scheduled helpers either merely MENTIONED the windows in alert
# text or ignored them, so a declared closure raised a CRITICAL cadence alert.
#
# Storage: master_context row key = 'halt_windows' (the key the BUG-070
# reference implementation has always read; the 1.12.0 CHANGELOG called it
# `pause_windows` in prose only — nothing reads or writes that name). Value is
# a JSON array of windows, dates inclusive, UTC:
#   [{"start":"2026-10-11","end":"2026-10-27"},
#    {"start":"2026-07-28","end":"2026-08-05"},
#    {"start":"2026-11-20","end":null}]          # end:null = open (still paused)
# Timestamps are accepted and truncated to their YYYY-MM-DD prefix. Malformed
# entries are dropped; a value that is not a JSON array is treated as "no
# windows declared" — i.e. alerts stand (fail-closed: a broken declaration can
# never silence an alarm).
#
# Semantics (identical for every consumer):
#   • no key / empty / unparsable  → behaviour unchanged (no suppression);
#   • gap fully covered            → uncovered gap 0 → no alert;
#   • gap partially covered        → alert only on the UNCOVERED portion (the
#                                    longest contiguous uncovered run of days);
#   • activity INSIDE a window     → INFO (e.g. rows replayed from a stranded
#                                    spool), never a contradiction alarm.
#
# Requires hooks/lib/db.sh to be sourced first (juvant_db_query) and jq.
#
# API:
#   juvant_pause_windows_load            → 0 + sets JUVANT_PAUSE_WINDOWS (normalized
#                                          JSON array) iff ≥1 valid window declared;
#                                          1 otherwise (caller keeps legacy behaviour).
#   juvant_pause_uncovered_days <gap_d>  → prints the longest uncovered run (days)
#                                          inside the silent span (today-gap_d, today].
#                                          Prints <gap_d> unchanged on any error.
#   juvant_pause_windows_summary         → "S..E, S..open" for messages.
#   juvant_pause_activity_inside <table> <ts_column>
#                                        → prints "COUNT|MIN|MAX" of rows whose date
#                                          falls inside any declared window.

JUVANT_PAUSE_WINDOWS_KEY="halt_windows"
JUVANT_PAUSE_WINDOWS=""

juvant_pause_windows_load() {
  JUVANT_PAUSE_WINDOWS=""
  command -v jq >/dev/null 2>&1 || return 1
  declare -F juvant_db_query >/dev/null 2>&1 || return 1
  local raw norm
  raw=$(juvant_db_query \
    "SELECT value FROM master_context WHERE key = '${JUVANT_PAUSE_WINDOWS_KEY}';" \
    2>/dev/null) || return 1
  [[ -n "${raw//[[:space:]]/}" ]] || return 1
  norm=$(jq -c '
    # Whole value must be a date or an ISO-ish timestamp — anything else
    # (including SQL-shaped junk) drops the entry before it is truncated.
    def okts: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9:.]+(Z|[+-][0-9:]+)?)?$");
    if type != "array" then error("not an array") else . end
    | [ .[]
        | select(type == "object" and (.start | okts))
        | select(.end == null or (.end | okts))
        | {start: .start[0:10], end: (if .end == null then null else .end[0:10] end)}
        | select(.end == null or .end >= .start) ]
    | sort_by(.start)
  ' <<<"$raw" 2>/dev/null) || return 1
  [[ -n "$norm" && "$norm" != "[]" ]] || return 1
  JUVANT_PAUSE_WINDOWS="$norm"
  return 0
}

juvant_pause_uncovered_days() {
  local gap="${1:-}"
  if [[ ! "$gap" =~ ^[0-9]+$ ]] || [[ -z "$JUVANT_PAUSE_WINDOWS" ]]; then
    printf '%s' "$gap"; return 0
  fi
  local out
  out=$(jq -r --arg g "$gap" --arg t "$(date -u +%Y-%m-%d)" '
    def day: (. + "T00:00:00Z" | fromdateiso8601 / 86400 | floor);
    ($t | day) as $T
    | ($g | tonumber) as $G
    | if $G <= 0 then 0 else
        ($T - $G + 1) as $G0
        | reduce (map({s: (.start | day), e: (if .end == null then $T else (.end | day) end)})
                  | sort_by(.s) | .[]) as $w
            ({cur: $G0, longest: 0};
             if .cur > $T or $w.e < .cur then .
             else
               (if $w.s > .cur
                then (([$w.s - 1, $T] | min) - .cur + 1) as $seg
                     | .longest = ([.longest, $seg] | max)
                else . end)
               | .cur = ([.cur, $w.e + 1] | max)
             end)
        | if .cur <= $T then .longest = ([.longest, ($T - .cur + 1)] | max) else . end
        | .longest
      end
  ' <<<"$JUVANT_PAUSE_WINDOWS" 2>/dev/null) || out=""
  if [[ "$out" =~ ^[0-9]+$ ]]; then printf '%s' "$out"; else printf '%s' "$gap"; fi
}

juvant_pause_windows_summary() {
  [[ -n "$JUVANT_PAUSE_WINDOWS" ]] || return 0
  jq -r 'map(.start + ".." + (.end // "open")) | join(", ")' \
    <<<"$JUVANT_PAUSE_WINDOWS" 2>/dev/null || true
}

juvant_pause_activity_inside() {
  local table="$1" col="$2" pred
  [[ -n "$JUVANT_PAUSE_WINDOWS" ]] || { printf '0||'; return 0; }
  # Dates were regex-validated in juvant_pause_windows_load → safe to inline.
  pred=$(jq -r --arg c "$col" '
    map("(date(" + $c + ") >= '\''" + .start + "'\''"
        + (if .end == null then "" else " AND date(" + $c + ") <= '\''" + .end + "'\''" end)
        + ")")
    | join(" OR ")
  ' <<<"$JUVANT_PAUSE_WINDOWS" 2>/dev/null) || pred=""
  [[ -n "$pred" ]] || { printf '0||'; return 0; }
  local row
  row=$(juvant_db_query \
    "SELECT COUNT(*) || '|' || COALESCE(MIN(${col}),'') || '|' || COALESCE(MAX(${col}),'') FROM ${table} WHERE ${pred};" \
    2>/dev/null | { grep -E '^[0-9]+\|' || true; } | tail -1)
  printf '%s' "${row:-0||}"
}
