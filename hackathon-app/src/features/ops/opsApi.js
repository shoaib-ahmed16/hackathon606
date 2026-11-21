import { api } from '@/app/api';
import { OPS_API_URL } from '@/config/env';

// FogOps API (FastAPI + Postgres). All reads are DB views, all actions call DB functions, so the
// rules (legality, guardrails, audit) live in one place. Docs: backend/API_README.md
const u = (path) => `${OPS_API_URL}${path}`;
const TAG = 'Ops';

export const opsApi = api.enhanceEndpoints({ addTagTypes: [TAG] }).injectEndpoints({
  endpoints: (build) => {
    const q = (path) =>
      build.query({ query: (params) => ({ url: u(path), params }), providesTags: [TAG] });
    const m = (fn) => build.mutation({ query: fn, invalidatesTags: [TAG] });
    return {
      getCases: q('/api/cases'),
      getScenarios: q('/api/scenarios'),
      getFlights: q('/api/flights'),
      getCrewLegality: q('/api/crew/legality'),
      getAirportStatus: q('/api/airport/status'),
      getRecoveryPlan: q('/api/recovery/plan'),
      getDecisionLog: q('/api/decisions/log'),
      getTimeline: q('/api/timeline'),
      getExceptions: q('/api/exceptions'),
      getFeedFreshness: q('/api/feed/freshness'),
      getStandby: q('/api/crew/standby-candidates'),
      getRecOptions: q('/api/recommendations/options'),
      getDiversions: q('/api/diversions'),
      getComments: q('/api/comments'),
      getFuel: q('/api/fuel'),
      getDeadlines: q('/api/deadlines'),
      getFlightDetail: build.query({
        query: ({ flightId, ...params }) => ({ url: u(`/api/flights/${flightId}/detail`), params }),
        providesTags: [TAG],
      }),
      getBriefing: q('/api/briefing'),
      getAskQuestions: q('/api/ask/questions'),
      getAudit: q('/api/audit'),
      getAircraft: build.query({
        query: ({ reg, ...params }) => ({
          url: u(`/api/aircraft/${encodeURIComponent(reg)}`),
          params,
        }),
        providesTags: [TAG],
      }),

      // ---- actions
      closeCase: m(({ caseId }) => ({ url: u(`/api/cases/${caseId}/close`), method: 'POST' })),
      deleteCase: m(({ caseId }) => ({ url: u(`/api/cases/${caseId}`), method: 'DELETE' })),
      ask: m((body) => ({ url: u('/api/ask'), method: 'POST', body })),
      whatIf: m((body) => ({ url: u('/api/whatif'), method: 'POST', body })),
      approvePlan: m(({ planId }) => ({
        url: u(`/api/recovery/${planId}/approve`),
        method: 'POST',
      })),
      moveSlot: m(({ planId, flightId, body }) => ({
        url: u(`/api/recovery/${planId}/items/${flightId}`),
        method: 'PATCH',
        body,
      })),
      logoutAudit: build.mutation({
        query: () => ({ url: u('/api/auth/logout'), method: 'POST' }),
      }),
      createCase: m((body) => ({ url: u('/api/cases/create'), method: 'POST', body })),
      recommendFlight: m(({ flightId, ...params }) => ({
        url: u(`/api/flights/${flightId}/recommend`),
        method: 'POST',
        params,
      })),
      updateDiversion: m(({ id, body }) => ({
        url: u(`/api/diversions/${id}`),
        method: 'PATCH',
        body,
      })),
      flightEvent: m((body) => ({ url: u('/api/events/flight'), method: 'POST', body })),
      addRecord: m(({ table, body }) => ({
        url: u(`/api/records/${table}`),
        method: 'POST',
        body,
      })),
      executeDiversion: m(({ decisionId }) => ({
        url: u(`/api/decisions/${decisionId}/execute-diversion`),
        method: 'POST',
      })),
      swapCrew: m((body) => ({ url: u('/api/crew/swap'), method: 'POST', body })),
      recomputeFlight: m(({ flightId, scenario_id }) => ({
        url: u(`/api/flights/${flightId}/recompute`),
        method: 'POST',
        params: { scenario_id },
      })),
      buildRecovery: m((body) => ({ url: u('/api/recovery/build'), method: 'POST', body })),
      generateReport: m(({ caseId }) => ({
        url: u(`/api/cases/${caseId}/report`),
        method: 'POST',
      })),
    };
  },
});

export const {
  useGetCasesQuery,
  useGetFlightsQuery,
  useGetCrewLegalityQuery,
  useGetAirportStatusQuery,
  useGetRecoveryPlanQuery,
  useGetDecisionLogQuery,
  useGetTimelineQuery,
  useGetExceptionsQuery,
  useGetFeedFreshnessQuery,
  useGetStandbyQuery,
  useGetAircraftQuery,
  useGetDeadlinesQuery,
  useGetFlightDetailQuery,
  useGetBriefingQuery,
  useGetAskQuestionsQuery,
  useGetAuditQuery,
  useAskMutation,
  useWhatIfMutation,
  useApprovePlanMutation,
  useMoveSlotMutation,
  useLogoutAuditMutation,
  useGetScenariosQuery,
  useCreateCaseMutation,
  useCloseCaseMutation,
  useDeleteCaseMutation,
  useGetRecOptionsQuery,
  useGetDiversionsQuery,
  useGetCommentsQuery,
  useGetFuelQuery,
  useRecommendFlightMutation,
  useUpdateDiversionMutation,
  useFlightEventMutation,
  useAddRecordMutation,
  useExecuteDiversionMutation,
  useSwapCrewMutation,
  useRecomputeFlightMutation,
  useBuildRecoveryMutation,
  useGenerateReportMutation,
} = opsApi;
