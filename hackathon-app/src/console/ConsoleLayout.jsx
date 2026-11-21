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
  usePushFeedMutation,
} from '@/features/ops/opsApi';
import { selectCase, setLens, toggleBriefing, toggleSources } from '@/features/ops/opsSlice';
import { useOps } from '@/features/ops/useOps';
import { iso, ms, stampMs } from '@/features/ops/helpers';
import { toggleMode } from '@/features/ui/uiSlice';
import { useAppSelector } from '@/app/hooks';
import { NowProvider, useMinuteNow, useNow, useWall } from '@/hooks/useNow';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { ConsoleProvider } from './ConsoleContext';
import ApprovalsDrawer from './drawers/ApprovalsDrawer';
import NotesDrawer from './drawers/NotesDrawer';
import AirportSheet from './sheets/AirportSheet';
import AskChat from './drawers/AskChat';
import NewCaseSheet from './sheets/NewCaseSheet';
import ReportSheet from './sheets/ReportSheet';
import WhatIfSheet from './sheets/WhatIfSheet';
import { Cd, Pill, Sheet } from './ui/ui';
import { fmtTime, fmtZ, fmtZday, roleLabel } from './lib';

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
  const date = new Intl.DateTimeFormat('en-GB', { weekday: 'short', day: '2-digit', month: 'short', year: 'numeric', timeZone: 'UTC' }).format(now);
  return (
    <div className="clock" data-src="scenario_now()">
      <span className="clock-d">{date}</span>
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

function ThemeIcon({ dark }) {
  // dark mode shows a sun (switch to light), light mode shows a moon (switch to dark)
  return dark ? (
    <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
      <circle cx="12" cy="12" r="4.2" />
      <path d="M12 2.5v2.2M12 19.3v2.2M2.5 12h2.2M19.3 12h2.2M5.3 5.3l1.6 1.6M17.1 17.1l1.6 1.6M5.3 18.7l1.6-1.6M17.1 6.9l1.6-1.6" />
    </svg>
  ) : (
    <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M20.5 14.2A8.5 8.5 0 0 1 9.8 3.5a8.5 8.5 0 1 0 10.7 10.7z" />
    </svg>
  );
}

function Strip({ d, onSheet, onAirport }) {
  const dispatch = useAppDispatch();
  const signOut = useSignOut();
  const dark = useAppSelector((s) => s.ui.mode) === 'dark';
  const now = useMinuteNow(); // the strip only needs the day, so it does not re-render every second
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
        <LogoMark size={36} />
        <span className="bn">{APP_NAME}</span>
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
                #{c.case_id} {c.title} ({c.scenario_kind.toLowerCase()})
              </option>
            ))}
          </select>
        </span>
      </div>
      {!hub && kase?.hub_iata && (
        <button type="button" className="hub hub-btn" data-src="v_airport_status_current (hub)" onClick={() => onAirport(kase.hub_iata)} title="Nobody has confirmed this airport yet. Click to verify it.">
          <div className="hub-line">
            <span className="hub-code">{kase.hub_iata}</span>
            <Pill tone="verify">Not verified</Pill>
          </div>
          <div className="hub-line k">No status on record. Click to verify</div>
        </button>
      )}
      {hub && (
        <div className="hub hub-btn" role="button" tabIndex={0} data-src="v_airport_status_current (hub)" onClick={() => onAirport(hub.iata)} onKeyDown={(e) => e.key === 'Enter' && onAirport(hub.iata)} title="Click to update the hub status">
          <div className="hub-line">
            <span className="hub-code">{hub.iata}</span>
            <Pill tone={hub.op_status === 'OPEN' ? 'legal' : hub.op_status === 'CLOSED' ? 'exceeded' : 'risk'}>{human(hub.op_status)}</Pill>
            {hub.lvp_in_force && <Pill tone="disc">LVP in force</Pill>}
            {hub.visibility_m != null && <span className="k">RVR {hub.visibility_m} m</span>}
          </div>
          <div className="hub-line k">
            {reopen ? (
              <>
                <span title={`forecast quality: ${String(hub.quality ?? '').toLowerCase()}`}>Reopens ~{fmtZday(reopen, now)}</span> · <Cd at={reopen} />
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
              <button type="button" key={c} className={`alt ${a.cls}`} onClick={() => onAirport(c)} title={a.cls === 'verify' ? `${c} is not confirmed. Click to verify it.` : `Click to update ${c}`}>
                <b>
                  {c} {a.mark}
                </b>
                {a.text}
              </button>
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
        <button className="btn icon-btn" onClick={() => dispatch(toggleMode())} aria-label={dark ? 'Switch to light theme' : 'Switch to dark theme'} title={dark ? 'Light theme' : 'Dark theme'}>
          <ThemeIcon dark={dark} />
        </button>
        <button className="btn icon-btn" onClick={signOut} aria-label="Sign out" title={`Sign out (${d.actor?.display_name ?? ''})`}>
          <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <path d="M9 4H5.5A1.5 1.5 0 0 0 4 5.5v13A1.5 1.5 0 0 0 5.5 20H9M16 8l4 4-4 4M20 12H9" />
          </svg>
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
  const now = useNow();
  const { ops, actor } = d;
  const [pushFeed, { isLoading: pushing }] = usePushFeedMutation();
  const onPush = async () => {
    try {
      const r = await pushFeed().unwrap();
      toast.success(
        r.events_applied || r.crew_duties_active || r.crew_duties_completed
          ? `Feed pushed: ${r.flights_updated} flights, ${r.events_applied} events, ${r.crew_duties_active} duties started, ${r.crew_duties_completed} completed, ${r.fuel_estimates} fuel updates${r.clock_moved_to ? ', clock moved to now' : ''}`
          : 'Feed pushed: already up to date',
      );
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
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
      <div className="bar-top">
      <div className="next" data-src="min(next_deadline_utc)">
        <Pill tone="exceeded">Next deadline</Pill>
        {next ? (
          <span>
            <Cd at={nextAt} className="cd" /> {next.flight_no}: {next.reason} ({fmtZday(nextAt, now)} / {fmtTime(nextAt)} SHJ)
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
      </div>
      <span className="tools">
        <button className="btn ghost" onClick={() => onSheet('newcase')}>New case</button>
        {d.kase && <button className="btn ghost" onClick={() => onSheet('case')} title="Close or delete this case, move the reopening forecast">Manage case</button>}
        <NavLink to="/rules" className={nav}>Rules &amp; filters</NavLink>
        <NavLink to="/integrations" className={nav}>Integrations</NavLink>
        <NavLink to="/capacity" className={nav}>Airport capacity</NavLink>
        <NavLink to="/audit" className={nav}>Audit</NavLink>
        <NavLink to="/data-quality" className={nav}>Data quality</NavLink>
        {['OCC', 'ADMIN'].includes(actor?.role_code) && <NavLink to="/data" className={nav} title="Browse every table and its relations (read-only)">Data explorer</NavLink>}
        <button className="btn ghost" onClick={() => onSheet('whatif')}>What if</button>
        <button className="btn ghost" disabled={pushing} onClick={onPush} title="Advance the live case with simulated movements, passengers, crew duty status and fuel (safe to press again)">
          {pushing ? 'Pushing…' : 'Push live data'}
        </button>
        <button className="btn ghost" onClick={() => onSheet('report')}>Report</button>
        <button className="btn ghost" aria-pressed={ops.showSources} id="srcBtn" onClick={() => dispatch(toggleSources())} title="Show which database object feeds each part">
          Data sources
        </button>
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
  const [chat, setChat] = useState('closed'); // the assistant is a docked chat: closed | open | min
  const [airportIata, setAirportIata] = useState(null);
  const { ops } = d;

  useEffect(() => {
    document.body.classList.toggle('show-src', Boolean(ops.showSources));
    return () => document.body.classList.remove('show-src');
  }, [ops.showSources]);
  useEffect(() => {
    const onKey = (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setChat((c) => (c === 'open' ? 'min' : 'open'));
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
            <Strip d={d} onSheet={(v) => (v === 'ask' ? setChat((c) => (c === 'open' ? 'min' : 'open')) : setSheet(v))} onAirport={setAirportIata} />
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
        <AskChat key={d.ctx.case_id} d={d} state={chat} setState={setChat} onOpenView={(v) => { setChat('min'); setSheet(v); }} />
        {sheet === 'whatif' && <WhatIfSheet d={d} onClose={close} />}
        {sheet === 'report' && <ReportSheet d={d} onClose={close} />}
        {sheet === 'newcase' && <NewCaseSheet d={d} onClose={close} />}
        {sheet === 'case' && <CaseSheet d={d} onClose={close} />}
        {airportIata && <AirportSheet d={d} iata={airportIata} onClose={() => setAirportIata(null)} />}
      </NowProvider>
    </ConsoleProvider>
  );
}
