#!/bin/sh
# Remove the QueryIceberg processor + its connections + its funnels (clean slate for rebuild).
# Deletes ONLY components recorded in /tmp/qi-id.txt and /tmp/qi-conns.txt (GetIceberg untouched).
set -e
B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
QI=$(cut -d= -f2 /tmp/qi-id.txt)
j() { jq -r "$1"; }
T=$(curl -sk -X POST "$B/access/token" -d "username=admin&password=admin12345678"); AUTH="Authorization: Bearer $T"

# stop the processor first
r=$(curl -sk -H "$AUTH" "$B/processors/$QI" | j ".revision.version")
curl -sk -H "$AUTH" -X PUT "$B/processors/$QI/run-status" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":$r},\"state\":\"STOPPED\"}" >/dev/null 2>&1 || true
sleep 1

: > /tmp/qi-funnels.txt
while read REL CONN; do
  # capture destination funnel id, then delete the connection
  FN=$(curl -sk -H "$AUTH" "$B/connections/$CONN" | j ".component.destination.id")
  echo "$FN" >> /tmp/qi-funnels.txt
  v=$(curl -sk -H "$AUTH" "$B/connections/$CONN" | j ".revision.version")
  curl -sk -H "$AUTH" -X DELETE "$B/connections/$CONN?version=$v" >/dev/null 2>&1 || true
  echo "deleted conn $CONN (rel=$REL), funnel=$FN"
done < /tmp/qi-conns.txt

# delete the processor
v=$(curl -sk -H "$AUTH" "$B/processors/$QI" | j ".revision.version")
curl -sk -H "$AUTH" -X DELETE "$B/processors/$QI?version=$v" >/dev/null 2>&1 || true
echo "deleted processor $QI"

# delete the funnels
sort -u /tmp/qi-funnels.txt | while read FN; do
  [ -z "$FN" ] && continue
  v=$(curl -sk -H "$AUTH" "$B/funnels/$FN" | j ".revision.version")
  curl -sk -H "$AUTH" -X DELETE "$B/funnels/$FN?version=$v" >/dev/null 2>&1 || true
  echo "deleted funnel $FN"
done
echo "TEARDOWN DONE"
