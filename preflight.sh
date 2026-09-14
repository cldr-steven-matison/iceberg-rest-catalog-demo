#!/usr/bin/env bash
# Pre-flight gate for the srm-iceberg redeploy. Read-only. Exits 1 on the first failure and
# prints the fix. `terraform apply` never starts unless this prints PREFLIGHT OK.
#
# Usage:  bash preflight.sh
set -uo pipefail
. "$(dirname "$0")/common.sh"

ok()   { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; echo; echo "PREFLIGHT FAILED"; exit 1; }

echo "== preflight: tooling =="
[ -n "$TERRAFORM" ] && [ -x "$TERRAFORM" ] || fail "terraform not found — install terraform >= 1.16 (snap install terraform) or set TERRAFORM=/path"
TFV=$("$TERRAFORM" version -json 2>/dev/null | jq -r '.terraform_version')
[ "$(printf '%s\n1.16.0\n' "$TFV" | sort -V | head -1)" = "1.16.0" ] || fail "terraform $TFV at $TERRAFORM is older than 1.16 — use /snap/bin/terraform"
ok "terraform $TFV ($TERRAFORM)"
for t in cdp aws jq curl; do command -v "$t" >/dev/null || fail "$t not on PATH"; done
ok "cdp $(cdp --version 2>&1 | head -1 | awk '{print $NF}') · aws $(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2) · jq"
"$HOME/.venvs/cdpcli/bin/python" -c "import impala" 2>/dev/null || fail "impyla missing — ~/.venvs/cdpcli/bin/pip install impyla"
ok "impyla in ~/.venvs/cdpcli"
[ -x "$CC_VENV/bin/ansible-playbook" ] || fail "$CC_VENV missing — see trino-demo/README.md 'Environment setup'"
"$CC_VENV/bin/python" -c "import cdpy" 2>/dev/null || fail "cdpy missing in $CC_VENV — $CC_VENV/bin/pip install git+https://github.com/cloudera-labs/cdpy.git"
VWMOD="$CC_VENV/collections/ansible_collections/cloudera/cloud/plugins/modules/dw_virtual_warehouse.py"
grep -q -i trino "$VWMOD" 2>/dev/null || fail "cloudera.cloud in $CC_VENV has no Trino support — ansible-galaxy collection install git+https://github.com/cloudera-labs/cloudera.cloud.git,5ad1809 --force -p $CC_VENV/collections"
ok "ansible $("$CC_VENV/bin/ansible" --version 2>/dev/null | head -1 | grep -o '[0-9.]*' | head -1) + cloudera.cloud (Trino) + cdpy in $CC_VENV"
for d in "$DEMO" "$TF" "$TRINO"; do [ -d "$d" ] || fail "missing clone $d"; done
[ -f "$TRINO/provision-trino-vw.yml" ] || fail "missing $TRINO/provision-trino-vw.yml"
ok "repos present"

echo "== preflight: auth + local inputs =="
aws sts get-caller-identity >/dev/null 2>&1 || fail "AWS SSO expired — run: aws sso login --profile $AWS_PROFILE"
ok "aws sts ($AWS_PROFILE)"
cdp iam get-user >/dev/null 2>&1 || fail "cdp not authenticated — run: cdp configure"
ok "cdp iam get-user"
[ -s "$DEMO/.workload.creds" ] || fail "$DEMO/.workload.creds missing — one line, the CDP workload password"
ok ".workload.creds present"
TFVARS="$TF/terraform.tfvars"
[ -f "$TFVARS" ] || fail "$TFVARS missing — copy terraform.tfvars.template and fill it in"
grep -q 'deployment_template *= *"semi-private"' "$TFVARS" || fail "tfvars: deployment_template must be \"semi-private\" (CDW/Trino needs private subnets)"
grep -q "env_prefix *= *\"$PREFIX\"" "$TFVARS" || fail "tfvars: env_prefix must be \"$PREFIX\""
ENDDATE=$(grep -o 'enddate *= *"[0-9-]*"' "$TFVARS" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}')
[ -n "$ENDDATE" ] || fail "tfvars: env_tags.enddate missing"
[ "$ENDDATE" \> "$(date +%F)" ] || [ "$ENDDATE" = "$(date +%F)" ] || fail "tfvars: enddate $ENDDATE is in the past — set it to the coming Friday"
ok "tfvars: semi-private, prefix $PREFIX, enddate $ENDDATE"

echo "== preflight: terraform state =="
( cd "$TF" && "$TERRAFORM" init -input=false >/dev/null 2>&1 ) || fail "terraform init failed in $TF"
N=$(tf_state_count)
[ "$N" = "0" ] || fail "terraform state holds $N resources — the account must be empty and the state empty before apply; run teardown.sh"
ok "terraform state empty"

echo "== preflight: nothing named $PREFIX may exist =="
[ -z "$(env_crn)" ]            || fail "CDP environment $ENV_NAME exists — run teardown.sh"
cdp datalake describe-datalake --datalake-name "$DL_NAME" >/dev/null 2>&1 && fail "DataLake $DL_NAME exists — run teardown.sh"
[ -z "$(cdp_cred_present)" ]   || fail "CDP credential $CRED_NAME exists — run teardown.sh (or: cdp environments delete-credential --credential-name $CRED_NAME)"
G=$(cdp_groups_present);  [ -z "$G" ] || fail "CDP groups exist: $(echo "$G" | tr '\n' ' ')— run teardown.sh"
D=$(datahubs_present);    [ -z "$D" ] || fail "Data Hubs exist: $(echo "$D" | tr '\n' ' ')— run teardown.sh"
C=$(cdw_cluster_ids);     [ -z "$C" ] || fail "CDW clusters exist: $(echo "$C" | tr '\n' ' ')— run teardown.sh"
ok "CDP: no env / datalake / credential / groups / data hubs / CDW"
V=$(vpc_id);              [ -z "$V" ] || fail "VPC $VPC_NAME ($V) exists — run teardown.sh"
R=$(iam_roles);           [ -z "$R" ] || fail "IAM roles exist: $R — run teardown.sh"
P=$(iam_policies);        [ -z "$P" ] || fail "IAM policies exist: $P — run teardown.sh"
I=$(iam_profiles);        [ -z "$I" ] || fail "IAM instance profiles exist: $I — run teardown.sh"
K=$(keypair_present);     [ -z "$K" ] || fail "EC2 keypair $KEYPAIR exists — run teardown.sh"
B=$(s3_buckets);          [ -z "$B" ] || fail "S3 buckets exist: $B — run teardown.sh"
E=$(ec2_instances);       [ -z "$E" ] || fail "EC2 instances exist: $E — run teardown.sh"
ok "AWS: no VPC / IAM / keypair / S3 / EC2"

echo
echo "PREFLIGHT OK"
