-- The Iceberg table this demo owns. Impala creates it in the DataLake HMS
-- (STORED BY ICEBERG), so it is the authoritative catalog table that Impala,
-- Hive and Flink (catalog-type=hive) all read. NiFi's PutDatabaseRecord then
-- INSERTs into it over the Impala DBCP pool -- Impala performs the S3 write and
-- HMS commit server-side with its own IDBroker mapping (no S3 creds in NiFi).
--
-- Applied by the DDL segment of build-dbcp-write.sh (GenerateFlowFile -> PutSQL).
-- Idempotent: IF NOT EXISTS.
CREATE TABLE IF NOT EXISTS poc_uc2.nifi_dbcp_sink (
  id     INT,
  msg    STRING,
  source STRING,
  ts     STRING
)
STORED BY ICEBERG;
