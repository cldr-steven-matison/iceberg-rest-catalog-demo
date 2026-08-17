#!/bin/sh
# RUN_ONCE the QueryIceberg processor (#156) and read back per-relationship proof attributes
# + content. Reads /tmp/qi-id.txt and /tmp/qi-conns.txt written by build-query-iceberg.sh.
# Run from inside the nifi-client pod.
set -e
B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
QI=$(cut -d= -f2 /tmp/qi-id.txt)
j() { jq -r "$1"; }
T=$(curl -sk -X POST "$B/access/token" -d "username=admin&password=admin12345678"); AUTH="Authorization: Bearer $T"

echo "=== RUN_ONCE QueryIceberg $QI ==="
r=$(curl -sk -H "$AUTH" "$B/processors/$QI" | j ".revision.version")
curl -sk -H "$AUTH" -X PUT "$B/processors/$QI/run-status" -H 'Content-Type: application/json' \
  -d "{\"revision\":{\"version\":$r},\"state\":\"RUN_ONCE\"}" >/dev/null

# wait until at least one queue has a flowfile
sleep 4
attr() { curl -sk -H "$AUTH" "$B/flowfile-queues/$1/flowfiles/$2?clusterNodeId=$3" | j ".flowFile.attributes[\"$4\"]"; }

while read REL CONN; do
  echo ""
  echo "########## relationship=$REL (conn=$CONN) ##########"
  # wait for the queue
  i=0; q=0
  while [ $i -lt 15 ]; do
    q=$(curl -sk -H "$AUTH" "$B/connections/$CONN" | j ".status.aggregateSnapshot.flowFilesQueued")
    [ "$q" -ge 1 ] 2>/dev/null && break; sleep 2; i=$((i+1))
  done
  echo "flowFilesQueued=$q"
  [ "$q" -ge 1 ] 2>/dev/null || { echo "(no flowfile)"; continue; }
  LR=$(curl -sk -H "$AUTH" -X POST "$B/flowfile-queues/$CONN/listing-requests" | j ".listingRequest.id")
  i=0; while [ $i -lt 15 ]; do fin=$(curl -sk -H "$AUTH" "$B/flowfile-queues/$CONN/listing-requests/$LR" | j ".listingRequest.finished"); [ "$fin" = "true" ] && break; sleep 1; i=$((i+1)); done
  SUMMARY=$(curl -sk -H "$AUTH" "$B/flowfile-queues/$CONN/listing-requests/$LR")
  U=$(echo "$SUMMARY" | j ".listingRequest.flowFileSummaries[0].uuid")
  CN=$(echo "$SUMMARY" | j ".listingRequest.flowFileSummaries[0].clusterNodeId // empty")
  echo "  QueryIceberg.query          = $(attr $CONN $U $CN 'QueryIceberg.query')"
  echo "  record.count                = $(attr $CONN $U $CN 'record.count')"
  echo "  iceberg.table.name          = $(attr $CONN $U $CN 'iceberg.table.name')"
  echo "  iceberg.pushdown.filter     = $(attr $CONN $U $CN 'iceberg.pushdown.filter')"
  echo "  iceberg.pushdown.columns    = $(attr $CONN $U $CN 'iceberg.pushdown.columns')"
  echo "  iceberg.scan.result.data.files      = $(attr $CONN $U $CN 'iceberg.scan.result.data.files')"
  echo "  iceberg.scan.skipped.data.files     = $(attr $CONN $U $CN 'iceberg.scan.skipped.data.files')"
  echo "  iceberg.scan.skipped.data.manifests = $(attr $CONN $U $CN 'iceberg.scan.skipped.data.manifests')"
  echo "  --- content ---"
  curl -sk -H "$AUTH" "$B/flowfile-queues/$CONN/flowfiles/$U/content?clusterNodeId=$CN"; echo
  curl -sk -H "$AUTH" -X DELETE "$B/flowfile-queues/$CONN/listing-requests/$LR" >/dev/null 2>&1 || true
done < /tmp/qi-conns.txt
echo ""
echo "=== DONE ==="
