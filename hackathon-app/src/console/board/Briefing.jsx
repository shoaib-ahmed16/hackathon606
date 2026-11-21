import { useAppDispatch } from '@/app/hooks';
import { useGetBriefingQuery } from '@/features/ops/opsApi';
import { markSeen } from '@/features/ops/opsSlice';
import { iso, ms } from '@/features/ops/helpers';
import { useNow } from '@/hooks/useNow';
import { Pill } from '../ui/ui';
import { fmtZ } from '../lib';

// The case timeline stores technical audit text ("INSERT DIVERT decision 8 (PROPOSED)"); say it in plain words.
const plain = (s = '') => {
  let m = /^INSERT (\w+) decision \d+ \((\w+)\)/.exec(s);
  if (m) return `Decision proposed: ${m[1].toLowerCase()}`;
  m = /^UPDATE (\w+) decision \d+ \((\w+)\)/.exec(s);
  if (m) return `Decision ${m[2].toLowerCase()}: ${m[1].toLowerCase()}`;
  if (/^disruption_case UPDATE/.test(s)) return 'Case updated';
  return s;
};

// What changed since the operator last looked, from the case timeline (decisions, status changes, diversions, comments).
export default function Briefing({ d }) {
  const dispatch = useAppDispatch();
  const now = useNow();
  const since = d.ops.lastSeenAt;
  const { data } = useGetBriefingQuery({ ...d.ctx, since: since ?? undefined }, { skip: !d.ctx.case_id, pollingInterval: 15000 });
  const items = data?.items ?? [];
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
          {items.slice(0, 8).map((i, k) => (
            <li key={k}>
              <span className="k">{fmtZ(ms(i.occurred_at))}</span> {plain(i.summary)}
              {i.actor ? <span className="k"> ({i.actor})</span> : null}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
