# fogops database inside this project

`README.md` (next to this file) is the teammate's handover guide for the database design. It was written for a
standalone `rebuild.sh` flow; in this project the layout is different:

| Handover guide says | In this project |
|---|---|
| `sql/01..04_*.sql` applied by `rebuild.sh` | Flyway migrations `src/main/resources/db/migration/V2..V5` (applied when the app starts) |
| `./rebuild.sh <data_dir> fogops` (drops the DB!) | **not used.** Start the app once, then run `./load_data.sh` on the empty database |
| `loader/load_data.py` | `loader/load_data.py` with two changes: airport timezones come from `loader/airports.csv` (no `airportsdata` package, no silently dropped flights) and crew mobile numbers are **not** loaded (`crew_member.mobile` stays NULL) |
| `sql/05_demo_fog_replay.sql` (+ expected output) | `demo/` - the end-to-end test; run it with `psql -f` and compare with `05_demo_expected_output.txt` |
| source Excel files in one folder | `../../data/` (all 11 files, including the 08:48 OCC rotation) |

`loader/airports.csv` holds 430 airports (airportsdata 20250909, plus ALY/DHA/FRU from 20230906). The data uses both
`BSZ` and its legacy code `FRU` for Bishkek Manas; `FRU` has no ICAO because `airport.icao` is unique.
Known quirk in the demo script: the replacement-crew step picks `... WHERE verdict = 'CANDIDATE' LIMIT 1` without an
`ORDER BY`, so which equally valid standby crew member is chosen can differ between runs.

Search path: the migrations set `fogops, public` for the database and the app sets it per connection
(`spring.datasource.hikari.connection-init-sql`). Flyway itself keeps its history table in `public`.

Load order for a fresh environment: start the app (Flyway) -> `./load_data.sh` -> (optional) demo script.
The loader is not re-runnable; to start over, recreate the database.
