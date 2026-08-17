#!/usr/bin/env bash
# Read-only validation of the Iceberg REST Catalog: JWT exchange → namespaces →
# tables → table metadata (with IDBroker-vended S3 STS creds). Never modifies CDP.
set -euo pipefail
cd "$(dirname "$0")"

DL_HOST="srm-iceberg-aw-dl-gateway.srm-iceb.a465-9q4k.cloudera.site"
DL_NAME="srm-iceberg-aw-dl"
BASE="https://${DL_HOST}/${DL_NAME}/cdp-datashare-access"
DB="${1:-poc_uc2}"
TABLE="${2:-airlines}"

CLIENT_ID=$(jq -r '.clientId' credentials.json)
CLIENT_SECRET=$(jq -r '.secret' credentials.json)

echo "# Step 1 — exchange client creds for JWT"
JWT=$(curl -sk -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}" \
  "${BASE}/knoxtoken/api/v2/token" | jq -r '.access_token')
[ -n "$JWT" ] && [ "$JWT" != "null" ] && echo "  JWT acquired (len ${#JWT})" || { echo "  FAILED to get JWT"; exit 1; }

echo "# Step 2 — list namespaces"
curl -sk -H "Authorization: Bearer ${JWT}" "${BASE}/iceberg-rest/v1/namespaces"; echo

echo "# Step 3 — list tables in ${DB}"
curl -sk -H "Authorization: Bearer ${JWT}" "${BASE}/iceberg-rest/v1/namespaces/${DB}/tables"; echo

echo "# Step 4 — load table ${DB}.${TABLE} (vended-creds keys shown, secrets redacted)"
curl -sk -H "Authorization: Bearer ${JWT}" \
  "${BASE}/iceberg-rest/v1/namespaces/${DB}/tables/${TABLE}" \
  | jq '{metadata_location: .["metadata-location"],
         config_keys: (.config // {} | keys),
         has_vended_creds: (((.config // {})["s3.session-token"] // "") | length > 0),
         region: (.config // {})["client.region"]}'
