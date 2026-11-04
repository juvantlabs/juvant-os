#!/usr/bin/env bash
# tests/hooks/test-cloud-cli.sh
# BUG-076 — R3 decides on the parsed argv: az, aws, gcloud and terraform run
# read-only for agent roles, quoted text is not a command, and lines argv can't
# see into still get the raw patterns.
# Direct library checks (fast) plus end-to-end cases through the real hook.
#
# SC2016: the cases are literal shell text, meant not to expand.
# shellcheck disable=SC2016,SC2015

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS="$REPO/hooks"
POLICY="$HOOKS/bash-policy.json"
for dep in jq sqlite3; do command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }; done

# shellcheck source=hooks/lib/bash-segments.sh
. "$HOOKS/lib/bash-segments.sh"
# shellcheck source=hooks/lib/cloud-cli.sh
. "$HOOKS/lib/cloud-cli.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }

# chk <expected rc> <command>
chk() {
  local rc
  juvant_cloud_cli_check "$POLICY" "$2" >/dev/null; rc=$?
  if [[ "$rc" == "$1" ]]; then ok; else no "rc=$rc, expected $1: $2"; fi
}
deny(){ local c; for c in "$@"; do chk 1 "$c"; done; }
pass(){ local c; for c in "$@"; do chk 0 "$c"; done; }
raw(){  local c; for c in "$@"; do chk 3 "$c"; done; }

echo "=== bypasses from the issue are denied ==="
deny 'terraform -chdir=Infra apply' \
     'terraform -chdir=infra destroy -auto-approve' \
     'az ad sp create-for-rbac --name ci' \
     'az k8s-extension create -n ext' \
     'az --subscription MySub group delete -n rg' \
     'gcloud alpha iam k8s-pol create -n p' \
     'gcloud --project MyProj compute disks delete' \
     'aws --profile Prod s3 rb s3://bucket' \
     'az containerapp up -n x' \
     'az rest --method post --url https://x'

echo "=== what was already denied stays denied ==="
deny 'az group delete --name rg-x' \
     'az storage account create -n foo' \
     'cd /tmp && az webapp restart -n app' \
     'aws ec2 delete-volume --volume-id v-1' \
     'terraform apply -auto-approve' \
     'terraform destroy' 'terraform import a b' 'terraform state rm x' \
     'terraform taint x' 'terraform force-unlock 1' \
     'terraform workspace new x' 'terraform workspace delete x' \
     'gcloud compute instances delete vm1' 'gcloud projects add-iam-policy-binding p'

echo "=== subcommands nobody enumerated fail closed ==="
deny 'terraform refresh' 'terraform test' 'terraform console' \
     'aws sts assume-role --role-arn x' \
     'gcloud compute instances suspend vm1' 'gcloud compute ssh vm1' \
     'gcloud frobnicate things'

echo "=== read-only commands pass ==="
pass 'terraform plan' 'terraform -chdir=infra plan -out=tf.plan' 'terraform fmt -check' \
     'terraform init -backend=false' 'terraform validate' 'terraform show' 'terraform output' \
     'terraform workspace list' 'terraform workspace select dev' 'terraform version' 'terraform -version' \
     'az account show' 'az group list --subscription MySub -o table' 'az version' 'az --version' \
     'az vm run-command list -l westeurope' 'az account list-locations' 'az group exists -n x' \
     'az --subscription MySub group list' 'az --debug group list' \
     'aws sts get-caller-identity' 'aws s3 ls' 'aws --profile Prod s3 ls s3://b' \
     'aws ec2 describe-instances --region eu-west-1' 'aws --region=eu-west-1 s3api head-object --bucket b --key k' \
     'aws dynamodb scan --table-name t' 'aws --version' \
     'gcloud projects describe my-proj' 'gcloud compute instances describe vm1 --zone z' \
     'gcloud --project MyProj compute disks list' 'gcloud run services list' 'gcloud deploy releases list' \
     'gcloud alpha run services list' 'gcloud config get-value project' 'gcloud auth list' \
     'gcloud projects get-iam-policy p' 'gcloud version' 'gcloud --version'

echo "=== quoted text, comments and heredocs are not commands ==="
pass 'echo "=== az login state ===" && git status' \
     'git commit -m "document az group delete policy"' \
     'git commit -m "terraform apply is denied for agents"' \
     'grep -n "az group delete" hooks/bash-policy.json' \
     '# az group delete' \
     $'cat <<EOF\naz group delete\nEOF'

echo "=== wrappers and inline shells are followed ==="
deny '/usr/local/bin/terraform apply' 'env FOO=1 az group delete -n x' 'timeout 30 terraform -chdir=x apply' \
     'nohup az group delete -n x' 'command az group delete -n x' 'exec aws s3 rm s3://b/k' \
     'find . -name x -exec az group delete -n {} ;' \
     'f() { az group delete -n x; }; f' 'true && (az group delete -n x)' \
     'echo "$(terraform apply)"' 'a""z group delete -n x' 'te\rraform apply' \
     'bash -c "terraform -chdir=x apply"' 'sh -c "az group delete -n x"' 'eval az group delete -n x'

echo "=== computed words and unlisted flags fail closed ==="
deny 'az group $VERB -n x' 'az group $(echo delete) -n x' 'az $(echo group delete) list' \
     'terraform $CMD' 'terraform $(echo apply)' 'aws s3 "$OP" s3://b' \
     'echo delete | xargs az group' 'xargs terraform' 'az' 'terraform' \
     'az --subscription $X list' 'az --subscription=$X list' 'aws --profile $X s3 ls' \
     'aws --unknown-flag s3 rm list-x' 'az --foo group delete' 'gcloud --flags-file=x.yaml projects list' \
     'terraform -foo apply'
pass 'az group list --subscription $SUB' 'aws s3 ls --profile "$P"' 'terraform -chdir=infra plan -var "x=$Y"'

echo "=== a code reader on the line asks for the raw patterns ==="
raw 'python3 -c "import os; os.system(\"az group delete\")"' \
    'echo az group delete | bash' \
    'bash <<EOF
az group delete
EOF' \
    "awk 'BEGIN{system(\"az group delete\")}'" \
    "git -c alias.x='!az group delete' x" \
    'node -e "x"' 'cat <unbalanced"'

echo "=== missing policy block asks for the raw patterns ==="
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo '{}' > "$T/empty.json"
juvant_cloud_cli_check "$T/empty.json" 'az group delete -n x' >/dev/null
[[ $? == 3 ]] && ok || no "empty policy → raw"

echo "=== the argv lines ==="
out=$(juvant_bash_argv "FOO=1 timeout 5 az group list -o 'a b'" | grep '^A' | tr '\037' '|')
[[ "$out" == 'A|az|group|list|-o|a b' ]] && ok || no "argv line: $out"
[[ "$(juvant_bash_binaries 'az group list')" == "B az" ]] && ok || no "juvant_bash_binaries prints only B lines"

echo "=== through the real hook ==="
sqlite3 "$T/test.db" < "$REPO/scripts/schema.sql" 2>/dev/null
mkdir "$T/bin"; cp "$REPO/tests/hooks/fake-turso.sh" "$T/bin/turso"; cp "$REPO/tests/hooks/fake-libsql-curl.sh" "$T/bin/curl"
chmod +x "$T/bin/turso" "$T/bin/curl"
export PATH="$T/bin:$PATH" JUVANT_TEST_DB_FILE="$T/test.db" TURSO_URL=libsql://test.fake TURSO_TOKEN=x
export JUVANT_SPOOL="$T/spool.sql" JUVANT_CONFIG="$T/no-config.json"
sqlite3 "$T/test.db" "INSERT OR REPLACE INTO agents (role, status) VALUES ('eng-platform','active'),('cso','active');" 2>/dev/null

# hookv <role> <command> → allow|deny + reason on the 2nd line
hookv() {
  local ev out
  ev=$(jq -cn --arg c "$2" '{tool_name:"Bash",session_id:"cloud-t",tool_input:{command:$c}}')
  if [[ -n "$1" ]]; then out=$(printf '%s' "$ev" | AGENT_ROLE="$1" bash "$HOOKS/pre-tool-use.sh" 2>/dev/null)
  else out=$(printf '%s' "$ev" | bash "$HOOKS/pre-tool-use.sh" 2>/dev/null); fi
  printf '%s\n%s\n' "$(jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$out")" "$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$out")"
}
expect() { # <decision> <role> <command> [reason substring]
  local got; got=$(hookv "$2" "$3")
  if [[ "${got%%$'\n'*}" == "$1" && "$got" == *"${4:-}"* ]]; then ok; else no "[$2] $3 → $(printf '%s' "$got" | tr '\n' ' ' | cut -c1-160)"; fi
}
expect deny  eng-platform 'terraform -chdir=infra apply' 'agent-role deny-list match'
expect deny  eng-platform 'az ad sp create-for-rbac --name x' 'agent-role deny-list match'
expect allow eng-platform 'terraform -chdir=infra plan'
expect allow eng-platform 'az group list'
expect allow eng-platform 'git commit -m "document az group delete policy"'
expect allow eng-platform 'echo "=== az login state ===" && git status'
expect deny  cso 'python3 -c "import os; os.system(\"az group delete -n x\")"' 'agent_role_deny_patterns'
expect deny  cso 'python3 -c "import os; os.system(\"terraform -chdir=x apply\")"' 'agent_role_deny_patterns'
expect allow "" 'terraform -chdir=infra apply'

# A missing lib (mid upstream-sync) degrades to the raw patterns.
cp -R "$HOOKS" "$T/hooks"; rm -f "$T/hooks/lib/cloud-cli.sh"
ev=$(jq -cn '{tool_name:"Bash",session_id:"cloud-t",tool_input:{command:"terraform -chdir=infra apply"}}')
out=$(printf '%s' "$ev" | AGENT_ROLE=eng-platform bash "$T/hooks/pre-tool-use.sh" 2>/dev/null)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" == "deny" ]] && ok || no "missing lib → raw patterns still deny"

echo ""
echo "  RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
