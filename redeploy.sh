#!/usr/bin/env bash
# Full automated redeploy of the srm-iceberg Iceberg REST Catalog demo (Runtime 7.3.2).
# Rebuilds everything the weekly Friday reaper destroys: env + DataLake + Impala Data Hub,
# seeds poc_uc2.airlines + poc_uc2.flights (120k rows, 12 monthly partitions), enables the
# REST Catalog, creates two external users (iceberg-consumer for Spark/Athena/etc.,
# iceberg-consumer-nifi for the NiFi flow), shares BOTH tables to BOTH users, activates,
# validates, and (best-effort) re-wires the surviving minikube NiFi flow's OAuth creds.
# ~1h40m wall-clock, mostly unattended polling.
#
# MANUAL PREREQS (interactive — do these first, once):
#   aws sso login --profile cldr-se
#   cdp configure                       # only if the CDP API key was rotated/deleted
#   ~/Documents/GitHub/iceberg-rest-catalog-demo/.workload.creds must exist (workload password)
#
# The NiFi re-wire (step 8) is best-effort: it only runs if the iceberg-lab minikube profile
# is up with a nifi-client helper pod in cfm-streaming. Otherwise it prints manual steps and
# the AWS rebuild still completes cleanly.
#
# Usage:  bash redeploy.sh
set -euo pipefail
export AWS_PROFILE=cldr-se
export PATH="$HOME/.venvs/cdpcli/bin:$PATH"

TF="$HOME/Documents/GitHub/cdp-tf-quickstarts/aws"
DEMO="$HOME/Documents/GitHub/iceberg-rest-catalog-demo"
PREFIX="srm-iceberg"
ENV_NAME="${PREFIX}-cdp-env"
DL="${PREFIX}-aw-dl"
DH="${PREFIX}-impala"
GW="${PREFIX}-aw-dl-gateway.srm-iceb.a465-9q4k.cloudera.site"   # stable for this tenant+prefix
USER_NAME="steven.matison"

echo "== [1/8] terraform apply (env + DataLake) — ~1h20m =="
( cd "$TF" && terraform init -input=false >/dev/null && terraform apply -auto-approve )

echo "== [2/8] wait for DataLake RUNNING =="
until [ "$(cdp datalake describe-datalake --datalake-name "$DL" 2>/dev/null | jq -r '.datalake.status')" = RUNNING ]; do sleep 30; done

DL_CRN=$(cdp datalake describe-datalake --datalake-name "$DL" | jq -r '.datalake.crn')
ENV_CRN=$(cdp environments describe-environment --environment-name "$ENV_NAME" | jq -r '.environment.crn')
printf 'ENV_CRN=%s\nDL_CRN=%s\n' "$ENV_CRN" "$DL_CRN" > "$DEMO/config.env"

# assign the resource roles this workflow needs (idempotent)
MYCRN=$(cdp iam get-user | jq -r '.user.crn')
for R in DataShareAdmin DataSteward EnvironmentAdmin DataHubCreator; do
  cdp iam assign-user-resource-role --user "$MYCRN" \
    --resource-role-crn "crn:altus:iam:us-west-1:altus:resourceRole:$R" \
    --resource-crn "$ENV_CRN" 2>/dev/null || true
done

echo "== [3/8] create Impala Data Hub + wait AVAILABLE — ~18m =="
cdp datahub create-aws-cluster --cluster-name "$DH" --environment-name "$ENV_NAME" \
  --cluster-definition-name "7.3.2 - Data Mart for AWS" || echo "(Data Hub may already exist)"
until [ "$(cdp datahub describe-cluster --cluster-name "$DH" 2>/dev/null | jq -r '.cluster.clusterStatus')" = AVAILABLE ]; do sleep 30; done

echo "== [4/8] seed poc_uc2.airlines + poc_uc2.flights =="
( cd "$DEMO" && python seed-impala.py sql/seed-airlines.sql )
# flights: 120k rows, 12 monthly partitions (identity spec on flight_month) — one manifest/month
# so WHERE flight_month=... prunes 11/12 manifests. (seed-impala.py's trailing count line always
# reads poc_uc2.airlines; the flights DDL/DML in seed-flights.sql still executes fully.)
( cd "$DEMO" && python seed-impala.py sql/seed-flights.sql )

echo "== [5/8] enable REST Catalog in HMS + restart HMS/Knox (CM API) =="
PW=$(cat "$DEMO/.workload.creds")
CMAPI="https://$GW/$DL/cdp-proxy-api/cm-api"
EXIST=$(curl -sk -u "$USER_NAME:$PW" "$CMAPI/v51/clusters/$DL/services/hive/config" \
  | jq -r '.items[]|select(.name=="hive_service_config_safety_valve").value // ""')
case "$EXIST" in
  *client.region*) SV="$EXIST" ;;
  *) SV="${EXIST}<property><name>client.region</name><value>us-east-2</value></property>" ;;
esac
jq -n --arg sv "$SV" '{items:[{name:"hive_rest_catalog_enabled",value:"true"},{name:"hive_service_config_safety_valve",value:$sv}]}' > /tmp/hcfg.json
curl -sk -u "$USER_NAME:$PW" -X PUT -H "Content-Type: application/json" -d @/tmp/hcfg.json \
  "$CMAPI/v51/clusters/$DL/services/hive/config" >/dev/null
for svc in hive knox; do
  CID=$(curl -sk -u "$USER_NAME:$PW" -X POST "$CMAPI/v51/clusters/$DL/services/$svc/commands/restart" | jq -r '.id')
  until [ "$(curl -sk -u "$USER_NAME:$PW" "$CMAPI/v51/commands/$CID" 2>/dev/null | jq -r '.active')" = false ]; do sleep 10; done
  echo "   restarted $svc"
done

echo "== [6/8] external users + data share (airlines + flights, both users) + activate =="
cd "$DEMO"
# consumer user (Spark/Athena/EMR/Snowflake/MCP) -> credentials.json
cdp datacatalog create-external-users --datalake-crn "$DL_CRN" --environment-crn "$ENV_CRN" \
  --external-users '[{"username":"iceberg-consumer","email":"steven.matison@cloudera.com","companyName":"Cloudera"}]' > /tmp/eu.json
jq '{clientId:.externalUsers[0].clientId, secret:.externalUsers[0].secret, username:.externalUsers[0].username}' /tmp/eu.json > credentials.json
chmod 600 credentials.json
EUID_=$(jq -r '.externalUsers[0].userId' /tmp/eu.json)

# NiFi user (the surviving minikube flow authenticates as this one) -> credentials-nifi.json
# Separate identity keeps the NiFi flow's Knox JWT quota independent of the ad-hoc consumer runs.
cdp datacatalog create-external-users --datalake-crn "$DL_CRN" --environment-crn "$ENV_CRN" \
  --external-users '[{"username":"iceberg-consumer-nifi","email":"steven.matison@cloudera.com","companyName":"Cloudera"}]' > /tmp/eu-nifi.json
jq '{clientId:.externalUsers[0].clientId, secret:.externalUsers[0].secret, username:.externalUsers[0].username}' /tmp/eu-nifi.json > credentials-nifi.json
chmod 600 credentials-nifi.json
EUID_NIFI=$(jq -r '.externalUsers[0].userId' /tmp/eu-nifi.json)

# one share, both tables (airlines + flights), both users
cdp datacatalog create-data-share --datalake-crn "$DL_CRN" --environment-crn "$ENV_CRN" \
  --data-share-name "srm-iceberg-share" \
  --assets '[{"databaseName":"poc_uc2","tableName":"airlines"},{"databaseName":"poc_uc2","tableName":"flights"}]' \
  --external-users "[{\"externalUserId\":$EUID_},{\"externalUserId\":$EUID_NIFI}]" > /tmp/ds.json
SID=$(jq -r '.dataShareId' /tmp/ds.json)
# refresh config.env with the fresh CRNs + share id (single source of truth for the demo scripts)
printf 'ENV_CRN=%s\nDL_CRN=%s\nDATA_SHARE_ID=%s\n' "$ENV_CRN" "$DL_CRN" "$SID" > "$DEMO/config.env"
cdp datacatalog share-data-share --datalake-crn "$DL_CRN" --environment-crn "$ENV_CRN" --data-share-id "$SID"

echo "== [7/8] validate REST Catalog (4-step) — airlines + flights =="
bash test-rest-catalog.sh poc_uc2 airlines
bash test-rest-catalog.sh poc_uc2 flights || echo "   (flights validation non-fatal here; Ranger can lag ~15-45s after share)"

echo "== [8/8] re-wire the surviving minikube NiFi flow's OAuth creds (best-effort) =="
# The NiFi flow (PG IcebergRESTCatalogDemo) survives on minikube, but its Parameter Context still
# holds the PRE-reaper clientId/secret -> 401 until updated to the fresh iceberg-consumer-nifi creds.
# Only runs if the iceberg-lab profile is up with the nifi-client helper pod; never fails the rebuild.
NIFI_NS=cfm-streaming
if kubectl -n "$NIFI_NS" get pod nifi-client >/dev/null 2>&1; then
  CID_N=$(jq -r '.clientId' "$DEMO/credentials-nifi.json")
  SEC_N=$(jq -r '.secret'   "$DEMO/credentials-nifi.json")
  kubectl -n "$NIFI_NS" cp "$DEMO/nifi/rewire-nifi-creds.sh" nifi-client:/tmp/rewire-nifi-creds.sh
  kubectl -n "$NIFI_NS" cp "$DEMO/nifi/refresh-oauth.sh"     nifi-client:/tmp/refresh-oauth.sh
  # 1) push fresh creds into the Parameter Context bound to the live PG
  kubectl -n "$NIFI_NS" exec -i nifi-client -- sh /tmp/rewire-nifi-creds.sh "$CID_N" "$SEC_N" || \
    echo "   (param-context update reported an issue — check output above)"
  # 2) cycle KnoxOAuth2 + CdpRestCatalog so a fresh token is minted against the new sandbox
  kubectl -n "$NIFI_NS" exec -i nifi-client -- sh /tmp/refresh-oauth.sh || \
    echo "   (oauth refresh reported an issue — check output above)"
else
  echo "   nifi-client pod not found in $NIFI_NS — skipping NiFi re-wire."
  echo "   To re-wire manually after starting the iceberg-lab minikube profile:"
  echo "     1) minikube -p iceberg-lab start"
  echo "     2) kubectl -n $NIFI_NS run nifi-client --image=badouralix/curl-jq --restart=Never --command -- sleep 10800"
  echo "     3) kubectl cp the mTLS cert from secret mynifi-cfm-operator-user-cert (human step)"
  echo "     4) kubectl -n $NIFI_NS cp nifi/rewire-nifi-creds.sh nifi-client:/tmp/ && \\"
  echo "        kubectl -n $NIFI_NS exec -i nifi-client -- sh /tmp/rewire-nifi-creds.sh <clientId> <secret>"
  echo "     5) kubectl -n $NIFI_NS cp nifi/refresh-oauth.sh nifi-client:/tmp/ && \\"
  echo "        kubectl -n $NIFI_NS exec -i nifi-client -- sh /tmp/refresh-oauth.sh"
  echo "   Fresh NiFi creds are in $DEMO/credentials-nifi.json."
fi

echo "== DONE.  MCP .env host is stable ($GW-based); MCP server needs no change. =="
echo "   Shared: poc_uc2.airlines (3 rows) + poc_uc2.flights (120k rows) to iceberg-consumer + iceberg-consumer-nifi."
