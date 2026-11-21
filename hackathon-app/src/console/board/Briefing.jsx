import { useState } from 'react';
import { useAppDispatch } from '@/app/hooks';
import { useGetBriefingQuery } from '@/features/ops/opsApi';
import { markSeen } from '@/features/ops/opsSlice';
import { iso, ms } from '@/features/ops/helpers';
import { useNow } from '@/hooks/useNow';
import { Pill } from '../ui/ui';
import { fmtZ, plainCodes } from '../lib';

// The case timeline stores technical audit text ("INSERT DIVERT decision 8 (PROPOSED)"); say it in plain words.
const TYPE_WORD = { CREW_REPLACE: 'crew replacement', DIVERT: 'diversion', HOLD: 'hold', RECOVER: 'departure from the alternate', DELAY: 'delay', CANCEL: 'cancellation', COMMANDER_DISCRETION: "commander's discretion", AIRCRAFT_SWAP: 'aircraft swap' };
const STATUS_WORD = { PROPOSED: 'proposed', APPROVED: 'approved', REJECTED: 'rejected', EXECUTED: 'executed', REVOKED: 'withdrawn' };
const word = (t) => TYPE_WORD[t] ?? String(t).replaceAll('_', ' ').toLowerCase();
const cap = (x) => x.charAt(0).toUpperCase() + x.slice(1);
const plain = (s = '') => {
  let m = /^INSERT (\w+) decision \d+ \((\w+)\)/.exec(s);
  if (m) return `Proposed: ${word(m[1])}`;
  m = /^UPDATE (\w+) decision \d+ \((\w+)\)/.exec(s);
  if (m) return `${cap(STATUS_WORD[m[2]] ?? m[2].toLowerCase())}: ${word(m[1])}`;
  m = /^(\w+) decision \d+ \((\w+)\)/.exec(s);
  if (m) return `${cap(STATUS_WORD[m[2]] ?? m[2].toLowerCase())}: ${word(m[1])}`;
  m = /^(APPROVED|REJECTED) (\w+) decision \d+/.exec(s);
  if (m) return `${cap(STATUS_WORD[m[1]] ?? m[1].toLowerCase())}: ${word(m[2])}`;
  if (/^disruption_case UPDATE/.test(s)) return 'Case updated';
  if (/^disruption_case INSERT/.test(s)) return 'Case opened';
  // single status words from the database (DIVERTING, READY, LANDING ...): lower case, never shouted
  return plainCodes(s).replace(/\b[A-Z]{4,}\b/g, (w) => w.toLowerCase());
};

// What changed since the operator last looked, from the case timeline (decisions, status changes, diversions, comments).
export default function Briefing({ d }) {
  const dispatch = useAppDispatch();
  const now = useNow();
  const since = d.ops.lastSeenAt;
  const { data } = useGetBriefingQuery({ ...d.ctx, since: since ?? undefined }, { skip: !d.ctx.case_id, pollingInterval: 15000 });
  const items = data?.items ?? [];
  const [all, setAll] = useState(false);
  // newest first matters: the first screen shows the latest two lines, the rest is one click away
  const shown = all ? items.slice(-8) : items.slice(-2);
  return (
    <div className="briefing" data-src="v_case_timeline since last_seen">
      <h3>
        <Pill tone="ai">Briefing</Pill> {since ? `Since you last looked at ${fmtZ(ms(since))}` : 'Latest activity on this case'}
        {data?.new_recommendations > 0 && <span className="k">{data.new_recommendations} engine updates</span>}
        <button className="btn sm ghost" style={{ marginLeft: 'auto' }} onClick={() => dispatch(markSeen(iso(now)))}>
          Mark as seen
        </button>
      </h3>
      {items.length === 0 ? (
        <span className="k">Nothing new.</span>
      ) : (
        <ul>
          {shown.map((i, k) => (
            <li key={k}>
              <span className="k">{fmtZ(ms(i.occurred_at))}</span> {plain(i.summary)}
              {i.actor ? <span className="k"> ({i.actor})</span> : null}
            </li>
          ))}
        </ul>
      )}
      {items.length > 2 && <button className="why-btn" onClick={() => setAll((v) => !v)}>{all ? 'Show only the latest 2' : `Show all ${Math.min(items.length, 8)}`}</button>}
    </div>
  );
}
