// Domain helpers for the FOO console: labels, tones and the "what is happening to this flight" wording.
// Pure functions over the rows the API returns (v_flight_watch + severity + tags); no React in here.
import { fmtZ, fmtTime, MIN } from '@/features/ops/time';
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
export const LIVE_STATUSES = ['Airborne', 'Holding', 'At alternate', 'Not departed', 'Recovered'];
export function liveLabel(f) {
  if (f.status === 'CANCELLED') return 'Cancelled';
  if (f.status === 'HOLDING') return 'Holding';
  if (f.diverted_to) return 'At alternate';
  if (isRecovered(f)) return 'Recovered';
  if (isAirborne(f)) return 'Airborne';
  return 'Not departed';
}

// [headline, detail] of where the aircraft is and what it is waiting for
export function whereText(f) {
  const eta = ms(f.eta_utc ?? f.sta_utc);
  if (f.status === 'CANCELLED') return ['Cancelled', ''];
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
  return human(r).replace(/^./, (c) => c.toUpperCase());
}

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
