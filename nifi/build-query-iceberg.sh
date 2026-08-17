#!/bin/sh
# Add QueryIceberg (custom SQL-with-pushdown read processor, #156) into the existing
# IcebergRESTCatalogDemo PG, reusing the already-ENABLED CdpRestCatalog (RESTCatalogService
# -> KnoxOAuth2) and GetIcebergJsonWriter from the #152/#154 eval. Datashare vends S3 creds,
# so NO catalog.* props are needed here. Three SQL dynamic props -> three relationships.
# Mirrors build-get-in-152pg.sh. Run from inside the nifi-client pod (FQDN resolves in-cluster).
set -e
B="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
PG=f79030ac-019f-1000-0000-000005ef9ce5           # IcebergRESTCatalogDemo
RC=f79031bf-019f-1000-ffff-ffffc1e8f614           # CdpRestCatalog (ENABLED)
WR=f8db0fc3-019f-1000-ffff-ffffe182db28           # GetIcebergJsonWriter (ENABLED)
NS=poc_uc2; TBL=airlines
VER=1.0.3-SNAPSHOT
j() { jq -r "$1"; }
T=$(curl -sk -X POST "$B/access/token" -d "username=admin&password=admin12345678"); AUTH="Authorization: Bearer $T"

# QueryIceberg (bundle 1.0.3), reusing CdpRestCatalog + GetIcebergJsonWriter.
# Dynamic props (name -> SQL) become output relationships (QueryRecord parity).
BODY=$(jq -n --arg rc "$RC" --arg wr "$WR" --arg ns "$NS" --arg tbl "$TBL" --arg ver "$VER" '{
  revision:{version:0},
  component:{
    type:"org.apache.nifi.processors.iceberg.QueryIceberg",
    bundle:{group:"com.example",artifact:"nifi-geticeberg-nar",version:$ver},
    name:"QueryIceberg",
    position:{x:600,y:400},
    config:{
      schedulingPeriod:"3600 sec",
      properties:{
        "catalog-service":$rc,
        "catalog-namespace":$ns,
        "table-name":$tbl,
        "record-writer":$wr,
        "all":"SELECT * FROM airlines",
        "filtered":"SELECT code, description, origin, dest FROM airlines WHERE code = '"'"'AA'"'"'",
        "by_dest":"SELECT dest, COUNT(*) AS n FROM airlines GROUP BY dest"
      }
    }
  }
}')
QI=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/processors" -H 'Content-Type: application/json' -d "$BODY" | j ".id")
echo "QI=$QI"

# Read back the relationships the processor now exposes (dynamic + failure)
sleep 1
RELS=$(curl -sk -H "$AUTH" "$B/processors/$QI" | j '.component.relationships[].name')
echo "relationships: $(echo $RELS | tr '\n' ' ')"

# One funnel per relationship; connect each. Record conn ids keyed by relationship.
Y=0
: > /tmp/qi-conns.txt
for R in $RELS; do
  FN=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/funnels" -H 'Content-Type: application/json' \
    -d "{\"revision\":{\"version\":0},\"component\":{\"position\":{\"x\":950,\"y\":$Y}}}" | j ".id")
  CONN=$(curl -sk -H "$AUTH" -X POST "$B/process-groups/$PG/connections" -H 'Content-Type: application/json' \
    -d "{\"revision\":{\"version\":0},\"component\":{\"source\":{\"id\":\"$QI\",\"groupId\":\"$PG\",\"type\":\"PROCESSOR\"},\"destination\":{\"id\":\"$FN\",\"groupId\":\"$PG\",\"type\":\"FUNNEL\"},\"selectedRelationships\":[\"$R\"]}}" | j ".id")
  echo "$R $CONN" >> /tmp/qi-conns.txt
  echo "  rel=$R funnel=$FN conn=$CONN"
  Y=$((Y+150))
done

sleep 2
echo "QI validation: $(curl -sk -H "$AUTH" "$B/processors/$QI" | j '.component.state + " vErrs=" + (.component.validationErrors|tostring)')"
echo "QI=$QI" > /tmp/qi-id.txt
echo "DONE"
