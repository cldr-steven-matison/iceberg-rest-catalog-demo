CREATE TABLE IF NOT EXISTS poc_uc2.nifi_sink (
  id     INT,
  msg    STRING,
  source STRING
)
STORED BY ICEBERG;
