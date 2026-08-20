#!/usr/bin/env bash
# bastion-connect.sh — open an SSH dynamic SOCKS proxy through the bastion.
# The browser (configured for SOCKS5 + remote DNS) then reaches the private-subnet Trino Web UI /
# Hue at their real *.cloudera.site hostnames, so TLS/SNI and Knox redirects work unchanged.
#
# Usage:  ./bastion-connect.sh [BASTION_PUBLIC_IP]   # IP optional; auto-discovered by tag if omitted
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-cldr-se}"
export AWS_REGION="${AWS_REGION:-us-east-2}"

SOCKS_PORT="${SOCKS_PORT:-1080}"
PEM="$(cd "$(dirname "$0")" && pwd)/../../cdp-tf-quickstarts/aws/srm-iceberg-ssh-key.pem"

PUB="${1:-}"
if [[ -z "$PUB" ]]; then
  PUB=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=srm-iceberg-bastion" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
fi
[[ -z "$PUB" || "$PUB" == "None" ]] && { echo "ERROR: no running bastion found (run ./bastion-up.sh first)"; exit 1; }

cat <<EOF

Opening SOCKS5 proxy 127.0.0.1:$SOCKS_PORT via bastion $PUB ...

Point your browser at the proxy (leave this window running):
  - Firefox: Settings > Network > Manual proxy > SOCKS Host 127.0.0.1  Port $SOCKS_PORT  (SOCKS v5)
             about:config -> network.proxy.socks_remote_dns = true      <-- REQUIRED (resolve DNS via bastion)
  - FoxyProxy: SOCKS5, host 127.0.0.1, port $SOCKS_PORT, "Send DNS through proxy" ON
  - Chrome (whole browser): open with
        /Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome \\
          --user-data-dir=/tmp/bastion-chrome --proxy-server="socks5://127.0.0.1:$SOCKS_PORT"

Then browse:
  Trino UI : https://srm-trino-vw.dw-srm-iceberg-cdp-env.a465-9q4k.cloudera.site/ui/
  Hue      : https://hue-srm-trino-vw.dw-srm-iceberg-cdp-env.a465-9q4k.cloudera.site/

Ctrl-C here closes the tunnel.
EOF

exec ssh -i "$PEM" -D "$SOCKS_PORT" -N \
  -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 \
  "ec2-user@$PUB"
