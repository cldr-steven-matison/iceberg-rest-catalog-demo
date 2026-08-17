import os
from pyspark.sql import SparkSession

gw = os.environ["GW"]
dl = os.environ["DL"]
uri = f"https://{gw}/{dl}/cdp-datashare-access/iceberg-rest"   # base URI, client appends /v1
token = os.environ["CDP_JWT"]                                  # pre-fetched Knox JWT (2-step OAuth)

spark = (
    SparkSession.builder.appName("iceberg-rest-airlines")
    .config("spark.sql.catalog.cdp", "org.apache.iceberg.spark.SparkCatalog")
    .config("spark.sql.catalog.cdp.type", "rest")
    .config("spark.sql.catalog.cdp.uri", uri)
    .config("spark.sql.catalog.cdp.token", token)
    .config("spark.sql.catalog.cdp.header.X-Iceberg-Access-Delegation", "vended-credentials")
    .config("spark.sql.catalog.cdp.io-impl", "org.apache.iceberg.aws.s3.S3FileIO")
    .config("spark.sql.catalog.cdp.client.region", "us-east-2")
    .getOrCreate()
)
spark.sparkContext.setLogLevel("WARN")

print(">>> SHOW NAMESPACES IN cdp")
spark.sql("SHOW NAMESPACES IN cdp").show(truncate=False)

print(">>> SELECT * FROM cdp.poc_uc2.airlines")
spark.sql("SELECT * FROM cdp.poc_uc2.airlines ORDER BY code").show(truncate=False)

print(">>> COUNT")
spark.sql("SELECT count(*) AS n FROM cdp.poc_uc2.airlines").show()
spark.stop()
