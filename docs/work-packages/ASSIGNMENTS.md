# Who does what: Shoaib, Datti, Somesh

Sizes: M = medium, L = large. The split balances size (about 7 to 8 units each, M = 2, L = 3) and puts the three packages that the new engine
facts depend on (WP-4, WP-5, WP-6) in the **first round on three different people**, so the integration (WP-7) is not waiting for one person.
Packages inside a round are independent, so two people can swap a package without breaking anything.

## Assignment

| Person | Round 1 | Round 2 | Round 3 |
|---|---|---|---|
| **Datti** (lead) | Step 0 baseline commit, then **WP-6** passenger risk (M) and **WP-0** parity kit (M) | **WP-7** engine integration (L; starts on stubs, merges when 4, 5, 6 are in) | WP-7 finish, release steps R1 to R7 on the shared database, final end-to-end run |
| **Shoaib** | **WP-4** stand and slot capacity (L) | **WP-1** live updates, stream and worker (M) | **WP-3** Ask assistant (L) |
| **Somesh** | **WP-5** fuel from history and fuel outlook (L) | **WP-2** recovery plan edits and what-if (M) | **WP-8** hardening and deployment (M) |

Load: Datti 7 plus lead duties (review, releases), Shoaib 8, Somesh 7.

Why this split:
- **Datti** built Phases 1 to 3 and the spec sync, so owns the baseline, the database releases and the engine integration (WP-7 edits the functions and `ConsoleService`
  that everyone else's work feeds). WP-0 is Datti's because the scratch-database method is the one already in use; everyone needs it from Round 2.
- **Shoaib** takes the stand capacity (the requirement with no data yet) in Round 1, then the Java-heavy live-update package, then Ask. WP-4 has a React screen; if Shoaib
  prefers, give that part to Omendra, who wrote the UI (the brief has a separate paste block for it).
- **Somesh** takes the data-analysis package (fuel from `hist.fuel`), which has the most unknowns, so it starts first. WP-2 is a straight port with a clear spec;
  WP-8 is last because it needs the other work merged to be tested end to end.
- These are assumptions about strengths from the repository history, not facts. Swap freely within a round.

## Sequence and what must happen first

1. **Before anything (Datti, today):** commit and push the baseline (see README, "Step 0"). Nobody can branch without it.
2. **Before Round 1 migrations (Datti asks Omendra once):** agree that new SQL goes in `backend/migrations/003` to `006` and is mirrored into Spring. WP-4, WP-5 and WP-6 each add one.
3. **Questions to answer in the first days (Datti collects the answers):**
   - WP-5: does "next leg" mean the leg being flown to SHJ and "leg + 1" the extra diversion leg? (the brief assumes yes)
   - WP-6: is there an official minimum connection time? If not, who supplies one?
   - WP-4: who supplies the real stand capacity for AAN, AUH, DWC, FJR, MCT, RKT (and for SHJ)? Until then the screen is empty and unknown capacity shows as "verify".
4. **Round 1** (all three in parallel): WP-4, WP-5, WP-6, and WP-0 (kit). Merge order inside the round: WP-0 first (it is small and helps Round 2), then the others as they finish.
5. **Round 2:** WP-1, WP-2 (both verified with the WP-0 kit) and WP-7 (Datti). WP-7 merges after WP-4, WP-5 and WP-6.
6. **Round 3:** WP-3, WP-8, and the release steps. WP-8's compose and README can start earlier when Somesh has a gap; its security review runs after everything has merged.

```
Round 1:  Datti WP-6 + WP-0   |  Shoaib WP-4          |  Somesh WP-5
Round 2:  Datti WP-7          |  Shoaib WP-1          |  Somesh WP-2
Round 3:  Datti release + QA  |  Shoaib WP-3          |  Somesh WP-8
```

## Review pairs (every package gets a second pair of eyes)

- Shoaib's packages are reviewed by Datti, Somesh's by Shoaib, Datti's by Somesh.
- A reviewer runs the parity kit (or the scratch-database check in the brief) and reads the pull request's list of deviations from FastAPI.

## Hand-off rules

- Each person pastes their package brief into their own Claude session, with "read `CLAUDE.md` first" (the briefs already say so).
- One branch per package, `wp<N>-<name>`, small pull requests, nothing committed straight to the shared branch.
- If a package changes a helper contract (README), post it in the team chat and tell Datti before merging, because WP-7 depends on it.
- Only Datti applies migrations to the shared database (`RELEASE-CHECKLIST.md`).
