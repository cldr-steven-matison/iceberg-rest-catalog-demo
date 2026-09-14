#!/usr/bin/env bash
# Full teardown of the srm-iceberg sandbox. Idempotent and independent of terraform state:
# CDP objects are removed with the cdp CLI, AWS leftovers with the aws CLI by name/tag, and
# terraform destroys only what its state actually owns. Ends with a VERIFY block that exits 1
# if anything named srm-iceberg remains — so a wrapper can never proceed on a dirty account.
#
# Order and why:
#   1. CDW (VWs -> connectors -> non-default DBCs -> cluster) and Data Hubs: the control plane
#      refuses an environment delete while either is attached.
#   2. Bastion EC2 + SG: out-of-band, lives in a terraform-managed subnet.
#   3. `cdp environments delete-environment --cascading --forced`, wait until gone: CDP tears
#      down DataLake -> RDS -> NLB -> ENI -> EC2 in its own order, with the IAM roles intact.
#   4. terraform: drop the env/datalake/idbroker addresses from state (CDP already deleted
#      them), then `destroy` the AWS shell + credential + groups it owns (seconds).
#   5. Orphan sweep by name/tag (covers a foreign or empty state): EC2, NLB/target groups,
#      RDS, ENI, IAM, keypair, S3, CDP credential + groups, and the VPC itself.
#   6. Reconcile: if nothing is live but state still lists resources, drop them from state.
#   7. VERIFY, exit 1 on anything left.
#
# Usage:  bash teardown.sh                    # typed confirmation gate
#         TEARDOWN_UNATTENDED=1 bash teardown.sh
set -uo pipefail
. "$(dirname "$0")/common.sh"

command -v cdp >/dev/null || die "cdp CLI not on PATH (need ~/.venvs/cdpcli)"
aws sts get-caller-identity >/dev/null 2>&1 || die "AWS SSO expired — run: aws sso login --profile $AWS_PROFILE"
cdp iam get-user >/dev/null 2>&1 || die "cdp not authenticated — run: cdp configure"
[ -n "$TERRAFORM" ] && [ -x "$TERRAFORM" ] || die "terraform not found — set TERRAFORM=/path"

if [ "${TEARDOWN_UNATTENDED:-0}" != "1" ]; then
  echo "This PERMANENTLY DESTROYS the $PREFIX env, VPC, S3 data, bastion, and local creds."
  read -r -p "Type the env name to confirm ($ENV_NAME): " ANS
  [ "$ANS" = "$ENV_NAME" ] || { echo "aborted"; exit 1; }
fi
T0=$(date +%s)
step() { echo; echo "== [$(( ($(date +%s) - T0) / 60 ))m] $* =="; }

# --- 1. CDW + Data Hubs ------------------------------------------------------------------
step "CDW clusters"
pkill -f "ssh -D 1080" 2>/dev/null && echo "  killed SOCKS proxy" || true
for CID in $(cdw_cluster_ids); do
  echo "  cluster $CID"
  for VID in $(cdp dw list-vws --cluster-id "$CID" | jq -r '.vws[]?.id'); do
    echo "    delete-vw $VID"; cdp dw delete-vw --cluster-id "$CID" --vw-id "$VID" >/dev/null 2>&1 || true
  done
  while [ "$(cdp dw list-vws --cluster-id "$CID" 2>/dev/null | jq '.vws|length')" != "0" ]; do echo "    ...waiting VWs"; sleep 20; done
  for KID in $(cdp dw list-connectors --cluster-id "$CID" 2>/dev/null | jq -r '.connectors[]?.id'); do
    echo "    delete-connector $KID"; cdp dw delete-connector --cluster-id "$CID" --connector-id "$KID" >/dev/null 2>&1 || true
  done
  for DID in $(cdp dw list-dbcs --cluster-id "$CID" | jq -r '.dbcs[]? | select(.name|endswith("-default")|not) | .id'); do
    echo "    delete-dbc $DID"; cdp dw delete-dbc --cluster-id "$CID" --dbc-id "$DID" >/dev/null 2>&1 || true
  done
  while [ "$(cdp dw list-dbcs --cluster-id "$CID" 2>/dev/null | jq '[.dbcs[]? | select(.name|endswith("-default")|not)] | length')" != "0" ]; do echo "    ...waiting DBCs"; sleep 20; done
  ACCEPTED=0
  for i in $(seq 1 10); do
    if cdp dw delete-cluster --cluster-id "$CID" >/dev/null 2>&1; then ACCEPTED=1; break; fi
    echo "    delete-cluster not accepted yet ($i/10)"; sleep 20
  done
  if [ "$ACCEPTED" = "1" ]; then
    while cdp dw list-clusters | jq -e --arg c "$CID" '.clusters[]?|select(.id==$c)' >/dev/null 2>&1; do echo "    ...waiting cluster"; sleep 30; done
    echo "    cluster $CID gone"
  else
    echo "  !! delete-cluster $CID refused 10 times — the env delete below will fail; inspect: cdp dw list-dbcs --cluster-id $CID"
  fi
done

step "Data Hubs"
for DH in $(datahubs_present); do echo "  delete $DH"; cdp datahub delete-cluster --cluster-name "$DH" >/dev/null 2>&1 || true; done
for DH in $DATAHUBS; do
  while cdp datahub describe-cluster --cluster-name "$DH" >/dev/null 2>&1; do echo "  ...waiting $DH"; sleep 30; done
done

# --- 2. bastion --------------------------------------------------------------------------
step "bastion"
BID=$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Name,Values=$BASTION_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$BID" ]; then
  echo "  terminate $BID"; aws ec2 terminate-instances --region "$REGION" --instance-ids $BID >/dev/null
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $BID
fi
BSG=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=$BASTION_SG" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ -n "$BSG" ] && [ "$BSG" != "None" ] && { echo "  delete SG $BSG"; aws ec2 delete-security-group --region "$REGION" --group-id "$BSG" >/dev/null 2>&1 || true; }

# --- 3. CDP environment (cascading) ------------------------------------------------------
step "CDP environment"
if [ -n "$(env_crn)" ]; then
  echo "  delete-environment --cascading --forced $ENV_NAME"
  cdp environments delete-environment --environment-name "$ENV_NAME" --cascading --forced >/dev/null 2>&1 || true
  N=0
  while [ -n "$(env_crn)" ]; do
    N=$((N+1)); [ $N -gt 90 ] && { echo "  !! env still present after 45 min"; break; }
    echo "  ...$(cdp environments describe-environment --environment-name "$ENV_NAME" 2>/dev/null | jq -r '.environment.status // "?"')"; sleep 30
  done
  [ -z "$(env_crn)" ] && echo "  env gone"
else
  echo "  no env"
fi

# --- 4. terraform ------------------------------------------------------------------------
step "terraform destroy (AWS shell + CDP credential/groups owned by state)"
cd "$TF" || die "missing $TF"
"$TERRAFORM" init -input=false >/dev/null 2>&1 || echo "  !! terraform init failed"
for ADDR in $("$TERRAFORM" state list 2>/dev/null | grep -E 'cdp_environments_aws_environment|cdp_datalake_aws_datalake|cdp_environments_id_broker_mappings'); do
  echo "  state rm $ADDR (deleted by CDP above)"; "$TERRAFORM" state rm "$ADDR" >/dev/null 2>&1 || true
done
# the cdp provider errors (instead of forgetting) when a group/credential in state is already gone
LIVE_GROUPS=$(cdp_groups_present); LIVE_CRED=$(cdp_cred_present)
for ADDR in $("$TERRAFORM" state list 2>/dev/null | grep -E 'cdp_iam_group|cdp_environments_aws_credential'); do
  case "$ADDR" in
    *cdp_iam_group*)  G=$(echo "$ADDR" | sed -n 's/.*\["\(.*\)"\].*/\1/p'); echo "$LIVE_GROUPS" | grep -qx -F "$G" && continue ;;
    *)                [ -n "$LIVE_CRED" ] && continue ;;
  esac
  echo "  state rm $ADDR (already gone)"; "$TERRAFORM" state rm "$ADDR" >/dev/null 2>&1 || true
done
if [ "$(tf_state_count)" != "0" ]; then
  "$TERRAFORM" destroy -auto-approve -input=false || echo "  !! terraform destroy exited non-zero — sweeping leftovers"
else
  echo "  state empty, nothing to destroy"
fi
cd "$DEMO"

# --- 5. orphan sweep (name/tag based, independent of state) -------------------------------
step "orphan sweep"
VPC=$(vpc_id)
if [ -n "$VPC" ]; then
  echo "  VPC $VPC still exists — clearing what lives in it"
  IDS=$(aws ec2 describe-instances --region "$REGION" --filters "Name=vpc-id,Values=$VPC" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -n "$IDS" ]; then echo "  terminate EC2: $IDS"; aws ec2 terminate-instances --region "$REGION" --instance-ids $IDS >/dev/null; aws ec2 wait instance-terminated --region "$REGION" --instance-ids $IDS; fi
  for LB in $(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" --output text); do
    echo "  delete LB $LB"
    aws elbv2 modify-load-balancer-attributes --region "$REGION" --load-balancer-arn "$LB" --attributes Key=deletion_protection.enabled,Value=false >/dev/null 2>&1 || true
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$LB" >/dev/null 2>&1 || true
  done
  for TG in $(aws elbv2 describe-target-groups --region "$REGION" --query "TargetGroups[?VpcId=='$VPC'].TargetGroupArn" --output text); do
    aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$TG" >/dev/null 2>&1 || true
  done
  for DB in $(aws rds describe-db-instances --region "$REGION" --query "DBInstances[?DBSubnetGroup.VpcId=='$VPC'].DBInstanceIdentifier" --output text); do
    echo "  delete RDS $DB"
    aws rds modify-db-instance --region "$REGION" --db-instance-identifier "$DB" --no-deletion-protection --apply-immediately >/dev/null 2>&1 || true
    aws rds delete-db-instance --region "$REGION" --db-instance-identifier "$DB" --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 || true
    aws rds wait db-instance-deleted --region "$REGION" --db-instance-identifier "$DB" 2>/dev/null || true
  done
  for SG in $(aws rds describe-db-subnet-groups --region "$REGION" --query "DBSubnetGroups[?VpcId=='$VPC'].DBSubnetGroupName" --output text); do
    aws rds delete-db-subnet-group --region "$REGION" --db-subnet-group-name "$SG" >/dev/null 2>&1 || true
  done
  N=0
  while :; do
    ENIS=$(aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=vpc-id,Values=$VPC" --query 'NetworkInterfaces[].[NetworkInterfaceId,Status]' --output text)
    [ -z "$ENIS" ] && break
    for E in $(echo "$ENIS" | awk '$2=="available"{print $1}'); do aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$E" >/dev/null 2>&1 || true; done
    N=$((N+1)); [ $N -gt 30 ] && { echo "  !! ENIs still attached after 15 min: $(echo "$ENIS" | tr '\n' ' ')"; break; }
    echo "  ...waiting ENIs ($(echo "$ENIS" | wc -l | tr -d ' '))"; sleep 30
  done
  echo "  delete VPC $VPC"
  EPS=$(aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=vpc-id,Values=$VPC" --query 'VpcEndpoints[].VpcEndpointId' --output text)
  [ -n "$EPS" ] && aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids $EPS >/dev/null 2>&1
  while [ -n "$(aws ec2 describe-vpc-endpoints --region "$REGION" --filters "Name=vpc-id,Values=$VPC" --query 'VpcEndpoints[].VpcEndpointId' --output text)" ]; do echo "  ...waiting endpoints"; sleep 15; done
  for NAT in $(aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=vpc-id,Values=$VPC" "Name=state,Values=pending,available" --query 'NatGateways[].NatGatewayId' --output text); do
    aws ec2 delete-nat-gateway --region "$REGION" --nat-gateway-id "$NAT" >/dev/null 2>&1 || true
    aws ec2 wait nat-gateway-deleted --region "$REGION" --nat-gateway-ids "$NAT" 2>/dev/null || true
  done
  for ALLOC in $(aws ec2 describe-addresses --region "$REGION" --filters "Name=tag:Name,Values=$VPC_NAME*" --query 'Addresses[?AssociationId==null].AllocationId' --output text); do
    aws ec2 release-address --region "$REGION" --allocation-id "$ALLOC" >/dev/null 2>&1 || true
  done
  for IGW in $(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=attachment.vpc-id,Values=$VPC" --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW" --vpc-id "$VPC" >/dev/null 2>&1 || true
    aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW" >/dev/null 2>&1 || true
  done
  for SN in $(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC" --query 'Subnets[].SubnetId' --output text); do
    aws ec2 delete-subnet --region "$REGION" --subnet-id "$SN" >/dev/null 2>&1 || true
  done
  for RT in $(aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=$VPC" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text); do
    for A in $(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$RT" --query 'RouteTables[].Associations[].RouteTableAssociationId' --output text); do
      aws ec2 disassociate-route-table --region "$REGION" --association-id "$A" >/dev/null 2>&1 || true
    done
    aws ec2 delete-route-table --region "$REGION" --route-table-id "$RT" >/dev/null 2>&1 || true
  done
  SGS=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$VPC" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)
  for SG in $SGS; do   # drop cross-references first, then delete
    ING=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG" --query 'SecurityGroups[0].IpPermissions' --output json)
    [ "$(echo "$ING" | jq 'length')" != "0" ] && aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$SG" --ip-permissions "$ING" >/dev/null 2>&1 || true
    EGR=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG" --query 'SecurityGroups[0].IpPermissionsEgress' --output json)
    [ "$(echo "$EGR" | jq 'length')" != "0" ] && aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$SG" --ip-permissions "$EGR" >/dev/null 2>&1 || true
  done
  for SG in $SGS; do aws ec2 delete-security-group --region "$REGION" --group-id "$SG" >/dev/null 2>&1 || true; done
  aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC" >/dev/null 2>&1 && echo "  VPC deleted" || echo "  !! VPC delete refused — see VERIFY"
else
  echo "  no VPC"
fi
for IP in $(iam_profiles); do
  for R in $(aws iam get-instance-profile --instance-profile-name "$IP" --query 'InstanceProfile.Roles[].RoleName' --output text 2>/dev/null); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$IP" --role-name "$R" >/dev/null 2>&1 || true
  done
  aws iam delete-instance-profile --instance-profile-name "$IP" >/dev/null 2>&1 && echo "  deleted instance profile $IP"
done
for ROLE in $(iam_roles); do
  for PA in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$PA" >/dev/null 2>&1 || true
  done
  for PI in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$PI" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 && echo "  deleted role $ROLE"
done
for PA in $(iam_policies); do
  for V in $(aws iam list-policy-versions --policy-arn "$PA" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null); do
    aws iam delete-policy-version --policy-arn "$PA" --version-id "$V" >/dev/null 2>&1 || true
  done
  aws iam delete-policy --policy-arn "$PA" >/dev/null 2>&1 && echo "  deleted policy $PA"
done
[ -n "$(keypair_present)" ] && aws ec2 delete-key-pair --region "$REGION" --key-name "$KEYPAIR" >/dev/null 2>&1 && echo "  deleted keypair $KEYPAIR"
for B in $(s3_buckets); do echo "  remove s3://$B"; aws s3 rb "s3://$B" --force >/dev/null 2>&1 || true; done
[ -n "$(cdp_cred_present)" ] && cdp environments delete-credential --credential-name "$CRED_NAME" >/dev/null 2>&1 && echo "  deleted CDP credential $CRED_NAME"
for G in $(cdp_groups_present); do cdp iam delete-group --group-name "$G" >/dev/null 2>&1 && echo "  deleted CDP group $G"; done

# --- 6. state reconcile + local files ---------------------------------------------------
step "reconcile"
LIVE="$(env_crn)$(vpc_id)$(iam_roles)$(iam_policies)$(iam_profiles)$(keypair_present)$(s3_buckets)$(ec2_instances)$(cdp_cred_present)$(cdp_groups_present)"
if [ -z "$LIVE" ] && [ "$(tf_state_count)" != "0" ]; then
  echo "  nothing live but state lists $(tf_state_count) resources — dropping them from state (backup: terraform.tfstate.backup)"
  ( cd "$TF" && "$TERRAFORM" state rm $("$TERRAFORM" state list) >/dev/null 2>&1 || true )
fi
rm -f "$DEMO/config.env" "$DEMO/credentials.json" "$DEMO/credentials-nifi.json"
echo "  removed local config.env + credentials*.json (.workload.creds kept)"
grep -q "dw-$ENV_NAME" /etc/hosts 2>/dev/null && echo "  note: stale *.dw-$ENV_NAME lines in /etc/hosts (manual, sudo)"

# --- 7. verify ---------------------------------------------------------------------------
step "VERIFY"
BAD=0
chk() { if [ -z "$2" ]; then echo "  gone     $1"; else echo "  REMAINS  $1: $(echo "$2" | tr '\n' ' ')"; BAD=1; fi; }
chk "CDP env"            "$(env_crn)"
chk "CDP credential"     "$(cdp_cred_present)"
chk "CDP groups"         "$(cdp_groups_present)"
chk "Data Hubs"          "$(datahubs_present)"
chk "CDW clusters"       "$(cdw_cluster_ids)"
chk "VPC $VPC_NAME"      "$(vpc_id)"
chk "IAM roles"          "$(iam_roles)"
chk "IAM policies"       "$(iam_policies)"
chk "IAM profiles"       "$(iam_profiles)"
chk "EC2 keypair"        "$(keypair_present)"
chk "S3 buckets"         "$(s3_buckets)"
chk "EC2 instances"      "$(ec2_instances)"
N=$(tf_state_count); [ "$N" = "0" ] && echo "  gone     terraform state" || { echo "  REMAINS  terraform state: $N resources"; BAD=1; }
echo
if [ "$BAD" = "0" ]; then echo "== TEARDOWN COMPLETE ($(( ($(date +%s) - T0) / 60 )) min) =="; exit 0; fi
echo "== TEARDOWN INCOMPLETE — fix the REMAINS lines above and re-run =="; exit 1
