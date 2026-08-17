#!/bin/sh
# Iceberg REST Catalog *query* flow in PG $1 on mynifi. Runs inside the nifi-client pod.
# GenerateFlowFile(trigger) -> InvokeHTTP(GET namespaces, Bearer via StandardOauth2AccessTokenProvider).
set -e
B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
C="--cert /tmp/client.crt --key /tmp/client.key"
PG="$1"; CID="$2"; SECRET="$3"; GW="$4"; DL="$5"
TOKEN_URL="https://$GW/$DL/cdp-datashare-access/knoxtoken/api/v2/token"
NS_URL="https://$GW/$DL/cdp-datashare-access/iceberg-rest/v1/namespaces"
j() { jq -r "$1"; }

# 1. Parameter Context (client_secret sensitive)
PC=$(curl -sk $C -X POST "$B/parameter-contexts" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":0},\"component\":{\"name\":\"iceberg-demo-params\",\"parameters\":[{\"parameter\":{\"name\":\"client_id\",\"sensitive\":false,\"value\":\"$CID\"}},{\"parameter\":{\"name\":\"client_secret\",\"sensitive\":true,\"value\":\"$SECRET\"}}]}}" | j ".id")
echo "PC=$PC"
PGREV=$(curl -sk $C "$B/process-groups/$PG" | j ".revision.version")
curl -sk $C -X PUT "$B/process-groups/$PG" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":$PGREV},\"component\":{\"id\":\"$PG\",\"parameterContext\":{\"id\":\"$PC\"}}}" >/dev/null

# 2. OAuth2 provider CS (Knox client_credentials; secret in request body)
OA=$(curl -sk $C -X POST "$B/process-groups/$PG/controller-services" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":0},\"component\":{\"type\":\"org.apache.nifi.oauth2.StandardOauth2AccessTokenProvider\",\"name\":\"KnoxOAuth\",\"properties\":{\"Authorization Server URL\":\"$TOKEN_URL\",\"Grant Type\":\"client_credentials\",\"Client Authentication Strategy\":\"Request Body\",\"Client ID\":\"#{client_id}\",\"Client secret\":\"#{client_secret}\"}}}" | j ".component.id")
echo "OA=$OA"
# enable + poll
OAREV=$(curl -sk $C "$B/controller-services/$OA" | j ".revision.version")
curl -sk $C -X PUT "$B/controller-services/$OA/run-status" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":$OAREV},\"state\":\"ENABLED\"}" >/dev/null
i=0; while [ $i -lt 20 ]; do S=$(curl -sk $C "$B/controller-services/$OA" | j ".component.state"); [ "$S" = ENABLED ] && break; sleep 2; i=$((i+1)); done
echo "OAuth CS state=$S"

mkproc() {
  curl -sk $C -X POST "$B/process-groups/$PG/processors" -H 'Content-Type: application/json' \
   -d "{\"revision\":{\"version\":0},\"component\":{\"type\":\"$1\",\"name\":\"$2\",\"position\":{\"x\":$3,\"y\":$4},\"config\":{\"properties\":$5,\"autoTerminatedRelationships\":$6,\"schedulingPeriod\":\"3600 sec\"}}}" | j ".id"
}
GEN=$(mkproc "org.apache.nifi.processors.standard.GenerateFlowFile" "Trigger" 0 0 "{\"File Size\":\"0B\",\"Batch Size\":\"1\"}" "[]")
echo "GEN=$GEN"
IH=$(mkproc "org.apache.nifi.processors.standard.InvokeHTTP" "ListNamespaces" 0 250 \
  "{\"HTTP Method\":\"GET\",\"HTTP URL\":\"$NS_URL\",\"Request OAuth2 Access Token Provider\":\"$OA\"}" \
  "[\"Original\",\"Failure\",\"Retry\",\"No Retry\"]")
echo "IH=$IH"
curl -sk $C -X POST "$B/process-groups/$PG/connections" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":0},\"component\":{\"source\":{\"id\":\"$GEN\",\"groupId\":\"$PG\",\"type\":\"PROCESSOR\"},\"destination\":{\"id\":\"$IH\",\"groupId\":\"$PG\",\"type\":\"PROCESSOR\"},\"selectedRelationships\":[\"success\"]}}" >/dev/null
echo "DONE PC=$PC OA=$OA GEN=$GEN IH=$IH"
