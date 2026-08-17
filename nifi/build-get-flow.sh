#!/bin/sh
# GetIceberg (custom native read processor, #154) demo flow on the iceberg-lab profile.
# Built via the single-user BEARER token over the minikube tunnel (no mTLS cert).
#   Param Context -> StandardOauth2AccessTokenProvider (Knox) -> RESTCatalogService
#                 -> GetIceberg(poc_uc2.airlines) -> JsonRecordSetWriter -> funnel.
# Creds sourced from credentials-nifi.json (iceberg-consumer-nifi, id14). Nothing secret is echoed.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)                 # iceberg-rest-catalog-demo/
CREDS="$HERE/credentials-nifi.json"
CID=$(python3 -c "import json;print(json.load(open('$CREDS'))['clientId'])")
SECRET=$(python3 -c "import json;print(json.load(open('$CREDS'))['secret'])")
GW=srm-iceberg-aw-dl-gateway.srm-iceb.a465-9q4k.cloudera.site
DL=srm-iceberg-aw-dl
NS=poc_uc2
TBL=airlines

B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
TOKEN_URL="https://$GW/$DL/cdp-datashare-access/knoxtoken/api/v2/token"
REST_URI="https://$GW/$DL/cdp-datashare-access/iceberg-rest"
j() { jq -r "$1"; }

T=$(curl -sk -X POST "$B/access/token" -d "username=admin&password=admin12345678")
AUTH="Authorization: Bearer $T"

ROOT=$(curl -sk -H "$AUTH" "$B/flow/process-groups/root" | j ".processGroupFlow.id")
echo "ROOT=$ROOT"

PG=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$ROOT/process-groups" -H 'Content-Type: application/json' \
  -d '{"revision":{"version":0},"component":{"name":"GetIcebergDemo","position":{"x":0,"y":0}}}' | j ".id")
echo "PG=$PG"

PC=$(curl -sk -H "$AUTH" -X POST "$B/parameter-contexts" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":0},\"component\":{\"name\":\"geticeberg-params\",\"parameters\":[{\"parameter\":{\"name\":\"client_id\",\"sensitive\":false,\"value\":\"$CID\"}},{\"parameter\":{\"name\":\"client_secret\",\"sensitive\":true,\"value\":\"$SECRET\"}}]}}" | j ".id")
echo "PC=$PC"
PGREV=$(curl -sk -H "$AUTH" "$B/process-groups/$PG" | j ".revision.version")
curl -sk -H "$AUTH" -X PUT "$B/process-groups/$PG" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":$PGREV},\"component\":{\"id\":\"$PG\",\"parameterContext\":{\"id\":\"$PC\"}}}" >/dev/null

# OAuth2 provider (Knox client_credentials, secret in request body)
OA=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/controller-services" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":0},\"component\":{\"type\":\"org.apache.nifi.oauth2.StandardOauth2AccessTokenProvider\",\"name\":\"KnoxOAuth\",\"properties\":{\"Authorization Server URL\":\"$TOKEN_URL\",\"Grant Type\":\"client_credentials\",\"Client Authentication Strategy\":\"Request Body\",\"Client ID\":\"#{client_id}\",\"Client secret\":\"#{client_secret}\"}}}" | j ".component.id")
echo "OA=$OA"

# RESTCatalogService (native Cloudera CS) - Catalog URI + OAuth2 provider (no warehouse, per #152)
RC=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/controller-services" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":0},\"component\":{\"type\":\"com.cloudera.nifi.services.iceberg.RESTCatalogService\",\"name\":\"CdpRestCatalog\",\"properties\":{\"Catalog URI\":\"$REST_URI\",\"OAuth2 Access Token Provider\":\"$OA\"}}}" | j ".component.id")
echo "RC=$RC"

# JsonRecordSetWriter
JR=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/controller-services" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":0},\"component\":{\"type\":\"org.apache.nifi.json.JsonRecordSetWriter\",\"name\":\"JsonWriter\",\"properties\":{}}}" | j ".component.id")
echo "JR=$JR"

# Enable CS in dependency order: OAuth -> (REST, JSON)
enable() {
  cs=$1
  r=$(curl -sk -H "$AUTH" "$B/controller-services/$cs" | j ".revision.version")
  curl -sk -H "$AUTH" -X PUT "$B/controller-services/$cs/run-status" -H 'Content-Type: application/json' \
    -d "{\"revision\":{\"version\":$r},\"state\":\"ENABLED\"}" >/dev/null
  i=0; while [ $i -lt 25 ]; do s=$(curl -sk -H "$AUTH" "$B/controller-services/$cs" | j ".component.state"); { [ "$s" = ENABLED ] || [ "$s" = INVALID ]; } && break; sleep 2; i=$((i+1)); done
  echo "CS $cs name=$(curl -sk -H "$AUTH" "$B/controller-services/$cs" | j '.component.name') state=$s vErrs=$(curl -sk -H "$AUTH" "$B/controller-services/$cs" | j '.component.validationErrors')"
}
enable "$OA"; enable "$RC"; enable "$JR"

# GetIceberg source processor
GI=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/processors" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":0},\"component\":{\"type\":\"org.apache.nifi.processors.iceberg.GetIceberg\",\"name\":\"GetIceberg\",\"position\":{\"x\":0,\"y\":0},\"config\":{\"properties\":{\"catalog-service\":\"$RC\",\"catalog-namespace\":\"$NS\",\"table-name\":\"$TBL\",\"record-writer\":\"$JR\"},\"schedulingPeriod\":\"3600 sec\"}}}" | j ".id")
echo "GI=$GI"

# funnel + connection GetIceberg success -> funnel
FN=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/funnels" -H 'Content-Type: application/json' \
  -d '{"revision":{"version":0},"component":{"position":{"x":0,"y":400}}}' | j ".id")
CN=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/connections" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":0},\"component\":{\"source\":{\"id\":\"$GI\",\"groupId\":\"$PG\",\"type\":\"PROCESSOR\"},\"destination\":{\"id\":\"$FN\",\"groupId\":\"$PG\",\"type\":\"FUNNEL\"},\"selectedRelationships\":[\"success\"]}}" | j ".id")
echo "GI=$GI FN=$FN CN=$CN"
echo "DONE PG=$PG PC=$PC OA=$OA RC=$RC JR=$JR GI=$GI CN=$CN"
