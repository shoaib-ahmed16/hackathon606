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
  useGetCrewLegalityQuery,
  useGetDecisionLogQuery,
  useGetExceptionsQuery,
  useGetFlightsQuery,
  useGetRecoveryPlanQuery,
} from './opsApi';
import { selectUser } from '@/features/auth/authSlice';
import { selectCase, selectOps } from './opsSlice';

const POLL = 10000; // fallback; the SSE stream below refreshes sooner

// One hook for every screen: selected case + all DB read models, kept fresh.
export function useOps() {
  const dispatch = useAppDispatch();
  const ops = useAppSelector(selectOps);
  const cases = useGetCasesQuery(undefined, { pollingInterval: 30000 });
  const user = useAppSelector(selectUser);
  const token = useAppSelector((s) => s.auth.token);

  // default to the newest case once, so the app opens on something real
  useEffect(() => {
    const known = cases.data?.some((c) => c.case_id === ops.caseId);
    if (cases.data?.length && !known) dispatch(selectCase(cases.data[0]));
  }, [ops.caseId, cases.data, dispatch]);

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

  // live push: the DB NOTIFYs when anything changes; refetch everything tagged Ops
  useEffect(() => {
    let es;
    try {
      es = new EventSource(`${OPS_API_URL}/api/stream?token=${encodeURIComponent(token)}`);
      es.addEventListener('reassess', () => dispatch(api.util.invalidateTags(['Ops'])));
    } catch {
      /* polling still works */
    }
    return () => es?.close();
  }, [dispatch, token]);

  const kase = useMemo(
    () => cases.data?.find((c) => c.case_id === ops.caseId),
    [cases.data, ops.caseId],
  );
  const actor = useMemo(
    () => (user ? { user_id: user.id, role_code: user.role, display_name: user.name } : null),
    [user],
  );
  const firstError = [cases, flights, crew].find((r) => r.isError);

  return {
    ops,
    ctx,
    kase,
    actor,
    cases: cases.data ?? [],
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
    isLoading:
      cases.isLoading ||
      (cases.isSuccess && cases.data.length > 0 && !ops.caseId) ||
      (!skip && flights.isLoading),
    error: firstError?.error,
    noCase: cases.isSuccess && cases.data.length === 0,
  };
}
