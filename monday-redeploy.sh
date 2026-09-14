#!/usr/bin/env bash
# One-command weekly rebuild of the srm-iceberg sandbox (Linux deploy host):
#   bump enddate -> teardown.sh -> preflight.sh -> redeploy.sh -> Trino VW playbook -> verify.
# Stops at the first failing leg. Everything is logged to monday-redeploy-<date>.log.
#
# Manual prereq (interactive, once per run):  aws sso login --profile cldr-se
# Usage:  bash monday-redeploy.sh            # run it in the background and watch the log
set -euo pipefail
. "$(dirname "$0")/common.sh"
cd "$DEMO"
LOG="$DEMO/monday-redeploy-$(date +%F-%H%M).log"
exec > >(tee -a "$LOG") 2>&1
T0=$(date +%s)
leg() { echo; echo "== [$(( ($(date +%s) - T0) / 60 ))m] $* =="; }

leg "enddate -> coming Friday"
END=$(date -d 'next friday' +%F)
sed -i -E "s/(enddate *= *\")[0-9-]+(\")/\1$END\2/" "$TF/terraform.tfvars"
grep -o 'enddate *= *"[0-9-]*"' "$TF/terraform.tfvars"

leg "leg 0: teardown"
TEARDOWN_UNATTENDED=1 bash "$DEMO/teardown.sh"

leg "leg 1: preflight"
bash "$DEMO/preflight.sh"

leg "leg 2: REST Catalog rebuild"
bash "$DEMO/redeploy.sh"

leg "leg 3: Trino VW"
. "$DEMO/config.env"                       # ENV_CRN written by redeploy.sh
[ -n "${ENV_CRN:-}" ] || die "config.env has no ENV_CRN"
SUBNETS=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=tag:Name,Values=$VPC_NAME-private-*" --query 'Subnets[].SubnetId' --output json | jq -c .)
[ "$(echo "$SUBNETS" | jq 'length')" = "3" ] || die "expected 3 private subnets tagged $VPC_NAME-private-*, got $SUBNETS"
echo "  env_crn=$ENV_CRN"; echo "  private_subnets=$SUBNETS"
export ANSIBLE_COLLECTIONS_PATH="$CC_VENV/collections"
( cd "$TRINO" && "$CC_VENV/bin/ansible-playbook" provision-trino-vw.yml -v \
    -e "$(jq -n --arg crn "$ENV_CRN" --argjson subs "$SUBNETS" '{env_crn:$crn, private_subnets:$subs}')" )

leg "verify"
CID=$(cdw_cluster_ids | head -1); [ -n "$CID" ] || die "no CDW cluster on $ENV_NAME"
VW=$(cdp dw list-vws --cluster-id "$CID" | jq -r --arg n "$TRINO_VW" '.vws[]? | select(.name==$n) | .status')
echo "  $TRINO_VW: ${VW:-missing}"
[ "$VW" = "Running" ] || die "$TRINO_VW is not Running"
bash "$DEMO/test-rest-catalog.sh" poc_uc2 airlines | grep has_vended_creds
bash "$DEMO/test-rest-catalog.sh" poc_uc2 flights  | grep has_vended_creds

echo
echo "== MONDAY REDEPLOY COMPLETE ($(( ($(date +%s) - T0) / 60 )) min): REST Catalog + Trino VW live. Log: $LOG =="
