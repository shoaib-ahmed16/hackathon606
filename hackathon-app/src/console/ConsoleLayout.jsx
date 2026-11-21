import { useEffect, useMemo, useRef, useState } from 'react';
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { LogoMark } from '@/components/Logo';
import { APP_NAME } from '@/config/brand';
import { useSignOut } from '@/features/auth/useSignOut';
import {
  useAddRecordMutation,
  useCloseCaseMutation,
  useGetBriefingQuery,
  useDeleteCaseMutation,
  usePushFeedMutation,
  useSetScenarioClockMutation,
} from '@/features/ops/opsApi';
import { markSeen, selectCase, setLens, toggleSources } from '@/features/ops/opsSlice';
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
import { plain } from './board/Briefing';
import { fmtTime, fmtZ, fmtZday, isRecovered, roleLabel } from './lib';

const LENSES = [
  ['occ', 'OCC'],
  ['dispatch', 'Dispatch'],
  ['crew', 'Crew Control'],
  ['station', 'Station'],
  ['recovery', 'Recovery'],
];

// "What's new": changes on this case since the operator last pressed "Mark all as seen". A popover, so it works on every screen.
function WhatsNew({ d }) {
  const dispatch = useAppDispatch();
  const now = useNow();
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  const since = d.ops.lastSeenAt;
  const { data } = useGetBriefingQuery({ ...d.ctx, since: since ?? undefined }, { skip: !d.ctx.case_id, pollingInterval: 15000 });
  const items = [...(data?.items ?? [])].reverse();   // newest first
  const n = items.length;
  useEffect(() => {
    if (!open) return undefined;
    const away = (e) => !ref.current?.contains(e.target) && setOpen(false);
    const esc = (e) => e.key === 'Escape' && setOpen(false);
    document.addEventListener('mousedown', away);
    document.addEventListener('keydown', esc);
    return () => { document.removeEventListener('mousedown', away); document.removeEventListener('keydown', esc); };
  }, [open]);
  return (
    <span className="wn-wrap" ref={ref}>
      <button type="button" className="whatsnew" onClick={() => setOpen((v) => !v)} aria-expanded={open} aria-haspopup="dialog"
        title="What changed on this case since you last pressed Mark all as seen: decisions, approvals, status changes">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z" /><path d="M19 17l.7 1.8 1.8.7-1.8.7L19 22l-.7-1.8-1.8-.7 1.8-.7z" /></svg>
        <span>What's new</span>
        {n > 0 ? <span className="wn-count" aria-label={`${n} changes`}>{n > 99 ? '99+' : n}</span> : <span className="wn-none">all caught up</span>}
      </button>
      {open && (
        <div className="wn-pop" role="dialog" aria-label="What's new on this case" data-src="v_case_timeline since last_seen">
          <div className="wn-head">
            <b>What's new on this case</b>
            <span className="k">{since ? `Since you last marked it as seen, ${fmtZ(ms(since))}` : 'Latest activity on this case'}</span>
          </div>
          {n === 0 ? <div className="wn-empty">Nothing new. You are up to date.</div> : (
            <ul className="wn-list">
              {items.slice(0, 12).map((i, k) => (
                <li key={k}><span className="wn-time">{fmtZ(ms(i.occurred_at))}</span><span>{plain(i.summary)}{i.actor ? <span className="k"> · {i.actor}</span> : null}</span></li>
              ))}
            </ul>
          )}
          {n > 12 && <div className="k" style={{ padding: '0 14px 6px' }}>Showing the latest 12 of {n}.</div>}
          <div className="wn-foot">
            <button type="button" className="btn sm primary" disabled={n === 0} onClick={() => { dispatch(markSeen(iso(now))); setOpen(false); }}>Mark all as seen</button>
          </div>
        </div>
      )}
    </span>
  );
}

// Wall-clock + scenario clock in the strip. Its own component so only it ticks every second.
function Clock({ refreshedAt, kase, role }) {
  const now = useNow();
  const wall = useWall();
  const [setClock, { isLoading }] = useSetScenarioClockMutation();
  const hasSimClock = Boolean(kase?.sim_clock_utc);
  const running = hasSimClock && kase.clock_running !== false;
  const canClock = hasSimClock && ['OCC', 'ADMIN'].includes(role);
  const act = async (body) => {
    try {
      await setClock({ id: kase.scenario_id, ...body }).unwrap();
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  const d = new Date(now);
  const z = `${String(d.getUTCHours()).padStart(2, '0')}:${String(d.getUTCMinutes()).padStart(2, '0')}:${String(d.getUTCSeconds()).padStart(2, '0')}Z`;
  const age = refreshedAt ? Math.max(0, Math.floor((wall - refreshedAt) / 1000)) : null;
  const date = new Intl.DateTimeFormat('en-GB', { weekday: 'short', day: '2-digit', month: 'short', year: 'numeric', timeZone: 'UTC' }).format(now);
  return (
    <div className="clock" data-src="scenario_now()">
      <span className="clock-d">{date}</span>
      <span className="clock-z">{z}</span>
      <span className="clock-l">
        {fmtTime(now)} SHJ{hasSimClock ? (running ? ' · running' : ' · paused') : age != null ? ` · data ${age} s ago` : ''}
        {canClock && (
          <>
            {' '}
            <button type="button" className="clock-btn" disabled={isLoading} onClick={() => act({ action: running ? 'pause' : 'run' })}
              title={running ? 'Pause the scenario clock: the time stands still, here and in every record' : 'Run the scenario clock: records are stamped with the time you see'}
              aria-label={running ? 'Pause the scenario clock' : 'Run the scenario clock'}>{running ? '⏸' : '▶'}</button>
            <button type="button" className="clock-btn" disabled={isLoading} onClick={() => act({ action: 'advance', minutes: 15 })} title="Move the scenario clock forward 15 minutes">+15 min</button>
          </>
        )}
      </span>
    </div>
  );
}

function altChip(code, airport) {
  const a = airport.find((x) => x.iata === code);
  if (!a) return { cls: 'verify', mark: '?', text: 'verify' };
  if (a.op_status !== 'OPEN') return { cls: 'blocked', mark: '✕', text: a.op_status.toLowerCase() };
  if (a.fuel_ok === false) return { cls: 'blocked', mark: '✕', text: 'No fuel' };
  // free stands = what the station reported minus diverted aircraft still on the ground there (the stand is given back when they leave)
  const free = a.stands_free ?? a.parking_available;
  return { cls: '', mark: '✓', text: free != null ? `${free} stands` : 'Open', title: a.stands_diverted > 0 ? `${a.parking_available} reported, ${a.stands_diverted} used by diverted aircraft` : undefined };
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
  // the alternates the engine may use: every ACTIVE one from the alternates list (even before anyone has entered its status),
  // plus any airport with a status that is not on the list; an alternate that was switched off disappears from the strip
  const altCodes = useMemo(() => {
    const list = d.alternates ?? [];
    const off = new Set(list.filter((a) => !a.is_active).map((a) => a.alt_iata));
    return [
      ...new Set([
        ...list.filter((a) => a.is_active).map((a) => a.alt_iata),
        ...airport.filter((a) => a.iata !== hub?.iata).map((a) => a.iata),
        ...options.filter((o) => o.alternate_iata).map((o) => o.alternate_iata),
      ]),
    ]
      .filter((c) => !off.has(c))
      .sort();
  }, [d.alternates, airport, options, hub?.iata]);
  return (
    <header className="strip" aria-label="Situation">
      <NavLink to="/" end className="brand brand-link" title="Go to the home board" aria-label={`${APP_NAME}: home`}>
        <LogoMark size={36} />
        <span className="bn">{APP_NAME}</span>
      </NavLink>
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
        <div className="hub" data-src="v_airport_status_current (hub)">
          <div className="hub-line">
            <span className="hub-code">{hub.iata}</span>
            <button type="button" className="hub-edit" aria-label={`Update ${hub.iata} status`} title={`Update ${hub.iata} status (open, closed, LVP, reopening time)`} onClick={() => onAirport(hub.iata)}>✎</button>
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
              <button type="button" key={c} className={`alt ${a.cls}`} onClick={() => onAirport(c)} title={a.cls === 'verify' ? `${c} is not confirmed. Click to verify it.` : `${a.title ? `${a.title}. ` : ''}Click to update ${c}`}>
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
      <Clock refreshedAt={d.refreshedAt} kase={kase} role={d.actor?.role_code} />
      <div className="strip-actions">
        <button className="btn" onClick={() => onSheet('approvals')} data-src="decision PROPOSED ⨝ approval_policy" title="Decisions waiting for your approval">
          Approvals <span className="badge-count" style={{ visibility: pending > 0 ? 'visible' : 'hidden' }}>{pending || 0}</span>
        </button>
        <button className="btn bell" onClick={() => onSheet('notes')} data-src="notification_outbox (IN_APP)" aria-label={`Notifications, ${unread} unread`}>
          🔔 <span className="badge-count" style={{ visibility: unread > 0 ? 'visible' : 'hidden' }}>{unread || 0}</span>
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

// What each role sees in the actions row (inline) and under "Tools" (menu). The same pages still exist for everyone who may open them.
const ROLE_TOOLS = {
  OCC: { inline: ['newcase', 'manage', 'whatif', 'report', 'alternates', 'capacity'], menu: ['rules', 'integrations', 'audit', 'quality', 'explorer', 'push', 'sources'] },
  ADMIN: { inline: ['newcase', 'manage', 'whatif', 'report', 'alternates', 'capacity'], menu: ['rules', 'integrations', 'audit', 'quality', 'explorer', 'push', 'sources'] },
  DISPATCH: { inline: ['newcase', 'whatif', 'report', 'capacity'], menu: ['rules', 'audit', 'quality'] },
  CREW_CONTROL: { inline: ['report'], menu: ['audit', 'quality'] },
  RECOVERY: { inline: ['report', 'capacity'], menu: ['audit'] },
  STATION: { inline: ['capacity'], menu: ['audit'] },
};

// One "Tools" button that opens a small list; closes on a click outside, Escape, or after choosing something.
function ToolsMenu({ children }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const away = (e) => !ref.current?.contains(e.target) && setOpen(false);
    const esc = (e) => e.key === 'Escape' && setOpen(false);
    document.addEventListener('mousedown', away);
    document.addEventListener('keydown', esc);
    return () => {
      document.removeEventListener('mousedown', away);
      document.removeEventListener('keydown', esc);
    };
  }, [open]);
  const kids = Array.isArray(children) ? children.flat().filter(Boolean) : children;
  if (!kids || kids.length === 0) return null;
  return (
    <span className="tools-menu" ref={ref}>
      <button type="button" className="btn ghost" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen((v) => !v)}>Tools ▾</button>
      {open && <div className="tools-pop" role="menu" onClick={() => setOpen(false)}>{children}</div>}
    </span>
  );
}

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
  // a deadline that passed within the last hour still comes first (in red, "passed N min ago"); older ones do not hide what is coming
  const next = dated.find((x) => ms(x.deadline_utc) >= now - 3600000) ?? dated[dated.length - 1];
  const nextAt = next ? ms(next.deadline_utc) : null;
  const reserve = d.deadlines.find((x) => x.at_reserve && !d.flights.find((f) => f.flight_id === x.flight_id && isRecovered(f)));   // fuel already at reserve: a fixed state, not a countdown
  const goLens = (l) => {
    dispatch(setLens(l));
    if (loc.pathname !== '/') navigate('/');
  };
  const nav = ({ isActive }) => `btn ghost ${isActive ? 'on-nav' : ''}`;
  const mine = ROLE_TOOLS[actor?.role_code] ?? { inline: ['report'], menu: ['audit'] };
  return (
    <div className="bar">
      <div className="bar-top">
      <div className="next" data-src="min(next_deadline_utc)">
        <Pill tone="exceeded">Next deadline</Pill>
        {reserve ? (
          <span><b className="c-exceeded">{reserve.flight_no}: {reserve.reason}</b> <span className="k">verify position and fuel now</span></span>
        ) : next ? (
          <span>
            <Cd at={nextAt} className="cd" /> {next.flight_no}: {next.reason} ({fmtZday(nextAt, now)} / {fmtTime(nextAt)} SHJ)
          </span>
        ) : (
          <span className="k">No deadline is running right now.</span>
        )}
      </div>
      <WhatsNew d={d} />
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
      {/* each role sees its own actions in the row; everything else is one click away under "Tools" */}
      <span className="tools" role="toolbar" aria-label="Actions">
        {mine.inline.includes('newcase') && <button className="btn ghost" onClick={() => onSheet('newcase')}>New case</button>}
        {mine.inline.includes('manage') && d.kase && <button className="btn ghost" onClick={() => onSheet('case')} title="Close this case or move the reopening forecast">Manage case</button>}
        {mine.inline.includes('whatif') && <button className="btn ghost" onClick={() => onSheet('whatif')}>What if</button>}
        {mine.inline.includes('report') && <button className="btn ghost" onClick={() => onSheet('report')}>Report</button>}
        {mine.inline.includes('alternates') && <NavLink to="/alternates" className={nav} title="Add, edit or switch off the alternate airports">Alternates</NavLink>}
        {mine.inline.includes('capacity') && <NavLink to="/capacity" className={nav}>Airport capacity</NavLink>}
        <ToolsMenu>
          {mine.menu.includes('rules') && <NavLink to="/rules" className={nav}>Rules &amp; filters</NavLink>}
          {mine.menu.includes('integrations') && <NavLink to="/integrations" className={nav}>Integrations</NavLink>}
          {mine.menu.includes('audit') && <NavLink to="/audit" className={nav}>Audit trail</NavLink>}
          {mine.menu.includes('quality') && <NavLink to="/data-quality" className={nav}>Data quality</NavLink>}
          {mine.menu.includes('explorer') && <NavLink to="/data" className={nav} title="Browse every table and its relations (read-only)">Data explorer</NavLink>}
          {mine.menu.includes('push') && (
            <button className="btn ghost" disabled={pushing} onClick={onPush} title="Advance the live case with simulated movements, passengers, crew duty status and fuel (safe to press again)">
              {pushing ? 'Pushing…' : 'Push live data'}
            </button>
          )}
          {mine.menu.includes('sources') && (
            <button className="btn ghost" aria-pressed={ops.showSources} id="srcBtn" onClick={() => dispatch(toggleSources())} title="Show which database object feeds each part">
              Data sources
            </button>
          )}
        </ToolsMenu>
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
              {actor?.role_code === 'ADMIN' && <button className="btn danger" onClick={() => setConfirm('delete')}>Delete case…</button>}
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

  // the Station view is the one screen meant for a phone or tablet: below 768 px it drops the desk-sized chrome (see console.css)
  useEffect(() => {
    document.body.classList.toggle('station-lens', ops.lens === 'station');
    return () => document.body.classList.remove('station-lens');
  }, [ops.lens]);
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
        <button type="button" className="btn primary" onClick={() => window.location.reload()}>Try again</button>
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
            {d.reconnecting && <div className="conn-banner" role="status">Connection to the server was interrupted. Showing the last data received; retrying automatically.</div>}
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
