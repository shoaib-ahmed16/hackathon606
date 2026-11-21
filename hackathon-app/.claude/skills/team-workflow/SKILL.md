---
name: team-workflow
description: Git and collaboration rules for parallel hackathon work -- branching, small commits, avoiding merge conflicts in shared files, PR checklist. Use when committing, creating branches/PRs, or splitting work between developers.
---

# Team workflow

- **Branches**: `feat/<short-name>` per person per feature, branched from the latest `main`; merge back often (every 30-60 min). Small PRs beat big ones.
- **Commits**: imperative and specific (`Add products CRUD page`). Run `npm run check` first. Never commit `.env`, `node_modules`, `dist`.
- **Conflict hotspots** (everyone touches them -> one-line edits, pull before editing, commit right after):
  `src/routes/index.jsx` (one lazy import + one `<Route>`), `src/config/navigation.jsx` (one item), `src/app/store.js` (one reducer line), `src/theme/*`, `package.json`/`package-lock.json` (announce new dependencies in chat; on lockfile conflict take main's and re-run `npm i`).
- **Own your folders**: each feature lives in `src/features/<x>/` + `src/pages/<X>.jsx`; avoid editing someone else's feature files.
- **Shared look**: change colors/fonts only in `src/theme/` and tell the team.
- **PR checklist**: lint + build pass; checked light/dark + both layouts (`verify-ui`); no `console.log`; new env vars in `.env.example`; screenshots for UI PRs.
