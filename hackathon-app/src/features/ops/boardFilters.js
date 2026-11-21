// ONE definition of every board filter. The KPI cards, the filter chips/selects and the lane list all use these
// predicates, so a card that says "2" always filters to exactly those 2 flights.
//
// A filter is a string key in the URL (?f=crew,status:Holding):
//   affected | lvp | crew | verify | approval | subscribed | sev:<min> | status:<label|divhold> | rule:<id>
import { isAirborne, isRecovered, liveLabel } from '@/console/lib';

export const CREW_RISK = ['AT_RISK', 'DISCRETION_REQUIRED', 'EXCEEDED'];
export const ruleKey = (id) => `rule:${id}`;

// An aircraft still in the air whose estimated landing time has already passed: the ETA is stale, so what hangs on it is unverified.
export const etaOverdue = (f, nowMs) => isAirborne(f) && !f.diverted_to && f.eta_utc != null && nowMs != null && new Date(f.eta_utc).getTime() < nowMs;

// Needs verification = unverified crew data, open exceptions, unknown fuel on an airborne flight, or an open data request.
export const needsVerification = (f, ctx) =>
  f.crew_status === 'VERIFICATION_REQUIRED' ||
  f.open_exceptions > 0 ||
  (isAirborne(f) && !f.diverted_to && ctx.fuelBy[f.flight_id] == null) ||
  ctx.requested.has(f.flight_id) ||
  etaOverdue(f, ctx.nowMs);

export function matches(f, key, ctx) {
  if (key === 'affected') {
    if (isRecovered(f) || f.status === 'CANCELLED') return false;
    // in the air or at an alternate = affected; a flight that has not left yet only while its hub is closed or under LVP
    return isAirborne(f) || Boolean(f.diverted_to) || ctx.hubRestricted !== false;
  }
  if (key === 'lvp') return Boolean(f.lvp_required) && f.lvp_crew_ok !== true;
  if (key === 'crew') return !isRecovered(f) && CREW_RISK.includes(f.crew_status);
  if (key === 'verify') return needsVerification(f, ctx);
  if (key === 'approval') return f.decision_status === 'PROPOSED';
  if (key === 'subscribed') return ctx.subscribed.has(f.flight_id);
  if (key.startsWith('sev:')) return (f.severity_score ?? 0) >= Number(key.slice(4));
  if (key.startsWith('status:')) {
    const v = key.slice(7);
    return v === 'divhold' ? Boolean(f.diverted_to) || f.status === 'HOLDING' : liveLabel(f) === v;
  }
  if (key.startsWith('rule:')) return (ctx.ruleMatches.flights?.[f.flight_id] ?? []).includes(Number(key.slice(5)));
  return true; // unknown / stale key: ignore rather than hide everything
}

export const passesAll = (f, keys, ctx) => keys.every((k) => matches(f, k, ctx));

export function filterLabel(key, ruleMatches) {
  if (key.startsWith('rule:')) return `Rule: ${ruleMatches.rules.find((r) => r.rule_id === Number(key.slice(5)))?.name ?? key.slice(5)}`;
  if (key.startsWith('status:')) return key.slice(7) === 'divhold' ? 'Diverted or holding' : key.slice(7);
  if (key.startsWith('sev:')) return Number(key.slice(4)) >= 50 ? 'High severity' : 'Medium and above';
  return {
    affected: 'Flights affected', lvp: 'Pilots not LVP-qualified', crew: 'Crew at risk',
    verify: 'Needs verification', approval: 'Waiting for approval', subscribed: 'Watched by me',
  }[key] ?? key;
}

// Rules of any kind that apply to one flight (row markers, flight panel).
export function rulesFor(ruleMatches, flightId) {
  const ids = ruleMatches?.flights?.[flightId] ?? [];
  return (ruleMatches?.rules ?? []).filter((r) => ids.includes(r.rule_id));
}
// Lower number = higher priority. Only in-force PRIORITY rules count.
export function priorityOf(ruleMatches, flightId) {
  const hits = rulesFor(ruleMatches, flightId).filter((r) => r.kind === 'PRIORITY');
  return hits.length ? Math.min(...hits.map((r) => r.priority)) : 1e9;
}
