import { createSlice } from '@reduxjs/toolkit';

// remember the selected case across reloads
const saved = (() => {
  try {
    return JSON.parse(localStorage.getItem('opsCase')) ?? {};
  } catch {
    return {};
  }
})();

const persist = (s) => {
  try {
    localStorage.setItem(
      'opsCase',
      JSON.stringify({
        scenarioId: s.scenarioId,
        caseId: s.caseId,
        lens: s.lens,
        showSources: s.showSources,
        lastSeenAt: s.lastSeenAt,
      }),
    );
  } catch {
    /* ignore */
  }
};

// Client-only state: which case we are looking at, who is acting, which flight is open.
// Everything operational (flights, crew, decisions, audit) lives in the Foooh! database.
const opsSlice = createSlice({
  name: 'ops',
  initialState: {
    scenarioId: saved.scenarioId ?? null,
    caseId: saved.caseId ?? null,
    selectedFlightId: null,
    lens: saved.lens ?? 'occ', // occ | dispatch | crew | station | recovery
    briefing: true, // the 'since you last looked' box above the board
    panel: null, // 'ask' | 'approvals' | 'whatif' | null
    showSources: Boolean(saved.showSources),
    lastSeenAt: saved.lastSeenAt ?? null, // for the 'since you last looked' briefing
    ready: false, // the console's first data has loaded: the fog loader lifts when this is true
    refreshedAt: Date.now(), // the last time the screens were refreshed (timer, button, an action or a live event): re-arms the one auto-refresh timer
  },
  reducers: {
    selectCase: (s, { payload }) => {
      s.scenarioId = payload.scenario_id;
      s.caseId = payload.case_id;
      s.selectedFlightId = null;
      persist(s);
    },
    setLens: (s, { payload }) => {
      s.lens = payload;
      persist(s);
    },
    openPanel: (s, { payload }) => void (s.panel = payload),
    closePanel: (s) => void (s.panel = null),
    toggleBriefing: (s) => void (s.briefing = !s.briefing),
    toggleSources: (s) => {
      s.showSources = !s.showSources;
      persist(s);
    },
    markSeen: (s, { payload }) => {
      s.lastSeenAt = payload;
      persist(s);
    },
    selectFlight: (s, { payload }) => void (s.selectedFlightId = payload),
    refreshed: (s, { payload }) => void (s.refreshedAt = payload ?? Date.now()),
    setReady: (s, { payload }) => void (s.ready = payload),
  },
});

export const { selectCase, selectFlight, setLens, openPanel, closePanel, toggleSources, toggleBriefing, markSeen, refreshed, setReady } =
  opsSlice.actions;
export const selectOps = (s) => s.ops;
export default opsSlice.reducer;
