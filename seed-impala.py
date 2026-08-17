#!/usr/bin/env python3
"""Seed an Iceberg table into the DataLake HMS via Impala (Data Hub) over Knox.

Auth: LDAP with the CDP workload user + workload password (HTTP transport, TLS).
Password source (in order): $WORKLOAD_PASSWORD, then ./.workload.creds (gitignored).
Usage: WORKLOAD_PASSWORD=... python seed-impala.py [sql/seed-airlines.sql]
"""
import os
import sys
from impala.dbapi import connect

HOST = "srm-iceberg-impala-master0.srm-iceb.a465-9q4k.cloudera.site"
PORT = 443
HTTP_PATH = "srm-iceberg-impala/cdp-proxy-api/impala"
USER = os.environ.get("WORKLOAD_USER", "steven.matison")

pw = os.environ.get("WORKLOAD_PASSWORD")
if not pw and os.path.exists(".workload.creds"):
    pw = open(".workload.creds").read().strip()
if not pw:
    sys.exit("No workload password: set $WORKLOAD_PASSWORD or create ./.workload.creds")

sqlfile = sys.argv[1] if len(sys.argv) > 1 else "sql/seed-airlines.sql"
raw = open(sqlfile).read()

# split into statements, dropping -- comment lines
stmts = []
for chunk in raw.split(";"):
    body = "\n".join(l for l in chunk.splitlines() if not l.strip().startswith("--")).strip()
    if body:
        stmts.append(body)

conn = connect(host=HOST, port=PORT, use_ssl=True, use_http_transport=True,
               http_path=HTTP_PATH, auth_mechanism="LDAP", user=USER, password=pw)
cur = conn.cursor()
for s in stmts:
    print(f">>> {s.splitlines()[0][:80]}")
    cur.execute(s)
cur.execute("SELECT count(*) FROM poc_uc2.airlines")
print("poc_uc2.airlines row count:", cur.fetchall())
cur.close()
conn.close()
print("Seed complete.")
