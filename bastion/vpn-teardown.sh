#!/usr/bin/env bash
# vpn-teardown.sh — delete the dead Client VPN endpoint + its ACM certs (stops the billing).
# The Client VPN approach failed: the private NLB has no return route to the VPN client CIDR
# (10.20.x), so connections time out. The bastion replaces it. Local vpn/*.crt|*.key are left
# in place (harmless, cheap) in case the endpoint is ever rebuilt.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-cldr-se}"
export AWS_REGION="${AWS_REGION:-us-east-2}"

VPN_ID="cvpn-endpoint-0f7b1e940c5c8fe48"

echo "== disassociating target networks =="
for A in $(aws ec2 describe-client-vpn-target-networks --client-vpn-endpoint-id "$VPN_ID" \
    --query 'ClientVpnTargetNetworks[].AssociationId' --output text 2>/dev/null); do
  echo "  disassociate $A"
  aws ec2 disassociate-client-vpn-target-network --client-vpn-endpoint-id "$VPN_ID" --association-id "$A" >/dev/null
done

echo "== waiting for associations to clear (up to ~5 min) =="
for i in $(seq 1 30); do
  N=$(aws ec2 describe-client-vpn-target-networks --client-vpn-endpoint-id "$VPN_ID" \
        --query 'length(ClientVpnTargetNetworks)' --output text 2>/dev/null || echo 0)
  [[ "$N" == "0" ]] && break
  sleep 10
done

echo "== deleting VPN endpoint =="
aws ec2 delete-client-vpn-endpoint --client-vpn-endpoint-id "$VPN_ID" >/dev/null && echo "  deleted $VPN_ID"

echo "== deleting the two ACM certs imported for the VPN =="
for ARN in $(aws acm list-certificates \
    --query "CertificateSummaryList[?contains(DomainName,'srm-iceberg-vpn')].CertificateArn" --output text); do
  echo "  delete $ARN"
  aws acm delete-certificate --certificate-arn "$ARN" >/dev/null 2>&1 \
    || echo "    (in use / already gone — skipped)"
done

echo "Done. Verify: aws ec2 describe-client-vpn-endpoints --query 'ClientVpnEndpoints[].ClientVpnEndpointId'"
