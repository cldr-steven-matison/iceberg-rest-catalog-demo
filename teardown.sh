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
#
# UNATTENDED: set TEARDOWN_UNATTENDED=1 to skip the interactive confirmation gate (used by
# monday-redeploy.sh). Interactive default is unchanged.
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
TEARDOWN_UNATTENDED="${TEARDOWN_UNATTENDED:-0}"
if [ "$TEARDOWN_UNATTENDED" != "1" ]; then
  echo "This will PERMANENTLY DESTROY the srm-iceberg env, VPC, S3 data, bastion, and local creds."
  read -r -p "Type the env name to confirm ($ENV_NAME): " ANS
  [ "$ANS" = "$ENV_NAME" ] || { echo "aborted"; exit 1; }
fi

# resolve the live env CRN up front (used for CDW match + data-share delete; empty if env already gone)
ENV_CRN_LIVE=$(cdp environments describe-environment --environment-name "$ENV_NAME" 2>/dev/null | jq -r '.environment.crn // empty')

# --- 2. local SOCKS proxy ------------------------------------------------------------------
pkill -f "ssh -D 1080" 2>/dev/null && echo "killed ssh -D 1080 SOCKS proxy" || echo "no SOCKS proxy running"

# --- 3. CDW teardown (VWs -> connectors -> non-default DBCs -> cluster) ---------------------
# Match CDW clusters by environmentCrn, NOT by .name — CDW generates its own cluster name
# (e.g. "env-kv9zsm") that has nothing to do with the CDP env name. Matching by .name means
# Error-state orphan clusters from prior sessions are silently skipped (hit live 2026-09-14).
# Fall back to name pattern only if the env CRN is already gone.
#
# CDW delete order (learned live 2026-09-09):
#   * delete all VWs, wait until none remain;
#   * delete only NON-default DBCs — the default DBC (name ends in "-default") CANNOT be deleted
#     directly (500 "only default catalog"); `delete-cluster` removes it. delete-cluster ALSO 400s
#     ("DB Catalog(s) associated") while a non-default DBC is still mid-delete, so wait it out;
#   * then delete-cluster, retried a few times to ride out the brief post-DBC-delete 400 window.
if [ -n "${ENV_CRN_LIVE:-}" ]; then
  CIDS=$(cdp dw list-clusters | jq -r --arg crn "$ENV_CRN_LIVE" \
    '.clusters[]? | select(.environmentCrn==$crn) | .id')
else
  # env already gone — fall back to name pattern
  CIDS=$(cdp dw list-clusters | jq -r '.clusters[]? | select(.name|contains("srm-iceberg")) | .id')
fi

if [ -n "${CIDS:-}" ]; then
  for CID in $CIDS; do
    echo "== CDW cluster $CID =="
    for VID in $(cdp dw list-vws --cluster-id "$CID" | jq -r '.vws[]?.id'); do
      echo "  delete-vw $VID"; cdp dw delete-vw --cluster-id "$CID" --vw-id "$VID" || true
    done
    while [ "$(cdp dw list-vws --cluster-id "$CID" 2>/dev/null | jq '.vws|length')" != "0" ]; do echo "  ...waiting VWs"; sleep 20; done
    # connectors (auto-created iceberg + hive connectors ride in with the Trino VW; delete-cluster
    # 500s "connector(s) associated" while any remain — learned live 2026-09-09).
    for KID in $(cdp dw list-connectors --cluster-id "$CID" | jq -r '.connectors[]?.id'); do
      echo "  delete-connector $KID"; cdp dw delete-connector --cluster-id "$CID" --connector-id "$KID" || true
    done
    # non-default DBCs only (skip the *-default catalog — delete-cluster reaps it)
    for DID in $(cdp dw list-dbcs --cluster-id "$CID" | jq -r '.dbcs[]? | select(.name|endswith("-default")|not) | .id'); do
      echo "  delete-dbc $DID"; cdp dw delete-dbc --cluster-id "$CID" --dbc-id "$DID" || true
    done
    while [ "$(cdp dw list-dbcs --cluster-id "$CID" 2>/dev/null | jq '[.dbcs[]? | select(.name|endswith("-default")|not)] | length')" != "0" ]; do echo "  ...waiting non-default DBCs"; sleep 20; done
    echo "  delete-cluster $CID"
    ACCEPTED=0
    for i in $(seq 1 10); do
      if cdp dw delete-cluster --cluster-id "$CID" 2>/dev/null; then ACCEPTED=1; break; fi
      echo "  ...delete-cluster not accepted yet (retry $i/10)"; sleep 20
    done
    if [ "$ACCEPTED" = "1" ]; then
      while cdp dw list-clusters | jq -e --arg c "$CID" '.clusters[]?|select(.id==$c)' >/dev/null 2>&1; do echo "  ...waiting CDW cluster"; sleep 30; done
      echo "  CDW cluster $CID gone (EKS + internal NLB + worker SGs removed with it)"
    else
      echo "  !! delete-cluster still refused after 10 retries — inspect: cdp dw list-dbcs --cluster-id $CID"
      echo "     continuing best-effort; the env delete in step 7 will block until CDW is fully gone."
    fi
  done
else
  echo "== no CDW cluster for $ENV_NAME =="
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

# --- 6. bastion — MUST run BEFORE terraform destroy (out-of-band, not in TF state) ----------
# The bastion EC2 sits in a TF-managed public subnet; leaving it up makes `terraform destroy`
# abort with DependencyViolation on that subnet (hit live 2026-09-09). Terminate it + its SG
# first so the VPC/subnet teardown is unblocked. (No manual S3 pre-empty: the data bucket is
# force_destroy=true, so terraform empties+deletes it during destroy.)
BID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=srm-iceberg-bastion" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$BID" ]; then
  echo "terminate bastion $BID"; aws ec2 terminate-instances --region "$REGION" --instance-ids $BID >/dev/null
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $BID
fi
BSG=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=srm-iceberg-bastion-sg" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ -n "$BSG" ] && [ "$BSG" != "None" ] && { echo "delete bastion SG $BSG"; aws ec2 delete-security-group --region "$REGION" --group-id "$BSG" || true; }

# --- 6b. IAM + keypair pre-purge (safe whether tfstate full or empty) -----------------------
# When tfstate is already empty (a prior destroy already ran), terraform destroy is a no-op and
# leaves the IAM roles/policies/instance profiles + EC2 keypair from the last apply in AWS.
# The next `terraform apply` then fails with EntityAlreadyExists on every IAM resource.
# Explicitly delete all srm-iceberg-* IAM resources + keypair here, before destroy, so the
# script is idempotent regardless of tfstate. || true throughout — best-effort teardown.
echo "== pre-terraform IAM + keypair purge =="
for IP in $(aws iam list-instance-profiles \
    --query 'InstanceProfiles[?starts_with(InstanceProfileName,`srm-iceberg-`)].InstanceProfileName' \
    --output text 2>/dev/null); do
  for R in $(aws iam get-instance-profile --instance-profile-name "$IP" \
      --query 'InstanceProfile.Roles[].RoleName' --output text 2>/dev/null); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$IP" --role-name "$R" 2>/dev/null || true
  done
  aws iam delete-instance-profile --instance-profile-name "$IP" 2>/dev/null || true
  echo "  deleted instance-profile $IP"
done
for ROLE in $(aws iam list-roles \
    --query 'Roles[?starts_with(RoleName,`srm-iceberg-`)].RoleName' \
    --output text 2>/dev/null); do
  for PA in $(aws iam list-attached-role-policies --role-name "$ROLE" \
      --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$PA" 2>/dev/null || true
  done
  for PI in $(aws iam list-role-policies --role-name "$ROLE" \
      --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$PI" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
  echo "  deleted role $ROLE"
done
for PA in $(aws iam list-policies --scope Local \
    --query 'Policies[?starts_with(PolicyName,`srm-iceberg-`)].Arn' \
    --output text 2>/dev/null); do
  aws iam delete-policy --policy-arn "$PA" 2>/dev/null || true
  echo "  deleted policy $PA"
done
aws ec2 delete-key-pair --region "$REGION" --key-name "srm-iceberg-ssh-key" 2>/dev/null || true
echo "  deleted EC2 keypair srm-iceberg-ssh-key (if present)"

# --- 7. terraform destroy (CDP env+DL+cred + VPC+SG+IAM+keypair+S3+data-bucket) --------------
# `terraform init` first — the module ref can drift between rebuilds and destroy aborts with
# "Module source has changed" until re-init'd (hit live 2026-09-09). Destroy is idempotent: if a
# run stops partway on a stray dependency, fix it and just re-run — it resumes from the remainder.
echo "== terraform init + destroy =="
( cd "$TF" && terraform init -input=false && terraform destroy -auto-approve )
# Fallback if destroy stalls on the CDP env (CDW/DH residue): uncomment, run, then re-run destroy:
#   cdp environments delete-environment --cascade --environment-name "$ENV_NAME"
#   ( cd "$TF" && terraform state rm $(terraform state list | grep -E 'cdp_(environment|datalake)') )

# out-of-band buckets terraform doesn't own (e.g. srm-iceberg-emr-*) survive destroy — remove them.
for B in $(aws s3api list-buckets --query 'Buckets[?starts_with(Name,`srm-iceberg-`)].Name' --output text); do
  echo "remove leftover s3://$B"; aws s3 rb "s3://$B" --force >/dev/null 2>&1 || true
done

# --- 8. local cleanup ----------------------------------------------------------------------
rm -f "$DEMO/config.env" "$DEMO/credentials.json" "$DEMO/credentials-nifi.json"
# NOTE: the SSH .pem is a terraform resource (local_sensitive_file.pem_file) and is removed by
# destroy above; Monday's `terraform apply` regenerates it. .workload.creds + tfstate are kept.
echo "removed local config.env + credentials*.json (.workload.creds + tfstate kept; ssh .pem regenerates on apply)"
grep -q "dw-srm-iceberg-cdp-env" /etc/hosts 2>/dev/null && echo "WARN: stale *.dw-srm-iceberg lines in /etc/hosts — remove by hand (needs sudo)" || true
echo "REMINDER: disable/clear the FoxyProxy SOCKS entry in the browser (manual)."

# --- 9. verify -----------------------------------------------------------------------------
echo "== VERIFY =="
cdp environments list-environments | jq -r '.environments[]?.environmentName' | grep -q srm-iceberg \
  && echo "  env STILL PRESENT (destroy may still be finishing)" || echo "  CDP env gone"
( cd "$TF" && [ "$(terraform state list | wc -l | tr -d ' ')" = "0" ] && echo "  terraform state empty" || echo "  terraform state NOT empty — inspect" )
aws s3api list-buckets --query 'Buckets[?starts_with(Name,`srm-iceberg-`)].Name' --output text | grep -q . \
  && echo "  S3 buckets remain" || echo "  S3 buckets gone"
aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=srm-iceberg-net" --query 'Vpcs[].VpcId' --output text | grep -q . \
  && echo "  VPC remains" || echo "  VPC gone"
aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Name,Values=srm-iceberg-bastion" "Name=instance-state-name,Values=running,stopped,stopping,pending" --query 'Reservations[].Instances[].InstanceId' --output text | grep -q . \
  && echo "  bastion remains" || echo "  bastion gone"
aws iam list-roles --query 'Roles[?starts_with(RoleName,`srm-iceberg-`)].RoleName' --output text | grep -q . \
  && echo "  IAM roles remain — check above output" || echo "  IAM roles gone"
aws ec2 describe-key-pairs --region "$REGION" --filters "Name=key-name,Values=srm-iceberg-ssh-key" --query 'KeyPairs[].KeyName' --output text | grep -q . \
  && echo "  EC2 keypair remains" || echo "  EC2 keypair gone"
echo "== TEARDOWN COMPLETE =="
