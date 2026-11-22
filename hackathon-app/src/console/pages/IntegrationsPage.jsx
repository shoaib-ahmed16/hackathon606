import { useState } from 'react';
import toast from 'react-hot-toast';
import { useGetIntegrationsQuery, useMarkEnteredMutation, usePatchSystemMutation } from '@/features/ops/opsApi';
import { ms } from '@/features/ops/helpers';
import { fmtZL } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { useConsole } from '../ConsoleContext';
import { Empty, Pill } from '../ui/ui';
import './pages.css';

const STATUS = { MANUAL: ['risk', 'Manual task'], ACKED: ['legal', 'ACKED'], PENDING: ['neutral', 'PENDING'] };

function SystemRow({ s, canEdit }) {
  const [patch, { isLoading }] = usePatchSystemMutation();
  const [draft, setDraft] = useState(null); // null = not editing
  const save = async (body, ok) => {
    try {
      await patch({ code: s.code, ...body }).unwrap();
      toast.success(ok);
      setDraft(null);
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  return (
    <tr>
      <td><b>{s.name}</b><div className="k">{s.code}</div></td>
      <td>{s.purpose}</td>
      <td>
        {draft == null ? (
          <>
            <code>{s.deep_link_template || 'not set'}</code>
            {canEdit && (
              <div><button type="button" className="btn sm ghost" onClick={() => setDraft(s.deep_link_template ?? '')}>Edit template</button></div>
            )}
          </>
        ) : (
          <>
            <div className="tpl-edit">
              <input className="field-in" aria-label={`Deep-link template for ${s.name}`} value={draft} onChange={(e) => setDraft(e.target.value)} />
              <button type="button" className="btn sm primary" disabled={isLoading || !draft.trim()} onClick={() => save({ deep_link_template: draft }, 'Template saved')}>Save</button>
              <button type="button" className="btn sm ghost" onClick={() => setDraft(null)}>Cancel</button>
            </div>
            <div className="k">Placeholders: {'{flight_no} {flight_date} {dep} {arr} {reg} {crew_id}'}. Must start with http:// or https://.</div>
          </>
        )}
      </td>
      <td>
        <Pill tone={s.enabled ? 'legal' : 'neutral'}>{s.enabled ? 'Enabled' : 'Off'}</Pill>
        {canEdit && (
          <label className="sw">
            <input type="checkbox" checked={!!s.enabled} disabled={isLoading} onChange={(e) => save({ enabled: e.target.checked }, e.target.checked ? 'Write API switched on' : 'Write API switched off')} />
            Write API
          </label>
        )}
      </td>
    </tr>
  );
}

export default function IntegrationsPage() {
  const d = useConsole();
  const { data, isLoading, error } = useGetIntegrationsQuery(undefined);
  const [markEntered, { isLoading: marking }] = useMarkEnteredMutation();
  const canEdit = ['OCC', 'ADMIN'].includes(d.actor?.role_code);
  const systems = data?.systems ?? [];
  const outbox = data?.outbox ?? [];

  const done = async (row) => {
    try {
      await markEntered({ id: row.message_id }).unwrap();
      toast.success(`${row.key} marked as entered`);
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };

  return (
    <div className="page">
      <h2>Integrations</h2>
      <p className="lead">
        Deep links open the selected flight in the system of record. Executed decisions queue writes in an outbox (idempotent, with retries).
        While an integration is off, each entry becomes a manual task with a link.
      </p>
      {error && <div className="err">Could not load integrations.</div>}
      {isLoading ? (
        <div className="skeleton" />
      ) : (
        <>
          <div className="tbl-wrap">
            <table className="tbl">
              <thead><tr><th>System</th><th>Used for</th><th>Deep-link template</th><th>Write API</th></tr></thead>
              <tbody>
                {systems.map((s) => <SystemRow key={s.code} s={s} canEdit={canEdit} />)}
              </tbody>
            </table>
          </div>
          <p className="k" style={{ marginTop: 6 }}>
            No connector ships with this build: switching a write API on leaves new entries pending instead of turning them into manual tasks.
            {!canEdit && ' Only OCC or an admin can change templates and switches.'}
          </p>
          <h2 style={{ marginTop: 22 }}>Outbox</h2>
          <p className="lead">Entries created by executed decisions.</p>
          {outbox.length === 0 ? (
            <Empty>The outbox is empty. Entries appear when a decision is executed.</Empty>
          ) : (
            <div className="tbl-wrap">
              <table className="tbl">
                <thead><tr><th>Key</th><th>System</th><th>Action</th><th>Flight</th><th>Queued</th><th>Status</th><th></th></tr></thead>
                <tbody>
                  {outbox.map((o) => {
                    const [tone, text] = STATUS[o.status] ?? ['neutral', o.status];
                    return (
                      <tr key={o.message_id}>
                        <td><code>{o.key}</code></td>
                        <td>{o.system}</td>
                        <td>{o.action}</td>
                        <td>{o.flight_no ?? '-'}</td>
                        <td>{fmtZL(ms(o.created_at))}</td>
                        <td><Pill tone={tone}>{text}</Pill></td>
                        <td>
                          <div className="act">
                            {o.link && <a className="btn sm" href={o.link} target="_blank" rel="noreferrer">Open in {o.system}</a>}
                            {o.status === 'MANUAL' && (
                              <button type="button" className="btn sm primary" disabled={marking} onClick={() => done(o)}>Mark entered</button>
                            )}
                          </div>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </div>
  );
}
