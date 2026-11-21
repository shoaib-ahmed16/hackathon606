import { useBoardFilters } from '@/features/ops/useBoardFilters';
import { ruleKey } from '@/features/ops/boardFilters';
import { LIVE_STATUSES } from '../lib';

const CHIPS = [
  ['lvp', 'Pilots not LVP-qualified'],
  ['crew', 'Crew at risk'],
  ['verify', 'Needs verification'],
  ['approval', 'Waiting for approval'],
  ['subscribed', 'Watched by me'],
];

// Filter row: live status, severity, toggles, and the saved FILTER rules that are in force.
export default function Filters({ d }) {
  const { chips, toggle, set, value, clear } = useBoardFilters();
  const rules = d.ruleMatches.rules.filter((r) => r.kind === 'FILTER');
  const rule = chips.find((c) => c.startsWith('rule:')) ?? '';
  return (
    <div className="filters" data-src="filter params + ops_rule (FILTER)">
      <label className="sr" htmlFor="fStatus">Live status</label>
      <select id="fStatus" value={value('status')} onChange={(e) => set('status', e.target.value)}>
        <option value="">All statuses</option>
        {LIVE_STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
        <option value="divhold">Diverted or holding</option>
      </select>
      <label className="sr" htmlFor="fSev">Severity</label>
      <select id="fSev" value={value('sev')} onChange={(e) => set('sev', e.target.value)}>
        <option value="">Any severity</option>
        <option value="30">Medium and above</option>
        <option value="50">High only</option>
      </select>
      {CHIPS.map(([k, label]) => (
        <button key={k} className="fchip" aria-pressed={chips.includes(k)} onClick={() => toggle(k)}>{label}</button>
      ))}
      <label className="sr" htmlFor="fRule">Saved rule</label>
      <select
        id="fRule"
        value={rule}
        onChange={(e) => {
          const next = e.target.value;
          // one saved rule at a time
          chips.filter((c) => c.startsWith('rule:')).forEach(toggle);
          if (next) setTimeout(() => toggle(next), 0);
        }}
      >
        <option value="">Saved rules…</option>
        {rules.map((r) => <option key={r.rule_id} value={ruleKey(r.rule_id)}>{r.name} ({r.matches})</option>)}
      </select>
      <button className="clear" onClick={clear} disabled={chips.length === 0}>Clear</button>
    </div>
  );
}
