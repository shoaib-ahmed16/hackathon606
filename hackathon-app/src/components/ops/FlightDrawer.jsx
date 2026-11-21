import { useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  Collapse,
  Divider,
  Drawer,
  LinearProgress,
  IconButton,
  MenuItem,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import CloseIcon from '@mui/icons-material/Close';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import {
  useAddRecordMutation,
  useExecuteDiversionMutation,
  useFlightEventMutation,
  useGetCommentsQuery,
  useGetAuditQuery,
  useGetFlightDetailQuery,
  useGetDiversionsQuery,
  useGetFuelQuery,
  useGetRecOptionsQuery,
  useGetStandbyQuery,
  useRecommendFlightMutation,
  useSwapCrewMutation,
  useUpdateDiversionMutation,
} from '@/features/ops/opsApi';
import { selectFlight } from '@/features/ops/opsSlice';
import {
  DECISION_TYPES,
  REC_TO_DECISION,
  iso,
  ms,
  scenarioNowMs,
  stampMs,
} from '@/features/ops/helpers';
import { flightDay, fmtDateTime, fmtDur, fmtZ, fmtZLD } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';
import StatusChip from './StatusChip';
import MarginBar from './MarginBar';
import Countdown from './Countdown';
import Ribbon from './Ribbon';

const Row = ({ k, v }) => (
  <Stack direction="row" sx={{ justifyContent: 'space-between', gap: 2 }}>
    <Typography variant="body2" sx={{ color: 'text.secondary' }}>
      {k}
    </Typography>
    <Typography variant="body2" sx={{ fontFamily: 'monospace', textAlign: 'right' }}>
      {v ?? '-'}
    </Typography>
  </Stack>
);
const Section = ({ title, children }) => (
  <Box sx={{ border: 1, borderColor: 'divider', borderRadius: 2, p: 1.5 }}>
    <Typography variant="overline" sx={{ color: 'primary.main' }}>
      {title}
    </Typography>
    {children}
  </Box>
);
const t = (v) => (v ? fmtZLD(ms(v)) : '-'); // date + UTC + SHJ local, never an unlabeled time
const human = (code) => String(code).replaceAll('_', ' ').toLowerCase();
const WAITING = [
  'LANDING',
  'HANDLING',
  'FUEL',
  'HUB_REOPENING',
  'ARRIVAL_SLOT',
  'REPLACEMENT_CREW',
  'CREW_REST',
  'ATC',
  'NOTHING',
];
const DIV_STATUS = ['DIVERTING', 'ON_GROUND_ALT', 'READY', 'DEPARTED', 'CLOSED', 'CANCELLED'];
const REFUEL = ['PENDING', 'IN_PROGRESS', 'DONE', 'NOT_REQUIRED'];

const QUALITY = {
  MEASURED: 'success',
  FORECAST: 'warning',
  ESTIMATED: 'warning',
  SIMULATED: 'info',
  ASSUMED: 'info',
  MANUAL: 'default',
};
const REASONS = [
  'Station capacity',
  'ATC restriction',
  'Crew preference',
  'Commercial / connections',
  'Fuel information',
  'Other',
];
const ICON = {
  '✓': 'success.main',
  '!': 'warning.main',
  '✕': 'error.main',
  '?': 'warning.main',
  i: 'text.secondary',
};

// "What will happen" for an option, from the engine's own numbers (stands, crew legal end, fuel, passengers).
function Conseq({ lines }) {
  if (!lines?.length) return null;
  return (
    <Box
      data-src="rank_alternates() + flight_decision_inputs() (read-only preview)"
      sx={{ border: 1, borderColor: 'divider', borderRadius: 1.5, p: 1, display: 'grid', gap: 0.5 }}
    >
      <Typography variant="caption" sx={{ color: 'text.secondary' }}>
        What will happen
      </Typography>
      {lines.map(([icon, text], i) => (
        <Stack key={i} direction="row" spacing={1}>
          <Typography variant="body2" sx={{ width: 16, fontWeight: 700, color: ICON[icon] }}>
            {icon}
          </Typography>
          <Typography variant="body2">{text}</Typography>
        </Stack>
      ))}
    </Box>
  );
}

// Shared inspector. Everything shown is a DB read model; every button is a DB action as the signed-in user.
function DrawerBody({ d, f }) {
  const dispatch = useAppDispatch();
  const { decisions, actor, ctx, kase } = d;
  const q = { scenario_id: ctx.scenario_id, case_id: ctx.case_id };

  const [add, { isLoading: saving }] = useAddRecordMutation();
  const [execute] = useExecuteDiversionMutation();
  const [rerun, { isLoading: rerunning }] = useRecommendFlightMutation();
  const [patchDiv] = useUpdateDiversionMutation();
  const [feed] = useFlightEventMutation();
  const [swap] = useSwapCrewMutation();
  const [pick, setPick] = useState(null); // chosen option row
  const [freeForm, setFreeForm] = useState(false); // record a decision without picking an option
  const [type, setType] = useState('');
  const [why, setWhy] = useState('');
  const [comment, setComment] = useState('');
  const [endurance, setEndurance] = useState('');
  const [div, setDiv] = useState({});

  const skip = false;
  const options = useGetRecOptionsQuery({ ...q, flight_id: f?.flight_id }, { skip });
  const diversions = useGetDiversionsQuery(q, { skip });
  const comments = useGetCommentsQuery({ case_id: ctx.case_id, flight_id: f?.flight_id }, { skip });
  const fuel = useGetFuelQuery({ scenario_id: ctx.scenario_id }, { skip });
  const standby = useGetStandbyQuery(
    {
      scenario_id: ctx.scenario_id,
      duty_id: f?.duty_id,
      position: f?.binding_position,
      station: f?.dep_iata ?? 'SHJ',
      from_leg: 1,
    },
    { skip: !f?.duty_id || !f?.binding_position },
  );
  const dv = diversions.data?.find((x) => x.original_flight_id === f?.flight_id);
  const est = fuel.data?.find((x) => x.flight_id === f?.flight_id);
  const history = decisions.filter((x) => x.flight_id === f?.flight_id);
  const hasOpen = f?.decision_id && !['REJECTED', 'REVOKED'].includes(f.decision_status);
  const crewDecision = history.find(
    (h) => h.decision_type === 'CREW_REPLACE' && h.status === 'APPROVED' && h.details?.out_crew_id,
  );
  const airborne = f && ['AIRBORNE', 'HOLDING'].includes(f.status);
  const detail = useGetFlightDetailQuery({ flightId: f.flight_id, ...q });
  const audit = useGetAuditQuery(
    { ...q, flight_id: f.flight_id, limit: 30 },
    { pollingInterval: 15000 },
  );
  const dl = d.deadlines.find((x) => x.flight_id === f.flight_id);
  const dt = detail.data;
  const [whyOpen, setWhyOpen] = useState(false);
  const [reason, setReason] = useState('');
  const isOverride = Boolean(pick && pick.rank > 1);
  const conseqKey = pick ? (pick.action === 'HOLD' ? 'HOLD' : pick.alternate_iata) : null;
  const conseq = conseqKey ? dt?.consequences?.[conseqKey] : null;
  const close = () => dispatch(selectFlight(null));
  const choose = (o) => {
    setPick(o);
    setType('');
    setFreeForm(false);
  };

  const run = async (fn, ok) => {
    try {
      await fn().unwrap();
      toast.success(ok);
      return true;
    } catch (e) {
      toast.error(getErrorMessage(e));
      return false;
    }
  };
  const decide = async () => {
    const dtype = type || pick?.action || REC_TO_DECISION[f.recommendation] || 'OTHER';
    const alt = pick ? pick.alternate_iata : f.recommended_alternate;
    const ok = await run(
      () =>
        add({
          table: 'decision',
          body: {
            ...q,
            flight_id: f.flight_id,
            rec_id: f.rec_id,
            option_id: pick?.option_id ?? null,
            decision_type: dtype,
            alternate_iata: alt || null,
            rationale: isOverride ? `[Override of engine: ${reason}] ${why.trim()}` : why.trim(),
            followed_recommendation: !pick || pick.rank === 1,
            details: isOverride ? { override_reason: reason } : {},
            decided_by: actor.user_id,
            decided_role: actor.role_code,
          },
        }),
      'Decision recorded',
    );
    if (ok) {
      setWhy('');
      setReason('');
    }
  };
  const verdict = (v) =>
    run(
      () =>
        add({
          table: 'decision_approval',
          body: {
            decision_id: f.decision_id,
            approver_id: actor.user_id,
            approver_role: actor.role_code,
            verdict: v,
          },
        }),
      `Decision ${v.toLowerCase()}`,
    );
  const postComment = async () => {
    if (
      await run(
        () =>
          add({
            table: 'case_comment',
            body: {
              case_id: ctx.case_id,
              flight_id: f.flight_id,
              author_id: actor.user_id,
              author_role: actor.role_code,
              body: comment.trim(),
            },
          }),
        'Comment added',
      )
    )
      setComment('');
  };
  const saveFuel = async () => {
    if (
      await run(
        () =>
          add({
            table: 'flight_fuel_estimate',
            body: {
              scenario_id: ctx.scenario_id,
              flight_id: f.flight_id,
              as_of_utc: iso(stampMs(kase)),
              est_holding_endurance_min: Number(endurance),
              quality: 'MANUAL',
              basis: { from: `entered by ${actor.display_name}` },
              entered_by: actor.user_id,
            },
          }),
        'Fuel endurance saved, engine will re-rank',
      )
    )
      setEndurance('');
  };
  const moveEta = (min) =>
    run(
      () =>
        feed({
          scenario_id: ctx.scenario_id,
          source: 'SIM_FEED',
          message_id: `ui-${f.flight_id}-${Date.now()}`,
          flight_id: f.flight_id,
          event_type: 'ETA_UPDATE',
          event_ts: iso(scenarioNowMs(kase)),
          payload: { eta: iso(ms(f.eta_utc ?? f.sta_utc) + min * 60000) },
        }),
      `ETA ${min > 0 ? '+' : ''}${min} min sent as a feed event`,
    );
  const station = () =>
    run(() => patchDiv({ id: dv.diversion_id, body: div }), 'Station update saved').then(() =>
      setDiv({}),
    );
  const execSwap = () =>
    run(
      () =>
        swap({
          scenario_id: ctx.scenario_id,
          case_id: ctx.case_id,
          decision_id: crewDecision.decision_id,
          ...crewDecision.details,
          reason: crewDecision.rationale,
        }),
      'Crew swapped, legality recalculated',
    );

  // Decision form: opens right under the option that was clicked (or at the bottom for "record without an option").
  const formBoxSx = {
    mt: 0.5,
    p: 1.5,
    border: 1,
    borderColor: 'primary.main',
    borderRadius: 1.5,
    bgcolor: 'action.hover',
  };
  const decisionForm = (
    <Stack spacing={1}>
      <Typography variant="subtitle2">
        {pick
          ? `Record a decision for option #${pick.rank}: ${pick.action} ${pick.alternate_iata ?? ''}`
          : 'Record a decision'}
      </Typography>
      <Conseq lines={conseq} />
      {isOverride && (
        <Box>
          <Typography variant="caption" sx={{ color: 'warning.main' }}>
            You chose a different option than the engine's first. Why? (required)
          </Typography>
          <Stack direction="row" sx={{ gap: 0.5, flexWrap: 'wrap', mt: 0.5 }}>
            {REASONS.map((r) => (
              <Chip
                key={r}
                size="small"
                label={r}
                color={reason === r ? 'primary' : 'default'}
                variant={reason === r ? 'filled' : 'outlined'}
                onClick={() => setReason(r)}
              />
            ))}
          </Stack>
        </Box>
      )}
      <TextField
        select
        label="Decision"
        value={type || pick?.action || REC_TO_DECISION[f.recommendation] || 'OTHER'}
        onChange={(e) => setType(e.target.value)}
      >
        {DECISION_TYPES.map((x) => (
          <MenuItem key={x} value={x}>
            {x.replaceAll('_', ' ')}
          </MenuItem>
        ))}
      </TextField>
      <TextField
        autoFocus
        label="Rationale (required)"
        value={why}
        onChange={(e) => setWhy(e.target.value)}
        multiline
        minRows={2}
      />
      <Button
        variant="contained"
        disabled={!why.trim() || saving || !actor || (isOverride && !reason)}
        onClick={decide}
      >
        Record decision as {actor?.display_name}
      </Button>
    </Stack>
  );

  return (
    <Stack spacing={2}>
      <Stack direction="row" sx={{ alignItems: 'center', justifyContent: 'space-between' }}>
        <div>
          <Typography variant="h5" component="div">
            {f.flight_no}{' '}
            <Chip size="small" variant="outlined" label={f.registration ?? 'no tail'} />{' '}
            <Chip size="small" variant="outlined" color="primary" label={flightDay(f)} />{' '}
            <StatusChip status={f.status} />
          </Typography>
          <Typography variant="body2" sx={{ color: 'text.secondary' }}>
            {f.dep_iata} to {f.planned_arr_iata}
            {f.diverted_to ? ` - diverted to ${f.diverted_to}` : ''} - captain {f.captain ?? 'n/a'}
          </Typography>
        </div>
        <IconButton onClick={close} aria-label="Close">
          <CloseIcon />
        </IconButton>
      </Stack>

      {f.lvp_required && f.lvp_crew_ok === false && (
        <Alert severity="error">
          LVP is in force at the destination and{' '}
          {f.lvp_not_qualified?.map((p) => `${p.position} ${p.name}`).join(', ')}{' '}
          {f.lvp_not_qualified?.length > 1 ? 'are' : 'is'} not LVP-qualified. Landing here needs a
          different crew.
        </Alert>
      )}
      {f.lvp_required && f.lvp_crew_ok === null && (
        <Alert severity="warning">
          LVP is in force but the operating pilots are not linked to this leg. Verify LVP
          qualification.
        </Alert>
      )}

      {dl && (
        <Section title="Deadline">
          <Stack
            direction="row"
            spacing={1.5}
            sx={{ alignItems: 'baseline', mt: 0.5, flexWrap: 'wrap' }}
          >
            {dl.deadline_utc ? (
              <Countdown at={ms(dl.deadline_utc)} big showTime />
            ) : (
              <Chip size="small" color="warning" label="Cannot compute: fuel not reported" />
            )}
            <Typography variant="body2">{dl.reason}</Typography>
            <Button size="small" onClick={() => setWhyOpen(!whyOpen)}>
              Why this time?
            </Button>
          </Stack>
          {whyOpen && (
            <Box
              component="ol"
              sx={{ m: 0, mt: 1, pl: 2.5, fontSize: 13 }}
              data-src="fdp_calculation / latest_departure_calc / flight_decision_inputs"
            >
              {[...dl.why, ...(dt?.why ?? [])].map((w) => (
                <li key={w}>{w}</li>
              ))}
            </Box>
          )}
        </Section>
      )}

      <Section title="Flight">
        <Box sx={{ display: 'grid', gap: 0.5, mt: 0.5 }}>
          <Row k="Scheduled departure" v={t(f.std_utc)} />
          <Row k="Scheduled arrival" v={t(f.sta_utc)} />
          <Row k="Estimated departure" v={t(f.etd_utc)} />
          <Row k="Estimated arrival" v={t(f.eta_utc)} />
          <Row k="Arrival delay" v={fmtDur(f.arr_delay_min)} />
          <Row k="Fog exposure" v={f.fog_exposure} />
          {f.waiting_for && <Row k="Aircraft waiting for" v={human(f.waiting_for)} />}
          <Row k="Data age" v={f.data_age_min != null ? `${f.data_age_min} min` : 'no feed yet'} />
          <Row k="Owner" v={f.owner ?? f.owner_role} />
        </Box>
        {f.status !== 'ON_BLOCKS' && f.status !== 'LANDED' && (
          <Stack direction="row" spacing={1} sx={{ mt: 1 }}>
            <Typography variant="caption" sx={{ alignSelf: 'center', color: 'text.secondary' }}>
              Feed event:
            </Typography>
            <Button size="small" variant="outlined" onClick={() => moveEta(15)}>
              ETA +15m
            </Button>
            <Button size="small" variant="outlined" onClick={() => moveEta(30)}>
              ETA +30m
            </Button>
            <Button size="small" variant="outlined" onClick={() => moveEta(-15)}>
              ETA -15m
            </Button>
          </Stack>
        )}
      </Section>

      {airborne && (
        <Section title="Hold fuel endurance">
          <Typography variant="body2" sx={{ color: 'text.secondary' }}>
            {est
              ? `${est.est_holding_endurance_min} min (${est.quality.toLowerCase()}, as of ${t(est.as_of_utc)})`
              : 'No estimate recorded. The engine marks the hold unverified.'}
          </Typography>
          <Stack direction="row" spacing={1} sx={{ mt: 1 }}>
            <TextField
              label="Endurance (min)"
              type="number"
              value={endurance}
              onChange={(e) => setEndurance(e.target.value)}
              sx={{ maxWidth: 170 }}
            />
            <Button
              variant="outlined"
              disabled={!endurance || Number(endurance) < 0}
              onClick={saveFuel}
            >
              Save estimate
            </Button>
          </Stack>
        </Section>
      )}

      <Section title="Crew legality (from the actual duty sheet)">
        <Box sx={{ display: 'grid', gap: 0.5, mt: 0.5 }}>
          <Stack direction="row" sx={{ justifyContent: 'space-between', alignItems: 'center' }}>
            <StatusChip status={f.crew_status} />
            {f.crew_margin_min != null && <MarginBar margin={f.crew_margin_min} />}
          </Stack>
          <Row k="Binding position" v={f.binding_position} />
          <Row k="Legs counted" v={f.legs_counted} />
          <Row k="Legal duty end" v={t(f.legal_end_utc)} />
          <Row k="With discretion (+3h)" v={t(f.discretion_end_utc)} />
          <Row k="Latest legal off-blocks" v={t(f.latest_legal_offblocks_utc)} />
          <Row k="Operational target" v={t(f.operational_target_utc)} />
          {f.departure_legality && <Row k="Departure legality" v={human(f.departure_legality)} />}
        </Box>
        {dt?.fdp && (
          <Box sx={{ mt: 1.5 }}>
            <Ribbon
              signIn={ms(dt.fdp.sign_in_utc)}
              legal={ms(dt.fdp.legal_end_utc)}
              disc={ms(dt.fdp.discretion_end_utc)}
              proj={ms(dt.fdp.projected_end_utc)}
            />
          </Box>
        )}
        {dt?.crew?.length > 0 && (
          <Stack direction="row" sx={{ gap: 0.75, flexWrap: 'wrap', mt: 1 }}>
            {dt.crew.map((c) => {
              const pilot = ['CP', 'FO'].includes(c.position_code);
              return (
                <Chip
                  key={c.crew_id}
                  size="small"
                  variant="outlined"
                  color={pilot ? (c.lvp ? 'success' : 'error') : 'default'}
                  label={`${c.position_code} ${c.full_name}${pilot ? (c.lvp ? ' - LVP' : ' - no LVP') : ''}`}
                />
              );
            })}
          </Stack>
        )}
        {f.crew_reasons?.map((r) => (
          <Typography key={r} variant="caption" sx={{ display: 'block', color: 'text.secondary' }}>
            {r}
          </Typography>
        ))}
        {f.open_exceptions > 0 && (
          <Alert severity="warning" sx={{ mt: 1 }}>
            {f.open_exceptions} open data exception(s) on this duty. Treat legality as unverified.
          </Alert>
        )}
      </Section>

      <Section title="Agent options (ranked) and decision">
        <Stack direction="row" spacing={1} sx={{ alignItems: 'center', mt: 0.5, flexWrap: 'wrap' }}>
          {f.recommendation ? (
            <>
              <StatusChip status={f.recommendation} />
              {f.recommended_alternate && (
                <Chip size="small" variant="outlined" label={`via ${f.recommended_alternate}`} />
              )}
              {f.confidence != null && (
                <Typography variant="caption">
                  confidence {Math.round(f.confidence * 100)}%
                </Typography>
              )}
              <StatusChip status={f.recommendation_status} />
            </>
          ) : (
            <Typography variant="body2" sx={{ color: 'text.secondary' }}>
              No open recommendation.
            </Typography>
          )}
          <Box sx={{ flex: 1 }} />
          {airborne && (
            <Button
              size="small"
              disabled={rerunning}
              onClick={() =>
                run(
                  () => rerun({ flightId: f.flight_id, ...q }),
                  'Engine re-ran with the latest data',
                )
              }
            >
              Re-run engine
            </Button>
          )}
        </Stack>
        <Typography variant="caption" sx={{ color: 'text.secondary', display: 'block' }}>
          Approver role required: {f.required_approver_role ?? 'n/a'}. The engine recommends; a
          human decides.
        </Typography>
        {dt?.recommendation && (
          <Box sx={{ mt: 1 }} data-src="recommendation (confidence, rationale, assumptions)">
            {dt.recommendation.confidence != null && (
              <Stack direction="row" spacing={1} sx={{ alignItems: 'center' }}>
                <Typography variant="caption">
                  Confidence {Math.round(dt.recommendation.confidence * 100)}%
                </Typography>
                <LinearProgress
                  variant="determinate"
                  value={dt.recommendation.confidence * 100}
                  sx={{ width: 110, height: 5, borderRadius: 3 }}
                />
              </Stack>
            )}
            <Typography variant="body2" sx={{ my: 0.75 }}>
              {dt.recommendation.rationale}
            </Typography>
            <Stack direction="row" sx={{ gap: 0.5, flexWrap: 'wrap' }}>
              {(dt.recommendation.assumptions ?? []).map((a) => {
                const k = /(MEASURED|FORECAST|ESTIMATED|SIMULATED|ASSUMED|MANUAL)/.exec(
                  String(a).toUpperCase(),
                )?.[1];
                return (
                  <Chip
                    key={a}
                    size="small"
                    variant="outlined"
                    color={QUALITY[k] ?? 'default'}
                    label={a}
                    sx={{ height: 'auto', '& .MuiChip-label': { whiteSpace: 'normal', py: 0.25 } }}
                  />
                );
              })}
            </Stack>
          </Box>
        )}

        {options.data?.length > 0 && (
          <Stack spacing={0.75} sx={{ mt: 1 }}>
            {options.data.map((o) => {
              const blocked = !o.is_executable;
              const chosen = pick?.rank === o.rank;
              return (
                <Box key={`${o.rec_id}-${o.rank}`}>
                  <Box
                    onClick={() => !hasOpen && (chosen ? setPick(null) : choose(o))}
                    sx={{
                      border: 1,
                      borderColor: chosen ? 'primary.main' : 'divider',
                      borderRadius: 1.5,
                      p: 1,
                      cursor: hasOpen ? 'default' : 'pointer',
                      opacity: blocked ? 0.75 : 1,
                      '&:hover': hasOpen ? undefined : { bgcolor: 'action.hover' },
                    }}
                  >
                    <Stack direction="row" spacing={1} sx={{ alignItems: 'center' }}>
                      <Typography variant="subtitle2" sx={{ width: 20 }}>
                        #{o.rank}
                      </Typography>
                      <Typography variant="subtitle2" sx={{ flex: 1 }}>
                        {o.action === 'HOLD'
                          ? 'Hold at SHJ'
                          : `Divert to ${o.alternate_iata}${o.alternate_name ? ` (${o.alternate_name})` : ''}`}
                      </Typography>
                      <Chip
                        size="small"
                        color={blocked ? 'error' : 'success'}
                        variant="outlined"
                        label={blocked ? 'Blocked' : 'Executable'}
                      />
                      {o.needs_verification && <Chip size="small" color="warning" label="Verify" />}
                    </Stack>
                    <Typography
                      variant="caption"
                      sx={{ display: 'block', color: 'text.secondary', fontFamily: 'monospace' }}
                    >
                      score {o.score} - fuel margin {o.fuel_margin_min ?? '-'}m - crew margin{' '}
                      {o.crew_margin_min ?? '-'}m
                      {o.est_arrival_utc ? ` - arrive ${t(o.est_arrival_utc)}` : ''}
                    </Typography>
                    {o.blocking_constraints?.map((b) => (
                      <Typography
                        key={b.code}
                        variant="caption"
                        sx={{ display: 'block', color: b.verify ? 'warning.main' : 'error.main' }}
                      >
                        {human(b.code)}
                        {b.margin_min != null ? ` (${b.margin_min} min)` : ''}
                      </Typography>
                    ))}
                    {o.reasons?.slice(0, 2).map((r) => (
                      <Typography
                        key={r}
                        variant="caption"
                        sx={{ display: 'block', color: 'text.secondary' }}
                      >
                        {r}
                      </Typography>
                    ))}
                  </Box>
                  <Collapse in={chosen && !hasOpen} mountOnEnter unmountOnExit>
                    <Box sx={formBoxSx}>{decisionForm}</Box>
                  </Collapse>
                </Box>
              );
            })}
          </Stack>
        )}

        {!hasOpen && options.data?.length > 0 && !pick && !freeForm && (
          <Button size="small" sx={{ mt: 1 }} onClick={() => setFreeForm(true)}>
            Record a decision without picking an option
          </Button>
        )}

        {hasOpen ? (
          <Stack spacing={1} sx={{ mt: 1 }}>
            <Alert severity="info" icon={false}>
              Decision #{f.decision_id}: <b>{f.last_decision}</b>{' '}
              <StatusChip status={f.decision_status} /> by {f.decided_by_name}
            </Alert>
            <Conseq
              lines={
                dt?.consequences?.[
                  history[0]?.decision_type === 'HOLD' ? 'HOLD' : history[0]?.alternate_iata
                ]
              }
            />
            {f.decision_status === 'PROPOSED' && (
              <Stack direction="row" spacing={1}>
                <Button variant="contained" onClick={() => verdict('APPROVED')}>
                  Approve as {actor?.role_code}
                </Button>
                <Button onClick={() => verdict('REJECTED')}>Reject</Button>
              </Stack>
            )}
            {f.decision_status === 'APPROVED' && f.last_decision === 'DIVERT' && !f.diverted_to && (
              <Button
                variant="contained"
                color="warning"
                onClick={() =>
                  run(
                    () => execute({ decisionId: f.decision_id }),
                    'Diversion executed, crew legality recalculated',
                  )
                }
              >
                Execute diversion
              </Button>
            )}
            {crewDecision && (
              <Button variant="contained" color="warning" onClick={execSwap}>
                Execute crew swap (approved)
              </Button>
            )}
          </Stack>
        ) : (
          (!options.data?.length || freeForm) && <Box sx={formBoxSx}>{decisionForm}</Box>
        )}
      </Section>

      {dv && (
        <Section title={`Station update - ${dv.alternate_iata}`}>
          <Typography variant="body2" sx={{ color: 'text.secondary' }}>
            Now: {human(dv.status)}, waiting for {human(dv.waiting_for)}, refuel{' '}
            {human(dv.refuel_status)}, handling {human(dv.handling_status)}
          </Typography>
          <Stack direction="row" spacing={1} sx={{ mt: 1 }}>
            <TextField
              select
              label="Waiting for"
              value={div.waiting_for ?? ''}
              onChange={(e) => setDiv({ ...div, waiting_for: e.target.value })}
            >
              {WAITING.map((x) => (
                <MenuItem key={x} value={x}>
                  {human(x)}
                </MenuItem>
              ))}
            </TextField>
            <TextField
              select
              label="Status"
              value={div.status ?? ''}
              onChange={(e) => setDiv({ ...div, status: e.target.value })}
            >
              {DIV_STATUS.map((x) => (
                <MenuItem key={x} value={x}>
                  {human(x)}
                </MenuItem>
              ))}
            </TextField>
            <TextField
              select
              label="Refuel"
              value={div.refuel_status ?? ''}
              onChange={(e) => setDiv({ ...div, refuel_status: e.target.value })}
            >
              {REFUEL.map((x) => (
                <MenuItem key={x} value={x}>
                  {human(x)}
                </MenuItem>
              ))}
            </TextField>
          </Stack>
          <Button
            sx={{ mt: 1 }}
            variant="outlined"
            disabled={Object.keys(div).length === 0}
            onClick={station}
          >
            Save station update
          </Button>
        </Section>
      )}

      {f.duty_id && (
        <Section title={`Standby cover (${f.binding_position ?? '?'})`}>
          {standby.isFetching && (
            <Typography variant="body2">Checking rest, roster, LVP and positioning...</Typography>
          )}
          {standby.data?.length === 0 && (
            <Typography variant="body2" sx={{ color: 'text.secondary' }}>
              No candidates.
            </Typography>
          )}
          <Stack spacing={1} sx={{ mt: 0.5 }}>
            {standby.data?.slice(0, 5).map((c) => (
              <Box
                key={c.crew_id}
                sx={{ border: 1, borderColor: 'divider', borderRadius: 1.5, p: 1 }}
              >
                <Stack direction="row" sx={{ justifyContent: 'space-between', gap: 1 }}>
                  <Typography variant="subtitle2">{c.full_name}</Typography>
                  <Typography variant="body2" sx={{ fontFamily: 'monospace' }}>
                    margin {fmtDur(c.margin_min)}
                  </Typography>
                </Stack>
                <Typography variant="caption" sx={{ display: 'block', color: 'text.secondary' }}>
                  {c.pattern_name} - {c.lvp_qualified ? 'LVP qualified' : 'no LVP'} - positioning{' '}
                  {c.positioning_min} min
                </Typography>
                <Typography
                  variant="caption"
                  sx={{
                    display: 'block',
                    color: c.verdict === 'CANDIDATE' ? 'success.main' : 'warning.main',
                    overflowWrap: 'anywhere',
                  }}
                >
                  {c.verdict}
                </Typography>
              </Box>
            ))}
          </Stack>
          <Typography variant="caption" sx={{ color: 'text.secondary' }}>
            Propose a swap from Crew Control; it needs an approved decision before it runs.
          </Typography>
        </Section>
      )}

      <Section title="Decision history and comments">
        {history.length === 0 && (
          <Typography variant="body2" sx={{ color: 'text.secondary', mt: 0.5 }}>
            No decisions for this flight yet.
          </Typography>
        )}
        {history.map((h) => (
          <Box key={h.decision_id} sx={{ mt: 1 }}>
            <Typography variant="caption" sx={{ color: 'text.secondary' }}>
              {fmtDateTime(ms(h.decided_at))} - {h.decided_by} ({h.decided_role})
            </Typography>
            <Typography variant="body2" component="div">
              <b>{h.decision_type}</b> <StatusChip status={h.status} />{' '}
              {h.alternate_iata && `via ${h.alternate_iata}`}
            </Typography>
            <Typography variant="body2" sx={{ color: 'text.secondary' }}>
              {h.rationale}
            </Typography>
            {h.approvals?.map((a) => (
              <Typography key={a.at} variant="caption" sx={{ display: 'block' }}>
                {a.verdict} by {a.by} ({a.role}){a.comment ? `: ${a.comment}` : ''}
              </Typography>
            ))}
          </Box>
        ))}
        <Divider sx={{ my: 1.5 }} />
        {comments.data?.map((c) => (
          <Box key={c.comment_id} sx={{ mb: 0.75 }}>
            <Typography variant="caption" sx={{ color: 'text.secondary' }}>
              {c.author} ({c.author_role}) - {fmtDateTime(ms(c.created_at))}
            </Typography>
            <Typography variant="body2">{c.body}</Typography>
          </Box>
        ))}
        <Stack direction="row" spacing={1} sx={{ mt: 1 }}>
          <TextField
            placeholder="Comment for the shared case"
            value={comment}
            onChange={(e) => setComment(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && comment.trim() && postComment()}
          />
          <Button variant="contained" disabled={!comment.trim()} onClick={postComment}>
            Post
          </Button>
        </Stack>
      </Section>
      <Section title="Activity (audit trail for this flight)">
        <Stack spacing={0.5} sx={{ mt: 0.5 }} data-src="audit_log (append-only) + API action log">
          {audit.data?.length === 0 && (
            <Typography variant="body2" sx={{ color: 'text.secondary' }}>
              Nothing recorded yet.
            </Typography>
          )}
          {audit.data?.slice(0, 12).map((a) => (
            <Stack key={a.audit_id} direction="row" spacing={1}>
              <Typography
                variant="caption"
                sx={{ width: 58, fontFamily: 'monospace', color: 'text.secondary' }}
              >
                {fmtZ(ms(a.occurred_at))}
              </Typography>
              <Typography variant="caption" sx={{ flex: 1 }}>
                <b>{a.actor ?? 'system'}</b>: {a.summary}
              </Typography>
            </Stack>
          ))}
        </Stack>
      </Section>
    </Stack>
  );
}

export default function FlightDrawer({ d }) {
  const dispatch = useAppDispatch();
  const f = d.flights.find((x) => x.flight_id === d.ops.selectedFlightId);
  return (
    <Drawer
      anchor="right"
      open={Boolean(f)}
      onClose={() => dispatch(selectFlight(null))}
      slotProps={{ paper: { sx: { width: { xs: '100%', sm: 600 }, p: 2.5 } } }}
    >
      {f && <DrawerBody key={f.flight_id} d={d} f={f} />}
    </Drawer>
  );
}
