#!/usr/bin/env bash
set -euo pipefail
DEMO="$HOME/Documents/GitHub/iceberg-rest-catalog-demo"
TRINO="$HOME/Documents/GitHub/trino-demo"

# Leg 0 — full teardown (unattended, no confirmation gate).
# Cleans CDW clusters by environmentCrn (catches Error-state orphans), purges IAM orphans,
# destroys terraform state. Safe whether state is empty or full.
TEARDOWN_UNATTENDED=1 bash "$DEMO/teardown.sh"

# Leg 1 — full REST Catalog rebuild (~1h40m). Reads tfvars: semi-private + bumped enddate.
bash "$DEMO/redeploy.sh"

# Leg 2 — Trino VW (~15m). Refresh env_crn from the fresh config.env, then provision.
. "$DEMO/config.env"                                                              # fresh ENV_CRN (redeploy step 2/6)
sed -i '' "s|env_crn: .*|env_crn: \"$ENV_CRN\"|" "$TRINO/provision-trino-vw.yml"  # BSD sed (macOS)
source "$HOME/.venvs/clouderacloud/bin/activate"
( cd "$TRINO" && ansible-playbook provision-trino-vw.yml -v )

echo "== MONDAY REDEPLOY COMPLETE: REST Catalog + Trino VW both live =="
