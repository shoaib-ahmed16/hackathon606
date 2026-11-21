import { useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useAppDispatch } from '@/app/hooks';
import { useAskMutation, useGetAskQuestionsQuery } from '@/features/ops/opsApi';
import { selectFlight, setLens } from '@/features/ops/opsSlice';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { Pill, Sheet } from '../ui/ui';
import '../lenses/lenses.css';
import './ask.css';

const MODE = {
  predefined: ['From live data', 'legal'],
  ai: ['AI, grounded on case data', 'ai'],
  fallback: ['AI not configured', 'risk'],
  error: ['Unavailable', 'exceeded'],
  refused: ['Not allowed', 'exceeded'],
};
const REASON = { write: 'Read-only', pii: 'No personal data', injection: 'Rules cannot be changed', domain: 'Out of scope', length: 'Too long' };

// Ctrl+K assistant. READ-ONLY and limited to this disruption: it never changes anything, never shows personal data
// (crew appear as position and number) and refuses other topics. Answers come with the flights they are about and the
// next step a person can take; those buttons only NAVIGATE (open the flight, the approvals list, a view).
export default function AskSheet({ d, onClose, onOpenView }) {
  const dispatch = useAppDispatch();
  const navigate = useNavigate();
  const loc = useLocation();
  const [ask, { isLoading }] = useAskMutation();
  const sug = useGetAskQuestionsQuery(d.ctx);
  const [q, setQ] = useState('');
  const [log, setLog] = useState([]);
  const end = useRef(null);

  useEffect(() => {
    end.current?.scrollIntoView?.({ block: 'nearest' });
  }, [log.length, isLoading]);

  const send = async (text) => {
    const question = (text ?? q).trim();
    if (!question || isLoading) return;
    setQ('');
    try {
      const res = await ask({ question, ...d.ctx }).unwrap();
      setLog((l) => [...l, { question, items: [], actions: [], ...res }]);
    } catch (e) {
      setLog((l) => [...l, { question, mode: 'error', answer: getErrorMessage(e), source: null, items: [], actions: [] }]);
    }
  };

  // navigation only: nothing here can write
  const go = (a) => {
    if (a.kind === 'open_flight') {
      if (['station', 'recovery'].includes(d.ops.lens)) dispatch(setLens('occ'));
      if (loc.pathname !== '/') navigate('/');
      dispatch(selectFlight(a.flight_id));
      onClose();
    } else if (a.kind === 'open_view') {
      if (a.view === 'approvals') onOpenView?.('approvals');
      else if (a.view === 'notes') onOpenView?.('notes');
      else if (['crew', 'recovery', 'station', 'occ', 'dispatch'].includes(a.view)) {
        dispatch(setLens(a.view));
        if (loc.pathname !== '/') navigate('/');
        onClose();
      } else {
        navigate(`/${a.view}`);
        onClose();
      }
    }
  };

  const needle = q.trim().toLowerCase();
  const items = (sug.data?.items ?? []).filter((s) => !needle || s.toLowerCase().includes(needle));

  return (
    <Sheet bare onClose={onClose}>
      <div className="palette" data-src="ask() · guarded: read-only, domain-limited, no personal data">
        <div className="pal-row">
          <label className="sr" htmlFor="pq">Ask about this case</label>
          <input
            id="pq"
            value={q}
            maxLength={300}
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && send()}
            placeholder="Ask about flights, crew legality, deadlines, approvals… e.g. which flights have pilots without LVP"
            autoComplete="off"
          />
          <button type="button" className="btn primary" disabled={!q.trim() || isLoading} onClick={() => send()}>
            Ask
          </button>
        </div>
        {sug.data && !sug.data.ai && (
          <div className="pal-ans k">Suggested questions work now. Free-text questions need the AI key configured on the server.</div>
        )}
        <div className="pal-list">
          {items.map((s) => (
            <button type="button" key={s} className="pal-item" disabled={isLoading} onClick={() => send(s)}>
              {s}
            </button>
          ))}
          {needle && (
            <button type="button" className="pal-item on" disabled={isLoading} onClick={() => send()}>
              Ask: “{q.trim()}”
            </button>
          )}
        </div>
        <div className="pal-log" aria-live="polite">
          {log.map((m, i) => (
            <div className={`pal-ans ${m.mode === 'refused' ? 'refused' : ''}`} key={i}>
              <div className="pal-q">{m.question}</div>
              <div className="answer">{m.answer}</div>
              {m.items.length > 0 && (
                <div className="ask-items" data-src="v_flight_watch · deadlines (navigation only)">
                  {m.items.map((it) => (
                    <div className="ask-item" key={it.flight_id}>
                      <span className="meta">
                        <b>{it.flight_no} <span className="k">{it.route} · {it.status}</span></b>
                        {it.chips.length > 0 && (
                          <span className="pills">
                            {it.chips.map((c) => <Pill key={c.label} tone={c.tone}>{c.label}</Pill>)}
                          </span>
                        )}
                      </span>
                      {it.actions.map((a, k) => (
                        <button type="button" key={k} className={`btn sm ${a.primary ? 'primary' : ''}`} onClick={() => go(a)}>
                          {a.label}
                        </button>
                      ))}
                    </div>
                  ))}
                </div>
              )}
              {m.actions.length > 0 && (
                <div className="ask-actions">
                  {m.actions.map((a, k) => (
                    <button type="button" key={k} className="btn sm" onClick={() => go(a)}>
                      {a.label}
                    </button>
                  ))}
                </div>
              )}
              {(m.items.length > 0 || m.actions.length > 0) && m.mode !== 'refused' && (
                <div className="ask-next">These buttons only open the screen where a person acts; the assistant changes nothing.</div>
              )}
              <div className="src">
                {m.mode === 'refused' ? <Pill tone="exceeded">{REASON[m.reason] ?? 'Not allowed'}</Pill> : MODE[m.mode]?.[0] && <Pill tone={MODE[m.mode][1]}>{MODE[m.mode][0]}</Pill>}
                {m.source && <> {m.source}</>}
              </div>
            </div>
          ))}
          {isLoading && <div className="pal-ans k">Thinking…</div>}
          <div ref={end} />
        </div>
        <div className="pal-ans pal-guard" data-src="routes_ask guards">
          <span>Read-only: it cannot approve, decide or change anything</span>
          <span>No personal data: crew shown by position and number</span>
          <span>Only this disruption: other topics are refused</span>
          <span>Every question and refusal is audited</span>
        </div>
      </div>
    </Sheet>
  );
}
