import { useEffect, useRef, useState } from 'react';
import { useAskMutation, useGetAskQuestionsQuery } from '@/features/ops/opsApi';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { Pill, Sheet } from '../ui/ui';
import '../lenses/lenses.css';

const MODE = {
  predefined: ['From live data', 'legal'],
  ai: ['AI, grounded on case data', 'ai'],
  fallback: ['AI not configured', 'risk'],
  error: ['Unavailable', 'exceeded'],
};

// Ctrl+K assistant. Suggested questions are answered from the database; free text goes to Claude (when the key is
// set on the server) with only this case's database facts, so it cannot make flights or times up.
export default function AskSheet({ d, onClose }) {
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
      setLog((l) => [...l, { question, ...res }]);
    } catch (e) {
      setLog((l) => [...l, { question, mode: 'error', answer: getErrorMessage(e), source: null }]);
    }
  };

  const needle = q.trim().toLowerCase();
  const items = (sug.data?.items ?? []).filter((s) => !needle || s.toLowerCase().includes(needle));

  return (
    <Sheet bare onClose={onClose}>
      <div className="palette" data-src="ask() · predefined queries + grounded AI">
        <div className="pal-row">
          <label className="sr" htmlFor="pq">Ask about this case</label>
          <input
            id="pq"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && send()}
            placeholder="Ask about flights, crew, approvals… e.g. which flights have pilots without LVP"
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
            <div className="pal-ans" key={i}>
              <div className="pal-q">{m.question}</div>
              <div className="answer">{m.answer}</div>
              <div className="src">
                {MODE[m.mode]?.[0] && <Pill tone={MODE[m.mode][1]}>{MODE[m.mode][0]}</Pill>}
                {m.source && <> Answered from {m.source}</>}
              </div>
            </div>
          ))}
          {isLoading && <div className="pal-ans k">Thinking…</div>}
          <div ref={end} />
        </div>
        <div className="pal-ans k" style={{ fontSize: 12 }}>
          The assistant only reads data. It cannot approve, decide or change anything, and every question is recorded in the audit trail.
        </div>
      </div>
    </Sheet>
  );
}
