import { useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { useGenerateReportMutation } from '@/features/ops/opsApi';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { useNow } from '@/hooks/useNow';
import { fmtZ, human, ms, typeLabel } from '../lib';
import { Pill, Sheet } from '../ui/ui';
import '../lenses/lenses.css';

const STATUS_TONE = { APPROVED: 'legal', EXECUTED: 'legal', PROPOSED: 'risk', REJECTED: 'exceeded', REVOKED: 'exceeded' };

// Generates the disruption report for the selected case (a reproducible snapshot stored in the database with an audit
// watermark). The API only returns the new report id, so the readable summary is taken from the same live case data.
export default function ReportSheet({ d, onClose }) {
  const [gen, { isLoading }] = useGenerateReportMutation();
  const now = useNow();
  const [done, setDone] = useState(null); // { id, at }
  const kase = d.kase;

  const stats = useMemo(() => {
    const dec = d.decisions;
    const by = (s) => dec.filter((x) => x.status === s).length;
    const plan = d.plan[0];
    return [
      ['Flights on watch', d.flights.length],
      ['Diversions', d.diversions.length],
      ['Decisions', dec.length],
      ['Executed', by('EXECUTED')],
      ['Awaiting approval', by('PROPOSED')],
      ['Recovery plan', plan ? `${d.plan.length} flights` : 'none'],
      ['Open data exceptions', d.exceptions.length],
    ];
  }, [d.flights, d.diversions, d.decisions, d.plan, d.exceptions]);

  const generate = async () => {
    try {
      const res = await gen({ caseId: d.ctx.case_id }).unwrap();
      const row = Array.isArray(res) ? res[0] : res;
      setDone({ id: row?.generate_report ?? row?.report_id ?? null, at: now });
      toast.success('Report generated (reproducible snapshot with audit watermark)');
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };

  return (
    <Sheet
      wide
      title="Disruption report"
      sub={kase ? `${kase.title} · ${kase.hub_iata} · ${human(kase.cause)}` : undefined}
      onClose={onClose}
      footer={
        <>
          <button type="button" className="btn ghost" onClick={onClose}>Close</button>
          <button type="button" className="btn primary" disabled={isLoading || !d.ctx.case_id} onClick={generate}>
            {isLoading ? 'Generating…' : done ? 'Generate again' : 'Generate report'}
          </button>
        </>
      }
    >
      <div data-src="generate_report(case_id)">
        {done ? (
          <p aria-live="polite" style={{ marginTop: 0 }}>
            <Pill tone="legal">Report {done.id != null ? `#${done.id} ` : ''}created</Pill>{' '}
            <span className="k">{fmtZ(done.at)} · stored in the database with the audit watermark, so it can be reproduced.</span>
          </p>
        ) : (
          <p className="k" style={{ marginTop: 0 }}>
            Creates a snapshot of this case: hub status history, flights, diversions, decisions with approvals, the recovery plan and the timeline.
          </p>
        )}
        <div className="sum-grid">
          {stats.map(([l, v]) => (
            <div key={l}>
              <b>{v}</b>
              <span>{l}</span>
            </div>
          ))}
        </div>
        <h3 className="lane-h">Decisions and approvals</h3>
        {d.decisions.length === 0 ? (
          <p className="k">No decisions recorded yet.</p>
        ) : (
          <div className="sheet-scroll">
            <table className="cmp">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Flight</th>
                  <th>Decision</th>
                  <th>Status</th>
                  <th>By</th>
                  <th>Rationale</th>
                </tr>
              </thead>
              <tbody>
                {d.decisions.map((x) => (
                  <tr key={x.decision_id}>
                    <td>{fmtZ(ms(x.decided_at))}</td>
                    <td><b>{x.flight_no ?? '-'}</b></td>
                    <td>
                      {typeLabel(x.decision_type)}
                      {x.alternate_iata ? ` ${x.alternate_iata}` : ''}
                    </td>
                    <td><Pill tone={STATUS_TONE[x.status] ?? 'neutral'}>{human(x.status)}</Pill></td>
                    <td>{x.decided_by}</td>
                    <td>{x.rationale ?? ''}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </Sheet>
  );
}
