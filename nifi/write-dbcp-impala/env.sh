# Coordinates for the NiFi -> Impala Data Hub Iceberg write demo (issue #151).
# Sourced by build-dbcp-write.sh / teardown-dbcp-write.sh. No secrets live here:
# the workload password is read at runtime from ../../.workload.creds.

# --- CDP Impala Data Hub (7.3.2) over Knox, LDAP HTTP transport ---
IMPALA_HOST="srm-iceberg-impala-master0.srm-iceb.a465-9q4k.cloudera.site"
IMPALA_PORT="443"                                   # Knox HTTPS (not the native 21050)
IMPALA_HTTPPATH="srm-iceberg-impala/cdp-proxy-api/impala"
WORKLOAD_USER="steven.matison"                      # password: ../../.workload.creds

# --- The table WE own (created STORED BY ICEBERG; not the shared poc_uc2.nifi_sink) ---
DB_SCHEMA="poc_uc2"
SINK_TABLE="nifi_dbcp_sink"

# --- NiFi on the iceberg-lab profile ---
NIFI_POD="mynifi-0"
NIFI_NS="cfm-streaming"
NIFI_CTR="nifi"
NIFI_API="https://mynifi-web.cfm-streaming.svc.cluster.local:8443/nifi-api"
NIFI_USER="admin"
NIFI_PASS="admin12345678"                           # single-user lab default (already in sibling scripts)

# --- Names for everything this demo creates (all deleted cleanly by teardown) ---
PG_NAME="IcebergImpalaDbcpDemo"
PC_NAME="iceberg-dbcp-params"

# JVM public-CA truststore inside the NiFi pod -> validates the Knox *.cloudera.site cert
TRUSTSTORE="/usr/lib/jvm/jre/lib/security/cacerts"
TRUSTSTORE_PASS="changeit"
