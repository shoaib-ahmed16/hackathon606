#!/usr/bin/env bash
# Fills the fogops schema from the Excel files in ../../data.
# Run it ONCE on an empty database, after the Spring Boot app has started (Flyway creates the schema, functions,
# views and seed data on startup). It never drops anything. Connection settings come from the same DB_* variables
# as the app (defaults match application.yml), or set FOGOPS_DSN (libpq "key=value" or URL form).
#
#   pip install -r requirements.txt
#   ./load_data.sh [data_dir]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${1:-$HERE/../../data}"
DSN="${FOGOPS_DSN:-host=${DB_HOST:-127.0.0.1} port=${DB_PORT:-5432} dbname=${DB_NAME:-hackathon_yashasvi} user=${DB_USERNAME:-postgres} password=${DB_PASSWORD:-postgres}}"

python3 - "$DSN" <<'PY'
import sys, psycopg2
try:
    cur = psycopg2.connect(sys.argv[1]).cursor()
    cur.execute("SELECT to_regclass('fogops.flight') IS NOT NULL")
    if not cur.fetchone()[0]:
        sys.exit("fogops schema not found - start the Spring Boot app once so Flyway creates it, then re-run.")
    cur.execute("SELECT count(*) FROM fogops.flight")
    if cur.fetchone()[0] > 0:
        sys.exit("fogops.flight already has rows - the loader is not re-runnable. "
                 "Recreate the database (or truncate the fogops/hist tables) before loading again.")
except psycopg2.OperationalError as e:
    sys.exit(f"cannot connect: {e}")
PY

python3 "$HERE/loader/load_data.py" --data-dir "$DATA_DIR" --dsn "$DSN"
