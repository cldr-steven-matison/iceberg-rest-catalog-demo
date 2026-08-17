#!/bin/sh
# Move QueryIceberg + its 4 funnels to the right of the existing flow (existing extent ends ~1240).
# Position-only PUTs (component id + position). QueryIceberg has no sensitive props.
B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
QI=fc578f2a-019f-1000-ffff-ffffbae5bc12
j() { jq -r "$1"; }
T=$(curl -sk -X POST "$B/access/token" -d "username=admin&password=admin12345678"); AUTH="Authorization: Bearer $T"

moveproc() { # id x y
  local r=$(curl -sk -H "$AUTH" "$B/processors/$1" | j ".revision.version")
  curl -sk -H "$AUTH" -X PUT "$B/processors/$1" -H 'Content-Type: application/json' \
    -d "{\"revision\":{\"version\":$r},\"component\":{\"id\":\"$1\",\"position\":{\"x\":$2,\"y\":$3}}}" -o /dev/null -w "proc $1 -> ($2,$3) HTTP %{http_code}\n"
}
movefunnel() { # id x y
  local r=$(curl -sk -H "$AUTH" "$B/funnels/$1" | j ".revision.version")
  curl -sk -H "$AUTH" -X PUT "$B/funnels/$1" -H 'Content-Type: application/json' \
    -d "{\"revision\":{\"version\":$r},\"component\":{\"id\":\"$1\",\"position\":{\"x\":$2,\"y\":$3}}}" -o /dev/null -w "funnel ${1%%-*} -> ($2,$3) HTTP %{http_code}\n"
}

moveproc "$QI" 1700 200
movefunnel fc57936d-019f-1000-ffff-fffff4f33606 2100 -50    # all
movefunnel fc5793c3-019f-1000-0000-000023449978 2100 130    # filtered
movefunnel fc57938c-019f-1000-0000-000008a4825c 2100 310    # by_dest
movefunnel fc5793a7-019f-1000-0000-000017d481ef 2100 490    # failure
echo "DONE"
