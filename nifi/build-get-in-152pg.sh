#!/bin/sh
# Add GetIceberg (custom read processor, #154) into the existing IcebergNativeCatalogDemo PG,
# reusing the already-ENABLED CdpRestCatalog (RESTCatalogService -> KnoxOAuth2) from the #152
# PutIceberg eval. Adds only a JsonRecordSetWriter + funnels; PutIceberg/GenIcebergRow untouched.
set -e
B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
PG=f79030ac-019f-1000-0000-000005ef9ce5           # IcebergNativeCatalogDemo
RC=f79031bf-019f-1000-ffff-ffffc1e8f614           # CdpRestCatalog (ENABLED)
NS=poc_uc2; TBL=airlines
j() { jq -r "$1"; }
T=$(curl -sk -X POST "$B/access/token" -d "username=admin&password=admin12345678"); AUTH="Authorization: Bearer $T"

# JsonRecordSetWriter (defaults: inherit schema, JSON array)
JR=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/controller-services" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":0},\"component\":{\"type\":\"org.apache.nifi.json.JsonRecordSetWriter\",\"name\":\"GetIcebergJsonWriter\",\"properties\":{}}}" | j ".component.id")
echo "JR=$JR"
r=$(curl -sk -H "$AUTH" "$B/controller-services/$JR" | j ".revision.version")
curl -sk -H "$AUTH" -X PUT "$B/controller-services/$JR/run-status" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":$r},\"state\":\"ENABLED\"}" >/dev/null
i=0; while [ $i -lt 20 ]; do s=$(curl -sk -H "$AUTH" "$B/controller-services/$JR" | j ".component.state"); [ "$s" = ENABLED ] && break; sleep 1; i=$((i+1)); done
echo "JR state=$s"

# GetIceberg (bundle 1.0.2), referencing the existing CdpRestCatalog
GI=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/processors" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":0},\"component\":{\"type\":\"org.apache.nifi.processors.iceberg.GetIceberg\",\"bundle\":{\"group\":\"org.apache.nifi\",\"artifact\":\"nifi-geticeberg-nar\",\"version\":\"1.0.2-SNAPSHOT\"},\"name\":\"GetIceberg\",\"position\":{\"x\":600,\"y\":0},\"config\":{\"properties\":{\"catalog-service\":\"$RC\",\"catalog-namespace\":\"$NS\",\"table-name\":\"$TBL\",\"record-writer\":\"$JR\"},\"schedulingPeriod\":\"3600 sec\"}}}" | j ".id")
echo "GI=$GI"

# funnels for success + failure
FS=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/funnels" -H 'Content-Type: application/json' -d '{"revision":{"version":0},"component":{"position":{"x":900,"y":-100}}}' | j ".id")
FF=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/funnels" -H 'Content-Type: application/json' -d '{"revision":{"version":0},"component":{"position":{"x":900,"y":200}}}' | j ".id")
mkconn() { curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/connections" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":0},\"component\":{\"source\":{\"id\":\"$GI\",\"groupId\":\"$PG\",\"type\":\"PROCESSOR\"},\"destination\":{\"id\":\"$1\",\"groupId\":\"$PG\",\"type\":\"FUNNEL\"},\"selectedRelationships\":[\"$2\"]}}" | j ".id"; }
CS=$(mkconn "$FS" success); CF=$(mkconn "$FF" failure)
echo "FS=$FS CF(conn success)=$CS ; FF=$FF CF(conn failure)=$CF"

echo "GI validation: state=$(curl -sk -H "$AUTH" "$B/processors/$GI" | j '.component.state') vErrs=$(curl -sk -H "$AUTH" "$B/processors/$GI" | j '.component.validationErrors')"
echo "DONE PG=$PG GI=$GI JR=$JR SUCCESS_CONN=$CS FAILURE_CONN=$CF"
