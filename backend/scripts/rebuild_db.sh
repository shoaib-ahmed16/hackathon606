#!/usr/bin/env bash
# Build a database from the DB team's baseline (../fogops_db) and the Excel files: schema, functions, views, reference seed, then the loader.
# This lives outside fogops_db/ on purpose, so installing a new drop from the DB team (a plain overwrite of fogops_db/) never loses it.
# Usage: scripts/rebuild_db.sh <data_dir> [dbname]      (PGHOST/PGPORT/PGUSER/PGPASSWORD or FOGOPS_DSN, as for psql)
set -euo pipefail
DATA_DIR=${1:?data dir (the Hack606_Fog_Ops folder)}; DB=${2:-fogops}
BASE="$(cd "$(dirname "$0")/../fogops_db" && pwd)"
PSQL="psql -v ON_ERROR_STOP=1 -q"
$PSQL -d postgres -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB"
$PSQL -d "$DB" -c "ALTER DATABASE $DB SET search_path = fogops, public"
for f in 01_schema 02_functions_triggers 03_views 04_seed_reference; do
  echo "applying $f"; $PSQL -d "$DB" -f "$BASE/sql/$f.sql"
done
DSN="${FOGOPS_DSN:-postgresql://${PGUSER:-postgres}:${PGPASSWORD:-}@${PGHOST:-127.0.0.1}:${PGPORT:-5432}/$DB}"
if python3 -c "import pandas, openpyxl, xlrd, psycopg2, airportsdata" 2>/dev/null; then
  python3 "$BASE/loader/load_data.py" --data-dir "$DATA_DIR" --dsn "$DSN"
else
  # no Python packages on this machine: run the loader in a throwaway container (needs docker; reaches the DB over the host network)
  echo "python packages missing: running the loader in a docker container"
  docker run --rm --network host -v "$BASE/loader":/loader:ro -v "$(cd "$DATA_DIR" && pwd)":/data:ro python:3.12-slim sh -c \
    "pip install -q pandas openpyxl xlrd psycopg2-binary airportsdata >/dev/null 2>&1 && python /loader/load_data.py --data-dir /data --dsn '$DSN'"
fi
