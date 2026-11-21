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
const T0 = Date.now();
export const simBase = (kase) => (kase?.sim_clock_utc ? Date.parse(kase.sim_clock_utc) : null);
export const scenarioNowMs = (kase) =>
  simBase(kase) != null ? simBase(kase) + (Date.now() - T0) : Date.now();
// DB view filters use the FIXED scenario clock (effective_from <= scenario_now), so status/fuel rows use this one.
export const stampMs = (kase) => simBase(kase) ?? Date.now();
export const iso = (msv) => new Date(msv).toISOString();
