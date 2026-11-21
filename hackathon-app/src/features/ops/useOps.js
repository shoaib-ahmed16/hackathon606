import { useEffect, useMemo } from 'react';
import { useAppDispatch, useAppSelector } from '@/app/hooks';
import { OPS_API_URL } from '@/config/env';
import { api } from '@/app/api';
import {
  useGetAirportStatusQuery,
  useGetDeadlinesQuery,
  useGetRecOptionsQuery,
  useGetFuelQuery,
  useGetDiversionsQuery,
  useGetCasesQuery,
  useGetAlternateAirportsQuery,
  useGetCrewLegalityQuery,
  useGetDecisionLogQuery,
  useGetExceptionsQuery,
  useGetFlightsQuery,
  useGetKpisQuery,
  useGetRulesQuery,
  useGetDataRequestsQuery,
  useGetRuleMatchesQuery,
  useGetApprovalsQuery,
  useGetMySubscriptionsQuery,
  useGetMyNotificationsQuery,
  useGetRecoveryPlanQuery,
} from './opsApi';
import { selectUser } from '@/features/auth/authSlice';
import { selectCase, selectOps } from './opsSlice';

const EMPTY_LIST = [];
const EMPTY_RULES = { rules: [], flights: {}, errors: [] };
const POLL = 10000; // fallback; the SSE stream below refreshes sooner

// One hook for every screen: selected case + all DB read models, kept fresh.
export function useOps() {
  const dispatch = useAppDispatch();
  const ops = useAppSelector(selectOps);
  const cases = useGetCasesQuery(undefined, { pollingInterval: 30000 });
  const user = useAppSelector(selectUser);
  const alternates = useGetAlternateAirportsQuery({ hub: 'SHJ' }, { pollingInterval: 60000 });
  const token = useAppSelector((s) => s.auth.token);

  // default to the newest case once, so the app opens on something real
  // Closed cases are history (Audit and Report still reach them): they are not offered in the case picker, and if the selected
  // case gets closed the app moves to the newest open one.
  const openCases = useMemo(() => (cases.data ?? []).filter((c) => c.phase !== 'CLOSED'), [cases.data]);
  useEffect(() => {
    const known = openCases.some((c) => c.case_id === ops.caseId);
    // open on a case whose hub is actually restricted (the fog case), not on a quiet daily case
    if (openCases.length && !known) dispatch(selectCase(openCases.find((c) => c.hub_restricted) ?? openCases[0]));
  }, [ops.caseId, openCases, dispatch]);

  const ctx = { scenario_id: ops.scenarioId, case_id: ops.caseId };
  const skip = !ops.caseId;
  const opt = { skip, pollingInterval: POLL };
  const flights = useGetFlightsQuery(ctx, opt);
  const crew = useGetCrewLegalityQuery({ scenario_id: ops.scenarioId, case_id: ops.caseId }, opt);
  const deadlines = useGetDeadlinesQuery(ctx, opt);
  const options = useGetRecOptionsQuery(ctx, opt);
  const fuel = useGetFuelQuery({ scenario_id: ops.scenarioId }, opt);
  const diversions = useGetDiversionsQuery(ctx, opt);
  const airport = useGetAirportStatusQuery({ scenario_id: ops.scenarioId }, opt);
  const plan = useGetRecoveryPlanQuery(ctx, opt);
  const decisions = useGetDecisionLogQuery(ctx, opt);
  const exceptions = useGetExceptionsQuery({ scenario_id: ops.scenarioId }, opt);
  const kpis = useGetKpisQuery({ case_id: ops.caseId }, opt);
  const rules = useGetRulesQuery({ scenario_id: ops.scenarioId }, { skip: !ops.scenarioId, pollingInterval: 30000 });
  const ruleMatches = useGetRuleMatchesQuery(ctx, opt);
  const requests = useGetDataRequestsQuery({ scenario_id: ops.scenarioId, status: 'OPEN' }, { skip: !ops.scenarioId, pollingInterval: POLL });
  const approvals = useGetApprovalsQuery(ctx, opt);
  const subs = useGetMySubscriptionsQuery(
    { scenario_id: ops.scenarioId },
    { pollingInterval: 30000, skip: !ops.scenarioId },
  );
  const notifications = useGetMyNotificationsQuery(undefined, { pollingInterval: 30000 });

  // live push: the DB NOTIFYs when anything changes; refetch everything tagged Ops
  // The browser asks for a one-time ticket (with its normal Authorization header) and only the ticket goes in the stream URL, so the session
  // token never lands in access logs or browser history. A ticket works once: when the stream drops, ask for a new one and reconnect.
  useEffect(() => {
    if (!token) return undefined;
    let es;
    let timer;
    let stopped = false;
    const refresh = () => dispatch(api.util.invalidateTags(['Ops']));
    const connect = async () => {
      try {
        const r = await fetch(`${OPS_API_URL}/api/stream/ticket`, { method: 'POST', headers: { Authorization: `Bearer ${token}` } });
        if (!r.ok) throw new Error(String(r.status));
        const { ticket } = await r.json();
        if (stopped) return;
        es = new EventSource(`${OPS_API_URL}/api/stream?ticket=${encodeURIComponent(ticket)}`);
        es.addEventListener('reassess', refresh);
        es.addEventListener('notify', refresh);
        es.onerror = () => {
          es.close();
          if (!stopped) timer = setTimeout(connect, 5000);
        };
      } catch {
        if (!stopped) timer = setTimeout(connect, 15000); // polling keeps the screen fresh meanwhile
      }
    };
    connect();
    return () => {
      stopped = true;
      clearTimeout(timer);
      es?.close();
    };
  }, [dispatch, token]);

  const kase = useMemo(
    () => openCases.find((c) => c.case_id === ops.caseId),
    [openCases, ops.caseId],
  );
  const actor = useMemo(
    () => (user ? { user_id: user.id, role_code: user.role, display_name: user.name } : null),
    [user],
  );
  const teams = useMemo(() => new Set((subs.data ?? []).filter((x) => x.teams).map((x) => x.flight_id)), [subs.data]);
  const subscribed = useMemo(() => new Set((subs.data ?? []).map((x) => x.flight_id)), [subs.data]);
  const firstError = [cases, flights, crew].find((r) => r.isError);

  return {
    ops,
    ctx,
    kase,
    actor,
    cases: openCases,
    alternates: alternates.data ?? EMPTY_LIST,
    flights: flights.data ?? [],
    crew: crew.data ?? [],
    airport: airport.data ?? [],
    plan: plan.data ?? [],
    decisions: decisions.data ?? [],
    exceptions: exceptions.data ?? [],
    deadlines: deadlines.data?.items ?? [],
    options: options.data ?? [],
    refreshedAt: flights.fulfilledTimeStamp,
    fuel: fuel.data ?? [],
    diversions: diversions.data ?? [],
    kpis: kpis.data,
    rules: rules.data ?? [],
    ruleMatches: ruleMatches.data ?? EMPTY_RULES,
    approvals: approvals.data ?? [],
    subscribed,
    teams,
    openRequests: requests.data ?? EMPTY_LIST,
    notifications: notifications.data ?? { unread: 0, items: [] },
    isLoading:
      cases.isLoading ||
      (cases.isSuccess && openCases.length > 0 && !ops.caseId) ||
      (!skip && flights.isLoading),
    error: firstError?.error,
    noCase: cases.isSuccess && openCases.length === 0,
  };
}
