# Iceberg REST Catalog on Cloudera — end-to-end demo

Prove that external engines can **read Apache Iceberg tables straight out of the Cloudera DataLake
Hive Metastore** through its embedded **Iceberg REST Catalog**, with no CDW and no copied
credentials. One catalog, many consumers: OSS Spark, AWS EMR Spark, Athena-for-Spark, Apache
Flink / SSB, and Apache NiFi all query the same shared tables over a Knox-fronted OAuth2 endpoint.

This repo is the scripts-and-artifacts companion to that build: stand up the environment, seed
Iceberg tables via Impala, enable the REST Catalog, and run each consumer against it.

## The one thing everything hangs on

The Iceberg REST service runs **inside the HMS JVM** (embedded Jetty), fronted by **Knox** for
auth (OAuth2 `client_credentials` → JWT; authorization via Apache Ranger). External clients hit:

```
https://<DL_GATEWAY_HOST>/<DL_NAME>/cdp-datashare-access/iceberg-rest/v1/…
```

Because the catalog lives in HMS, it serves exactly what HMS knows about — and a few constraints
are non-negotiable:

| Constraint | Why | What we do |
| :-- | :-- | :-- |
| **Runtime 7.3.2 GA** | REST Catalog / Data Sharing is a 7.3.2 GA feature | Pin the DataLake to `7.3.2` |
| **Single IDBroker** | IDBroker HA breaks credential vending | `LIGHT_DUTY` DataLake (never `ENTERPRISE`/HA) |
| **`CDP_DATA_SHARE_ADMIN` entitlement** | Gates the data-share feature | Enabled tenant-wide before deploy; `DataShareAdmin` role per env |
| **`client.region`** when the bucket ≠ `us-west-2` | Clients otherwise get an HTTP 301 | Set `client.region` in the HMS safety valve **and** on every client |
| **Base SDX has no query engine** | The DataLake HMS can't run `CREATE`/`INSERT` | Add an **Impala Data Hub** to seed the Iceberg tables |
| **The data share vends *read-only* S3 creds** | By design | Reads work anywhere; writes go through Impala (see below) |

## Architecture

```
                        ┌──────────────── CDP Public Cloud (Runtime 7.3.2) ───────────────┐
                        │                                                                  │
  Impala Data Hub  ─────┼──► DataLake HMS  ──►  Iceberg REST Catalog (embedded in HMS JVM) │
  (seeds + writes)      │      (tables live here)         │  fronted by Knox (OAuth2/JWT)  │
                        └─────────────────────────────────┼──────────────────────────────┘
                                                           │  https://…/iceberg-rest/v1/
        ┌──────────────────────┬───────────────────┬──────┴───────┬────────────────────┐
        ▼                      ▼                   ▼               ▼                    ▼
   OSS Spark (k8s)       EMR Spark            Athena-for-Spark   Flink / SSB          NiFi
   k8s/                  (same conf)          athena/            flink/               nifi/
                                                                             (InvokeHTTP · GetIceberg · QueryIceberg)
```

Reads use IDBroker-vended S3 STS credentials, unlocked by the
`X-Iceberg-Access-Delegation: vended-credentials` header on `loadTable`. Writes never touch the
read datashare: they route through Impala, the authoritative HMS Iceberg writer
(`nifi/write-dbcp-impala/`).

## Repo layout

| Path | What it is |
| :-- | :-- |
| `test-rest-catalog.sh` | **Start here.** Read-only validation: JWT exchange → list namespaces → list tables → load a table (shows vended-cred keys). Never modifies CDP. |
| `redeploy.sh` | Full unattended rebuild of everything a weekly reaper destroys — env + DataLake + Impala Data Hub, seed tables, enable REST Catalog, create external users, share tables, validate (~1h40m). |
| `seed-impala.py` | Seed an Iceberg table into HMS via Impala over Knox (LDAP workload auth). |
| `sql/` | Table DDL + seed data: `airlines` (3 rows), `flights` (120k rows, 12 monthly partitions for manifest-pruning demos), `nifi_sink`. |
| `k8s/` | OSS Spark reading the REST Catalog as a Kubernetes `Job` (`apache/spark:3.5.3`). |
| `athena/` | Athena-for-Spark calculation (`.py` + notebook) using the same catalog config block as OSS/EMR Spark. |
| `flink/` | Flink / SSB (CSA) — a Dockerfile that layers the Iceberg + hadoop runtime jars (fetched separately; gitignored) onto the Cloudera Flink image. |
| `nifi/` | NiFi read paths — `InvokeHTTP` (zero-dependency), and native `GetIceberg` / `QueryIceberg` (predicate + projection pushdown) — plus build/run scripts, the `jackson-fix/` NAR recipe, and the `write-dbcp-impala/` write leg. |

## Prerequisites

- A CDP Public Cloud environment on **Runtime 7.3.2** with a `LIGHT_DUTY` DataLake and an **Impala
  Data Hub**, the REST Catalog enabled, and a **data share** activated for an external user.
  `redeploy.sh` builds all of this from a `cdp-tf-quickstarts` Terraform base.
- CLI tools: `curl`, `jq`, `python3` with `impyla` (for `seed-impala.py`), and `aws` + `cdp` CLIs
  for `redeploy.sh`.
- **Credentials you supply locally (all gitignored — never committed):**
  - `credentials.json` — the external user's REST-catalog OAuth client: `{ "clientId", "secret", "username" }`.
  - `.workload.creds` — a one-line CDP **workload password** (for Impala LDAP), or set `$WORKLOAD_PASSWORD`.
  - `config.env` — environment/DataLake CRNs, written by `redeploy.sh`.

Coordinates (gateway host, DataLake name, S3 warehouse) are set at the top of each script and in
`nifi/*.env`. They are specific to a given deployment — update them when you rebuild.

## Quickstart

```bash
# 1. Verify the REST Catalog is live and readable (read-only, safe to run anytime)
bash test-rest-catalog.sh poc_uc2 airlines

# 2. (Re)seed tables via Impala if needed
WORKLOAD_PASSWORD=… python seed-impala.py sql/seed-airlines.sql

# 3. Run a consumer — e.g. OSS Spark on Kubernetes
kubectl create secret generic cdp-jwt --from-literal=token="$FRESH_KNOX_JWT" -n iceberg-demo
kubectl apply -f k8s/spark-iceberg-job.yaml
```

Each consumer directory (`athena/`, `flink/`, `nifi/`) is self-contained; the NiFi write leg has
its own [`nifi/write-dbcp-impala/README.md`](nifi/write-dbcp-impala/README.md).

## Secret hygiene

Knox JWTs are short-lived — fetch them **fresh at submit time** and never commit a populated
token. All credential files, PEM/CRT/KEY material, `config.env`, logs, and the large Flink
dependency jars are gitignored. Nothing in version control contains a secret.
