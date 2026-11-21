---
name: verify-ui
description: Verify UI changes actually work before saying done -- lint, build, run the app, check light/dark and both layouts, mobile width, console errors, and the main flow. Use after any UI change and before commits/PRs.
---

# Verify UI

1. `npm run check` -- must be clean.
2. Run the app (`npm run dev`) and open the changed screens. For automated checks use the `webapp-testing` skill (Playwright; `scripts/with_server.py --server "npm run dev" --port 3000 -- python check.py`). Always `wait_for_load_state('networkidle')` first.
3. Pre-authenticate scripts by seeding storage instead of typing in the login form:
   `localStorage.setItem('auth', JSON.stringify({ user: { name: 'Test' }, token: 'x' }))`, then reload. Real login: `emilys` / `emilyspass`.
4. Checklist -- look at screenshots, don't assume:
   - Light AND dark (`localStorage.mode = 'dark' | 'light'`), sidebar AND top layout (`localStorage.layout = 'sidebar' | 'topbar'`), collapsed sidebar (`sidebarCollapsed = 'true'`).
   - Desktop (1280px) and phone (390px); no horizontal scroll.
   - No console errors/warnings from our code (the missing-favicon 404 in dev is fine).
   - Loading, error and empty states render; actions give toast feedback; destructive actions confirm.
   - Text uses theme typography; no hardcoded colors.
5. If the layout looks broken (missing flex/padding/min-height): MUI 9 removed system props -> use `sx`.
6. Tooltips must stay non-interactive (theme default) or they can swallow clicks on neighbouring buttons.
