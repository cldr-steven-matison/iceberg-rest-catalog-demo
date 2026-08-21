#!/usr/bin/env bash
# bastion-up.sh — provision (idempotent) an EC2 bastion inside the srm-iceberg VPC so the Mac can
# reach private-subnet CDP services (Trino Web UI, Hue, HMS thrift). The bastion's ENI has a
# 10.10.x source IP the private NLB/services already route back to.
#
# Idempotent + tag-keyed: resolves VPC/subnet by Name tag (survives weekly rebuilds with new IDs),
# reuses an existing bastion if present, and re-points the SSH ingress at the current Mac IP.
#
# Usage:  ./bastion-up.sh          # create or start + print public IP
#         ./bastion-up.sh --stop   # stop the bastion (keeps it; stops compute billing)
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-cldr-se}"
export AWS_REGION="${AWS_REGION:-us-east-2}"

VPC_NAME="srm-iceberg-net"
SUBNET_NAME="srm-iceberg-net-public-us-east-2a"
SG_NAME="srm-iceberg-bastion-sg"
KEY_NAME="srm-iceberg-keypair"
INSTANCE_NAME="srm-iceberg-bastion"
INSTANCE_TYPE="t3.small"
AMI_SSM_PARAM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

q() { aws ec2 "$@"; }

# --- resolve bastion instance (any non-terminated) up front, used by --stop and reuse ---
find_instance() {
  q describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n' | head -1
}

if [[ "${1:-}" == "--stop" ]]; then
  IID=$(find_instance)
  [[ -z "$IID" ]] && { echo "No bastion found to stop."; exit 0; }
  echo "Stopping $IID ..."; q stop-instances --instance-ids "$IID" >/dev/null
  echo "Stopped (compute billing paused; re-run without --stop to start again)."
  exit 0
fi

MYIP=$(curl -s https://checkip.amazonaws.com)
echo "Mac public IP: $MYIP"

VPC_ID=$(q describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" --query 'Vpcs[0].VpcId' --output text)
[[ "$VPC_ID" == "None" || -z "$VPC_ID" ]] && { echo "ERROR: VPC $VPC_NAME not found"; exit 1; }
SUBNET_ID=$(q describe-subnets --filters "Name=tag:Name,Values=$SUBNET_NAME" --query 'Subnets[0].SubnetId' --output text)
[[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]] && { echo "ERROR: subnet $SUBNET_NAME not found"; exit 1; }
echo "VPC=$VPC_ID  public-subnet=$SUBNET_ID"

# --- security group: create if absent, then ensure exactly SSH/22 from the current Mac IP ---
SG_ID=$(q describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  SG_ID=$(q create-security-group --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
    --description "Bastion SSH access for the Mac (iceberg demo #190)" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=owner,Value=steven.matison},{Key=project,Value=iceberg-rest-catalog-demo}]" \
    --query 'GroupId' --output text)
  echo "Created SG $SG_ID"
fi
# Revoke any stale SSH rules, then add the current Mac IP (keeps the rule set to one /32).
for CIDR in $(q describe-security-groups --group-ids "$SG_ID" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp' --output text); do
  [[ "$CIDR" == "$MYIP/32" ]] && continue
  q revoke-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$CIDR" >/dev/null 2>&1 || true
done
q authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MYIP/32" \
  >/dev/null 2>&1 || true
echo "SG $SG_ID — SSH/22 open to $MYIP/32 only"

# --- reuse-or-launch ---
IID=$(find_instance)
if [[ -n "$IID" ]]; then
  STATE=$(q describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].State.Name' --output text)
  echo "Reusing existing bastion $IID (state=$STATE)"
  if [[ "$STATE" == "stopped" ]]; then q start-instances --instance-ids "$IID" >/dev/null; fi
else
  AMI_ID=$(aws ssm get-parameters --names "$AMI_SSM_PARAM" --query 'Parameters[0].Value' --output text)
  ENDDATE=$(q describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].Tags[?Key==`enddate`].Value|[0]' --output text)
  echo "Launching new bastion: AMI=$AMI_ID type=$INSTANCE_TYPE enddate=$ENDDATE"
  IID=$(q run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=owner,Value=steven.matison},{Key=project,Value=iceberg-rest-catalog-demo},{Key=enddate,Value=$ENDDATE}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "Launched $IID"
fi

echo "Waiting for running + public IP ..."
q wait instance-running --instance-ids "$IID"
PUB=$(q describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo
echo "================ BASTION READY ================"
echo "  instance : $IID"
echo "  public IP: $PUB"
echo "  SSH      : ssh -i ../../cdp-tf-quickstarts/aws/srm-iceberg-ssh-key.pem ec2-user@$PUB"
echo "  next     : ./bastion-connect.sh $PUB"
echo "==============================================="
