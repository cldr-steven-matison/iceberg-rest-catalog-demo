#!/usr/bin/env bash
# Build the NiFi -> Impala Data Hub Iceberg write flow (issue #151), isolated in its
# own process group. Idempotent: re-running deletes and rebuilds only this PG + its
# parameter context, touching nothing else (the REST-catalog demo is untouched).
#
#   GenerateFlowFile (our own JSON rows) -> PutDatabaseRecord -> ImpalaConnectionPool
#
# The workload password is read from ../../.workload.creds and written ONLY into the
# parameter context (write-only, sensitive) -- never a processor literal (rule 2).
# DDL + verification are handled by impala.py, not NiFi.
#
# Built STOPPED. Start it from the NiFi UI (or `nifi start`) once impala.py create
# has made the table. Prereq: `minikube profile iceberg-lab` up, mynifi-0 Running.
set -euo pipefail
cd "$(dirname "$0")"
. ./env.sh

WP="$(cat ../../.workload.creds | tr -d '\n')"
[ -n "$WP" ] || { echo "empty ../../.workload.creds"; exit 1; }

# Our own data source: three rows we own, one flow file, one INSERT batch.
ROWS='[{"id":1,"msg":"hello from nifi dbcp","source":"PutDatabaseRecord","ts":"2026-01-01T00:00:00"},{"id":2,"msg":"second row","source":"PutDatabaseRecord","ts":"2026-01-01T00:00:01"},{"id":3,"msg":"third row","source":"PutDatabaseRecord","ts":"2026-01-01T00:00:02"}]'

echo "Building PG '$PG_NAME' on $NIFI_POD ($NIFI_NS) ..."
kubectl exec -i "$NIFI_POD" -n "$NIFI_NS" -c "$NIFI_CTR" -- sh -s -- \
  "$NIFI_API" "$NIFI_USER" "$NIFI_PASS" "$PG_NAME" "$PC_NAME" \
  "$IMPALA_HOST" "$IMPALA_PORT" "$IMPALA_HTTPPATH" "$WORKLOAD_USER" "$WP" \
  "$DB_SCHEMA" "$SINK_TABLE" "$TRUSTSTORE" "$TRUSTSTORE_PASS" "$ROWS" <<'INNER'
set -eu
API="$1"; NU="$2"; NP="$3"; PGN="$4"; PCN="$5"
IHOST="$6"; IPORT="$7"; IHTTP="$8"; WU="$9"; WP="${10}"
SCHEMA="${11}"; TABLE="${12}"; TS="${13}"; TSP="${14}"; ROWS="${15}"

T=$(curl -sk -X POST "$API/access/token" -d "username=$NU&password=$NP")
AUTH="Authorization: Bearer $T"
g(){ curl -sk -H "$AUTH" "$@"; }
post(){ curl -sk -H "$AUTH" -X POST "$1" -H 'Content-Type: application/json' -d "$2"; }
put(){ curl -sk -H "$AUTH" -X PUT "$1" -H 'Content-Type: application/json' -d "$2"; }

ROOT=$(g "$API/flow/process-groups/root" | jq -r '.processGroupFlow.id')

# ---- idempotent pre-clean: delete only OUR PG (by name), then OUR PC (by name) ----
EXPG=$(g "$API/flow/process-groups/$ROOT" | jq -r --arg n "$PGN" '.processGroupFlow.flow.processGroups[]?|select(.component.name==$n)|.id' | head -1)
if [ -n "$EXPG" ]; then
  echo "  removing existing PG $EXPG"
  put "$API/flow/process-groups/$EXPG" "{\"id\":\"$EXPG\",\"state\":\"STOPPED\"}" >/dev/null 2>&1 || true
  for cs in $(g "$API/flow/process-groups/$EXPG/controller-services" | jq -r '.controllerServices[]?.id'); do
    r=$(g "$API/controller-services/$cs" | jq -r '.revision.version')
    put "$API/controller-services/$cs/run-status" "{\"revision\":{\"version\":$r},\"state\":\"DISABLED\"}" >/dev/null 2>&1 || true
  done
  sleep 4
  rev=$(g "$API/process-groups/$EXPG" | jq -r '.revision.version')
  g -X DELETE "$API/process-groups/$EXPG?version=$rev" >/dev/null 2>&1 || true
fi
EXPC=$(g "$API/flow/parameter-contexts" | jq -r --arg n "$PCN" '.parameterContexts[]?|select(.component.name==$n)|.id' | head -1)
if [ -n "$EXPC" ]; then
  echo "  removing existing PC $EXPC"
  rev=$(g "$API/parameter-contexts/$EXPC" | jq -r '.revision.version')
  g -X DELETE "$API/parameter-contexts/$EXPC?version=$rev" >/dev/null 2>&1 || true
fi

# ---- process group ----
PG=$(post "$API/process-groups/$ROOT/process-groups" \
  "$(jq -n --arg n "$PGN" '{revision:{version:0},component:{name:$n,position:{x:0,y:0}}}')" | jq -r '.id')
echo "PG=$PG"

# ---- parameter context (workload_password sensitive; all else plain) ----
PC=$(post "$API/parameter-contexts" "$(jq -n --arg n "$PCN" --arg wu "$WU" --arg wp "$WP" \
  --arg ih "$IHOST" --arg ip "$IPORT" --arg ht "$IHTTP" --arg sc "$SCHEMA" \
  '{revision:{version:0},component:{name:$n,parameters:[
    {parameter:{name:"workload_user",sensitive:false,value:$wu}},
    {parameter:{name:"workload_password",sensitive:true,value:$wp}},
    {parameter:{name:"impala_host",sensitive:false,value:$ih}},
    {parameter:{name:"impala_port",sensitive:false,value:$ip}},
    {parameter:{name:"impala_httppath",sensitive:false,value:$ht}},
    {parameter:{name:"db_schema",sensitive:false,value:$sc}}]}}')" | jq -r '.id')
echo "PC=$PC"
PGREV=$(g "$API/process-groups/$PG" | jq -r '.revision.version')
put "$API/process-groups/$PG" "{\"revision\":{\"version\":$PGREV},\"component\":{\"id\":\"$PG\",\"parameterContext\":{\"id\":\"$PC\"}}}" >/dev/null

# ---- SSL context (JVM public-CA truststore -> validates the Knox cert) ----
SSL=$(post "$API/process-groups/$PG/controller-services" "$(jq -n --arg ts "$TS" --arg tsp "$TSP" \
  '{revision:{version:0},component:{type:"org.apache.nifi.ssl.StandardSSLContextService",name:"KnoxTruststore",
    properties:{"Truststore Filename":$ts,"Truststore Password":$tsp,"Truststore Type":"JKS","SSL Protocol":"TLS"}}}')" | jq -r '.component.id')
echo "SSL=$SSL"

# ---- Cloudera Impala DBCP pool (bundled ImpalaJDBC42, Knox LDAP HTTP) ----
POOL=$(post "$API/process-groups/$PG/controller-services" "$(jq -n --arg ssl "$SSL" \
  '{revision:{version:0},component:{type:"com.cloudera.nifi.service.dbcp.impala.ImpalaConnectionPool",name:"ImpalaDataHubPool",
    properties:{"database-hostname":"#{impala_host}","database-port":"#{impala_port}","httpPath":"#{impala_httppath}",
      "transportMode":"http","AuthMech":"3","driver-version":"bundled","schema-name":"#{db_schema}",
      "UID":"#{workload_user}","PWD":"#{workload_password}","SSL Context Service":$ssl}}}')" | jq -r '.component.id')
echo "POOL=$POOL"

# ---- JsonTreeReader (infer schema from the generated rows) ----
JR=$(post "$API/process-groups/$PG/controller-services" \
  '{"revision":{"version":0},"component":{"type":"org.apache.nifi.json.JsonTreeReader","name":"JsonReader","properties":{"schema-access-strategy":"infer-schema"}}}' | jq -r '.component.id')
echo "JR=$JR"

# ---- enable SSL first, then pool + reader ----
enable(){ r=$(g "$API/controller-services/$1" | jq -r '.revision.version')
  put "$API/controller-services/$1/run-status" "{\"revision\":{\"version\":$r},\"state\":\"ENABLED\"}" >/dev/null; }
enable "$SSL"; sleep 3; enable "$POOL"; enable "$JR"; sleep 4
for cs in "$SSL" "$POOL" "$JR"; do
  echo "  CS $cs -> $(g "$API/controller-services/$cs" | jq -r '.component.validationStatus')"
done

# ---- processors ----
mkproc(){ post "$API/process-groups/$PG/processors" "$(jq -n --arg t "$1" --arg n "$2" \
  --argjson x "$3" --argjson y "$4" --argjson p "$5" --argjson a "$6" --arg s "$7" \
  '{revision:{version:0},component:{type:$t,name:$n,position:{x:$x,y:$y},
    config:{properties:$p,autoTerminatedRelationships:$a,schedulingPeriod:$s}}}')" | jq -r '.component.id'; }

GEN=$(mkproc "org.apache.nifi.processors.standard.GenerateFlowFile" "GenRows" 400 0 \
  "$(jq -n --arg r "$ROWS" '{"File Size":"0B","Batch Size":"1","Custom Text":$r}')" '[]' "3600 sec")
echo "GEN=$GEN"

PUT=$(mkproc "org.apache.nifi.processors.standard.PutDatabaseRecord" "InsertRows" 400 300 \
  "$(jq -n --arg pool "$POOL" --arg jr "$JR" --arg sc "$SCHEMA" --arg tb "$TABLE" \
    '{"put-db-record-dcbp-service":$pool,"put-db-record-record-reader":$jr,
      "put-db-record-statement-type":"INSERT","put-db-record-schema-name":$sc,
      "put-db-record-table-name":$tb,"db-type":"Generic"}')" '["success","retry"]' "0 sec")
echo "PUT=$PUT"

# LogAttribute sink for PutDatabaseRecord failures
LOG=$(mkproc "org.apache.nifi.processors.standard.LogAttribute" "LogFailure" 750 300 \
  '{"Log Level":"error"}' '["success"]' "0 sec")

conn(){ post "$API/process-groups/$PG/connections" "$(jq -n --arg s "$1" --arg d "$2" --arg pg "$PG" --argjson rel "$3" \
  '{revision:{version:0},component:{source:{id:$s,groupId:$pg,type:"PROCESSOR"},destination:{id:$d,groupId:$pg,type:"PROCESSOR"},selectedRelationships:$rel}}')" >/dev/null; }
conn "$GEN" "$PUT" '["success"]'
conn "$PUT" "$LOG" '["failure"]'

echo "DONE. PG=$PG built STOPPED. Start it in the NiFi UI after: python impala.py create"
INNER
echo "Build script finished."
