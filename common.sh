# shellcheck shell=bash
# Shared settings for preflight.sh / teardown.sh / redeploy.sh / monday-redeploy.sh.
# Source it; do not run it. Every name the srm-iceberg sandbox creates is defined once here.

export AWS_PROFILE="${AWS_PROFILE:-cldr-se}"
export AWS_PAGER=""
export PATH="$HOME/.venvs/cdpcli/bin:$PATH"

REGION="${AWS_REGION:-us-east-2}"
DEMO="$HOME/Documents/GitHub/iceberg-rest-catalog-demo"
TF="$HOME/Documents/GitHub/cdp-tf-quickstarts/aws"
TRINO="$HOME/Documents/GitHub/trino-demo"
CC_VENV="$HOME/.venvs/clouderacloud"          # ansible + cloudera.cloud (Trino-capable) + cdpy

# One terraform binary for every script (state files are version-sensitive).
if [ -z "${TERRAFORM:-}" ]; then
  if [ -x /snap/bin/terraform ]; then TERRAFORM=/snap/bin/terraform; else TERRAFORM="$(command -v terraform || true)"; fi
fi

PREFIX="srm-iceberg"
ENV_NAME="$PREFIX-cdp-env"
DL_NAME="$PREFIX-aw-dl"
DH_NAME="$PREFIX-impala"
DATAHUBS="$DH_NAME srm-hol-optimizer"
CRED_NAME="$PREFIX-xaccount-cred"
CDP_GROUPS="$PREFIX-aw-cdp-admin-group $PREFIX-aw-cdp-user-group"
VPC_NAME="$PREFIX-net"
KEYPAIR="$PREFIX-keypair"
BASTION_NAME="$PREFIX-bastion"
BASTION_SG="$PREFIX-bastion-sg"
TRINO_VW="srm-trino-vw"
GW="$PREFIX-aw-dl-gateway.srm-iceb.a465-9q4k.cloudera.site"   # stable for this tenant + prefix
USER_NAME="steven.matison"

die() { echo "FAIL: $*" >&2; exit 1; }

# --- lookups shared by preflight + teardown (all read-only) ---------------------------------
env_crn()      { cdp environments describe-environment --environment-name "$ENV_NAME" 2>/dev/null | jq -r '.environment.crn // empty'; }
vpc_id()       { aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=$VPC_NAME" --query 'Vpcs[0].VpcId' --output text 2>/dev/null | grep -v '^None$' || true; }
cdw_cluster_ids() {   # every CDW cluster attached to this env (by CRN); name match as fallback
  local crn; crn="$(env_crn)"
  if [ -n "$crn" ]; then cdp dw list-clusters 2>/dev/null | jq -r --arg c "$crn" '.clusters[]? | select(.environmentCrn==$c) | .id'
  else cdp dw list-clusters 2>/dev/null | jq -r --arg p "$PREFIX" '.clusters[]? | select(.name|contains($p)) | .id'; fi
}
cdp_groups_present() { local g all; all=$(cdp iam list-groups --max-items 1000 2>/dev/null | jq -r '.groups[]?.groupName'); for g in $CDP_GROUPS; do echo "$all" | grep -x -F "$g" || true; done; }
cdp_cred_present()   { cdp environments list-credentials 2>/dev/null | jq -r --arg n "$CRED_NAME" '.credentials[]? | select(.credentialName==$n) | .credentialName'; }
datahubs_present()   { local d; for d in $DATAHUBS; do cdp datahub describe-cluster --cluster-name "$d" >/dev/null 2>&1 && echo "$d"; done; }
iam_roles()          { aws iam list-roles --query "Roles[?starts_with(RoleName,'$PREFIX-')].RoleName" --output text 2>/dev/null; }
iam_policies()       { aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName,'$PREFIX-')].Arn" --output text 2>/dev/null; }
iam_profiles()       { aws iam list-instance-profiles --query "InstanceProfiles[?starts_with(InstanceProfileName,'$PREFIX-')].InstanceProfileName" --output text 2>/dev/null; }
keypair_present()    { aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEYPAIR" --query 'KeyPairs[].KeyName' --output text 2>/dev/null; }
s3_buckets()         { aws s3api list-buckets --query "Buckets[?starts_with(Name,'$PREFIX-')].Name" --output text 2>/dev/null; }
ec2_instances()      { aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Name,Values=$PREFIX*" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null; }
tf_state_count()     { ( cd "$TF" && "$TERRAFORM" state list 2>/dev/null | wc -l | tr -d ' ' ); }
