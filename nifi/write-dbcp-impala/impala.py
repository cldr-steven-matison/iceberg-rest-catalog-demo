#!/usr/bin/env python3
"""Impala-API side of the NiFi DBCP write demo (issue #151).

Reuses the exact Knox/LDAP Impala Data Hub connection that seed-impala.py proves
reachable. Two jobs, neither of which touches NiFi:

  create   apply ddl.sql -> poc_uc2.nifi_dbcp_sink (STORED BY ICEBERG) in the DataLake HMS
  verify   SELECT count(*) FROM poc_uc2.nifi_dbcp_sink   (the DoD cross-check)

The row INSERTs are done by NiFi (GenerateFlowFile -> PutDatabaseRecord over the
Impala DBCP pool); this script only creates the table Impala owns and reads it back.

Auth: LDAP with the CDP workload user + password (HTTP transport, TLS).
Password: $WORKLOAD_PASSWORD, else ../../.workload.creds (gitignored).

Usage:
  pip install impyla thrift_sasl        # once, wherever you run this
  python impala.py create
  python impala.py verify
"""
import os
import sys
from impala.dbapi import connect

HOST = "srm-iceberg-impala-master0.srm-iceb.a465-9q4k.cloudera.site"
PORT = 443
HTTP_PATH = "srm-iceberg-impala/cdp-proxy-api/impala"
USER = os.environ.get("WORKLOAD_USER", "steven.matison")
TABLE = "poc_uc2.nifi_dbcp_sink"

HERE = os.path.dirname(os.path.abspath(__file__))
CREDS = os.path.join(HERE, "..", "..", ".workload.creds")
DDL = os.path.join(HERE, "ddl.sql")


def password():
    pw = os.environ.get("WORKLOAD_PASSWORD")
    if not pw and os.path.exists(CREDS):
        pw = open(CREDS).read().strip()
    if not pw:
        sys.exit("No workload password: set $WORKLOAD_PASSWORD or create ../../.workload.creds")
    return pw


def cursor():
    conn = connect(host=HOST, port=PORT, use_ssl=True, use_http_transport=True,
                   http_path=HTTP_PATH, auth_mechanism="LDAP", user=USER, password=password())
    return conn, conn.cursor()


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "verify"
    conn, cur = cursor()
    try:
        if action == "create":
            raw = open(DDL).read()
            for chunk in raw.split(";"):
                stmt = "\n".join(l for l in chunk.splitlines()
                                 if not l.strip().startswith("--")).strip()
                if stmt:
                    print(f">>> {stmt.splitlines()[0][:80]}")
                    cur.execute(stmt)
            print(f"Table {TABLE} ready (STORED BY ICEBERG).")
        elif action == "verify":
            cur.execute(f"SELECT count(*) FROM {TABLE}")
            print(f"{TABLE} row count:", cur.fetchall()[0][0])
        else:
            sys.exit(f"unknown action {action!r} (use: create | verify)")
    finally:
        cur.close()
        conn.close()


if __name__ == "__main__":
    main()
