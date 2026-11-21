import { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { useCreateRuleMutation, useGetRuleFieldsQuery, usePreviewRuleMutation } from '@/features/ops/opsApi';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { OP_LABEL } from './ruleDescribe';
import './pages.css';

// Starting points taken from the plan's own examples; the user edits them before saving.
const TEMPLATES = [
  { key: 'lvp', name: 'Pilots not LVP-qualified', kind: 'FILTER', description: 'LVP is in force and the pilots are not both qualified', mode: 'all', rows: [['lvp_required', 'eq', true], ['lvp_crew_ok', 'neq', true]] },
  { key: 'margin', name: 'Crew margin under 45 min', kind: 'ALERT', description: 'Crew margin is under 45 minutes', mode: 'all', rows: [['crew_margin_min', 'lt', 45]] },
  { key: 'undecided', name: 'High severity, no decision yet', kind: 'FILTER', description: 'Severity is high and nobody has proposed a decision', mode: 'all', rows: [['severity_score', 'gte', 60], ['decision_status', 'is_null', '']] },
  { key: 'divhold', name: 'Diverted or holding first', kind: 'PRIORITY', description: 'Diverted and holding flights are shown first', mode: 'any', rows: [['diverted_to', 'not_null', ''], ['status', 'eq', 'HOLDING']] },
  { key: 'disc', name: 'No crew beyond the limit', kind: 'CONSTRAINT', description: 'Flag flights whose crew needs commander discretion or has exceeded the limit', mode: 'all', rows: [['crew_status', 'in', ['DISCRETION_REQUIRED', 'EXCEEDED']]] },
];

const KINDS = ['FILTER', 'ALERT', 'PRIORITY', 'CONSTRAINT'];
const blankRow = (fields) => ({ field: fields?.[0]?.field ?? 'status', op: 'eq', value: '' });
const nice = (o) => String(o).replaceAll('_', ' ').toLowerCase();

function ValueInput({ row, spec, onChange }) {
  if (!spec || row.op === 'is_null' || row.op === 'not_null') return null;
  if (spec.type === 'bool')
    return (
      <select className="field-in" aria-label="Value" value={String(row.value)} onChange={(e) => onChange(e.target.value === 'true')}>
        <option value="" disabled>choose</option>
        <option value="true">yes</option>
        <option value="false">no</option>
      </select>
    );
  if (spec.options && row.op === 'in') {
    const cur = Array.isArray(row.value) ? row.value : [];
    return (
      <div className="opt-chips" role="group" aria-label="Values">
        {spec.options.map((o) => (
          <button
            type="button"
            key={o}
            className="btn sm"
            aria-pressed={cur.includes(o)}
            onClick={() => onChange(cur.includes(o) ? cur.filter((x) => x !== o) : [...cur, o])}
          >
            {nice(o)}
          </button>
        ))}
      </div>
    );
  }
  if (spec.options)
    return (
      <select className="field-in" aria-label="Value" value={row.value ?? ''} onChange={(e) => onChange(e.target.value)}>
        <option value="" disabled>choose</option>
        {spec.options.map((o) => (
          <option key={o} value={o}>{nice(o)}</option>
        ))}
      </select>
    );
  if (spec.type === 'number')
    return <input className="field-in" aria-label="Value" type="number" style={{ width: 120 }} value={row.value ?? ''} onChange={(e) => onChange(e.target.value === '' ? '' : Number(e.target.value))} />;
  return (
    <input
      className="field-in"
      aria-label="Value"
      placeholder={row.op === 'in' ? 'comma separated' : 'value'}
      value={Array.isArray(row.value) ? row.value.join(', ') : (row.value ?? '')}
      onChange={(e) => onChange(row.op === 'in' ? e.target.value.split(',').map((x) => x.trim()).filter(Boolean) : e.target.value)}
    />
  );
}

// Rule builder: a few conditions joined by AND / OR over the whitelisted fields only. The preview runs the real rule
// against the open case so you see how many flights it would catch before saving.
const Req = () => <span className="req" title="Required" aria-hidden="true">*</span>;

export default function NewRuleForm({ d }) {
  const catalogue = useGetRuleFieldsQuery();
  const fields = catalogue.data?.fields;
  const kinds = catalogue.data?.kinds ?? {};
  const [create, { isLoading: saving }] = useCreateRuleMutation();
  const [runPreview] = usePreviewRuleMutation();
  const [name, setName] = useState('');
  const [kind, setKind] = useState('FILTER');
  const [description, setDescription] = useState('');
  const [priority, setPriority] = useState(100);
  const [validTo, setValidTo] = useState('');
  const [mode, setMode] = useState('all');
  const [rowsState, setRowsState] = useState(null); // null until edited: first row comes from the field list
  const [preview, setPreview] = useState(null);
  const [error, setError] = useState(null);
  const [tried, setTried] = useState(false); // after one Save click, missing fields are marked
  const { scenario_id, case_id } = d.ctx;

  const rows = useMemo(() => rowsState ?? (fields ? [blankRow(fields)] : []), [rowsState, fields]);
  const setRows = (next) => setRowsState((prev) => (typeof next === 'function' ? next(prev ?? rows) : next));
  const spec = (f) => fields?.find((x) => x.field === f);
  const definition = useMemo(() => {
    const conds = rows.map((r) => {
      const base = { field: r.field, op: r.op };
      return r.op === 'is_null' || r.op === 'not_null' ? base : { ...base, value: r.value };
    });
    return { [mode]: conds };
  }, [rows, mode]);
  const complete =
    rows.length > 0 &&
    rows.every((r) => ['is_null', 'not_null'].includes(r.op) || (r.value !== '' && r.value != null && !(Array.isArray(r.value) && r.value.length === 0)));

  useEffect(() => {
    if (!complete) return undefined;
    const t = setTimeout(() => {
      runPreview({ scenario_id, case_id, definition })
        .unwrap()
        .then((r) => {
          setPreview(r);
          setError(null);
        })
        .catch((e) => {
          setPreview(null);
          setError(getErrorMessage(e));
        });
    }, 450);
    return () => clearTimeout(t);
  }, [definition, complete, runPreview, scenario_id, case_id]);

  const shownPreview = complete ? preview : null;
  const setRow = (i, patch) => setRows((rs) => rs.map((r, j) => (j === i ? { ...r, ...patch } : r)));
  const applyTemplate = (t) => {
    setName(t.name);
    setKind(t.kind);
    setDescription(t.description);
    setMode(t.mode);
    setRows(t.rows.map(([field, op, value]) => ({ field, op, value })));
  };

  const reset = () => {
    setTried(false);
    setName('');
    setDescription('');
    setValidTo('');
    setPriority(100);
    setMode('all');
    setRowsState(null);
    setPreview(null);
    setError(null);
  };

  const valueMissing = (r) => !(['is_null', 'not_null'].includes(r.op) || (r.value !== '' && r.value != null && !(Array.isArray(r.value) && r.value.length === 0)));
  const problems = [!name.trim() && 'Name', !description.trim() && 'Description', !complete && 'a value for every condition'].filter(Boolean);
  const bad = (cond) => tried && cond;
  const save = async () => {
    if (problems.length) {
      setTried(true);
      toast.error(`Still needed: ${problems.join(', ')}`);
      return;
    }
    try {
      await create({
        scenario_id,
        name,
        kind,
        description,
        definition,
        priority: Number(priority),
        valid_to: validTo ? new Date(validTo).toISOString() : null,
      }).unwrap();
      toast.success(['PRIORITY', 'CONSTRAINT'].includes(kind) ? 'Rule saved. It starts once an approver approves it.' : 'Rule is active');
      reset();
    } catch (e) {
      setError(getErrorMessage(e));
    }
  };

  return (
    <div className="form rule-form">
      <b>New rule</b>
      <div className="tpl">
        <span className="k">Start from an example:</span>
        {TEMPLATES.map((t) => (
          <button type="button" key={t.key} className="btn sm" onClick={() => applyTemplate(t)}>
            {t.name}
          </button>
        ))}
      </div>
      <div className="rowf">
        <label style={{ flex: '2 1 220px' }}>
          <span>Name <Req /></span>
          <input className={`field-in ${bad(!name.trim()) ? 'invalid' : ''}`} aria-required="true" aria-invalid={bad(!name.trim())} value={name} placeholder="e.g. Flights with medical cases" onChange={(e) => setName(e.target.value)} />
          {bad(!name.trim()) && <span className="field-err">Give the rule a name</span>}
        </label>
        <label style={{ flex: '1 1 160px' }}>
          What it does
          <select className="field-in" value={kind} onChange={(e) => setKind(e.target.value)}>
            {KINDS.map((k) => (
              <option key={k} value={k}>{k.toLowerCase()}</option>
            ))}
          </select>
        </label>
      </div>
      {kinds[kind] && <div className={`note ${kind === 'CONSTRAINT' ? 'warn' : ''}`}>{kinds[kind]}</div>}
      <label>
        <span>Description (shown on alerts and flight rows) <Req /></span>
        <textarea className={`field-in ${bad(!description.trim()) ? 'invalid' : ''}`} aria-required="true" aria-invalid={bad(!description.trim())} rows={2} value={description} onChange={(e) => setDescription(e.target.value)} />
        {bad(!description.trim()) && <span className="field-err">Say what the rule does, in a sentence</span>}
      </label>

      <div className="rowf">
        <b style={{ fontSize: 13 }}>A flight matches when <Req /></b>
        <button type="button" className={`btn sm ${mode === 'all' ? 'primary' : ''}`} onClick={() => setMode('all')}>all of these are true</button>
        <button type="button" className={`btn sm ${mode === 'any' ? 'primary' : ''}`} onClick={() => setMode('any')}>any of these is true</button>
      </div>
      {rows.map((r, i) => {
        const sp = spec(r.field);
        return (
          <div className={`cond ${bad(valueMissing(r)) ? 'cond-invalid' : ''}`} key={i}>
            <select className="field-in" aria-label="Field" value={r.field} onChange={(e) => setRow(i, { field: e.target.value, op: 'eq', value: '' })}>
              {fields?.map((f) => (
                <option key={f.field} value={f.field}>{f.label}</option>
              ))}
            </select>
            <select className="field-in" aria-label="Operator" value={r.op} onChange={(e) => setRow(i, { op: e.target.value, value: e.target.value === 'in' ? [] : '' })}>
              {(sp?.ops ?? ['eq']).map((o) => (
                <option key={o} value={o}>{OP_LABEL[o] ?? o}</option>
              ))}
            </select>
            <ValueInput row={r} spec={sp} onChange={(v) => setRow(i, { value: v })} />
            {bad(valueMissing(r)) && <span className="field-err" style={{ flexBasis: '100%' }}>Choose or enter a value for this condition</span>}
            <button type="button" className="btn sm ghost" disabled={rows.length === 1} onClick={() => setRows((rs) => rs.filter((_, j) => j !== i))}>
              Remove
            </button>
          </div>
        );
      })}
      <div>
        <button type="button" className="btn sm" disabled={rows.length >= 8} onClick={() => setRows((rs) => [...rs, blankRow(fields)])}>
          Add condition
        </button>
      </div>
      <div className="k">Fields come from a fixed list and are compiled to parameterised SQL. No free text reaches the database.</div>

      <div className="rowf">
        <label>
          Priority (1 = first)
          <input className="field-in" type="number" style={{ width: 110 }} value={priority} onChange={(e) => setPriority(e.target.value)} />
        </label>
        <label>
          Stops at (optional)
          <input className="field-in" type="datetime-local" value={validTo} onChange={(e) => setValidTo(e.target.value)} />
        </label>
        <span className="k">Starts now. Times follow the case clock.</span>
      </div>

      {error && <div className="err">{error}</div>}
      {shownPreview && (
        <div className={shownPreview.count ? 'ok-note' : 'k'} data-testid="rule-preview">
          This rule matches <b>{shownPreview.count}</b> flight{shownPreview.count === 1 ? '' : 's'} of this case right now
          {shownPreview.sample?.length > 0 && `: ${shownPreview.sample.join(', ')}${shownPreview.count > shownPreview.sample.length ? ' ...' : ''}`}.
        </div>
      )}
      <div>
        <button type="button" className="btn primary" disabled={saving} onClick={save}>
          Save rule
        </button>
        <span className="k" style={{ marginLeft: 10 }}><Req /> required</span>
      </div>
    </div>
  );
}
