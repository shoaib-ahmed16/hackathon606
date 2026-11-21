#!/usr/bin/env bash
# Wipe the Foooh! database and rebuild it from backend/db/init (the seed built from the Excel files by the loader, plus the daily cases); the API then applies backend/migrations on first start.
# Run from the project folder on the server:   ./reset-db.sh        (add --yes to skip the question)
# WARNING: this deletes every decision, comment and case created since the last reset.
set -euo pipefail
cd "$(dirname "$0")"
if [ "${1:-}" != "--yes" ]; then
  read -r -p "This deletes ALL Foooh! data (decisions, comments, cases you created). Type RESET to continue: " a
  [ "$a" = "RESET" ] || { echo "aborted"; exit 1; }
fi
test -f backend/db/init/10_fogops.sql.gz || { echo "backend/db/init/10_fogops.sql.gz is missing: copy the project again"; exit 1; }
docker compose down
docker volume rm "$(basename "$PWD" | tr 'A-Z' 'a-z')_fogops-data" 2>/dev/null || docker volume rm hackathon_fogops-data
docker compose up -d --build
echo "Waiting for the database to restore (1 to 2 minutes)..."
for i in $(seq 1 60); do
  if curl -fs http://localhost:${API_PORT:-8888}/health 2>/dev/null | grep -q '"schema":"current"'; then echo "Ready: schema is current."; docker compose ps; exit 0; fi
  sleep 3
done
echo "Not ready yet. Check: docker compose ps  and  docker compose logs db | tail -30"; exit 1
