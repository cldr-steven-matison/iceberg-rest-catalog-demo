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
echo "client_id + client_secret updated on $CTX_NAME."

# --- Ensure KnoxOAuth2 references the parameters (not a stale literal clientId) ---
# Incident (2026-08-17, #162): the KnoxOAuth2 CS had its Client ID hardcoded to a dead clientId
# (baked in when the flow was originally imported), so the Parameter Context update above had NO
# effect and the flow 401'd at runtime ("OAuth2 access token request failed [HTTP 401]") even
# though the fresh creds authenticate fine via a direct curl. This repair points the CS
# Client ID/secret at the params. Idempotent: only cycles the CS if it isn't already a ref.
OA=f820761c-019f-1000-0000-00003bc01d06   # KnoxOAuth2 (OAuth token provider)
RC=f79031bf-019f-1000-ffff-ffffc1e8f614   # CdpRestCatalog (references OA — disable this first)
CUR=$(curl -sk -H "$AUTH" "$B/controller-services/$OA" | j '.component.properties["Client ID"] // empty')
if [ "$CUR" != '#{client_id}' ]; then
  echo "KnoxOAuth2 Client ID is '$CUR' (not a param ref) — repairing to #{client_id}/#{client_secret}."
  setcs() { id="$1"; want="$2"; r=$(curl -sk -H "$AUTH" "$B/controller-services/$id" | j '.revision.version')
    curl -sk -H "$AUTH" -X PUT "$B/controller-services/$id/run-status" -H 'Content-Type: application/json' \
      -d "{\"revision\":{\"version\":$r},\"state\":\"$want\"}" >/dev/null
    i=0; while [ $i -lt 30 ]; do s=$(curl -sk -H "$AUTH" "$B/controller-services/$id" | j '.component.state'); [ "$s" = "$want" ] && break; sleep 1; i=$((i+1)); done; }
  setcs "$RC" DISABLED; setcs "$OA" DISABLED
  rev=$(curl -sk -H "$AUTH" "$B/controller-services/$OA" | j '.revision.version')
  # PUT ONLY the two props (never GET-then-PUT the blob — that writes the masked "********" back).
  curl -sk -H "$AUTH" -X PUT "$B/controller-services/$OA" -H 'Content-Type: application/json' \
    -d "{\"revision\":{\"version\":$rev},\"component\":{\"id\":\"$OA\",\"properties\":{\"Client ID\":\"#{client_id}\",\"Client secret\":\"#{client_secret}\"}}}" >/dev/null
  setcs "$OA" ENABLED; setcs "$RC" ENABLED
  echo "  repaired: Client ID -> $(curl -sk -H "$AUTH" "$B/controller-services/$OA" | j '.component.properties["Client ID"]')"
else
  echo "KnoxOAuth2 already references #{client_id} — no CS repair needed."
fi
echo "Now run refresh-oauth.sh to mint a fresh token."
echo "DONE"
