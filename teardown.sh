#!/usr/bin/env bash
# Full teardown of the srm-iceberg sandbox — run BY HAND before the Friday reaper for a true
# clean-slate Monday redeploy (#268). Symmetric to redeploy.sh + `terraform apply`.
#
# Removes EVERYTHING: Trino VW + Database Catalog + CDW cluster, the Impala Data Hub, the CDP
# environment + DataLake, the VPC + security groups + IAM + keypair + S3 (via terraform destroy),
# the out-of-band bastion EC2 + its SG, and local SOCKS/cred state on the Mac.
#
# WHY THIS ORDER: CDW (EKS) and the Data Hubs are NOT in terraform state, and the CDP control plane
# BLOCKS an environment delete while any Data Hub / CDW cluster is still attached. So the CDP-side
# objects are torn down via `cdp` CLI FIRST; only then does `terraform destroy` (which owns the CDP
# env+DL+cross-acct cred + VPC + SGs + IAM + keypair + S3) succeed. S3 must be emptied before
# destroy or the bucket delete fails. Bastion + its SG are raw `aws ec2` and go last.
#
# NOTE: intentionally NOT `set -e` — teardown is best-effort; a 404 on an already-gone object must
# not abort the rest. Every destructive call is `|| true`; the final VERIFY block is the done-check.
set -uo pipefail
export PATH="$HOME/.venvs/cdpcli/bin:$PATH"
export AWS_PROFILE="${AWS_PROFILE:-cldr-se}"
REGION="${AWS_REGION:-us-east-2}"
DEMO="$HOME/Documents/GitHub/iceberg-rest-catalog-demo"
TF="$HOME/Documents/GitHub/cdp-tf-quickstarts/aws"
ENV_NAME="srm-iceberg-cdp-env"

# --- 1. prereqs + confirmation gate --------------------------------------------------------
command -v cdp >/dev/null || { echo "cdp CLI not on PATH (need ~/.venvs/cdpcli)"; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || { echo "AWS creds invalid — run: aws sso login --profile $AWS_PROFILE"; exit 1; }
cdp environments list-environments >/dev/null 2>&1 || { echo "cdp not authed — run: cdp configure"; exit 1; }
echo "This will PERMANENTLY DESTROY the srm-iceberg env, VPC, S3 data, bastion, and local creds."
read -r -p "Type the env name to confirm ($ENV_NAME): " ANS
[ "$ANS" = "$ENV_NAME" ] || { echo "aborted"; exit 1; }

# resolve the live env CRN up front (used for the data-share delete; empty if env already gone)
ENV_CRN_LIVE=$(cdp environments describe-environment --environment-name "$ENV_NAME" 2>/dev/null | jq -r '.environment.crn // empty')

# --- 2. local SOCKS proxy ------------------------------------------------------------------
pkill -f "ssh -D 1080" 2>/dev/null && echo "killed ssh -D 1080 SOCKS proxy" || echo "no SOCKS proxy running"

# --- 3. CDW teardown (VW -> DBC -> cluster) ------------------------------------------------
# match on .name (= the env name); .environmentCrn is a UUID CRN and won't contain "srm-iceberg".
CID=$(cdp dw list-clusters | jq -r '.clusters[]? | select(.name|contains("srm-iceberg")) | .id')
if [ -n "${CID:-}" ]; then
  echo "== CDW cluster $CID =="
  for VID in $(cdp dw list-vws --cluster-id "$CID" | jq -r '.vws[]?.id'); do
    echo "  delete-vw $VID"; cdp dw delete-vw --cluster-id "$CID" --vw-id "$VID" || true
  done
  # drain VWs before dropping the DBC (DBC delete fails while a VW still references it)
  while [ "$(cdp dw list-vws --cluster-id "$CID" 2>/dev/null | jq '.vws|length')" != "0" ]; do echo "  ...waiting VWs"; sleep 20; done
  for DID in $(cdp dw list-dbcs --cluster-id "$CID" | jq -r '.dbcs[]?.id'); do
    echo "  delete-dbc $DID"; cdp dw delete-dbc --cluster-id "$CID" --dbc-id "$DID" || true
  done
  echo "  delete-cluster $CID"; cdp dw delete-cluster --cluster-id "$CID" || true
  while cdp dw list-clusters | jq -e --arg c "$CID" '.clusters[]?|select(.id==$c)' >/dev/null 2>&1; do echo "  ...waiting CDW cluster"; sleep 30; done
  echo "  CDW gone (EKS + internal NLB + worker SGs removed with it)"
else
  echo "== no CDW cluster for srm-iceberg =="
fi

# --- 4. Data Hubs (srm-iceberg-impala; srm-hol-optimizer if the HOL was left up) ------------
for DH in srm-iceberg-impala srm-hol-optimizer; do
  if cdp datahub describe-cluster --cluster-name "$DH" >/dev/null 2>&1; then
    echo "delete data hub $DH"; cdp datahub delete-cluster --cluster-name "$DH" || true
  fi
done
for DH in srm-iceberg-impala srm-hol-optimizer; do
  while cdp datahub describe-cluster --cluster-name "$DH" >/dev/null 2>&1; do echo "  ...waiting DH $DH"; sleep 30; done
done

# --- 5. DataShare (best-effort; the env delete cascades this too) ---------------------------
[ -f "$DEMO/config.env" ] && . "$DEMO/config.env"
ENV_CRN="${ENV_CRN:-$ENV_CRN_LIVE}"   # prefer config.env, fall back to the live lookup
if [ -n "${DL_CRN:-}" ] && [ -n "${ENV_CRN:-}" ] && [ -n "${DATA_SHARE_ID:-}" ]; then
  cdp datacatalog delete-data-share --datalake-crn "$DL_CRN" --environment-crn "$ENV_CRN" --data-share-id "$DATA_SHARE_ID" 2>/dev/null \
    && echo "deleted data share $DATA_SHARE_ID" || echo "data share already gone / cascades with env"
fi

# --- 6. empty S3 buckets (required before terraform destroy) --------------------------------
for B in $(aws s3api list-buckets --query 'Buckets[?starts_with(Name,`srm-iceberg-`)].Name' --output text); do
  echo "empty s3://$B"; aws s3 rm "s3://$B" --recursive >/dev/null 2>&1 || true
done

# --- 7. terraform destroy (CDP env+DL+cred + VPC+SG+IAM+keypair+S3) --------------------------
echo "== terraform destroy =="
( cd "$TF" && terraform destroy -auto-approve )
# Fallback if destroy stalls on the CDP env (CDW/DH residue): uncomment, run, then re-run destroy:
#   cdp environments delete-environment --cascade --environment-name "$ENV_NAME"
#   ( cd "$TF" && terraform state rm $(terraform state list | grep -E 'cdp_(environment|datalake)') )

# --- 8. bastion (out-of-band — not in TF state) --------------------------------------------
BID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=srm-iceberg-bastion" "Name=instance-state-name,Values=running,stopped,stopping" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$BID" ]; then
  echo "terminate bastion $BID"; aws ec2 terminate-instances --region "$REGION" --instance-ids $BID >/dev/null
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $BID
fi
BSG=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=srm-iceberg-bastion-sg" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ -n "$BSG" ] && [ "$BSG" != "None" ] && { echo "delete bastion SG $BSG"; aws ec2 delete-security-group --region "$REGION" --group-id "$BSG" || true; }

# --- 9. local cleanup ----------------------------------------------------------------------
rm -f "$DEMO/config.env" "$DEMO/credentials.json" "$DEMO/credentials-nifi.json"
echo "removed local config.env + credentials*.json (kept .workload.creds, ssh key, tfstate)"
grep -q "dw-srm-iceberg-cdp-env" /etc/hosts 2>/dev/null && echo "WARN: stale *.dw-srm-iceberg lines in /etc/hosts — remove by hand (needs sudo)" || true
echo "REMINDER: disable/clear the FoxyProxy SOCKS entry in the browser (manual)."

# --- 10. verify ----------------------------------------------------------------------------
echo "== VERIFY =="
cdp environments list-environments | jq -r '.environments[]?.environmentName' | grep -q srm-iceberg \
  && echo "  env STILL PRESENT (destroy may still be finishing)" || echo "  CDP env gone"
( cd "$TF" && [ "$(terraform state list | wc -l | tr -d ' ')" = "0" ] && echo "  terraform state empty" || echo "  terraform state NOT empty — inspect" )
aws s3api list-buckets --query 'Buckets[?starts_with(Name,`srm-iceberg-`)].Name' --output text | grep -q . \
  && echo "  S3 buckets remain" || echo "  S3 buckets gone"
echo "== TEARDOWN COMPLETE =="
