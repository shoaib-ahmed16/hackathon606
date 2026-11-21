#!/usr/bin/env bash
# Rebuild the FogOps database from the Excel files and write backend/db/init/10_fogops.sql.gz,
# which the compose db service restores on its first start.
# Usage: PGHOST=127.0.0.1 PGPORT=5433 PGUSER=postgres PGPASSWORD=... ./scripts/make_db_dump.sh ./Hack606_Fog_Ops
set -euo pipefail
DATA=${1:?path to the Hack606_Fog_Ops folder}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DB=fogops_dump
export FOGOPS_DSN="${FOGOPS_DSN:-postgresql://${PGUSER:-postgres}:${PGPASSWORD:-postgres}@${PGHOST:-127.0.0.1}:${PGPORT:-5432}/$DB}"
"$HERE/fogops_db/rebuild.sh" "$DATA" "$DB"
psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$HERE/fogops_db/sql/05_demo_fog_replay.sql" >/dev/null
# the demo leaves reassessment jobs behind; clear them or the API worker would recompute thousands on first start
psql -d "$DB" -q -c "UPDATE fogops.reassessment_queue SET status='DONE', done_at=now(), error='baseline: cleared before dump' WHERE status IN ('PENDING','RUNNING')"
mkdir -p "$HERE/db/init"
pg_dump -d "$DB" --no-owner --no-privileges -Fp | gzip -9 > "$HERE/db/init/10_fogops.sql.gz"
ls -la "$HERE/db/init"
