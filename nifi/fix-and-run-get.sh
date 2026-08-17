#!/bin/sh
# Fix the two CS validation errors on the GetIcebergDemo PG, enable in order,
# then RUN_ONCE the GetIceberg processor and report record.count + content.
set -e
B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
OA=f8bc2b10-019f-1000-ffff-fffffeb2c3f6
RC=f8bc3f10-019f-1000-0000-0000075f6031
GI=f8c0396d-019f-1000-ffff-ffffc764257b
CN=f8c06176-019f-1000-0000-000070ff7ab7
WAREHOUSE='s3a://srm-iceberg-buk-081550c7/data/warehouse/tablespace/external/hive/'
j() { jq -r "$1"; }
T=$(curl -sk -X POST "$B/access/token" -d "username=admin&password=admin12345678")
AUTH="Authorization: Bearer $T"

set_state() { # id state
  r=$(curl -sk -H "$AUTH" "$B/controller-services/$1" | j ".revision.version")
  curl -sk -H "$AUTH" -X PUT "$B/controller-services/$1/run-status" -H 'Content-Type: application/json' \
    -d "{\"revision\":{\"version\":$r},\"state\":\"$2\"}" >/dev/null
}
wait_state() { # id target
  i=0; while [ $i -lt 30 ]; do s=$(curl -sk -H "$AUTH" "$B/controller-services/$1" | j ".component.state"); [ "$s" = "$2" ] && break; sleep 2; i=$((i+1)); done; echo "$s"
}
set_props() { # id jsonprops
  r=$(curl -sk -H "$AUTH" "$B/controller-services/$1" | j ".revision.version")
  curl -sk -H "$AUTH" -X PUT "$B/controller-services/$1" -H 'Content-Type: application/json' \
    -d "{\"revision\":{\"version\":$r},\"component\":{\"id\":\"$1\",\"properties\":$2}}" >/dev/null
}

echo "--- disable OA + RC ---"
set_state "$RC" DISABLED >/dev/null 2>&1 || true; echo "RC=$(wait_state "$RC" DISABLED)"
set_state "$OA" DISABLED >/dev/null 2>&1 || true; echo "OA=$(wait_state "$OA" DISABLED)"

echo "--- fix props ---"
set_props "$OA" '{"Client Authentication Strategy":"REQUEST_BODY"}'
set_props "$RC" "{\"warehouse-path\":\"$WAREHOUSE\",\"Warehouse\":null}"

echo "--- enable OA then RC ---"
set_state "$OA" ENABLED; echo "OA=$(wait_state "$OA" ENABLED) vErrs=$(curl -sk -H "$AUTH" "$B/controller-services/$OA" | j '.component.validationErrors')"
set_state "$RC" ENABLED; echo "RC=$(wait_state "$RC" ENABLED) vErrs=$(curl -sk -H "$AUTH" "$B/controller-services/$RC" | j '.component.validationErrors')"

echo "--- GetIceberg validation ---"
sleep 2
echo "GI state=$(curl -sk -H "$AUTH" "$B/processors/$GI" | j '.component.state') vErrs=$(curl -sk -H "$AUTH" "$B/processors/$GI" | j '.component.validationErrors')"

echo "--- RUN_ONCE GetIceberg ---"
gr=$(curl -sk -H "$AUTH" "$B/processors/$GI" | j ".revision.version")
curl -sk -H "$AUTH" -X PUT "$B/processors/$GI/run-status" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":$gr},\"state\":\"RUN_ONCE\"}" >/dev/null

echo "--- wait for flowfile on success connection ---"
i=0; q=0; while [ $i -lt 20 ]; do q=$(curl -sk -H "$AUTH" "$B/connections/$CN" | j ".status.aggregateSnapshot.flowFilesQueued"); [ "$q" -ge 1 ] 2>/dev/null && break; sleep 2; i=$((i+1)); done
echo "queued=$q"

echo "--- read flowfile attributes + content ---"
LR=$(curl -sk -H "$AUTH" -X POST "$B/flowfile-queues/$CN/listing-requests" | j ".listingRequest.id")
i=0; while [ $i -lt 15 ]; do fin=$(curl -sk -H "$AUTH" "$B/flowfile-queues/$CN/listing-requests/$LR" | j ".listingRequest.finished"); [ "$fin" = "true" ] && break; sleep 1; i=$((i+1)); done
FF=$(curl -sk -H "$AUTH" "$B/flowfile-queues/$CN/listing-requests/$LR" | j ".listingRequest.flowFileSummaries[0].uuid")
echo "flowfile uuid=$FF"
echo "record.count=$(curl -sk -H "$AUTH" "$B/flowfile-queues/$CN/flowfiles/$FF" | j '.flowFile.attributes["record.count"]')"
echo "namespace=$(curl -sk -H "$AUTH" "$B/flowfile-queues/$CN/flowfiles/$FF" | j '.flowFile.attributes["iceberg.catalog.namespace"]') table=$(curl -sk -H "$AUTH" "$B/flowfile-queues/$CN/flowfiles/$FF" | j '.flowFile.attributes["iceberg.table.name"]')"
echo "--- content ---"
curl -sk -H "$AUTH" "$B/flowfile-queues/$CN/flowfiles/$FF/content"
echo
curl -sk -H "$AUTH" -X DELETE "$B/flowfile-queues/$CN/listing-requests/$LR" >/dev/null 2>&1 || true
