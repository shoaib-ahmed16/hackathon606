#!/usr/bin/env bash
# Rebuild the database from scratch and load the provided files.
# Usage: ./rebuild.sh <data_dir> [dbname]
set -euo pipefail
DATA_DIR=${1:?data dir}; DB=${2:-fogops}
HERE="$(cd "$(dirname "$0")" && pwd)"
PSQL="psql -v ON_ERROR_STOP=1 -q"
$PSQL -d postgres -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB"
$PSQL -d "$DB" -c "ALTER DATABASE $DB SET search_path = fogops, public"
for f in 01_schema 02_functions_triggers 03_views 04_seed_reference; do
  echo "applying $f"; $PSQL -d "$DB" -f "$HERE/sql/$f.sql"
done
python3 "$HERE/loader/load_data.py" --data-dir "$DATA_DIR" --dsn "${FOGOPS_DSN:-postgresql://${PGUSER:-postgres}@${PGHOST:-127.0.0.1}:${PGPORT:-5432}/$DB}"
