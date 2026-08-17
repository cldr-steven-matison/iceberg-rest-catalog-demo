#!/bin/sh
# Robustly remove the orphaned first QueryIceberg (fc4edd8c) + its 4 connections + 4 funnels.
# Empties each queue (drop-request, polled) BEFORE deleting the connection, since NiFi refuses
# to delete a connection with queued flowfiles. The correct processor fc578f2a is untouched.
B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
QI=fc4edd8c-019f-1000-0000-000067b0636f
CONNS="fc4ee1ec-019f-1000-0000-00006f5c04ee fc4ee209-019f-1000-0000-00000dcad8b6 fc4ee223-019f-1000-0000-00004dcc85db fc4ee23c-019f-1000-ffff-fffffc849b45"
FUNNELS="fc4ee1dc-019f-1000-ffff-ffffcfc90fc6 fc4ee1fc-019f-1000-0000-000077f1d9ae fc4ee217-019f-1000-ffff-ffffdd438426 fc4ee230-019f-1000-ffff-fffffa995c27"
j() { jq -r "$1"; }
T=$(curl -sk -X POST "$B/access/token" -d "username=admin&password=admin12345678"); AUTH="Authorization: Bearer $T"
gone() { curl -sk -H "$AUTH" "$1" | jq -e ".id" >/dev/null 2>&1 && echo no || echo yes; }

for C in $CONNS; do
  [ "$(gone "$B/connections/$C")" = yes ] && { echo "conn $C already gone"; continue; }
  # empty the queue
  DR=$(curl -sk -H "$AUTH" -X POST "$B/flowfile-queues/$C/drop-requests" | j ".dropRequest.id")
  i=0; while [ $i -lt 15 ]; do fin=$(curl -sk -H "$AUTH" "$B/flowfile-queues/$C/drop-requests/$DR" | j ".dropRequest.finished"); [ "$fin" = true ] && break; sleep 1; i=$((i+1)); done
  curl -sk -H "$AUTH" -X DELETE "$B/flowfile-queues/$C/drop-requests/$DR" >/dev/null 2>&1 || true
  v=$(curl -sk -H "$AUTH" "$B/connections/$C" | j ".revision.version")
  code=$(curl -sk -H "$AUTH" -X DELETE "$B/connections/$C?version=$v" -o /dev/null -w "%{http_code}")
  echo "conn $C delete HTTP $code"
done

for F in $FUNNELS; do
  [ "$(gone "$B/funnels/$F")" = yes ] && { echo "funnel $F already gone"; continue; }
  v=$(curl -sk -H "$AUTH" "$B/funnels/$F" | j ".revision.version")
  code=$(curl -sk -H "$AUTH" -X DELETE "$B/funnels/$F?version=$v" -o /dev/null -w "%{http_code}")
  echo "funnel $F delete HTTP $code"
done

# stop + delete the processor
r=$(curl -sk -H "$AUTH" "$B/processors/$QI" | j ".revision.version")
curl -sk -H "$AUTH" -X PUT "$B/processors/$QI/run-status" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":$r},\"state\":\"STOPPED\"}" >/dev/null 2>&1 || true
sleep 1
v=$(curl -sk -H "$AUTH" "$B/processors/$QI" | j ".revision.version")
code=$(curl -sk -H "$AUTH" -X DELETE "$B/processors/$QI?version=$v" -o /dev/null -w "%{http_code}")
echo "processor $QI delete HTTP $code"
echo "--- remaining QueryIceberg processors ---"
curl -sk -H "$AUTH" "$B/process-groups/f79030ac-019f-1000-0000-000005ef9ce5/processors" | j '.processors[]? | select(.component.name=="QueryIceberg") | .id'
