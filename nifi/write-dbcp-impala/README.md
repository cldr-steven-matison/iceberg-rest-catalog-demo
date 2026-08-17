# NiFi → Impala Data Hub Iceberg write (issue #151)

The **write / round-trip** leg of the CDP PC 7.3.2 Iceberg work. NiFi generates its own
rows and INSERTs them into an Iceberg table over a **Cloudera Impala DBCP pool** (JDBC over
Knox/LDAP). **Impala** performs the S3 write + HMS commit server-side with its own IDBroker
mapping — so no S3 credentials ever live in NiFi, and the table is the authoritative
HMS-registered Iceberg table that Impala/Hive/Flink all read.

This is deliberately separate from — and does not touch — the REST-catalog *read* demo
(`IcebergNativeCatalogDemo`, `RESTCatalogService`, GetIceberg/QueryIceberg). It also does not
use PutIceberg (already proven elsewhere); the write here is `PutDatabaseRecord`.

```
NiFi PG "IcebergImpalaDbcpDemo":
  GenerateFlowFile (3 rows we own) --success--> PutDatabaseRecord (INSERT) --> ImpalaConnectionPool
                                                                 \--failure--> LogAttribute

Impala API (impala.py):  create table (STORED BY ICEBERG)  +  verify count(*)   [the DoD check]
```

## Why DBCP-to-Impala and not a catalog service

The REST datashare only vends **read-only** S3 creds, and a `HadoopCatalogService` would write
by S3 directory convention into a table Impala can't see (catalog mismatch). Routing the write
through Impala's JDBC endpoint sidesteps both: Impala is the authoritative HMS Iceberg writer.
Full rationale: `DesktopShare/cloudera-impala-iceberg-plan.md`.

## Files

| File | Purpose |
|---|---|
| `env.sh` | All coordinates (Impala host, httpPath, table, NiFi pod). No secrets. |
| `ddl.sql` | `CREATE TABLE IF NOT EXISTS poc_uc2.nifi_dbcp_sink (...) STORED BY ICEBERG` |
| `impala.py` | Impala-API `create` (apply ddl) + `verify` (count). Reuses `seed-impala.py`'s connection. |
| `build-dbcp-write.sh` | Idempotent build of the NiFi PG (built **STOPPED**). Secrets → param context only. |
| `teardown-dbcp-write.sh` | Removes only this PG + its param context. |

## Run it (repeatable, against a fresh 7.3.2 env)

Prereqs: `minikube profile iceberg-lab` up, `mynifi-0` Running, a current
`../../.workload.creds` (workload password, one line), and `pip install impyla thrift_sasl`
wherever you run `impala.py`. Edit `env.sh` if the CDP env coordinates changed.

```sh
python impala.py create          # 1. create the Iceberg table via Impala
bash   build-dbcp-write.sh       # 2. build the NiFi PG (STOPPED); check CS report says VALID
# 3. Start the PG in the NiFi UI (or `nifi start` the two processors); GenRows fires once/hr
python impala.py verify          # 4. count(*) climbs by 3 per GenRows run  -> DoD met
```

Then **re-export the PG JSON and commit it** (rule 5 — a canvas not in version control is one
restart from gone). Clean up with `bash teardown-dbcp-write.sh`.

## Notes

- `PutDatabaseRecord` emits `INSERT INTO … VALUES (?)` batches; Impala accepts these (many small
  files — fine for a demo). If the driver balks at batching, drop `put-db-record-max-batch-size`
  to `1`.
- The pool uses the JVM public-CA truststore (`/usr/lib/jvm/jre/lib/security/cacerts`) to validate
  the Knox `*.cloudera.site` cert — no custom truststore needed.
- Built STOPPED on purpose: start it deliberately after the table exists (live-service discipline).
