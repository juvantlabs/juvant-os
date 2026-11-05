#!/usr/bin/env bash
# tests/helpers/test-audit-project-scope.sh
# BUG-102 — audit-bootstrap-baseline.sh Layer 1 reads the project DB in project
# scope, fails loud when it can't, and the promotion gate holds on an open
# traceability finding until the CSO closes it. Runs on a throwaway copy.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dep in sqlite3 jq python3; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok(){ echo "    PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
R="$TMP/inst"; C="$R/.juvant/state.db"; P="$R/.juvant/project-apollo.db"
mkdir -p "$R/scripts" "$R/hooks" "$R/.juvant"
cp "$REPO/scripts/audit-bootstrap-baseline.sh" "$REPO/scripts/migrate.sh" "$REPO/scripts/schema.sql" "$R/scripts/"
cp -R "$REPO/hooks/lib" "$R/hooks/lib"
jq -n '{db:{provider:"local",url:"file:.juvant/state.db"},
        feature_toggles:{eng_platform_enabled:true},
        projects:{apollo:{name:"Apollo",db:{provider:"local",url:"file:.juvant/project-apollo.db"}}}}' \
  > "$R/.juvant/config.json"

bash "$R/scripts/migrate.sh" >/dev/null 2>&1
eq "company DB migrated" "0" "$?"
bash "$R/scripts/migrate.sh" --project=apollo >/dev/null 2>&1
eq "project DB migrated" "0" "$?"

seed() { # <db> <rows> <bypass>
  local i
  for ((i = 1; i <= $2; i++)); do
    sqlite3 "$1" "INSERT INTO manifests (agent,content,status,tier,tier1_bootstrap,precondition_bypassed)
        VALUES ('a$i','body','operational_restricted',1,1,'$3');
      INSERT INTO agents (role,manifesto_status,tier1_bootstrap) VALUES ('a$i','operational_restricted',1);
      INSERT INTO decisions (agent,title,category,rationale,status)
        VALUES ('skill','bootstrap a$i','bootstrap-action','seed','executed');"
  done
}
seed "$C" 10 bootstrap
seed "$P" 8 project-bootstrap

access() { # <scope> <severity>: findings of Layer 1 at that severity
  (cd "$R" && JUVANT_CONFIG="$R/.juvant/config.json" bash scripts/audit-bootstrap-baseline.sh --scope="$1" 2>/dev/null) \
    | jq -r --arg s "$2" 'select(.layer=="access" and .severity==$s) | "\(.category)|\(.finding)"' 2>/dev/null
}

echo "== project scope reads the project DB =="
out=$(access apollo info)
case "$out" in *"8 project (apollo) manifestos"*) ok "manifests counted in the project DB" ;; *) no "manifests: $out" ;; esac
case "$out" in *"project-bootstrap"*) ok "project bypass flag used" ;; *) no "bypass flag" ;; esac
case "$out" in *"8 agent rows"*) ok "agent mirror counted in the project DB" ;; *) no "agents: $out" ;; esac
case "$out" in *"8 bootstrap-action"*) ok "decisions counted in the project DB" ;; *) no "decisions: $out" ;; esac
# The continuity check is company-wide, and an empty log trips it on any new DB.
eq "no high traceability finding" "" "$(access apollo high | grep -v '^audit-surface-continuity-gap')"

echo "== company scope is unchanged =="
out=$(access company info)
case "$out" in *"10 founding manifestos"*"bootstrap'"*) ok "company figures" ;; *) no "company: $out" ;; esac

echo "== project drift is seen =="
sqlite3 "$P" "UPDATE agents SET manifesto_status='pending' WHERE role='a1';"
case "$(access apollo medium)" in agent-manifest-drift*) ok "drift in the project DB" ;; *) no "drift missing" ;; esac
sqlite3 "$P" "UPDATE agents SET manifesto_status='operational_restricted' WHERE role='a1';"

echo "== unreadable project DB fails loud =="
mv "$P" "$P.off"
case "$(access apollo high | grep -v '^audit-surface-continuity-gap')" in
  audit-coverage-gap*) ok "coverage gap, not zero rows" ;;
  *) no "no gap reported" ;;
esac
[[ -f "$P" ]] && no "audit created an empty project DB" || ok "no empty DB created"
mv "$P.off" "$P"

echo "== promotion gate =="
gate() {
  sqlite3 "$P" "SELECT COUNT(*) FROM security_audit_log_current
    WHERE scope='apollo' AND current_status='open' AND is_test_artifact=0
      AND (category IN ('manifesto-bootstrap-incomplete','agent-manifest-drift',
                        'decision-trail-incomplete')
           OR (category='audit-coverage-gap' AND layer='access'));"
}
eq "no finding, no hold" "0" "$(gate)"
sqlite3 "$P" "INSERT INTO security_audit_log (auditor,scope,audit_type,severity,category,finding,bootstrap_baseline)
  VALUES ('cso','apollo','bootstrap_baseline','P2','optional-role-toggle-leak','unrelated',1);"
eq "other category doesn't hold" "0" "$(gate)"
sqlite3 "$P" "INSERT INTO security_audit_log (auditor,scope,audit_type,layer,severity,category,finding,bootstrap_baseline)
  VALUES ('cso','apollo','bootstrap_baseline','code','low','audit-coverage-gap','no branch protection API',1);"
eq "gap outside Layer 1 doesn't hold" "0" "$(gate)"
sqlite3 "$P" "INSERT INTO security_audit_log (auditor,scope,audit_type,layer,severity,category,finding,bootstrap_baseline)
  VALUES ('cso','apollo','bootstrap_baseline','access','P2','audit-coverage-gap','gap',1);"
eq "open gap holds" "1" "$(gate)"
ID=$(sqlite3 "$P" "SELECT id FROM security_audit_log WHERE category='audit-coverage-gap' AND layer='access';")
sqlite3 "$P" "INSERT INTO decisions (agent,title,category,rationale,status)
  VALUES ('cso','close gap','system-audit','re-audit no longer reproduces it','executed');"
DEC=$(sqlite3 "$P" "SELECT MAX(id) FROM decisions;")
sqlite3 "$P" "INSERT INTO audit_events (target_table,target_id,event_type,from_value,to_value,reason,authority_ref,author)
  VALUES ('security_audit_log',$ID,'closure','open','resolved','re-audit clean',$DEC,'cso');"
eq "CSO closure releases" "0" "$(gate)"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
