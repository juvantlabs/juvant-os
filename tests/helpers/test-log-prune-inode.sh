#!/usr/bin/env bash
# tests/helpers/test-log-prune-inode.sh
#
# BUG-062: the BUG-027 log-prune must NOT swap the log's inode. launchd opens the
# helper's StandardOutPath fd at process launch; if the prune installs a new inode
# via `mv`, that fd is orphaned and every subsequent stdout write is silently
# dropped (headers-only log). The fix truncates in place (`cat tmp > $_LOG`), so
# the inode — and any inherited fd — stays valid.
#
# This reproduces the launchd scenario end-to-end against the REAL helpers: each
# is run with stdout redirected to its OWN pre-seeded log (>= 8 RUN blocks, so the
# prune activates). With the inode preserved, the helper's own stdout survives in
# the file; with the old `mv` it would be lost (only headers remain).

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="$REPO/scripts/schema.sql"
FAKETURSO="$REPO/tests/hooks/fake-turso.sh"

for dep in sqlite3 jq; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok(){ echo "    PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); FAKEBIN=$(mktemp -d)
trap 'rm -rf "$TMP" "$FAKEBIN"' EXIT

mkdir -p "$TMP/helpers" "$TMP/hooks/lib" "$TMP/.juvant/logs"
cp "$REPO"/helpers/cso-weekly-audit.sh "$REPO"/helpers/anomaly-check.sh \
   "$REPO"/helpers/audit-reconcile.sh "$REPO"/helpers/morning-brief.sh "$TMP/helpers/"
cp "$REPO/hooks/lib/db.sh" "$TMP/hooks/lib/"
printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1 || true\nexit 0\n' > "$TMP/hooks/notification.sh"
chmod +x "$TMP/hooks/notification.sh"
cp "$FAKETURSO" "$FAKEBIN/turso"; chmod +x "$FAKEBIN/turso"
# curl stub so morning-brief reaches its final stdout line instead of erroring.
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/curl"; chmod +x "$FAKEBIN/curl"

# ── Mechanism test (deterministic, helper-agnostic) ─────────────────────────
# Prove the fix preserves the inode (an inherited fd survives) and that the old
# `mv` orphans it (control — so a regression back to `mv` would be caught here).
echo "=== inode-preservation mechanism ==="
mklog(){ : > "$1"; local i; for i in 1 2 3 4 5 6 7 8; do printf '=== RUN %s ===\nB%s\n' "$i" "$i" >> "$1"; done; }
prune_head(){ local L="$1"; grep -c '^=== RUN ' "$L"; }

LF="$TMP/fix.log"; mklog "$LF"; exec 9>>"$LF"
_s=$(( $(prune_head "$LF") - 7 ))
awk -v skip="$_s" '/^=== RUN /{n++} n>skip{print}' "$LF" > "$LF.tmp" && cat "$LF.tmp" > "$LF" && rm -f "$LF.tmp"
echo "FDWRITE-fix" >&9; exec 9>&-
grep -q 'FDWRITE-fix' "$LF" && ok "truncate-in-place: inherited fd write survived (inode kept)" \
  || no "truncate-in-place: inherited fd write LOST"

LM="$TMP/mv.log"; mklog "$LM"; exec 9>>"$LM"
_s=$(( $(prune_head "$LM") - 7 ))
awk -v skip="$_s" '/^=== RUN /{n++} n>skip{print}' "$LM" > "$LM.tmp" && mv "$LM.tmp" "$LM"
echo "FDWRITE-mv" >&9; exec 9>&-
grep -q 'FDWRITE-mv' "$LM" \
  && no "control: mv unexpectedly kept the fd write" \
  || ok "control: mv orphans the inherited fd → write lost (a regression would fail here)"

DBFILE="$TMP/.juvant/state.db"
CONFIG_PATH="$TMP/.juvant/config.json"
rm -f "$DBFILE"; sqlite3 "$DBFILE" < "$SCHEMA"
# Include a webhook so morning-brief proceeds past its "not configured" skip and
# reaches its final stdout line (curl is stubbed → the send is a no-op).
jq -n --arg u "file:$DBFILE" \
  '{db:{provider:"local",url:$u},notifications:{teams_webhooks:{ops:"https://x.webhook.office.com/y",approvals:"https://x.webhook.office.com/z"}}}' \
  > "$CONFIG_PATH"

# One seed RUN block: a header + a distinctively-prefixed body line.
seed_block(){ printf '=== RUN 2026090%sT000000Z ===\nZSEED body %s\n' "$1" "$1" >> "$2"; }

for h in cso-weekly-audit anomaly-check audit-reconcile morning-brief; do
  LOG="$TMP/.juvant/logs/$h.log"
  : > "$LOG"
  for i in 1 2 3 4 5 6 7 8; do seed_block "$i" "$LOG"; done   # 8 blocks → prune fires
  # Run the REAL helper with stdout redirected to its OWN log (mimics launchd
  # StandardOutPath == the file the helper prunes). The helper prunes 8→7, writes
  # a new header, then emits its stdout — which must land in the same inode.
  ( PATH="$FAKEBIN:$PATH" JUVANT_TEST_DB_FILE="$DBFILE" JUVANT_DB_TIMEOUT=15 \
    bash "$TMP/helpers/$h.sh" >> "$LOG" 2>/dev/null ) || true

  # Prune must have activated (<= 7 RUN blocks kept from the seed, + this run's).
  runs=$(grep -c '^=== RUN ' "$LOG" 2>/dev/null || echo 0)
  [[ "$runs" -le 8 && "$runs" -ge 7 ]] && ok "$h: prune kept the last 7 seed blocks (+run)" \
    || no "$h: unexpected RUN-block count after prune ($runs)"

  # The helper's own stdout (anything that is NOT a RUN header and NOT a ZSEED
  # line) must have survived the prune — i.e. the inode/fd was preserved.
  if grep -vE '^=== RUN |^ZSEED body ' "$LOG" | grep -q '[^[:space:]]'; then
    ok "$h: post-prune stdout survived (inode preserved)"
  else
    no "$h: post-prune stdout LOST — only headers remain (inode swapped)"
    echo "        log tail:"; tail -3 "$LOG" | sed 's/^/          > /'
  fi
done

echo "───────────────────────────────────"
echo "  log-prune-inode: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
