#!/bin/sh
# Force KnoxOAuth2 to mint a fresh token by disable->enable cycling it and its referencing
# RESTCatalogService. Knox purged the cached token (sandbox restart -> 401 "Unknown token").
# State-only /run-status calls (safe for the sensitive Client secret). Processors are STOPPED.
set -e
B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
RC=f79031bf-019f-1000-ffff-ffffc1e8f614   # CdpRestCatalog (RESTCatalogService)
OA=f820761c-019f-1000-0000-00003bc01d06   # KnoxOAuth2 (OAuth token provider)
j() { jq -r "$1"; }
T=$(curl -sk -X POST "$B/access/token" -d "username=admin&password=admin12345678"); AUTH="Authorization: Bearer $T"

setcs() { # id state
  local id="$1" want="$2"
  local r=$(curl -sk -H "$AUTH" "$B/controller-services/$id" | j ".revision.version")
  curl -sk -H "$AUTH" -X PUT "$B/controller-services/$id/run-status" -H 'Content-Type: application/json' \
    -d "{\"revision\":{\"version\":$r},\"state\":\"$want\"}" >/dev/null
  local i=0 s=""
  while [ $i -lt 30 ]; do s=$(curl -sk -H "$AUTH" "$B/controller-services/$id" | j ".component.state"); [ "$s" = "$want" ] && break; sleep 1; i=$((i+1)); done
  echo "  $id -> $s"
}

echo "=== disable CdpRestCatalog, then KnoxOAuth2 ==="
setcs "$RC" DISABLED
setcs "$OA" DISABLED
echo "=== enable KnoxOAuth2 (fresh token), then CdpRestCatalog ==="
setcs "$OA" ENABLED
setcs "$RC" ENABLED
echo "=== final validation ==="
echo "  KnoxOAuth2:    $(curl -sk -H "$AUTH" "$B/controller-services/$OA" | j '.component.state + " / " + .component.validationStatus')"
echo "  CdpRestCatalog:$(curl -sk -H "$AUTH" "$B/controller-services/$RC" | j '.component.state + " / " + .component.validationStatus')"
echo "DONE"
