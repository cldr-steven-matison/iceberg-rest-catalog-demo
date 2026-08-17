#!/bin/sh
set -e
B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
PG=f79030ac-019f-1000-0000-000005ef9ce5
GI=f8dd6fd3-019f-1000-ffff-ffffdf9db183
j() { jq -r "$1"; }
T=$(curl -sk -X POST "$B/access/token" -d "username=admin&password=admin12345678"); AUTH="Authorization: Bearer $T"

FS=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/funnels" -H 'Content-Type: application/json' -d '{"revision":{"version":0},"component":{"position":{"x":900,"y":-100}}}' | j ".id")
FF=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/funnels" -H 'Content-Type: application/json' -d '{"revision":{"version":0},"component":{"position":{"x":900,"y":200}}}' | j ".id")
mkconn() { curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/connections" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":0},\"component\":{\"source\":{\"id\":\"$GI\",\"groupId\":\"$PG\",\"type\":\"PROCESSOR\"},\"destination\":{\"id\":\"$1\",\"groupId\":\"$PG\",\"type\":\"FUNNEL\"},\"selectedRelationships\":[\"$2\"]}}" | j ".id"; }
CS=$(mkconn "$FS" success); CF=$(mkconn "$FF" failure)
echo "FS=$FS CS=$CS FF=$FF CF=$CF"
sleep 2
echo "GI validation: $(curl -sk -H "$AUTH" "$B/processors/$GI" | j '.component.state + " vErrs=" + (.component.validationErrors|tostring)')"

echo "--- RUN_ONCE ---"
gr=$(curl -sk -H "$AUTH" "$B/processors/$GI" | j ".revision.version")
curl -sk -H "$AUTH" -X PUT "$B/processors/$GI/run-status" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":$gr},\"state\":\"RUN_ONCE\"}" >/dev/null

echo "--- wait for success flowfile ---"
i=0; q=0; while [ $i -lt 20 ]; do q=$(curl -sk -H "$AUTH" "$B/connections/$CS" | j ".status.aggregateSnapshot.flowFilesQueued"); [ "$q" -ge 1 ] 2>/dev/null && break; sleep 2; i=$((i+1)); done
echo "success_queued=$q  failure_queued=$(curl -sk -H "$AUTH" "$B/connections/$CF" | j '.status.aggregateSnapshot.flowFilesQueued')"

if [ "$q" -ge 1 ] 2>/dev/null; then
  LR=$(curl -sk -H "$AUTH" -X POST "$B/flowfile-queues/$CS/listing-requests" | j ".listingRequest.id")
  i=0; while [ $i -lt 15 ]; do fin=$(curl -sk -H "$AUTH" "$B/flowfile-queues/$CS/listing-requests/$LR" | j ".listingRequest.finished"); [ "$fin" = "true" ] && break; sleep 1; i=$((i+1)); done
  UUID=$(curl -sk -H "$AUTH" "$B/flowfile-queues/$CS/listing-requests/$LR" | j ".listingRequest.flowFileSummaries[0].uuid")
  echo "record.count=$(curl -sk -H "$AUTH" "$B/flowfile-queues/$CS/flowfiles/$UUID" | j '.flowFile.attributes["record.count"]')"
  echo "namespace=$(curl -sk -H "$AUTH" "$B/flowfile-queues/$CS/flowfiles/$UUID" | j '.flowFile.attributes["iceberg.catalog.namespace"]') table=$(curl -sk -H "$AUTH" "$B/flowfile-queues/$CS/flowfiles/$UUID" | j '.flowFile.attributes["iceberg.table.name"]')"
  echo "--- content ---"; curl -sk -H "$AUTH" "$B/flowfile-queues/$CS/flowfiles/$UUID/content"; echo
  curl -sk -H "$AUTH" -X DELETE "$B/flowfile-queues/$CS/listing-requests/$LR" >/dev/null 2>&1 || true
fi
echo "DONE FS=$FS FF=$FF CS=$CS CF=$CF"
