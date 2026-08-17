# Athena for Apache Spark — Iceberg REST Catalog calculation.
# Runs as a calculation in a Spark-enabled Athena workgroup (us-east-2).
# Athena provides a pre-initialized `spark` SparkSession with Iceberg support built in,
# so we only set the catalog config (same block as OSS Spark / EMR) then query.
#
# Secret hygiene: the Knox JWT is short-lived (2-step OAuth). Fetch it FRESH right
# before submitting, substitute it here at submit time, and never commit a populated
# copy. Athena Spark egresses from an AWS-managed VPC (non-fixed IP) → the DataLake
# knox SG must allow 0.0.0.0/0 on 443 for this to connect.

GW    = "srm-iceberg-aw-dl-gateway.srm-iceb.a465-9q4k.cloudera.site"
DL    = "srm-iceberg-aw-dl"
URI   = f"https://{GW}/{DL}/cdp-datashare-access/iceberg-rest"   # base URI, client appends /v1
TOKEN = "__CDP_JWT__"   # replaced at submit time with a fresh Knox JWT — do NOT commit populated

spark.conf.set("spark.sql.catalog.cdp", "org.apache.iceberg.spark.SparkCatalog")
spark.conf.set("spark.sql.catalog.cdp.type", "rest")
spark.conf.set("spark.sql.catalog.cdp.uri", URI)
spark.conf.set("spark.sql.catalog.cdp.token", TOKEN)
spark.conf.set("spark.sql.catalog.cdp.header.X-Iceberg-Access-Delegation", "vended-credentials")
spark.conf.set("spark.sql.catalog.cdp.io-impl", "org.apache.iceberg.aws.s3.S3FileIO")
spark.conf.set("spark.sql.catalog.cdp.client.region", "us-east-2")

print(">>> SHOW NAMESPACES IN cdp")
spark.sql("SHOW NAMESPACES IN cdp").show(truncate=False)

print(">>> SELECT * FROM cdp.poc_uc2.airlines")
spark.sql("SELECT * FROM cdp.poc_uc2.airlines ORDER BY code").show(truncate=False)

print(">>> COUNT")
spark.sql("SELECT count(*) AS n FROM cdp.poc_uc2.airlines").show()
