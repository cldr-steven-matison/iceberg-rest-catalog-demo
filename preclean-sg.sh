#!/usr/bin/env bash
# Pre-flight SG reconcile — run ONCE before redeploy.sh (before `terraform apply`).
#
# The VPC survives the Friday reaper, so its security groups keep two classes of junk that
# make `terraform apply` fail with InvalidPermission.Duplicate on the knox/default SGs:
#   1. stale personal /32 ingress rules from a PRIOR session's public IP (your IP rotates), and
#   2. a CDP-created admin :443 ingress rule with NO description — CDP adds your admin IP to the
#      knox SG on env creation, and it collides with terraform's own managed extra-CIDR rule.
#
# This revokes exactly those two classes on srm-iceberg-knox-sg + srm-iceberg-default-sg so
# terraform recreates the managed rules cleanly for your CURRENT IP. It preserves the self-ingress,
# the inter-VPC /16 rule, and the current-IP managed extra rules. Idempotent: revokes nothing if
# the SGs are already clean.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-cldr-se}"
REGION="${AWS_REGION:-us-east-2}"
MYIP="$(curl -s https://checkip.amazonaws.com)/32"
echo "== preclean-sg: current public IP = $MYIP =="

for NAME in srm-iceberg-knox-sg srm-iceberg-default-sg; do
  SG=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=tag:Name,Values=$NAME" \
        --query 'SecurityGroups[0].GroupId' --output text)
  [ "$SG" = "None" ] && { echo "  $NAME: not found, skip"; continue; }
  echo "  $NAME ($SG):"
  # revoke: any /32 CIDR that isn't the current IP (stale), OR a no-description :443 /32 (CDP orphan)
  aws ec2 describe-security-group-rules --region "$REGION" \
      --filters "Name=group-id,Values=$SG" \
      --query 'SecurityGroupRules[?!IsEgress]' --output json \
  | jq -r --arg ip "$MYIP" '.[]
      | select(
          ((.CidrIpv4 // "" | endswith("/32")) and (.CidrIpv4 != $ip))
          or ((.Description // "" | length == 0) and .FromPort == 443 and (.CidrIpv4 // "" | endswith("/32")))
        )
      | .SecurityGroupRuleId' \
  | while read -r RID; do
      [ -n "$RID" ] || continue
      echo "    revoke $RID"
      aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$SG" --security-group-rule-ids "$RID" >/dev/null
    done
done
echo "== preclean-sg: done =="
