import { useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useAppDispatch } from '@/app/hooks';
import { useAskMutation, useGetAskQuestionsQuery } from '@/features/ops/opsApi';
import { selectFlight, setLens } from '@/features/ops/opsSlice';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { Pill } from '../ui/ui';
import '../sheets/ask.css';
import './chat.css';

const MODE = {
  predefined: ['From live data', 'legal'],
  ai: ['AI, grounded on case data', 'ai'],
  fallback: ['AI not configured', 'risk'],
  error: ['Unavailable', 'exceeded'],
  help: ['Built-in guide', 'ai'],
};
const REASON = { write: 'Read-only', pii: 'No personal data', injection: 'Rules cannot be changed', domain: 'Out of scope', length: 'Too long' };
const FLIGHT = /\bG9\d{3,4}D?\b|\bA6-?[A-Z]{3}\b/i;
const PRONOUN = /\b(it|that flight|this flight|that one|this one|the same flight|its)\b/i;
const keyFor = (c) => `fooChat:${c}`;

// The assistant as a chat: a docked panel on the right (not a popup), so the page stays usable while you talk.
// READ-ONLY and limited to this disruption; it never shows personal data. Answers carry the flights they are about and
// buttons that only NAVIGATE. The conversation survives minimising and closing (per case, for this browser session).
export default function AskChat({ d, state, setState, onOpenView }) {
  const dispatch = useAppDispatch();
  const navigate = useNavigate();
  const loc = useLocation();
  const [ask, { isLoading }] = useAskMutation();
  const sug = useGetAskQuestionsQuery(d.ctx, { skip: state === 'closed' });
  const caseId = d.ctx.case_id;
  const [log, setLog] = useState(() => {
    try {
      return JSON.parse(sessionStorage.getItem(keyFor(caseId))) ?? [];
    } catch {
      return [];
    }
  });
  const [q, setQ] = useState('');
  const end = useRef(null);
  const input = useRef(null);

  useEffect(() => {
    try {
      sessionStorage.setItem(keyFor(caseId), JSON.stringify(log.slice(-40)));
    } catch {
      /* private mode: the chat just does not persist */
    }
  }, [log, caseId]);
  useEffect(() => {
    end.current?.scrollIntoView?.({ block: 'end' });
  }, [log.length, isLoading, state]);
  useEffect(() => {
    if (state === 'open') input.current?.focus();
  }, [state]);
  useEffect(() => {
    if (state !== 'open') return undefined;
    const onKey = (e) => e.key === 'Escape' && !document.querySelector('.scrim.open') && setState('min');
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [state, setState]);

  // follow-ups: "what time must it leave?" -> remember the flight we were just talking about
  const lastFlight = [...log].reverse().map((m) => m.items?.[0]?.flight_no ?? FLIGHT.exec(m.question)?.[0]).find(Boolean);

  const send = async (text) => {
    const question = (text ?? q).trim();
    if (!question || isLoading) return;
    setQ('');
    const sent = !FLIGHT.test(question) && PRONOUN.test(question) && lastFlight ? `${question} (${lastFlight})` : question;
    setLog((l) => [...l, { role: 'user', text: question }]);
    try {
      const res = await ask({ question: sent, ...d.ctx }).unwrap();
      setLog((l) => [...l, { role: 'bot', question, items: [], actions: [], ...res }]);
    } catch (e) {
      setLog((l) => [...l, { role: 'bot', question, mode: 'error', answer: getErrorMessage(e), items: [], actions: [] }]);
    }
  };

  // navigation only: nothing here can write. The chat tucks itself away so the screen you asked for is visible.
  const go = (a) => {
    if (a.kind === 'open_flight') {
      if (['station', 'recovery'].includes(d.ops.lens)) dispatch(setLens('occ'));
      if (loc.pathname !== '/') navigate('/');
      dispatch(selectFlight(a.flight_id));
      setState('min');
    } else if (a.kind === 'open_view') {
      if (['approvals', 'notes', 'whatif', 'report'].includes(a.view)) onOpenView?.(a.view);
      else if (['crew', 'recovery', 'station', 'occ', 'dispatch'].includes(a.view)) {
        dispatch(setLens(a.view));
        if (loc.pathname !== '/') navigate('/');
        setState('min');
      } else {
        navigate(`/${a.view}`);
        setState('min');
      }
    }
  };

  if (state === 'closed') return null;
  if (state === 'min')
    return (
      <button type="button" className="chat-pill" onClick={() => setState('open')} aria-label="Open the assistant">
        <span className="chat-dot" /> Ask FOO <span className="kbd">⌘K</span>
        {log.length > 0 && <span className="chat-count">{log.filter((m) => m.role === 'bot').length}</span>}
      </button>
    );

  const starters = (sug.data?.items ?? []).slice(0, 8);
  return (
    <aside className="chat" aria-label="Assistant" data-src="ask() · guarded: read-only, domain-limited, no personal data">
      <header className="chat-h">
        <div>
          <b>Ask FOO</b>
          <span className="k">Read-only · this disruption only · no personal data</span>
        </div>
        <span className="chat-btns">
          <button type="button" className="btn ghost sm" onClick={() => setLog([])} disabled={log.length === 0} title="Start a new conversation">New chat</button>
          <button type="button" className="btn ghost sm" onClick={() => setState('min')} aria-label="Minimise" title="Minimise (Esc)">—</button>
          <button type="button" className="btn ghost sm" onClick={() => setState('closed')} aria-label="Close" title="Close">✕</button>
        </span>
      </header>

      <div className="chat-body" aria-live="polite">
        <div className="bub bot">
          <div className="answer">
            Hi, I'm the FOO assistant. Ask me about the flights, crew, deadlines and approvals on this case, or how any screen works, for example "How does the Recovery tab work?". I only read data: I can't change anything, and I show crew by position and number, never by name.
          </div>
          {!sug.data?.ai && sug.data && <div className="k" style={{ marginTop: 6 }}>Free-text questions need the AI key on the server; the suggested questions work now.</div>}
        </div>
        {log.length === 0 && (
          <div className="chat-starters">
            {starters.map((s) => (
              <button type="button" key={s} className="fchip" onClick={() => send(s)}>{s}</button>
            ))}
          </div>
        )}

        {log.map((m, i) =>
          m.role === 'user' ? (
            <div className="bub me" key={i}>{m.text}</div>
          ) : (
            <div className={`bub bot ${m.mode === 'refused' ? 'refused' : ''}`} key={i}>
              {m.title && <div className="ask-title">{m.title}</div>}
              <div className="answer">{m.answer}</div>
              {m.items?.length > 0 && (
                <div className="ask-items" data-src="v_flight_watch · deadlines (navigation only)">
                  {m.items.map((it) => (
                    <div className="ask-item" key={it.flight_id}>
                      <span className="meta">
                        <b>{it.flight_no} <span className="k">{it.route} · {it.status}</span></b>
                        {it.chips.length > 0 && <span className="pills">{it.chips.map((c) => <Pill key={c.label} tone={c.tone}>{c.label}</Pill>)}</span>}
                      </span>
                      {it.actions.map((a, k) => (
                        <button type="button" key={k} className={`btn sm ${a.primary ? 'primary' : ''}`} onClick={() => go(a)}>{a.label}</button>
                      ))}
                    </div>
                  ))}
                </div>
              )}
              {m.actions?.length > 0 && (
                <div className="ask-actions">
                  {m.actions.map((a, k) => <button type="button" key={k} className="btn sm" onClick={() => go(a)}>{a.label}</button>)}
                </div>
              )}
              {m.related?.length > 0 && (
                <div className="ask-related">
                  <span className="k">Related:</span>
                  {m.related.map((r) => <button type="button" key={r.id} className="fchip" disabled={isLoading} onClick={() => send(r.question)}>{r.title}</button>)}
                </div>
              )}
              <div className="src">
                {m.mode === 'refused' ? <Pill tone="exceeded">{REASON[m.reason] ?? 'Not allowed'}</Pill> : MODE[m.mode]?.[0] && <Pill tone={MODE[m.mode][1]}>{MODE[m.mode][0]}</Pill>}
                {m.source && <> {m.source}</>}
              </div>
            </div>
          ),
        )}
        {isLoading && (
          <div className="bub bot typing" aria-label="The assistant is typing">
            <i /><i /><i />
          </div>
        )}
        <div ref={end} />
      </div>

      <form
        className="chat-in"
        onSubmit={(e) => {
          e.preventDefault();
          send();
        }}
      >
        <label className="sr" htmlFor="chat-q">Message the assistant</label>
        <textarea
          id="chat-q"
          ref={input}
          rows={1}
          maxLength={300}
          value={q}
          placeholder="Ask about this case, or how a screen works…"
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault();
              send();
            }
          }}
        />
        <button type="submit" className="btn primary" disabled={!q.trim() || isLoading}>Send</button>
      </form>
      {lastFlight && <div className="chat-ctx k">Follow-ups like "it" or "that flight" mean {lastFlight}.</div>}
    </aside>
  );
}
