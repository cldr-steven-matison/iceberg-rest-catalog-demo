#!/usr/bin/env bash
# Work stream B (#151) — read-only gate.
# Mints ONE workload Knox token (steven.matison) and probes for the authoritative
# (producer) Iceberg REST endpoint — distinct from cdp-datashare-access, which is
# read-only. Confirms the endpoint accepts a workload token and vends WRITE-capable
# creds. Never writes anything. Knox has a per-user token quota → mint once, reuse.
set -uo pipefail
cd "$(dirname "$0")/../.."   # -> demo root

GW="srm-iceberg-aw-dl-gateway.srm-iceb.a465-9q4k.cloudera.site"
DL="srm-iceberg-aw-dl"
USER="steven.matison"
PW="$(cat .workload.creds)"

echo "# Step 1 — mint ONE workload Knox token (cdp-proxy-token)"
TOKRESP=$(curl -sk -u "${USER}:${PW}" \
  "https://${GW}/${DL}/cdp-proxy-token/knoxtoken/api/v1/token" || true)
JWT=$(echo "$TOKRESP" | jq -r '.access_token // empty' 2>/dev/null)
if [ -z "$JWT" ]; then
  echo "  FAILED to mint token. Raw response (first 300 chars):"
  echo "  ${TOKRESP:0:300}"
  exit 1
fi
echo "  workload JWT acquired (len ${#JWT})"

echo "# Step 2 — probe candidate authoritative Iceberg REST endpoints (GET /v1/config)"
CANDIDATES=(
  "https://${GW}/${DL}/cdp-proxy-api/iceberg-rest"
  "https://${GW}/${DL}/cdp-proxy-api/hms-iceberg/iceberg-rest"
  "https://${GW}/${DL}/cdp-proxy-api/hive/iceberg-rest"
  "https://${GW}/${DL}/cdp-proxy/iceberg-rest"
  "https://${GW}/${DL}/cdp-proxy-api/hms/v1"
)
FOUND=""
for BASE in "${CANDIDATES[@]}"; do
  CODE=$(curl -sk -o /tmp/probe_body -w '%{http_code}' \
    -H "Authorization: Bearer ${JWT}" "${BASE}/v1/config" || echo "000")
  echo "  [$CODE] ${BASE}/v1/config"
  if [ "$CODE" = "200" ]; then
    echo "    -> body: $(head -c 300 /tmp/probe_body)"
    FOUND="$BASE"
    break
  fi
done

if [ -z "$FOUND" ]; then
  echo "# No candidate returned 200 for /v1/config. Need endpoint discovery via CM-API/Knox topologies."
  exit 2
fi

echo "# Step 3 — through ${FOUND}: list namespaces + load airlines, check WRITE creds"
curl -sk -H "Authorization: Bearer ${JWT}" "${FOUND}/v1/namespaces"; echo
curl -sk -H "Authorization: Bearer ${JWT}" \
  -H "X-Iceberg-Access-Delegation: vended-credentials" \
  "${FOUND}/v1/namespaces/poc_uc2/tables/airlines" \
  | jq '{metadata_location: .["metadata-location"],
         config_keys: (.config // {} | keys),
         has_vended_creds: (((.config // {})["s3.session-token"] // "") | length > 0),
         region: (.config // {})["client.region"]}'
echo "# authoritative endpoint = ${FOUND}"
