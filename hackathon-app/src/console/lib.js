// Domain helpers for the Foooh! console: labels, tones and the "what is happening to this flight" wording.
// Pure functions over the rows the API returns (v_flight_watch + severity + tags); no React in here.
import { fmtDay, fmtZ, fmtTime, MIN } from '@/features/ops/time';
import { ms } from '@/features/ops/helpers';

export { fmtZ, fmtTime, MIN, ms };
export const ROLE_LABEL = {
  OCC: 'OCC',
  DISPATCH: 'Dispatch',
  CREW_CONTROL: 'Crew Control',
  STATION: 'Station',
  RECOVERY: 'Recovery',
  ADMIN: 'Admin',
  AGENT: 'Engine',
};
export const roleLabel = (r) => ROLE_LABEL[r] ?? String(r ?? '').replaceAll('_', ' ');
export const TYPE_LABEL = {
  DIVERT: 'Divert',
  HOLD: 'Hold',
  DELAY: 'Delay departure',
  RECOVER: 'Depart alternate',
  COMMANDER_DISCRETION: 'Commander discretion',
  CREW_REPLACE: 'Crew replacement',
  CANCEL: 'Cancel',
  AIRCRAFT_SWAP: 'Aircraft swap',
  OVERRIDE: 'Override',
  OTHER: 'Other',
};
export const typeLabel = (t) => TYPE_LABEL[t] ?? String(t ?? '').replaceAll('_', ' ').toLowerCase();
export const human = (code) => String(code ?? '').replaceAll('_', ' ').toLowerCase();

// Engine codes in words a duty manager reads. Anything not listed is still turned into lower-case words, never shown as CODE_LIKE_THIS.
const CODE_WORDS = {
  ENDURANCE_ENDS_BEFORE_REOPENING: 'fuel runs out before the airport reopens',
  CREW_NOT_LVP_QUALIFIED_FOR_HUB: 'the crew is not LVP-qualified for the hub',
  CREW_NOT_LVP_QUALIFIED_FOR_ALTERNATE: 'the crew is not LVP-qualified for this alternate',
  REOPENING_TIME_UNKNOWN: 'the reopening time is not known',
  FLIGHT_FEED_STALE: 'the flight data is out of date',
  PROJECTED_END_UNKNOWN: 'the landing time is not known',
  CANNOT_REACH_WITH_FUEL: 'not enough fuel to reach it',
  FUEL_ENDURANCE_UNKNOWN: 'fuel endurance is not known',
  ALTERNATE_STATUS_UNKNOWN: 'the alternate has not been confirmed',
  ALTERNATE_NOT_OPEN: 'the alternate is not open',
  WEATHER_BELOW_MINIMA: 'weather is below minima',
  WEATHER_UNCONFIRMED: 'weather is not confirmed',
  NO_PARKING: 'no parking stands left',
  PARKING_UNCONFIRMED: 'parking is not confirmed',
  NO_FUEL_AT_ALTERNATE: 'no fuel at the alternate',
  NO_HANDLING: 'no handling agent',
  TIME_BASE_INCONSISTENT: 'the times do not add up: verify',
  FLIGHT_NOT_DIVERTIBLE: 'the flight cannot divert any more',
  SHEET_DISAGREES_WITH_RULESET: 'the duty sheet disagrees with the approved rule',
};
export const plainCodes = (s = '') => String(s).replace(/\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b/g, (c) => CODE_WORDS[c] ?? human(c));
// one short sentence for a proposal: what, and the first plain reason. The engine's full text stays behind "Why?"
export const plainProposal = (opt, rationale) => {
  const hold = /Hold not feasible: ([A-Z_]+)/.exec(rationale ?? '');
  const lead = (opt.why?.[0] ?? '').split(' (')[0].replace(/\.$/, '');
  return [opt.what, [hold ? `holding is not possible: ${plainCodes(hold[1])}` : '', plainCodes(lead)].filter(Boolean).join('; ')].filter(Boolean).join(': ') + '.';
};
export const REASONS = [
  'Station capacity',
  'ATC restriction',
  'Crew preference',
  'Commercial / connections',
  'Medical / priority',
  'Fuel information',
  'Other',
];
export const TAG_LABEL = { MEDICAL: 'Medical', VIP: 'VIP', HIGH_IMPACT: 'High impact' };

// time to a deadline -> colour word used across the board (same thresholds as the mockup)
export const minsTo = (at, now) => (at == null ? null : Math.floor((at - now) / MIN));
export const toneFor = (at, now) => {
  if (at == null) return 'verify';
  const m = minsTo(at, now);
  return m < 15 ? 'exceeded' : m < 45 ? 'risk' : 'legal';
};

export const isRecovered = (f) => ['LANDED', 'ON_BLOCKS'].includes(f.status) && !f.diverted_to;
export const isAirborne = (f) => ['AIRBORNE', 'HOLDING', 'DIVERTING'].includes(f.status);

// The five live statuses the board filters on.
export const LIVE_STATUSES = ['Airborne', 'Holding', 'Diverting', 'At alternate', 'Not departed', 'Recovered'];
export function liveLabel(f) {
  if (f.status === 'CANCELLED') return 'Cancelled';
  if (f.status === 'HOLDING') return 'Holding';
  if (f.diverted_to && f.status === 'DIVERTING') return 'Diverting';
  if (f.diverted_to) return 'At alternate';
  if (isRecovered(f)) return 'Recovered';
  if (isAirborne(f)) return 'Airborne';
  return 'Not departed';
}

// [headline, detail] of where the aircraft is and what it is waiting for
export function whereText(f) {
  const eta = ms(f.eta_utc ?? f.sta_utc);
  if (f.status === 'CANCELLED') return ['Cancelled', ''];
  // right after a diversion is executed the aircraft is still flying there: it is not "on the ground" until it lands
  if (f.diverted_to && f.status === 'DIVERTING')
    return [`Diverting to ${f.diverted_to}`, `Landing about ${fmtZ(eta)}`];
  if (f.diverted_to)
    return [
      `On ground at ${f.diverted_to}`,
      f.waiting_for ? `Waiting for ${human(f.waiting_for)}` : `Diverted from ${f.planned_arr_iata}`,
    ];
  if (f.status === 'HOLDING')
    return [
      `Holding near ${f.current_dest_iata}`,
      `${f.holding_since_utc ? `Since ${fmtZ(ms(f.holding_since_utc))} · ` : ''}ETA ${fmtZ(eta)}`,
    ];
  if (isRecovered(f)) return [`On blocks at ${f.current_dest_iata}`, f.ata_utc ? `Landed ${fmtZ(ms(f.ata_utc))}` : ''];
  if (isAirborne(f)) return ['Airborne', `ETA ${fmtZ(eta)}`];
  return [`On ground at ${f.dep_iata}`, `STD ${fmtZ(ms(f.std_utc))}`];
}

export function recWhat(f) {
  const r = f.recommendation;
  if (!r) return null;
  if (r === 'HOLD') return 'Keep holding';
  if (r === 'DIVERT') return f.recommended_alternate ? `Divert to ${f.recommended_alternate}` : 'Divert';
  return REC_LABEL[r] ?? human(r).replace(/^./, (c) => c.toUpperCase());
}
// the engine's seven recommendation types in plain words
export const REC_LABEL = {
  NO_ACTION: 'Continue as planned',
  MONITOR: 'Watch, no action yet',
  HOLD: 'Keep holding',
  DIVERT: 'Divert',
  DELAY_DEPARTURE: 'Delay departure',
  RECOVER: 'Depart the alternate',
  CREW_REPLACE: 'Replace the crew',
};
export const REC_TONE = { NO_ACTION: 'legal', MONITOR: 'verify', HOLD: 'risk', DIVERT: 'exceeded', DELAY_DEPARTURE: 'risk', RECOVER: 'ai', CREW_REPLACE: 'disc' };

// "03:23Z", or "22 Nov 03:23Z" when that moment is not on the same UTC day as `now` (live cases span several days)
const dayOf = (t) => new Date(t).toISOString().slice(0, 10);
export const fmtZday = (t, now) => (t == null ? '-' : dayOf(t) === dayOf(now) ? fmtZ(t) : `${fmtDay(t)} ${fmtZ(t)}`);

export const sevClass = (v) => (v >= 50 ? 'sev-h' : v >= 30 ? 'sev-m' : 'sev-l');
export const sevWord = (v) => (v >= 50 ? 'High' : v >= 30 ? 'Medium' : 'Low');

export const crewTone = (margin) => (margin == null ? 'verify' : margin < 0 ? 'disc' : margin < 60 ? 'risk' : 'legal');
export const verdictPill = { LEGAL: 't-legal', AT_RISK: 't-risk', DISCRETION_REQUIRED: 't-disc', EXCEEDED: 't-exceeded', VERIFICATION_REQUIRED: 't-verify' };

// the "?" gaps of a flight, from what the API already tells us
export function gapsOf(f, { fuelEnd, openRequests = [] } = {}) {
  const g = [];
  if (isAirborne(f) && !f.diverted_to && fuelEnd == null)
    g.push({
      field: 'FUEL_ENDURANCE',
      label: 'Fuel endurance not available',
      sub: 'Neither holding nor a diversion can be marked executable without it',
      ask: 'Ask crew',
      to: 'DISPATCH',
    });
  return g.map((x) => ({ ...x, open: openRequests.find((r) => r.field === x.field && r.flight_id === f.flight_id && r.status === 'OPEN') }));
}

// What a decision row means in words ("Divert to FJR", "Keep holding", "Crew replacement").
export function decisionWhat(x) {
  const t = x.decision_type;
  if (t === 'DIVERT') return x.alternate_iata ? `Divert to ${x.alternate_iata}` : 'Divert';
  if (t === 'HOLD') return 'Keep holding';
  return typeLabel(t);
}
// the decision that is still in flight for a flight (proposed or approved, newest first)
export const currentDecision = (list) => list.find((x) => ['PROPOSED', 'APPROVED'].includes(x.status)) ?? null;
