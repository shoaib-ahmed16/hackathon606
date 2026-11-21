import { useEffect, useMemo, useState } from 'react';
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { LogoMark } from '@/components/Logo';
import { APP_NAME } from '@/config/brand';
import { useSignOut } from '@/features/auth/useSignOut';
import {
  useAddRecordMutation,
  useCloseCaseMutation,
  useDeleteCaseMutation,
} from '@/features/ops/opsApi';
import { selectCase, setLens, toggleBriefing, toggleSources } from '@/features/ops/opsSlice';
import { useOps } from '@/features/ops/useOps';
import { iso, ms, stampMs } from '@/features/ops/helpers';
import { toggleMode } from '@/features/ui/uiSlice';
import { NowProvider, useNow, useWall } from '@/hooks/useNow';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { ConsoleProvider } from './ConsoleContext';
import ApprovalsDrawer from './drawers/ApprovalsDrawer';
import NotesDrawer from './drawers/NotesDrawer';
import AskSheet from './sheets/AskSheet';
import NewCaseSheet from './sheets/NewCaseSheet';
import ReportSheet from './sheets/ReportSheet';
import WhatIfSheet from './sheets/WhatIfSheet';
import { Cd, Pill, Sheet } from './ui/ui';
import { fmtTime, fmtZ, roleLabel } from './lib';

const LENSES = [
  ['occ', 'OCC'],
  ['dispatch', 'Dispatch'],
  ['crew', 'Crew Control'],
  ['station', 'Station'],
  ['recovery', 'Recovery'],
];

// Wall-clock + scenario clock in the strip. Its own component so only it ticks every second.
function Clock({ refreshedAt }) {
  const now = useNow();
  const wall = useWall();
  const d = new Date(now);
  const z = `${String(d.getUTCHours()).padStart(2, '0')}:${String(d.getUTCMinutes()).padStart(2, '0')}:${String(d.getUTCSeconds()).padStart(2, '0')}Z`;
  const age = refreshedAt ? Math.max(0, Math.floor((wall - refreshedAt) / 1000)) : null;
  return (
    <div className="clock" data-src="scenario_now()">
      <span className="clock-z">{z}</span>
      <span className="clock-l">
        {fmtTime(now)} SHJ{age != null ? ` · data ${age} s ago` : ''}
      </span>
    </div>
  );
}

function altChip(code, airport) {
  const a = airport.find((x) => x.iata === code);
  if (!a) return { cls: 'verify', mark: '?', text: 'verify' };
  if (a.op_status !== 'OPEN') return { cls: 'blocked', mark: '✕', text: a.op_status.toLowerCase() };
  if (a.fuel_ok === false) return { cls: 'blocked', mark: '✕', text: 'No fuel' };
  return { cls: '', mark: '✓', text: a.parking_available != null ? `${a.parking_available} stands` : 'Open' };
}

function Strip({ d, onSheet }) {
  const dispatch = useAppDispatch();
  const { kase, cases, airport, options, ops } = d;
  const hub = airport.find((a) => a.iata === kase?.hub_iata) ?? airport[0];
  const reopen = hub?.expected_reopen_utc ? ms(hub.expected_reopen_utc) : null;
  const pending = d.approvals.filter((x) => x.can_approve).length;
  const unread = d.notifications.unread;
  const altCodes = useMemo(
    () =>
      [
        ...new Set([
          ...airport.filter((a) => a.iata !== hub?.iata).map((a) => a.iata),
          ...options.filter((o) => o.alternate_iata).map((o) => o.alternate_iata),
        ]),
      ].sort(),
    [airport, options, hub?.iata],
  );
  return (
    <header className="strip" aria-label="Situation">
      <div className="brand">
        <LogoMark size={30} />
        <span className="bn">
          {APP_NAME}
          <small>{hub?.iata ?? kase?.hub_iata ?? 'Hub'} disruption room</small>
        </span>
      </div>
      <div className="scn" data-src="scenario / disruption_case">
        <span className="k">Case</span>
        <span className="scn-row">
          <span className="scn-dot" style={{ marginRight: 0 }} />
          <label className="sr" htmlFor="caseSel">
            Case and scenario
          </label>
          <select
            id="caseSel"
            value={ops.caseId ?? ''}
            onChange={(e) => {
              const c = cases.find((x) => x.case_id === Number(e.target.value));
              if (c) dispatch(selectCase(c));
            }}
          >
            {cases.map((c) => (
              <option key={c.case_id} value={c.case_id}>
                #{c.case_id} {c.title} ({c.scenario_kind.toLowerCase()}){c.phase === 'CLOSED' ? ' [closed]' : ''}
              </option>
            ))}
          </select>
        </span>
      </div>
      {hub && (
        <div className="hub" data-src="v_airport_status_current (hub)">
          <div className="hub-line">
            <span className="hub-code">{hub.iata}</span>
            <Pill tone={hub.op_status === 'OPEN' ? 'legal' : hub.op_status === 'CLOSED' ? 'exceeded' : 'risk'}>{human(hub.op_status)}</Pill>
            {hub.lvp_in_force && <Pill tone="disc">LVP in force</Pill>}
            {hub.visibility_m != null && <span className="k">RVR {hub.visibility_m} m</span>}
          </div>
          <div className="hub-line k">
            {reopen ? (
              <>
                <span title={`forecast quality: ${String(hub.quality ?? '').toLowerCase()}`}>Reopens ~{fmtZ(reopen)}</span> · <Cd at={reopen} />
              </>
            ) : (
              'No reopening forecast'
            )}
            {hub.arrival_capacity_per_hr != null && ` · arrivals ${hub.arrival_capacity_per_hr}/h`}
          </div>
        </div>
      )}
      <div className="alts" data-src="v_airport_status_current (alternates) + engine alternates">
        <span className="k">Alternates</span>
        <div className="alts-row">
          {altCodes.length === 0 && <span className="k">none ranked yet</span>}
          {altCodes.map((c) => {
            const a = altChip(c, airport);
            return (
              <span key={c} className={`alt ${a.cls}`}>
                <b>
                  {c} {a.mark}
                </b>
                {a.text}
              </span>
            );
          })}
        </div>
      </div>
      <div className="spacer" />
      <Clock refreshedAt={d.refreshedAt} />
      <div className="strip-actions">
        <button className="btn" onClick={() => onSheet('approvals')} data-src="decision PROPOSED ⨝ approval_policy" title="Decisions waiting for your approval">
          Approvals {pending > 0 && <span className="badge-count">{pending}</span>}
        </button>
        <button className="btn bell" onClick={() => onSheet('notes')} data-src="notification_outbox (IN_APP)" aria-label={`Notifications, ${unread} unread`}>
          🔔 {unread > 0 && <span className="badge-count">{unread}</span>}
        </button>
        <button className="btn" onClick={() => onSheet('ask')} title="Ask a question (Ctrl/Cmd + K)">
          Ask <span className="kbd">⌘K</span>
        </button>
      </div>
    </header>
  );
}
const human = (c) => String(c ?? '').replaceAll('_', ' ').toLowerCase().replace(/^./, (x) => x.toUpperCase());

function Bar({ d, onSheet }) {
  const dispatch = useAppDispatch();
  const navigate = useNavigate();
  const loc = useLocation();
  const signOut = useSignOut();
  const now = useNow();
  const { ops, actor } = d;
  const dated = d.deadlines.filter((x) => x.deadline_utc).sort((a, b) => ms(a.deadline_utc) - ms(b.deadline_utc));
  const next = dated.find((x) => ms(x.deadline_utc) >= now) ?? dated[dated.length - 1];
  const nextAt = next ? ms(next.deadline_utc) : null;
  const goLens = (l) => {
    dispatch(setLens(l));
    if (loc.pathname !== '/') navigate('/');
  };
  const nav = ({ isActive }) => `btn ghost ${isActive ? 'on-nav' : ''}`;
  return (
    <div className="bar">
      <div className="next" data-src="min(next_deadline_utc)">
        <Pill tone="exceeded">Next deadline</Pill>
        {next ? (
          <span>
            <Cd at={nextAt} className="cd" /> {next.flight_no}: {next.reason} ({fmtZ(nextAt)} / {fmtTime(nextAt)} SHJ)
          </span>
        ) : (
          <span className="k">No deadline is running right now.</span>
        )}
      </div>
      <button className="btn ghost" onClick={() => { if (loc.pathname !== '/') navigate('/'); dispatch(toggleBriefing()); }} aria-pressed={ops.briefing}>
        Since you last looked
      </button>
      <div className="lenses" role="group" aria-label="Role lens">
        {LENSES.map(([k, label]) => (
          <button key={k} className="lens" aria-pressed={ops.lens === k && loc.pathname === '/'} onClick={() => goLens(k)}>
            {label}
          </button>
        ))}
      </div>
      <span className="who">
        {actor?.display_name} · {roleLabel(actor?.role_code)}
      </span>
      <span className="tools">
        <button className="btn ghost" onClick={() => onSheet('newcase')}>New case</button>
        {d.kase && <button className="btn ghost" onClick={() => onSheet('case')} title="Close or delete this case, move the reopening forecast">Case…</button>}
        <NavLink to="/rules" className={nav}>Rules &amp; filters</NavLink>
        <NavLink to="/integrations" className={nav}>Integrations</NavLink>
        <NavLink to="/audit" className={nav}>Audit</NavLink>
        <NavLink to="/data-quality" className={nav}>Data quality</NavLink>
        <button className="btn ghost" onClick={() => onSheet('whatif')}>What if…</button>
        <button className="btn ghost" onClick={() => onSheet('report')}>Report</button>
        <button className="btn ghost" aria-pressed={ops.showSources} id="srcBtn" onClick={() => dispatch(toggleSources())} title="Show which database object feeds each part">
          Data sources
        </button>
        <button className="btn ghost" onClick={() => dispatch(toggleMode())}>Theme</button>
        <button className="btn ghost" onClick={signOut}>Sign out</button>
      </span>
    </div>
  );
}

// Case actions: close (keep history), delete (only if nobody acted), move the hub reopening forecast.
function CaseSheet({ d, onClose }) {
  const [add] = useAddRecordMutation();
  const [closeCase] = useCloseCaseMutation();
  const [deleteCase] = useDeleteCaseMutation();
  const { kase, airport, actor } = d;
  const hub = airport.find((a) => a.iata === kase?.hub_iata) ?? airport[0];
  const reopen = hub?.expected_reopen_utc ? ms(hub.expected_reopen_utc) : null;
  const canManage = ['OCC', 'ADMIN'].includes(actor?.role_code);
  const [confirm, setConfirm] = useState(null);
  const run = async (fn, ok) => {
    try {
      await fn();
      toast.success(ok);
      onClose();
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  const move = (min) =>
    run(
      () =>
        add({
          table: 'airport_status_event',
          body: {
            scenario_id: kase.scenario_id, iata: hub.iata, op_status: hub.op_status, reason: hub.reason, visibility_m: hub.visibility_m,
            lvp_in_force: hub.lvp_in_force, arrival_capacity_per_hr: hub.arrival_capacity_per_hr, parking_available: hub.parking_available,
            effective_from_utc: iso(stampMs(kase)), expected_reopen_utc: iso(reopen + min * 60000), quality: 'MANUAL', entered_by: actor.user_id,
            note: `Reopening forecast moved ${min > 0 ? '+' : ''}${min} min from the console`,
          },
        }).unwrap(),
      `${hub.iata} reopening moved ${min > 0 ? '+' : ''}${min} min. Recommendations re-rank.`,
    );
  return (
    <Sheet title={`Case #${kase?.case_id}: ${kase?.title}`} sub={`${kase?.scenario_kind} scenario, ${kase?.phase?.toLowerCase()}`} onClose={onClose}
      footer={<button className="btn ghost" onClick={onClose}>Close</button>}>
      {!canManage && <p className="k">Only OCC or admin can change a case.</p>}
      {canManage && hub && reopen && (
        <>
          <div className="field-l" style={{ marginTop: 0 }}>{hub.iata} reopening forecast ({fmtZ(reopen)})</div>
          <div className="ai-buttons" style={{ marginTop: 8 }}>
            <button className="btn" onClick={() => move(-30)}>30 min earlier</button>
            <button className="btn" onClick={() => move(30)}>30 min later</button>
          </div>
        </>
      )}
      {canManage && (
        <>
          <div className="field-l">Close or delete</div>
          {!confirm && (
            <div className="ai-buttons" style={{ marginTop: 8 }}>
              <button className="btn" disabled={kase?.phase === 'CLOSED'} onClick={() => setConfirm('close')}>Close case (keep history)</button>
              <button className="btn danger" onClick={() => setConfirm('delete')}>Delete case…</button>
            </div>
          )}
          {confirm && (
            <div className="state-note">
              {confirm === 'close'
                ? 'The case is marked closed. Decisions, comments and the audit trail are kept.'
                : 'Only a case nobody has decided on or commented on can be deleted. Otherwise the database keeps it for the audit trail and you must close it instead.'}
              <div className="ai-buttons" style={{ marginTop: 10 }}>
                <button
                  className={`btn ${confirm === 'delete' ? 'danger' : 'primary'}`}
                  onClick={() => run(() => (confirm === 'close' ? closeCase({ caseId: kase.case_id }) : deleteCase({ caseId: kase.case_id })).unwrap(), confirm === 'close' ? 'Case closed' : 'Case deleted')}
                >
                  {confirm === 'close' ? 'Close case' : 'Delete'}
                </button>
                <button className="btn ghost" onClick={() => setConfirm(null)}>Back</button>
              </div>
            </div>
          )}
        </>
      )}
    </Sheet>
  );
}

export default function ConsoleLayout() {
  const d = useOps();
  const [sheet, setSheet] = useState(null);
  const { ops } = d;

  useEffect(() => {
    document.body.classList.toggle('show-src', Boolean(ops.showSources));
    return () => document.body.classList.remove('show-src');
  }, [ops.showSources]);
  useEffect(() => {
    const onKey = (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setSheet('ask');
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  if (d.isLoading)
    return (
      <div className="app">
        <div className="skeleton" />
        <div className="skeleton" />
        <div className="skeleton" />
      </div>
    );
  if (d.error)
    return (
      <div className="page">
        <h2>Cannot reach the {APP_NAME} API</h2>
        <p className="lead">{getErrorMessage(d.error)}. Check that the API container is running (see backend/API_README.md).</p>
      </div>
    );

  const replay = d.kase && d.kase.scenario_kind !== 'LIVE';
  const close = () => setSheet(null);
  return (
    <ConsoleProvider value={d}>
      <NowProvider key={d.kase?.case_id ?? 'none'} kase={d.kase}>
        <div className={`app ${replay ? 'scenario-replay' : ''}`} id="app">
          <div>
            <div className="replay-banner">
              {d.kase?.scenario_kind} scenario. Nothing here affects live operations.
            </div>
            <Strip d={d} onSheet={setSheet} />
          </div>
          <Bar d={d} onSheet={setSheet} />
          {d.noCase ? (
            <div className="main" style={{ gridTemplateColumns: '1fr' }}>
              <section className="view">
                <div className="page">
                  <h2>No disruption case yet</h2>
                  <p className="lead">Create one to start: pick the airport and a time window and the real flights arriving then are loaded.</p>
                  <button className="btn primary" onClick={() => setSheet('newcase')}>New case</button>
                </div>
              </section>
            </div>
          ) : (
            <Outlet />
          )}
        </div>
        {sheet === 'approvals' && <ApprovalsDrawer d={d} onClose={close} />}
        {sheet === 'notes' && <NotesDrawer d={d} onClose={close} />}
        {sheet === 'ask' && <AskSheet d={d} onClose={close} />}
        {sheet === 'whatif' && <WhatIfSheet d={d} onClose={close} />}
        {sheet === 'report' && <ReportSheet d={d} onClose={close} />}
        {sheet === 'newcase' && <NewCaseSheet d={d} onClose={close} />}
        {sheet === 'case' && <CaseSheet d={d} onClose={close} />}
      </NowProvider>
    </ConsoleProvider>
  );
}
