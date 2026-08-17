-- Seed a LARGER partitioned Iceberg table into the DataLake HMS via Impala (Data Hub).
-- poc_uc2.flights: 120k rows, 12 monthly partitions (flight_month STRING, identity spec),
-- one append (=one manifest) per month so WHERE flight_month=... prunes 11/12 manifests.
-- Rows generated deterministically from a 10k numbers helper (no giant VALUES lists).
CREATE DATABASE IF NOT EXISTS poc_uc2;

DROP TABLE IF EXISTS default.gen_nums;

CREATE TABLE default.gen_nums (r BIGINT) STORED AS PARQUET;

INSERT INTO default.gen_nums
SELECT d1.n + d2.n*10 + d3.n*100 + d4.n*1000
FROM (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d1 CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d2 CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d3 CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d4;

DROP TABLE IF EXISTS poc_uc2.flights;

CREATE TABLE poc_uc2.flights (
  flight_id    BIGINT,
  carrier_code STRING,
  flight_num   INT,
  origin       STRING,
  dest         STRING,
  flight_month STRING,
  dep_delay    INT,
  distance     INT
)
PARTITIONED BY SPEC (flight_month)
STORED BY ICEBERG;

INSERT INTO poc_uc2.flights
SELECT
  CAST(r + 0 AS BIGINT) AS flight_id,
  CASE pmod(r,8) WHEN 0 THEN 'AA' WHEN 1 THEN 'DL' WHEN 2 THEN 'UA' WHEN 3 THEN 'WN' WHEN 4 THEN 'B6' WHEN 5 THEN 'AS' WHEN 6 THEN 'NK' ELSE 'F9' END AS carrier_code,
  CAST(pmod(r*13, 9000) + 1000 AS INT) AS flight_num,
  CASE pmod(r,5) WHEN 0 THEN 'JFK' WHEN 1 THEN 'ATL' WHEN 2 THEN 'ORD' WHEN 3 THEN 'DFW' ELSE 'DEN' END AS origin,
  CASE pmod(r,4) WHEN 0 THEN 'LAX' WHEN 1 THEN 'SEA' WHEN 2 THEN 'SFO' ELSE 'MIA' END AS dest,
  '2026-01' AS flight_month,
  CAST(pmod(r*7, 140) - 15 AS INT) AS dep_delay,
  CAST(200 + pmod(r*3, 4800) AS INT) AS distance
FROM default.gen_nums;

INSERT INTO poc_uc2.flights
SELECT
  CAST(r + 10000 AS BIGINT) AS flight_id,
  CASE pmod(r,8) WHEN 0 THEN 'AA' WHEN 1 THEN 'DL' WHEN 2 THEN 'UA' WHEN 3 THEN 'WN' WHEN 4 THEN 'B6' WHEN 5 THEN 'AS' WHEN 6 THEN 'NK' ELSE 'F9' END AS carrier_code,
  CAST(pmod(r*13, 9000) + 1000 AS INT) AS flight_num,
  CASE pmod(r,5) WHEN 0 THEN 'JFK' WHEN 1 THEN 'ATL' WHEN 2 THEN 'ORD' WHEN 3 THEN 'DFW' ELSE 'DEN' END AS origin,
  CASE pmod(r,4) WHEN 0 THEN 'LAX' WHEN 1 THEN 'SEA' WHEN 2 THEN 'SFO' ELSE 'MIA' END AS dest,
  '2026-02' AS flight_month,
  CAST(pmod(r*7, 140) - 15 AS INT) AS dep_delay,
  CAST(200 + pmod(r*3, 4800) AS INT) AS distance
FROM default.gen_nums;

INSERT INTO poc_uc2.flights
SELECT
  CAST(r + 20000 AS BIGINT) AS flight_id,
  CASE pmod(r,8) WHEN 0 THEN 'AA' WHEN 1 THEN 'DL' WHEN 2 THEN 'UA' WHEN 3 THEN 'WN' WHEN 4 THEN 'B6' WHEN 5 THEN 'AS' WHEN 6 THEN 'NK' ELSE 'F9' END AS carrier_code,
  CAST(pmod(r*13, 9000) + 1000 AS INT) AS flight_num,
  CASE pmod(r,5) WHEN 0 THEN 'JFK' WHEN 1 THEN 'ATL' WHEN 2 THEN 'ORD' WHEN 3 THEN 'DFW' ELSE 'DEN' END AS origin,
  CASE pmod(r,4) WHEN 0 THEN 'LAX' WHEN 1 THEN 'SEA' WHEN 2 THEN 'SFO' ELSE 'MIA' END AS dest,
  '2026-03' AS flight_month,
  CAST(pmod(r*7, 140) - 15 AS INT) AS dep_delay,
  CAST(200 + pmod(r*3, 4800) AS INT) AS distance
FROM default.gen_nums;

INSERT INTO poc_uc2.flights
SELECT
  CAST(r + 30000 AS BIGINT) AS flight_id,
  CASE pmod(r,8) WHEN 0 THEN 'AA' WHEN 1 THEN 'DL' WHEN 2 THEN 'UA' WHEN 3 THEN 'WN' WHEN 4 THEN 'B6' WHEN 5 THEN 'AS' WHEN 6 THEN 'NK' ELSE 'F9' END AS carrier_code,
  CAST(pmod(r*13, 9000) + 1000 AS INT) AS flight_num,
  CASE pmod(r,5) WHEN 0 THEN 'JFK' WHEN 1 THEN 'ATL' WHEN 2 THEN 'ORD' WHEN 3 THEN 'DFW' ELSE 'DEN' END AS origin,
  CASE pmod(r,4) WHEN 0 THEN 'LAX' WHEN 1 THEN 'SEA' WHEN 2 THEN 'SFO' ELSE 'MIA' END AS dest,
  '2026-04' AS flight_month,
  CAST(pmod(r*7, 140) - 15 AS INT) AS dep_delay,
  CAST(200 + pmod(r*3, 4800) AS INT) AS distance
FROM default.gen_nums;

INSERT INTO poc_uc2.flights
SELECT
  CAST(r + 40000 AS BIGINT) AS flight_id,
  CASE pmod(r,8) WHEN 0 THEN 'AA' WHEN 1 THEN 'DL' WHEN 2 THEN 'UA' WHEN 3 THEN 'WN' WHEN 4 THEN 'B6' WHEN 5 THEN 'AS' WHEN 6 THEN 'NK' ELSE 'F9' END AS carrier_code,
  CAST(pmod(r*13, 9000) + 1000 AS INT) AS flight_num,
  CASE pmod(r,5) WHEN 0 THEN 'JFK' WHEN 1 THEN 'ATL' WHEN 2 THEN 'ORD' WHEN 3 THEN 'DFW' ELSE 'DEN' END AS origin,
  CASE pmod(r,4) WHEN 0 THEN 'LAX' WHEN 1 THEN 'SEA' WHEN 2 THEN 'SFO' ELSE 'MIA' END AS dest,
  '2026-05' AS flight_month,
  CAST(pmod(r*7, 140) - 15 AS INT) AS dep_delay,
  CAST(200 + pmod(r*3, 4800) AS INT) AS distance
FROM default.gen_nums;

INSERT INTO poc_uc2.flights
SELECT
  CAST(r + 50000 AS BIGINT) AS flight_id,
  CASE pmod(r,8) WHEN 0 THEN 'AA' WHEN 1 THEN 'DL' WHEN 2 THEN 'UA' WHEN 3 THEN 'WN' WHEN 4 THEN 'B6' WHEN 5 THEN 'AS' WHEN 6 THEN 'NK' ELSE 'F9' END AS carrier_code,
  CAST(pmod(r*13, 9000) + 1000 AS INT) AS flight_num,
  CASE pmod(r,5) WHEN 0 THEN 'JFK' WHEN 1 THEN 'ATL' WHEN 2 THEN 'ORD' WHEN 3 THEN 'DFW' ELSE 'DEN' END AS origin,
  CASE pmod(r,4) WHEN 0 THEN 'LAX' WHEN 1 THEN 'SEA' WHEN 2 THEN 'SFO' ELSE 'MIA' END AS dest,
  '2026-06' AS flight_month,
  CAST(pmod(r*7, 140) - 15 AS INT) AS dep_delay,
  CAST(200 + pmod(r*3, 4800) AS INT) AS distance
FROM default.gen_nums;

INSERT INTO poc_uc2.flights
SELECT
  CAST(r + 60000 AS BIGINT) AS flight_id,
  CASE pmod(r,8) WHEN 0 THEN 'AA' WHEN 1 THEN 'DL' WHEN 2 THEN 'UA' WHEN 3 THEN 'WN' WHEN 4 THEN 'B6' WHEN 5 THEN 'AS' WHEN 6 THEN 'NK' ELSE 'F9' END AS carrier_code,
  CAST(pmod(r*13, 9000) + 1000 AS INT) AS flight_num,
  CASE pmod(r,5) WHEN 0 THEN 'JFK' WHEN 1 THEN 'ATL' WHEN 2 THEN 'ORD' WHEN 3 THEN 'DFW' ELSE 'DEN' END AS origin,
  CASE pmod(r,4) WHEN 0 THEN 'LAX' WHEN 1 THEN 'SEA' WHEN 2 THEN 'SFO' ELSE 'MIA' END AS dest,
  '2026-07' AS flight_month,
  CAST(pmod(r*7, 140) - 15 AS INT) AS dep_delay,
  CAST(200 + pmod(r*3, 4800) AS INT) AS distance
FROM default.gen_nums;

INSERT INTO poc_uc2.flights
SELECT
  CAST(r + 70000 AS BIGINT) AS flight_id,
  CASE pmod(r,8) WHEN 0 THEN 'AA' WHEN 1 THEN 'DL' WHEN 2 THEN 'UA' WHEN 3 THEN 'WN' WHEN 4 THEN 'B6' WHEN 5 THEN 'AS' WHEN 6 THEN 'NK' ELSE 'F9' END AS carrier_code,
  CAST(pmod(r*13, 9000) + 1000 AS INT) AS flight_num,
  CASE pmod(r,5) WHEN 0 THEN 'JFK' WHEN 1 THEN 'ATL' WHEN 2 THEN 'ORD' WHEN 3 THEN 'DFW' ELSE 'DEN' END AS origin,
  CASE pmod(r,4) WHEN 0 THEN 'LAX' WHEN 1 THEN 'SEA' WHEN 2 THEN 'SFO' ELSE 'MIA' END AS dest,
  '2026-08' AS flight_month,
  CAST(pmod(r*7, 140) - 15 AS INT) AS dep_delay,
  CAST(200 + pmod(r*3, 4800) AS INT) AS distance
FROM default.gen_nums;

INSERT INTO poc_uc2.flights
SELECT
  CAST(r + 80000 AS BIGINT) AS flight_id,
  CASE pmod(r,8) WHEN 0 THEN 'AA' WHEN 1 THEN 'DL' WHEN 2 THEN 'UA' WHEN 3 THEN 'WN' WHEN 4 THEN 'B6' WHEN 5 THEN 'AS' WHEN 6 THEN 'NK' ELSE 'F9' END AS carrier_code,
  CAST(pmod(r*13, 9000) + 1000 AS INT) AS flight_num,
  CASE pmod(r,5) WHEN 0 THEN 'JFK' WHEN 1 THEN 'ATL' WHEN 2 THEN 'ORD' WHEN 3 THEN 'DFW' ELSE 'DEN' END AS origin,
  CASE pmod(r,4) WHEN 0 THEN 'LAX' WHEN 1 THEN 'SEA' WHEN 2 THEN 'SFO' ELSE 'MIA' END AS dest,
  '2026-09' AS flight_month,
  CAST(pmod(r*7, 140) - 15 AS INT) AS dep_delay,
  CAST(200 + pmod(r*3, 4800) AS INT) AS distance
FROM default.gen_nums;

INSERT INTO poc_uc2.flights
SELECT
  CAST(r + 90000 AS BIGINT) AS flight_id,
  CASE pmod(r,8) WHEN 0 THEN 'AA' WHEN 1 THEN 'DL' WHEN 2 THEN 'UA' WHEN 3 THEN 'WN' WHEN 4 THEN 'B6' WHEN 5 THEN 'AS' WHEN 6 THEN 'NK' ELSE 'F9' END AS carrier_code,
  CAST(pmod(r*13, 9000) + 1000 AS INT) AS flight_num,
  CASE pmod(r,5) WHEN 0 THEN 'JFK' WHEN 1 THEN 'ATL' WHEN 2 THEN 'ORD' WHEN 3 THEN 'DFW' ELSE 'DEN' END AS origin,
  CASE pmod(r,4) WHEN 0 THEN 'LAX' WHEN 1 THEN 'SEA' WHEN 2 THEN 'SFO' ELSE 'MIA' END AS dest,
  '2026-10' AS flight_month,
  CAST(pmod(r*7, 140) - 15 AS INT) AS dep_delay,
  CAST(200 + pmod(r*3, 4800) AS INT) AS distance
FROM default.gen_nums;

INSERT INTO poc_uc2.flights
SELECT
  CAST(r + 100000 AS BIGINT) AS flight_id,
  CASE pmod(r,8) WHEN 0 THEN 'AA' WHEN 1 THEN 'DL' WHEN 2 THEN 'UA' WHEN 3 THEN 'WN' WHEN 4 THEN 'B6' WHEN 5 THEN 'AS' WHEN 6 THEN 'NK' ELSE 'F9' END AS carrier_code,
  CAST(pmod(r*13, 9000) + 1000 AS INT) AS flight_num,
  CASE pmod(r,5) WHEN 0 THEN 'JFK' WHEN 1 THEN 'ATL' WHEN 2 THEN 'ORD' WHEN 3 THEN 'DFW' ELSE 'DEN' END AS origin,
  CASE pmod(r,4) WHEN 0 THEN 'LAX' WHEN 1 THEN 'SEA' WHEN 2 THEN 'SFO' ELSE 'MIA' END AS dest,
  '2026-11' AS flight_month,
  CAST(pmod(r*7, 140) - 15 AS INT) AS dep_delay,
  CAST(200 + pmod(r*3, 4800) AS INT) AS distance
FROM default.gen_nums;

INSERT INTO poc_uc2.flights
SELECT
  CAST(r + 110000 AS BIGINT) AS flight_id,
  CASE pmod(r,8) WHEN 0 THEN 'AA' WHEN 1 THEN 'DL' WHEN 2 THEN 'UA' WHEN 3 THEN 'WN' WHEN 4 THEN 'B6' WHEN 5 THEN 'AS' WHEN 6 THEN 'NK' ELSE 'F9' END AS carrier_code,
  CAST(pmod(r*13, 9000) + 1000 AS INT) AS flight_num,
  CASE pmod(r,5) WHEN 0 THEN 'JFK' WHEN 1 THEN 'ATL' WHEN 2 THEN 'ORD' WHEN 3 THEN 'DFW' ELSE 'DEN' END AS origin,
  CASE pmod(r,4) WHEN 0 THEN 'LAX' WHEN 1 THEN 'SEA' WHEN 2 THEN 'SFO' ELSE 'MIA' END AS dest,
  '2026-12' AS flight_month,
  CAST(pmod(r*7, 140) - 15 AS INT) AS dep_delay,
  CAST(200 + pmod(r*3, 4800) AS INT) AS distance
FROM default.gen_nums;

DROP TABLE default.gen_nums;
