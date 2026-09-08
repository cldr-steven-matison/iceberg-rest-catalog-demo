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
# Runtime 7.3.2 (CM 7.13.2.10000+) moved vended creds out of top-level `.config` into the Iceberg
# REST `storage-credentials[]` array (per the evolved REST spec). Older runtimes returned them in
# `.config`. Merge both so this validates on either, and send the delegation header that unlocks
# the datashare S3 read creds. (Pre-2026-09 the header was optional; the storage-credentials shape
# is what silently broke the old `.config`-only check — see #268.)
curl -sk -H "Authorization: Bearer ${JWT}" \
  -H "X-Iceberg-Access-Delegation: vended-credentials" \
  "${BASE}/iceberg-rest/v1/namespaces/${DB}/tables/${TABLE}" \
  | jq '((.config // {}) + ((.["storage-credentials"][0].config) // {})) as $c
      | {metadata_location: .["metadata-location"],
         config_keys: ($c | keys),
         has_vended_creds: (($c["s3.session-token"] // "") | length > 0),
         region: $c["client.region"]}'
