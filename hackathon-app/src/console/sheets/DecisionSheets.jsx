import { useState } from 'react';
import toast from 'react-hot-toast';
import {
  useAddRecordMutation,
  useAnswerDataMutation,
  useAskForDataMutation,
  useExecuteDecisionMutation,
  useGetApprovalPolicyQuery,
  useGetFlightDetailQuery,
  useGetIntegrationsQuery,
  useSendVerdictMutation,
  useAddTagMutation,
} from '@/features/ops/opsApi';
import { DECISION_TYPES } from '@/features/ops/helpers';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { Conseq, ReasonChips, RoleChips, Sheet } from '../ui/ui';
import { REASONS, TAG_LABEL, decisionWhat, roleLabel, typeLabel } from '../lib';
import { fmtZ, ms } from '../lib';

const policyFor = (rows, type) => {
  const r = (rows ?? []).filter((x) => x.decision_type === type);
  return {
    approvers: r.filter((x) => x.required).map((x) => x.approver_role),
    notify: [...new Set(r.flatMap((x) => x.notify_roles ?? []))],
  };
};
// consequence lines for a decision from the flight detail (keyed by alternate airport, or HOLD)
const linesFor = (detail, type, alt) => detail?.consequences?.[type === 'HOLD' ? 'HOLD' : alt] ?? null;

const run = async (fn, ok) => {
  try {
    const r = await fn();
    toast.success(typeof ok === 'function' ? ok(r) : ok);
    return true;
  } catch (e) {
    toast.error(getErrorMessage(e));
    return false;
  }
};

// ---------------------------------------------------------------- propose (an engine option, or free-form)
export function ProposeSheet({ d, f, opt, onClose }) {
  const [add, { isLoading }] = useAddRecordMutation();
  const policy = useGetApprovalPolicyQuery().data;
  const detail = useGetFlightDetailQuery({ flightId: f.flight_id, ...d.ctx }).data;
  const firstExec = d.options.filter((o) => o.flight_id === f.flight_id && o.is_executable).sort((a, b) => a.rank - b.rank)[0];
  const over = Boolean(opt) && firstExec && opt.rank !== firstExec.rank;
  const [type, setType] = useState(opt?.type ?? 'DELAY');
  const [alt, setAlt] = useState('');
  const [reason, setReason] = useState(null);
  const [why, setWhy] = useState(opt && !over ? `Agree with the engine (option ${opt.rank}): ${detail?.recommendation?.rationale ?? opt.what}` : '');
  const dtype = opt ? opt.type : type;
  const pol = policyFor(policy, dtype);
  const lines = opt ? linesFor(detail, opt.type, opt.alt) : null;
  const ready = why.trim() && (!over || reason) && (opt || dtype !== 'DIVERT' || alt.trim().length === 3);

  const submit = async () => {
    const ok = await run(
      () =>
        add({
          table: 'decision',
          body: {
            ...d.ctx,
            flight_id: f.flight_id,
            rec_id: f.rec_id,
            option_id: opt?.option_id ?? null,
            decision_type: dtype,
            alternate_iata: (opt ? opt.alt : alt.trim().toUpperCase()) || null,
            rationale: over ? `[Not the engine's first option: ${reason}] ${why.trim()}` : why.trim(),
            followed_recommendation: Boolean(opt) && !over,
            details: over ? { override_reason: reason } : opt ? {} : { free_form: true },
            decided_by: d.actor.user_id,
            decided_role: d.actor.role_code,
          },
        }).unwrap(),
      `Proposed: ${opt?.what ?? typeLabel(dtype)}. Approvers have been notified.`,
    );
    if (ok) onClose();
  };
  return (
    <Sheet
      title={`Propose: ${opt?.what ?? 'a decision'} (${f.flight_no})`}
      sub={`Check what will happen. Your proposal goes to ${pol.approvers.map(roleLabel).join(' and ') || 'an approver'} for approval.`}
      onClose={onClose}
      footer={
        <>
          <button className="btn ghost" onClick={onClose}>Cancel</button>
          <button className="btn primary" disabled={!ready || isLoading} onClick={submit}>Propose decision</button>
        </>
      }
    >
      {!opt && (
        <>
          <div className="field-l" style={{ marginTop: 0 }}>Decision type</div>
          <select className="field-in" value={type} onChange={(e) => setType(e.target.value)} style={{ marginTop: 6 }}>
            {DECISION_TYPES.filter((t) => t !== 'OVERRIDE').map((t) => <option key={t} value={t}>{typeLabel(t)}</option>)}
          </select>
          {dtype === 'DIVERT' && (
            <input className="field-in" style={{ marginLeft: 8, width: 110 }} placeholder="Alternate (IATA)" maxLength={3} value={alt} onChange={(e) => setAlt(e.target.value)} />
          )}
        </>
      )}
      {opt && (
        <>
          <div className="field-l" style={{ marginTop: 0 }}>What will happen</div>
          <Conseq lines={lines} />
        </>
      )}
      <div className="field-l">Approvals required</div>
      <RoleChips roles={pol.approvers.length ? pol.approvers : ['OCC']} />
      <div className="k">
        {pol.notify.length ? `Also notified: ${pol.notify.map(roleLabel).join(', ')} and everyone watching ${f.flight_no}.` : `Everyone watching ${f.flight_no} is notified.`}
      </div>
      {over && (
        <>
          <div className="field-l">Why not the engine's first option? (required)</div>
          <ReasonChips options={REASONS} value={reason} onChange={setReason} />
        </>
      )}
      <div className="field-l">Rationale (shared with all teams)</div>
      <textarea value={why} onChange={(e) => setWhy(e.target.value)} placeholder="Why this decision?" />
    </Sheet>
  );
}

// ---------------------------------------------------------------- approve
export function ApproveSheet({ d, f, decision: x, onClose, onReject }) {
  const [verdict, { isLoading }] = useSendVerdictMutation();
  const detail = useGetFlightDetailQuery({ flightId: f.flight_id, ...d.ctx }).data;
  const [comment, setComment] = useState('');
  const others = x.required_roles.filter((r) => r !== d.actor.role_code && !x.approved_roles.includes(r));
  const log = d.decisions.find((l) => l.decision_id === x.decision_id);
  const send = async () => {
    const ok = await run(
      () => verdict({ decisionId: x.decision_id, verdict: 'APPROVED', comment: comment.trim() || undefined }).unwrap(),
      (r) => (r.status === 'APPROVED' ? 'Approved by all required roles. OCC can execute.' : `Approved as ${roleLabel(d.actor.role_code)}. Waiting for ${r.waiting_for.map(roleLabel).join(' and ')}.`),
    );
    if (ok) onClose();
  };
  return (
    <Sheet
      title={`Approve as ${roleLabel(d.actor.role_code)}: ${decisionWhat(x)} (${f.flight_no})`}
      sub={`Proposed by ${x.proposed_by} (${roleLabel(x.proposed_role)}) at ${fmtZ(ms(x.decided_at))}. ${x.followed_recommendation ? 'Matches the engine recommendation.' : `Differs from the engine${log?.details?.override_reason ? `: ${log.details.override_reason}` : ''}.`}`}
      onClose={onClose}
      footer={
        <>
          <button className="btn ghost" onClick={onClose}>Cancel</button>
          <button className="btn danger" onClick={onReject}>Reject</button>
          <button className="btn primary" disabled={isLoading} onClick={send}>Approve</button>
        </>
      }
    >
      <div className="state-note" style={{ marginTop: 0 }}>“{x.rationale}”</div>
      <div className="field-l">What will happen</div>
      <Conseq lines={linesFor(detail, x.decision_type, x.alternate_iata)} />
      <div className="field-l">Approval status</div>
      <RoleChips roles={x.required_roles} approved={x.approved_roles} rejected={x.rejected_roles} me={d.actor.role_code} />
      <p className="approver-note">
        {others.length ? `After your approval it still needs ${others.map(roleLabel).join(' and ')}.` : 'You are the last required approver. OCC can then execute.'}
      </p>
      <div className="field-l">Comment (optional)</div>
      <textarea value={comment} onChange={(e) => setComment(e.target.value)} />
    </Sheet>
  );
}

// ---------------------------------------------------------------- reject
export function RejectSheet({ f, decision: x, onClose }) {
  const [verdict, { isLoading }] = useSendVerdictMutation();
  const [reason, setReason] = useState(null);
  const [detail, setDetail] = useState('');
  const send = async () => {
    const ok = await run(
      () => verdict({ decisionId: x.decision_id, verdict: 'REJECTED', comment: `${reason}${detail.trim() ? `: ${detail.trim()}` : ''}` }).unwrap(),
      `Rejected. ${x.proposed_by} has been notified.`,
    );
    if (ok) onClose();
  };
  return (
    <Sheet
      title={`Reject: ${decisionWhat(x)} (${f.flight_no})`}
      sub={`Pick a reason. It is stored with the decision and shared with ${x.proposed_by}.`}
      onClose={onClose}
      footer={
        <>
          <button className="btn ghost" onClick={onClose}>Cancel</button>
          <button className="btn danger" disabled={!reason || isLoading} onClick={send}>Reject</button>
        </>
      }
    >
      <ReasonChips options={REASONS} value={reason} onChange={setReason} />
      <textarea value={detail} onChange={(e) => setDetail(e.target.value)} placeholder="Optional detail" />
    </Sheet>
  );
}

// ---------------------------------------------------------------- execute (OCC)
export function ExecuteSheet({ d, f, decision: x, onClose }) {
  const [exec, { isLoading }] = useExecuteDecisionMutation();
  const detail = useGetFlightDetailQuery({ flightId: f.flight_id, ...d.ctx }).data;
  const sys = useGetIntegrationsQuery().data?.systems.find((s) => s.code === 'AEROMART');
  const send = async () => {
    const ok = await run(() => exec({ decisionId: x.decision_id }).unwrap(), `Executed: ${decisionWhat(x)}`);
    if (ok) onClose();
  };
  return (
    <Sheet
      title={`Execute: ${decisionWhat(x)} (${f.flight_no})`}
      sub={`Approved by ${x.approved_roles.map(roleLabel).join(' and ')}. This updates Foooh! and queues entries for the systems of record.`}
      onClose={onClose}
      footer={
        <>
          <button className="btn ghost" onClick={onClose}>Cancel</button>
          <button className="btn primary" disabled={isLoading} onClick={send}>Execute</button>
        </>
      }
    >
      <Conseq lines={linesFor(detail, x.decision_type, x.alternate_iata)} />
      <div className="integ">
        {x.decision_type === 'DIVERT'
          ? sys?.enabled
            ? `aeroMart: CREATE_DIVERSION_ENTRY will be queued (idempotency key DIVERT-${x.decision_id}).`
            : `aeroMart: CREATE_DIVERSION_ENTRY will be queued (idempotency key DIVERT-${x.decision_id}). The integration is off, so it becomes a manual task with an “Open in aeroMart” link on the Integrations page.`
          : 'No system-of-record write for this decision type.'}
      </div>
    </Sheet>
  );
}

// ---------------------------------------------------------------- answer a data request ("?")
const SOURCES = [['MEASURED', 'Reported'], ['ESTIMATED', 'Estimate']];
export function AnswerSheet({ d, f, gap, onClose }) {
  const [ask] = useAskForDataMutation();
  const [answer, { isLoading }] = useAnswerDataMutation();
  const isFuel = gap.field === 'FUEL_ENDURANCE';
  const [minutes, setMinutes] = useState('');
  const [status, setStatus] = useState('OPEN');
  const [stands, setStands] = useState('');
  const [quality, setQuality] = useState('MEASURED');
  const ready = isFuel ? minutes !== '' && Number(minutes) >= 0 : true;
  const save = async () => {
    try {
      const req = gap.open ?? (await ask({ flightId: f.flight_id, scenario_id: d.ctx.scenario_id, field: gap.field, iata: gap.iata }).unwrap());
      const value = isFuel ? Number(minutes) : { op_status: status, stands: stands === '' ? null : Number(stands) };
      const r = await answer({ requestId: req.request_id, value, quality }).unwrap();
      toast.success(`Saved${r.reranked ? `, the engine re-ranked the options for ${f.flight_no}` : ''}`);
      onClose();
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  return (
    <Sheet
      title={`${isFuel ? 'Enter fuel endurance' : `Confirm ${gap.iata ?? 'alternate'} status`} (${f.flight_no})`}
      sub="Saved with a quality label so everyone knows how reliable it is."
      onClose={onClose}
      footer={
        <>
          <button className="btn ghost" onClick={onClose}>Cancel</button>
          <button className="btn primary" disabled={!ready || isLoading} onClick={save}>Save and re-rank options</button>
        </>
      }
    >
      {isFuel ? (
        <>
          <div className="field-l" style={{ marginTop: 0 }}>Holding endurance (minutes above final reserve)</div>
          <input className="field-in" type="number" min="0" max="600" value={minutes} onChange={(e) => setMinutes(e.target.value)} style={{ width: 150, marginTop: 6 }} />
        </>
      ) : (
        <>
          <div className="field-l" style={{ marginTop: 0 }}>Status reported by the station</div>
          <div className="reason-chips">
            {['OPEN', 'RESTRICTED', 'CLOSED'].map((s) => (
              <button key={s} type="button" aria-pressed={status === s} onClick={() => setStatus(s)}>{s.toLowerCase()}</button>
            ))}
          </div>
          <div className="field-l">Stands free</div>
          <input className="field-in" type="number" min="0" value={stands} onChange={(e) => setStands(e.target.value)} style={{ width: 110, marginTop: 6 }} />
        </>
      )}
      <div className="field-l">Source</div>
      <div className="reason-chips">
        {SOURCES.map(([q, label]) => (
          <button key={q} type="button" aria-pressed={quality === q} onClick={() => setQuality(q)}>
            {label} by {isFuel ? 'crew' : 'station'}
          </button>
        ))}
      </div>
    </Sheet>
  );
}

// ---------------------------------------------------------------- tag a flight (medical case on board ...)
export function TagSheet({ d, f, onClose }) {
  const [addTag, { isLoading }] = useAddTagMutation();
  const [tag, setTag] = useState('MEDICAL');
  const [note, setNote] = useState('');
  const save = async () => {
    const ok = await run(() => addTag({ flightId: f.flight_id, scenario_id: d.ctx.scenario_id, tag, note: note.trim() || undefined }).unwrap(), `${f.flight_no} tagged ${TAG_LABEL[tag]}`);
    if (ok) onClose();
  };
  return (
    <Sheet
      title={`Tag ${f.flight_no}`}
      sub="Tags show on the board and in rules (for example a priority rule 'Medical flights first'). Watchers and OCC are notified."
      onClose={onClose}
      footer={
        <>
          <button className="btn ghost" onClick={onClose}>Cancel</button>
          <button className="btn primary" disabled={isLoading} onClick={save}>Tag flight</button>
        </>
      }
    >
      <div className="reason-chips" style={{ marginTop: 0 }}>
        {Object.entries(TAG_LABEL).map(([k, label]) => (
          <button key={k} type="button" aria-pressed={tag === k} onClick={() => setTag(k)}>{label}</button>
        ))}
      </div>
      <textarea value={note} onChange={(e) => setNote(e.target.value)} placeholder="Note, for example: passenger stable, ambulance requested" />
    </Sheet>
  );
}

// ---------------------------------------------------------------- deep link when the template is still a placeholder
export function LinkSheet({ f, link, onClose }) {
  return (
    <Sheet
      title={`Open ${f.flight_no} in ${link.name}`}
      sub={`${link.purpose ?? ''}. The flight is pre-selected, so nothing needs to be searched again.`}
      onClose={onClose}
      footer={<button className="btn ghost" onClick={onClose}>Close</button>}
    >
      <div className="field-l" style={{ marginTop: 0 }}>Link</div>
      <code style={{ display: 'block', padding: 10, background: 'var(--surface-2)', borderRadius: 8, wordBreak: 'break-all' }}>{link.url}</code>
      <p className="k">
        This template still points at the placeholder host. OCC or admin sets the real URL on the Integrations page (placeholders: {'{flight_no} {flight_date} {dep} {arr} {reg}'}).
      </p>
    </Sheet>
  );
}
