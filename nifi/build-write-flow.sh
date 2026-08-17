#!/bin/sh
# Native Iceberg write flow in PG $1: RESTCatalogService + PutIceberg (+ JsonTreeReader).
# Reuses the already-enabled StandardOauth2AccessTokenProvider ($OA). Runs in the nifi-client pod.
set -e
B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
C="--cert /tmp/client.crt --key /tmp/client.key"
PG="$1"; OA="$2"; GW="$3"; DL="$4"
REST_URI="https://$GW/$DL/cdp-datashare-access/iceberg-rest"
j() { jq -r "$1"; }

# RESTCatalogService (native Cloudera CS) -> our REST catalog, auth via the OAuth2 provider
RC=$(curl -sk $C -X POST "$B/process-groups/$PG/controller-services" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":0},\"component\":{\"type\":\"com.cloudera.nifi.services.iceberg.RESTCatalogService\",\"name\":\"CdpRestCatalog\",\"properties\":{\"Catalog URI\":\"$REST_URI\",\"OAuth2 Access Token Provider\":\"$OA\"}}}" | j ".component.id")
echo "RC=$RC"

# JsonTreeReader (infer schema)
JR=$(curl -sk $C -X POST "$B/process-groups/$PG/controller-services" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":0},\"component\":{\"type\":\"org.apache.nifi.json.JsonTreeReader\",\"name\":\"JsonReader\",\"properties\":{\"Schema Access Strategy\":\"infer-schema\"}}}" | j ".component.id")
echo "JR=$JR"

# enable both CS
for cs in "$RC" "$JR"; do
  r=$(curl -sk $C "$B/controller-services/$cs" | j ".revision.version")
  curl -sk $C -X PUT "$B/controller-services/$cs/run-status" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":$r},\"state\":\"ENABLED\"}" >/dev/null
done
for cs in "$RC" "$JR"; do
  i=0; while [ $i -lt 20 ]; do s=$(curl -sk $C "$B/controller-services/$cs" | j ".component.state"); { [ "$s" = ENABLED ] || [ "$s" = INVALID ]; } && break; sleep 2; i=$((i+1)); done
  echo "CS $cs state=$s vs=$(curl -sk $C "$B/controller-services/$cs" | j ".component.validationStatus") errs=$(curl -sk $C "$B/controller-services/$cs" | j ".component.validationErrors")"
done

mkproc() { curl -sk $C -X POST "$B/process-groups/$PG/processors" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":0},\"component\":{\"type\":\"$1\",\"name\":\"$2\",\"position\":{\"x\":$3,\"y\":$4},\"config\":{\"properties\":$5,\"autoTerminatedRelationships\":$6,\"schedulingPeriod\":\"3600 sec\"}}}" | j ".id"; }

# GenerateFlowFile with one JSON row matching poc_uc2.nifi_sink (id,msg,source)
GEN=$(mkproc "org.apache.nifi.processors.standard.GenerateFlowFile" "GenIcebergRow" 500 0 \
  "{\"File Size\":\"0B\",\"Batch Size\":\"1\",\"Custom Text\":\"{\\\"id\\\":1,\\\"msg\\\":\\\"hello from nifi\\\",\\\"source\\\":\\\"PutIceberg\\\"}\"}" "[]")
echo "GEN=$GEN"

# PutIceberg -> poc_uc2.nifi_sink via the native REST catalog CS
PUT=$(mkproc "org.apache.nifi.processors.iceberg.PutIceberg" "PutIceberg" 500 250 \
  "{\"catalog-service\":\"$RC\",\"catalog-namespace\":\"poc_uc2\",\"table-name\":\"nifi_sink\",\"record-reader\":\"$JR\",\"file-format\":\"PARQUET\"}" \
  "[\"success\",\"failure\"]")
echo "PUT=$PUT"

curl -sk $C -X POST "$B/process-groups/$PG/connections" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":0},\"component\":{\"source\":{\"id\":\"$GEN\",\"groupId\":\"$PG\",\"type\":\"PROCESSOR\"},\"destination\":{\"id\":\"$PUT\",\"groupId\":\"$PG\",\"type\":\"PROCESSOR\"},\"selectedRelationships\":[\"success\"]}}" >/dev/null
echo "DONE RC=$RC JR=$JR GEN=$GEN PUT=$PUT"
