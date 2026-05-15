#!/usr/bin/env bash
# helpers/kb-sync.sh
# FEAT-026 Layer 1+2 — Knowledge Sync Pipeline source change detection.
#
# Called at every SessionStart by the session-start hook.
# Computes content hashes for configured knowledge sources and writes
# changes to `source_snapshots` in Turso. No Claude calls — pure bash.
#
# CoS reads source_snapshots at boot to detect what changed since the
# last session and offer CRO processing (Layer 3).
#
# Sources checked:
#   - GitHub issues (open, last 30 days) per github_user_map repos
#   - GitHub PRs (open) per github_user_map repos
#   - Turso decisions (last 7 days count + last decision id as proxy)
#
# OneDrive/SharePoint sources are checked via m365-graph at session time
# by the Skill (requires auth token — cannot run headless here).
#
# Per FEAT-026: fast + deterministic. Exits 0 always (never blocks boot).

set -uo pipefail

# launchd / cron provide a minimal PATH — extend it to find Homebrew tools.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

if [[ ! -f "$CONFIG" ]]; then
  echo "[kb-sync] SKIP: no config.json found" >&2
  exit 0
fi

TURSO_URL=$(jq -r '.turso_url // ""' "$CONFIG" 2>/dev/null || echo "")
if [[ -z "$TURSO_URL" ]]; then
  echo "[kb-sync] SKIP: turso_url missing from config" >&2
  exit 0
fi

# ─── Helper: upsert source_snapshots row ─────────────────────────────────────
# Args: source_type source_ref new_hash summary
upsert_snapshot() {
  local stype="$1" sref="$2" new_hash="$3" summary="$4"
  local now
  now=$(date -u +"%Y-%m-%d %H:%M:%S")

  # Check existing hash
  local old_hash
  old_hash=$(turso db shell "$TURSO_URL" \
    "SELECT content_hash FROM source_snapshots WHERE source_type='$stype' AND source_ref='$sref';" \
    2>/dev/null | awk 'NR > 1 && NF' | head -1 | xargs)

  if [[ -z "$old_hash" ]]; then
    # First time seeing this source
    turso db shell "$TURSO_URL" \
      "INSERT INTO source_snapshots (source_type, source_ref, content_hash, last_seen_at)
       VALUES ('$stype', '$sref', '$new_hash', '$now')
       ON CONFLICT(source_type, source_ref) DO UPDATE
       SET content_hash='$new_hash', last_seen_at='$now';" \
      2>/dev/null || true
    echo "[kb-sync] new source: $stype/$sref" >&2
  elif [[ "$old_hash" != "$new_hash" ]]; then
    # Hash changed — record delta
    local escaped_summary
    escaped_summary=$(echo "$summary" | sed "s/'/''/g")
    turso db shell "$TURSO_URL" \
      "UPDATE source_snapshots
       SET content_hash='$new_hash', last_seen_at='$now',
           last_changed_at='$now', delta_summary='$escaped_summary'
       WHERE source_type='$stype' AND source_ref='$sref';" \
      2>/dev/null || true
    echo "[kb-sync] CHANGED: $stype/$sref — $summary" >&2
  else
    # No change — update last_seen_at only
    turso db shell "$TURSO_URL" \
      "UPDATE source_snapshots SET last_seen_at='$now'
       WHERE source_type='$stype' AND source_ref='$sref';" \
      2>/dev/null || true
  fi
}

# ─── GitHub sources ───────────────────────────────────────────────────────────
GH_TOKEN=${GITHUB_PERSONAL_ACCESS_TOKEN:-$(jq -r '.github_token // ""' "$CONFIG" 2>/dev/null || echo "")}

if [[ -n "$GH_TOKEN" ]]; then
  # Collect repos from github_user_map projects + company repos
  REPOS=()
  while IFS= read -r repo; do
    [[ -n "$repo" && "$repo" != "null" ]] && REPOS+=("$repo")
  done < <(jq -r '
    .github_user_map // {} | to_entries[] |
    select(.value != null and .value != "") |
    .value
  ' "$CONFIG" 2>/dev/null | sort -u)

  # Also add explicitly configured project repos
  while IFS= read -r repo; do
    [[ -n "$repo" && "$repo" != "null" ]] && REPOS+=("$repo")
  done < <(jq -r '.projects // {} | to_entries[] | .value.github_repo // empty' "$CONFIG" 2>/dev/null)

  for repo in "${REPOS[@]}"; do
    # Open issues count as hash proxy
    issue_count=$(curl -s -H "Authorization: Bearer $GH_TOKEN" \
      "https://api.github.com/repos/$repo/issues?state=open&per_page=1" \
      -I 2>/dev/null | grep -i "x-total-count:" | tr -d '\r' | awk '{print $2}')
    last_issue=$(curl -s -H "Authorization: Bearer $GH_TOKEN" \
      "https://api.github.com/repos/$repo/issues?state=open&per_page=1&sort=updated" \
      2>/dev/null | jq -r '.[0].updated_at // "none"' 2>/dev/null || echo "none")

    if [[ -n "$issue_count" ]]; then
      hash=$(echo "${issue_count}:${last_issue}" | shasum -a 256 | awk '{print $1}')
      upsert_snapshot "github_issues" "$repo" "$hash" \
        "$issue_count open issues (last updated: $last_issue)"
    fi
  done
fi

# ─── Turso decisions proxy ────────────────────────────────────────────────────
decision_proxy=$(turso db shell "$TURSO_URL" \
  "SELECT COUNT(*), MAX(id) FROM decisions WHERE created_at > date('now','-7 days');" \
  2>/dev/null | awk 'NR > 1 && NF' | head -1 | xargs)

if [[ -n "$decision_proxy" ]]; then
  count=$(echo "$decision_proxy" | awk '{print $1}')
  max_id=$(echo "$decision_proxy" | awk '{print $2}')
  hash=$(echo "${count}:${max_id}" | shasum -a 256 | awk '{print $1}')
  upsert_snapshot "turso_decisions" "company:decisions" "$hash" \
    "$count decisions in last 7 days (latest id: $max_id)"
fi

echo "[kb-sync] OK — source snapshot check complete"
exit 0
