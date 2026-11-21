#!/usr/bin/env bash
# Install a new database drop from the DB team and rebuild the seed that the server restores. One command, no manual steps.
#
#   backend/scripts/install_db_drop.sh ~/Downloads/fogops_db\ \(4\).zip        (or a folder)
#
# What it does
#   1. unpacks the drop and shows which files differ from what is installed (sql, loader, docs)
#   2. replaces backend/fogops_db/sql and loader with the drop (docs and test files are copied too)
#   3. starts a throwaway Postgres 16 container, builds the database from the SQL + the Excel files, runs the demo replay,
#      and writes backend/db/init/10_fogops.sql.gz  (this is the seed a fresh database restores)
#   4. restores that seed into a clean database and applies OUR migrations (backend/migrations) on top, to prove they still fit
#   5. prints what to commit and run on the server
# Needs: docker, psql/pg_dump on this machine. Takes about 3 minutes (the loader reads 25 MB of Excel).
set -euo pipefail
SRC=${1:?usage: install_db_drop.sh <fogops_db.zip | folder>}
BACK="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; PGC=fooh-seed-pg; PORT=${SEED_PG_PORT:-55432}
cleanup() { docker rm -f "$PGC" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

echo "== 1. unpack"
if [ -d "$SRC" ]; then cp -r "$SRC" "$TMP/x"; else mkdir "$TMP/x"; unzip -q "$SRC" -d "$TMP/x"; fi
DROP="$(find "$TMP/x" -maxdepth 3 -type f -name 01_schema.sql -printf '%h\n' | head -1 | xargs -r dirname)"
[ -n "$DROP" ] && [ -f "$DROP/sql/04_seed_reference.sql" ] && [ -f "$DROP/loader/load_data.py" ] || { echo "not a DB drop: sql/ and loader/ not found in $SRC"; exit 1; }
echo "changed files vs installed backend/fogops_db:"
( cd "$DROP" && find . -type f | sort ) | while read -r f; do
  if [ ! -f "$BACK/fogops_db/$f" ]; then echo "  NEW      $f"; elif ! cmp -s "$DROP/$f" "$BACK/fogops_db/$f"; then echo "  CHANGED  $f"; fi
done
echo "  (everything else is identical)"

echo "== 2. install"
rm -rf "$BACK/fogops_db/sql" "$BACK/fogops_db/loader"
cp -r "$DROP"/. "$BACK/fogops_db/"

echo "== 3. build the seed in a throwaway Postgres"
docker rm -f "$PGC" >/dev/null 2>&1 || true
docker run -d --name "$PGC" -e POSTGRES_PASSWORD=seed -p 127.0.0.1:$PORT:5432 postgres:16 >/dev/null
for i in $(seq 1 40); do docker exec "$PGC" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
export PGHOST=127.0.0.1 PGPORT=$PORT PGUSER=postgres PGPASSWORD=seed; unset FOGOPS_DSN
sleep 2
"$BACK/scripts/make_db_dump.sh" "$BACK/Hack606_Fog_Ops" > "$TMP/dump.log" 2>&1 || { tail -30 "$TMP/dump.log"; echo "BUILD FAILED"; exit 1; }
grep -E "flights:|duties:|pax connections:|legality computed|DONE" "$TMP/dump.log" | sed 's/^/  /'

echo "== 4. restore the seed, apply our migrations on top"
psql -v ON_ERROR_STOP=1 -q -d postgres -c "DROP DATABASE IF EXISTS fogops_verify" -c "CREATE DATABASE fogops_verify"
psql -d fogops_verify -q -c "ALTER DATABASE fogops_verify SET search_path = fogops, public"
gunzip -c "$BACK/db/init/10_fogops.sql.gz" | psql -v ON_ERROR_STOP=1 -q -d fogops_verify >/dev/null
psql -q -d fogops_verify -f "$BACK/db/init/20_cases.sql" >/dev/null
docker build -q -t fooh-api-check "$BACK" >/dev/null
docker run --rm --network host -e FOGOPS_DSN="postgresql://postgres:seed@127.0.0.1:$PORT/fogops_verify" -e AUTH_SECRET=verify fooh-api-check python -c "
from app import migrate; r = migrate.run(); print('  migrations applied:', len(r['applied']), '| current:', r['current'], '| mismatched:', r['mismatched'])
assert not r['mismatched']"
psql -tA -d fogops_verify -c "select '  flights '||(select count(*) from fogops.flight)||', crew '||(select count(*) from fogops.crew_member)||', cases '||(select count(*) from fogops.disruption_case)||', pax connections '||(select count(*) from fogops.pax_connection)"

echo
echo "== DONE. Next:"
echo "   git add -A backend && git commit -m 'new DB drop' && git push"
echo "   on the server:  cd /home/opc/hackathon606 && git pull && ./reset-db.sh"
echo "   (reset-db.sh deletes the server's database and restores this seed, then the API applies the migrations)"
