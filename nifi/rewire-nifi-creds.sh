#!/bin/sh
# Push fresh Knox external-user creds into the Parameter Context bound to the surviving
# NiFi flow (PG IcebergRESTCatalogDemo), after a weekly sandbox rebuild mints a new
# clientId/secret. Run INSIDE the nifi-client helper pod (in-cluster FQDN + single-user bearer).
#
#   sh rewire-nifi-creds.sh <clientId> <clientSecret>
#
# Updates only the client_id (non-sensitive) and client_secret (sensitive) parameters by NAME
# via the async update-request API — a targeted set of a known value, NOT a GET-then-PUT of a
# masked "********" (skill rule: never write a masked secret back). After this, cycle the OAuth
# provider with refresh-oauth.sh so a token is minted against the new sandbox.
set -e
CID="$1"; SEC="$2"
[ -n "$CID" ] && [ -n "$SEC" ] || { echo "usage: sh rewire-nifi-creds.sh <clientId> <clientSecret>"; exit 2; }

B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
PG=f79030ac-019f-1000-0000-000005ef9ce5   # IcebergRESTCatalogDemo (surviving flow)
j() { jq -r "$1"; }

T=$(curl -sk -X POST "$B/access/token" -d "username=admin&password=admin12345678")
AUTH="Authorization: Bearer $T"

# Resolve the Parameter Context bound to the live PG.
CTX=$(curl -sk -H "$AUTH" "$B/process-groups/$PG" | j '.component.parameterContext.id // empty')
[ -n "$CTX" ] || { echo "No Parameter Context bound to PG $PG — nothing to re-wire."; exit 1; }
CTX_NAME=$(curl -sk -H "$AUTH" "$B/parameter-contexts/$CTX" | j '.component.name')
REV=$(curl -sk -H "$AUTH" "$B/parameter-contexts/$CTX" | j '.revision.version')
echo "Parameter Context: $CTX_NAME ($CTX) rev=$REV"

# Build the update-request body (merge-by-name: only these two params change).
BODY=$(jq -n --arg ctx "$CTX" --argjson rev "$REV" --arg cid "$CID" --arg sec "$SEC" '{
  revision:{version:$rev},
  id:$ctx,
  component:{
    id:$ctx,
    parameters:[
      {parameter:{name:"client_id",     sensitive:false, value:$cid}},
      {parameter:{name:"client_secret", sensitive:true,  value:$sec}}
    ]
  }
}')

REQ=$(curl -sk -H "$AUTH" -X POST "$B/parameter-contexts/$CTX/update-requests" \
  -H 'Content-Type: application/json' -d "$BODY" | j '.request.requestId')
[ -n "$REQ" ] && [ "$REQ" != null ] || { echo "update-request not accepted (check creds/param names)."; exit 1; }

# Poll to completion.
i=0
while [ $i -lt 30 ]; do
  DONE=$(curl -sk -H "$AUTH" "$B/parameter-contexts/$CTX/update-requests/$REQ" | j '.request.complete')
  [ "$DONE" = true ] && break
  sleep 1; i=$((i+1))
done
FAIL=$(curl -sk -H "$AUTH" "$B/parameter-contexts/$CTX/update-requests/$REQ" | j '.request.failureReason // empty')
# Clean up the request resource.
curl -sk -H "$AUTH" -X DELETE "$B/parameter-contexts/$CTX/update-requests/$REQ" >/dev/null 2>&1 || true

[ -z "$FAIL" ] || { echo "Parameter Context update FAILED: $FAIL"; exit 1; }
echo "client_id + client_secret updated on $CTX_NAME. Now run refresh-oauth.sh to mint a fresh token."
echo "DONE"
