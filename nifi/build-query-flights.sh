#!/bin/sh
# Second QueryIceberg processor "QueryFlights" (#156) against the LARGER live table
# poc_uc2.flights (120k rows, 12 monthly partitions) now shared on the CDP Data Share.
# Reuses CdpRestCatalog + GetIcebergJsonWriter. Placed below/right of the airlines QueryIceberg.
# Three SQL dynamic props -> three relationships. Run from inside the nifi-client pod.
set -e
B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
PG=f79030ac-019f-1000-0000-000005ef9ce5           # IcebergRESTCatalogDemo
RC=f79031bf-019f-1000-ffff-ffffc1e8f614           # CdpRestCatalog (ENABLED)
WR=f8db0fc3-019f-1000-ffff-ffffe182db28           # GetIcebergJsonWriter (ENABLED)
NS=poc_uc2; TBL=flights
VER=1.0.3-SNAPSHOT
j() { jq -r "$1"; }
T=$(curl -sk -X POST "$B/access/token" -d "username=admin&password=admin12345678"); AUTH="Authorization: Bearer $T"

BODY=$(jq -n --arg rc "$RC" --arg wr "$WR" --arg ns "$NS" --arg tbl "$TBL" --arg ver "$VER" '{
  revision:{version:0},
  component:{
    type:"org.apache.nifi.processors.iceberg.QueryIceberg",
    bundle:{group:"com.example",artifact:"nifi-geticeberg-nar",version:$ver},
    name:"QueryFlights",
    position:{x:1700,y:800},
    config:{
      schedulingPeriod:"3600 sec",
      properties:{
        "catalog-service":$rc,
        "catalog-namespace":$ns,
        "table-name":$tbl,
        "record-writer":$wr,
        "pruned":"SELECT carrier_code, origin, dest, dep_delay FROM flights WHERE flight_month = '"'"'2026-03'"'"'",
        "delayed":"SELECT flight_id, carrier_code, dep_delay FROM flights WHERE dep_delay > 45 AND carrier_code = '"'"'AA'"'"'",
        "carrier_stats":"SELECT carrier_code, COUNT(*) AS n, AVG(dep_delay) AS avg_delay FROM flights GROUP BY carrier_code"
      }
    }
  }
}')
QI=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/processors" -H 'Content-Type: application/json' -d "$BODY" | j ".id")
echo "QueryFlights=$QI"
sleep 1
RELS=$(curl -sk -H "$AUTH" "$B/processors/$QI" | j '.component.relationships[].name')
echo "relationships: $(echo $RELS | tr '\n' ' ')"

Y=650
: > /tmp/qf-conns.txt
for R in $RELS; do
  FN=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/funnels" -H 'Content-Type: application/json' \
    -d "{\"revision\":{\"version\":0},\"component\":{\"position\":{\"x\":2100,\"y\":$Y}}}" | j ".id")
  CONN=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/connections" -H 'Content-Type: application/json' \
    -d "{\"revision\":{\"version\":0},\"component\":{\"source\":{\"id\":\"$QI\",\"groupId\":\"$PG\",\"type\":\"PROCESSOR\"},\"destination\":{\"id\":\"$FN\",\"groupId\":\"$PG\",\"type\":\"FUNNEL\"},\"selectedRelationships\":[\"$R\"]}}" | j ".id")
  echo "$R $CONN" >> /tmp/qf-conns.txt
  echo "  rel=$R funnel=$FN conn=$CONN"
  Y=$((Y+180))
done
sleep 2
echo "QueryFlights validation: $(curl -sk -H "$AUTH" "$B/processors/$QI" | j '.component.state + " vErrs=" + (.component.validationErrors|tostring)')"
echo "QI=$QI" > /tmp/qf-id.txt
echo "DONE"
