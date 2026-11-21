// Small pure helpers on top of v_flight_watch rows.
export const CREW_RANK = {
  EXCEEDED: 0,
  DISCRETION_REQUIRED: 1,
  VERIFICATION_REQUIRED: 2,
  AT_RISK: 3,
  LEGAL: 4,
};
export const REC_TO_DECISION = {
  HOLD: 'HOLD',
  DIVERT: 'DIVERT',
  RECOVER: 'RECOVER',
  CREW_REPLACE: 'CREW_REPLACE',
  DELAY_DEPARTURE: 'DELAY',
  MONITOR: 'OTHER',
  NO_ACTION: 'OTHER',
};
export const DECISION_TYPES = [
  'HOLD',
  'DIVERT',
  'RECOVER',
  'CANCEL',
  'DELAY',
  'CREW_REPLACE',
  'COMMANDER_DISCRETION',
  'AIRCRAFT_SWAP',
  'OVERRIDE',
  'OTHER',
];

export const needsAttention = (f) =>
  Boolean(f.recommendation && f.recommendation !== 'NO_ACTION') ||
  ['AT_RISK', 'EXCEEDED', 'DISCRETION_REQUIRED'].includes(f.crew_status) ||
  f.is_holding ||
  Boolean(f.diverted_to);

// Lower = more urgent: illegal crew first, then least margin.
export const urgency = (f) => [CREW_RANK[f.crew_status] ?? 5, f.crew_margin_min ?? 9999];
export const byUrgency = (a, b) => {
  const [ra, ma] = urgency(a);
  const [rb, mb] = urgency(b);
  return ra - rb || ma - mb;
};
export const ms = (iso) => (iso ? Date.parse(iso) : null);

// Scenario clock: replays run on a fixed simulated time, LIVE on the wall clock. The UI ticks the replay
// clock forward from page load so event timestamps stay unique and ordered.
let T0 = Date.now();
let lastBase = null;
export const simBase = (kase) => (kase?.sim_clock_utc ? Date.parse(kase.sim_clock_utc) : null);
// When the server moves the scenario clock (a feed push), count the elapsed time from the moment we saw the new value.
export const scenarioNowMs = (kase) => {
  const base = simBase(kase);
  if (base == null) return Date.now();
  // a PAUSED scenario clock stands still in the database, so it stands still on the screen too (same time in both places)
  if (kase.clock_running === false) return base;
  if (base !== lastBase) {
    lastBase = base;
    T0 = Date.now();
  }
  return base + (Date.now() - T0);
};
// DB view filters use the FIXED scenario clock (effective_from <= scenario_now), so status/fuel rows use this one.
export const stampMs = (kase) => simBase(kase) ?? Date.now();
export const iso = (msv) => new Date(msv).toISOString();
