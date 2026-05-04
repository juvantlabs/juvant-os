#!/usr/bin/env bash
# helpers/turso-backup.sh
# Daily encrypted off-host backup of the Turso DB.
#
# Per handbook ADR 0004 Track 3: addresses failure mode #4 ("backups
# in same blast radius") by shipping the dump to a destination
# OUTSIDE the agent's credential reach. The agent never holds the
# destination's credentials at runtime — this helper script does.
#
# Usage: scheduled daily at 03:00 via launchd (Mac) / cron (Linux)
# at company init. CEO can also run on-demand:
#   ./helpers/turso-backup.sh
#
# Required config (`.juvant/config.json`):
#   turso_url            — DB to dump
#   turso_token          — read-only token sufficient
#   backup.destination   — local path or rclone remote string
#                          (e.g. "/Volumes/Backup/juvant",
#                           "b2:juvant-backups",
#                           "s3:juvant-backups/turso")
#   backup.gpg_recipient — GPG key ID or email of recipient.
#                          Private key MUST NOT be on this host.
#                          Public-key encrypt only here; restore
#                          requires the offline private key.
#
# Retention: 30 days rolling. The helper does NOT enforce retention
# on the destination — that's the destination's lifecycle policy
# (B2 lifecycle rule, S3 lifecycle, manual rotation on NAS, etc.).
#
# Permanent retention for spec-class decisions: helper greps the
# dump for "category='spec'" rows in decisions; if any, prefixes
# the filename with "ARCHIVAL-" so the destination's retention
# rule can pin those.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

if [[ ! -f "$CONFIG" ]]; then
  echo "[turso-backup] FATAL: $CONFIG missing" >&2
  exit 1
fi

TURSO_DB_NAME=$(jq -r '.turso_db_name // ""' "$CONFIG")
DEST=$(jq -r '.backup.destination // ""' "$CONFIG")
GPG_RECIPIENT=$(jq -r '.backup.gpg_recipient // ""' "$CONFIG")

if [[ -z "$TURSO_DB_NAME" || -z "$DEST" || -z "$GPG_RECIPIENT" ]]; then
  echo "[turso-backup] FATAL: missing turso_db_name / backup.destination / backup.gpg_recipient in $CONFIG" >&2
  echo "[turso-backup]        See JUVANT_OS.md § wizard for setup." >&2
  echo "[turso-backup]        Note: turso_db_name (NOT turso_url) is required because Turso CLI's" >&2
  echo "[turso-backup]        '.dump' command does not work via libsql:// URLs — only via DB name." >&2
  exit 1
fi

DATE=$(date -u +"%Y-%m-%d")
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

DUMP="$TMPDIR/juvant-${DATE}.sql"
ENCRYPTED="$TMPDIR/juvant-${DATE}.sql.gz.gpg"

echo "[turso-backup] dumping Turso ($TURSO_DB_NAME) to $DUMP" >&2
turso db shell "$TURSO_DB_NAME" ".dump" > "$DUMP" 2>/dev/null

# Tag spec-class dumps for permanent retention
PREFIX=""
if grep -qE "category='spec'" "$DUMP"; then
  PREFIX="ARCHIVAL-"
  ENCRYPTED="$TMPDIR/${PREFIX}juvant-${DATE}.sql.gz.gpg"
fi

echo "[turso-backup] gzipping + GPG-encrypting to $ENCRYPTED" >&2
gzip -c "$DUMP" | gpg --batch --yes --trust-model always \
  --recipient "$GPG_RECIPIENT" --encrypt --output "$ENCRYPTED"

# Ship to destination — local cp or rclone copy
if [[ "$DEST" =~ ^/ || "$DEST" =~ ^~ ]]; then
  # Local destination
  DEST_EXPANDED="${DEST/#~/$HOME}"
  mkdir -p "$DEST_EXPANDED"
  cp "$ENCRYPTED" "$DEST_EXPANDED/"
  echo "[turso-backup] OK — copied to $DEST_EXPANDED/$(basename "$ENCRYPTED")" >&2
else
  # rclone remote (b2:bucket/path, s3:bucket/path, etc.)
  if ! command -v rclone >/dev/null 2>&1; then
    echo "[turso-backup] FATAL: rclone not installed and destination '$DEST' is a remote (e.g. b2:, s3:). Install rclone or use a local path." >&2
    exit 1
  fi
  rclone copy "$ENCRYPTED" "$DEST" --quiet
  echo "[turso-backup] OK — uploaded to $DEST/$(basename "$ENCRYPTED")" >&2
fi
