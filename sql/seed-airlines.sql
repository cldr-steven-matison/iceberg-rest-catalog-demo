-- Seed a small Iceberg table via Impala on the srm-iceberg-impala Data Hub.
-- Impala writes Iceberg through the HiveCatalog, so the table lands in the
-- DataLake HMS and the Iceberg REST Catalog can serve it.
CREATE DATABASE IF NOT EXISTS poc_uc2;

CREATE TABLE IF NOT EXISTS poc_uc2.airlines (
  code        STRING,
  description STRING,
  origin      STRING,
  dest        STRING,
  year_id     INT
)
STORED BY ICEBERG;

INSERT INTO poc_uc2.airlines VALUES
  ('AA','American Airlines','JFK','LAX',2026),
  ('DL','Delta Air Lines',  'ATL','SEA',2026),
  ('UA','United Airlines',  'ORD','SFO',2026);
