#!/usr/bin/env bash
# Remove ONLY the issue-#151 DBCP write demo: the IcebergImpalaDbcpDemo process group
# and its iceberg-dbcp-params parameter context. Selects strictly by name, so the
# REST-catalog demo (IcebergNativeCatalogDemo / iceberg-demo-params) is never touched.
# Does NOT drop the Impala table -- run `python impala.py` + DROP TABLE by hand if wanted.
set -euo pipefail
cd "$(dirname "$0")"
. ./env.sh

kubectl exec -i "$NIFI_POD" -n "$NIFI_NS" -c "$NIFI_CTR" -- sh -s -- \
  "$NIFI_API" "$NIFI_USER" "$NIFI_PASS" "$PG_NAME" "$PC_NAME" <<'INNER'
set -eu
API="$1"; NU="$2"; NP="$3"; PGN="$4"; PCN="$5"
T=$(curl -sk -X POST "$API/access/token" -d "username=$NU&password=$NP")
AUTH="Authorization: Bearer $T"
g(){ curl -sk -H "$AUTH" "$@"; }
put(){ curl -sk -H "$AUTH" -X PUT "$1" -H 'Content-Type: application/json' -d "$2"; }

ROOT=$(g "$API/flow/process-groups/root" | jq -r '.processGroupFlow.id')
PG=$(g "$API/flow/process-groups/$ROOT" | jq -r --arg n "$PGN" '.processGroupFlow.flow.processGroups[]?|select(.component.name==$n)|.id' | head -1)
if [ -n "$PG" ]; then
  put "$API/flow/process-groups/$PG" "{\"id\":\"$PG\",\"state\":\"STOPPED\"}" >/dev/null 2>&1 || true
  for cs in $(g "$API/flow/process-groups/$PG/controller-services" | jq -r '.controllerServices[]?.id'); do
    r=$(g "$API/controller-services/$cs" | jq -r '.revision.version')
    put "$API/controller-services/$cs/run-status" "{\"revision\":{\"version\":$r},\"state\":\"DISABLED\"}" >/dev/null 2>&1 || true
  done
  sleep 4
  rev=$(g "$API/process-groups/$PG" | jq -r '.revision.version')
  g -X DELETE "$API/process-groups/$PG?version=$rev" >/dev/null 2>&1 && echo "deleted PG $PG" || echo "PG delete failed (drain queues?)"
else
  echo "no PG named $PGN"
fi
PC=$(g "$API/flow/parameter-contexts" | jq -r --arg n "$PCN" '.parameterContexts[]?|select(.component.name==$n)|.id' | head -1)
if [ -n "$PC" ]; then
  rev=$(g "$API/parameter-contexts/$PC" | jq -r '.revision.version')
  g -X DELETE "$API/parameter-contexts/$PC?version=$rev" >/dev/null 2>&1 && echo "deleted PC $PC" || echo "PC delete failed"
else
  echo "no PC named $PCN"
fi
INNER
echo "Teardown finished."
