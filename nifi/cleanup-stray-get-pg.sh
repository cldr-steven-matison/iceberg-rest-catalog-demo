#!/bin/sh
# Tear down the stray GetIcebergDemo PG (built while iterating on fresh CS, now superseded).
set -e
B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
PG=f8bbdaf7-019f-1000-0000-00003382a90e
PC=f8bbef08-019f-1000-ffff-ffffa98e98e5
OA=f8bc2b10-019f-1000-ffff-fffffeb2c3f6
RC=f8bc3f10-019f-1000-0000-0000075f6031
JR=f8bc532f-019f-1000-0000-000000f95117
GI=f8c0396d-019f-1000-ffff-ffffc764257b
CN=f8c06176-019f-1000-0000-000070ff7ab7
j() { jq -r "$1"; }
T=$(curl -sk -X POST "$B/access/token" -d "username=admin&password=admin12345678"); AUTH="Authorization: Bearer $T"

echo "--- stop GetIceberg ---"
gr=$(curl -sk -H "$AUTH" "$B/processors/$GI" | j ".revision.version")
curl -sk -H "$AUTH" -X PUT "$B/processors/$GI/run-status" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":$gr},\"state\":\"STOPPED\"}" >/dev/null || true

echo "--- empty success queue ---"
curl -sk -H "$AUTH" -X POST "$B/flowfile-queues/$CN/drop-requests" >/dev/null 2>&1 || true

echo "--- disable CS (RC, JR, OA) ---"
for cs in "$RC" "$JR" "$OA"; do
  r=$(curl -sk -H "$AUTH" "$B/controller-services/$cs" | j ".revision.version")
  curl -sk -H "$AUTH" -X PUT "$B/controller-services/$cs/run-status" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":$r},\"state\":\"DISABLED\"}" >/dev/null 2>&1 || true
done
sleep 4

echo "--- delete PG (cascades processors/funnel/connections/CS) ---"
pr=$(curl -sk -H "$AUTH" "$B/process-groups/$PG" | j ".revision.version")
curl -sk -H "$AUTH" -X DELETE "$B/process-groups/$PG?version=$pr" -w "  [PG delete HTTP %{http_code}]\n" -o /dev/null

echo "--- delete parameter context ---"
cr=$(curl -sk -H "$AUTH" "$B/parameter-contexts/$PC" | j ".revision.version")
curl -sk -H "$AUTH" -X DELETE "$B/parameter-contexts/$PC?version=$cr" -w "  [PC delete HTTP %{http_code}]\n" -o /dev/null

echo "--- verify gone ---"
curl -sk -H "$AUTH" "$B/process-groups/$PG" -w "  [GET PG HTTP %{http_code}]\n" -o /dev/null
