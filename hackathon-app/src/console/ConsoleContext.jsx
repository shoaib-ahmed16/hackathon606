import { createContext, useContext } from 'react';

// The one shared data object for every console screen (cases, flights, crew, decisions, approvals, kpis, rules,
// notifications, ...). Built once in ConsoleLayout from useOps(). Components read it with useConsole().
//
// Notable fields:  d.kase (selected case)   d.ctx = { scenario_id, case_id }   d.actor = { user_id, role_code, display_name }
//   d.flights  (v_flight_watch rows + severity_score, connecting_pax, tags[])   d.deadlines  d.fuel  d.options
//   d.approvals (decisions with required_roles / approved_roles / waiting_for / can_approve)   d.kpis
//   d.rules (all rules)   d.ruleMatches ({ rules, flights })   d.subscribed (Set)   d.teams (Set)
//   d.openRequests (open data requests)   d.notifications ({ unread, items })   d.ops (redux: lens, selectedFlightId ...)
const Ctx = createContext(null);
export const ConsoleProvider = Ctx.Provider;
export function useConsole() {
  const d = useContext(Ctx);
  if (!d) throw new Error('useConsole must be used inside ConsoleLayout');
  return d;
}
