import { useEffect, useRef } from 'react';
import { createPortal } from 'react-dom';
import { cdText } from '@/features/ops/time';
import { useNow } from '@/hooks/useNow';
import { roleLabel, toneFor } from '../lib';

export const Pill = ({ tone = 'neutral', children, title }) => (
  <span className={`pill t-${tone}`} title={title}>
    {children}
  </span>
);

// Countdown to a UTC time. The only thing that re-renders every second on the board.
export function Cd({ at, className = '', big = false }) {
  const now = useNow();
  const long = at != null && ((at - now) / 60000 >= 60 || at < now);
  return (
    <span className={`${big ? `cd-big ${long ? 'long' : ''}` : 'cd'} c-${toneFor(at, now)} ${className}`}>
      {cdText(at, now)}
    </span>
  );
}

// Modal sheet (propose / approve / reject / execute / answer ...). Esc and a click outside close it.
export function Sheet({ title, sub, children, footer, onClose, wide, bare }) {
  const ref = useRef(null);
  const closeRef = useRef(onClose);
  // parents pass a new function every render; keep the latest without re-running the mount effect below
  useEffect(() => {
    closeRef.current = onClose;
  });
  useEffect(() => {
    const onKey = (e) => e.key === 'Escape' && closeRef.current?.();
    document.addEventListener('keydown', onKey);
    // focus the first field ONCE when the sheet opens (re-focusing on every parent refresh moved the cursor while typing)
    ref.current?.querySelector('textarea, input, select, button:not(.close-x)')?.focus();
    return () => document.removeEventListener('keydown', onKey);
  }, []);
  return createPortal(
    <div className="scrim open" role="dialog" aria-modal="true" aria-label={title} onMouseDown={(e) => e.target === e.currentTarget && onClose?.()}>
      <div className={`sheet ${wide ? 'wide' : ''}`} ref={ref}>
        {!bare && (
          <div className="sheet-h">
            <h2>{title}</h2>
            {sub && <p>{sub}</p>}
          </div>
        )}
        {bare ? children : <div className="sheet-b">{children}</div>}
        {footer && <div className="sheet-f">{footer}</div>}
      </div>
    </div>,
    document.body,
  );
}

// Right-hand drawer (approvals, notifications).
export function Drawer({ title, sub, onClose, children }) {
  const closeRef = useRef(onClose);
  useEffect(() => {
    closeRef.current = onClose;
  });
  useEffect(() => {
    const onKey = (e) => e.key === 'Escape' && closeRef.current?.();
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, []);
  return createPortal(
    <>
      <div className="panel-scrim open" onClick={onClose} style={{ zIndex: 54 }} />
      <aside className="drawer open" role="dialog" aria-modal="true" aria-label={title}>
        <div className="sheet-h" style={{ display: 'flex', alignItems: 'center' }}>
          <div>
            <h2>{title}</h2>
            {sub && <p>{sub}</p>}
          </div>
          <button className="btn ghost" style={{ marginLeft: 'auto' }} onClick={onClose}>
            Close
          </button>
        </div>
        <div className="sheet-b">{children}</div>
      </aside>
    </>,
    document.body,
  );
}

// Single-choice chips ("Why a different option?"): value is the chosen text or null.
export function ReasonChips({ options, value, onChange }) {
  return (
    <div className="reason-chips">
      {options.map((r) => (
        <button key={r} type="button" aria-pressed={value === r} onClick={() => onChange(r)}>
          {r}
        </button>
      ))}
    </div>
  );
}

export const Empty = ({ children }) => <div className="empty">{children}</div>;

// "Needs approval 1/2" style role chips
export function RoleChips({ roles, approved = [], rejected = [], me }) {
  return (
    <div className="roles" aria-label="Required approvals">
      {roles.map((r) => {
        const ok = approved.includes(r.code ?? r);
        const no = rejected.includes(r.code ?? r);
        const code = r.code ?? r;
        return (
          <span key={code} className={`role ${ok ? 'ok' : no ? 'no' : 'wait'}`}>
            {ok ? '✓' : no ? '✕' : '⏳'} {r.label ?? roleLabel(code)}
            {me === code ? ' (you)' : ''}
            {ok ? '' : no ? '' : ' · waiting'}
          </span>
        );
      })}
    </div>
  );
}

// "What will happen" list. Lines come from the engine as [icon, text] pairs: ✓ ok, ! caution, ✕ blocked, ? unknown, i info.
const ICON_CLASS = { '✓': 'c-legal', '!': 'c-risk', '✕': 'c-exceeded', '?': 'c-verify' };
export function Conseq({ lines }) {
  const rows = lines?.length ? lines : [['i', 'No downstream changes detected']];
  return (
    <ul className="conseq" data-src="flight_decision_inputs() + rank_alternates() (read-only preview)">
      {rows.map(([i, t], k) => (
        <li key={k}>
          <span className={`ic ${ICON_CLASS[i] ?? 'c-muted'}`}>{i}</span>
          <span>{t}</span>
        </li>
      ))}
    </ul>
  );
}

// Crew duty ribbon: sign-in to +3 h discretion, with markers for now, projected landing and legal end.
export function Ribbon({ c, compact = false }) {
  const now = useNow();
  if (!c?.signIn || !c?.disc) return null;
  const span = c.disc - c.signIn;
  const p = (t) => Math.max(0, Math.min(100, ((t - c.signIn) / span) * 100));
  const z = (t) => {
    const d = new Date(t);
    return `${String(d.getUTCHours()).padStart(2, '0')}:${String(d.getUTCMinutes()).padStart(2, '0')}Z`;
  };
  return (
    <>
      <div className="ribbon">
        <div className="rb-track">
          <div className="rb-used" style={{ width: `${p(now)}%` }} />
          <div className="rb-disc" style={{ left: `${p(c.legal)}%`, right: 0 }} />
        </div>
        <div className="rb-mark" style={{ left: `${p(now)}%` }} />
        {c.proj && <div className="rb-mark proj" style={{ left: `${p(c.proj)}%` }} />}
        <div className="rb-mark legal" style={{ left: `${p(c.legal)}%` }} />
      </div>
      {!compact && (
        <div className="rb-legend">
          <span><i className="lg-now" />Now {z(now)}</span>
          {c.proj && <span><i className="lg-proj" />Lands {z(c.proj)}</span>}
          <span><i className="lg-legal" />Legal end {z(c.legal)}</span>
          <span><i className="lg-disc" />Discretion to {z(c.disc)}</span>
          <span className="k">Sign-in {z(c.signIn)}</span>
        </div>
      )}
    </>
  );
}
