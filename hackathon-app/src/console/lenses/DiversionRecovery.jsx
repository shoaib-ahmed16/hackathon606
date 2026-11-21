import { useState } from 'react';
import { useAppDispatch } from '@/app/hooks';
import { useGetDiversionRecoveryQuery } from '@/features/ops/opsApi';
import { selectFlight } from '@/features/ops/opsSlice';
import { Pill } from '../ui/ui';
import { fmtZ, human, ms } from '../lib';
import './lenses.css';

// Per diverted flight: when the aircraft can return, whether the crew can legally fly it, and which connecting
// passengers would miss their onward flight at the projected hub arrival. Read-only (diversion_recovery_plan()):
// the engine suggests, people decide.
const CREW = {
  CREW_CAN_RETURN: { tone: 'legal', label: 'Crew can return' },
  NEEDS_COMMANDER_DISCRETION: { tone: 'disc', label: 'Needs commander discretion' },
  NEEDS_REPLACEMENT: { tone: 'exceeded', label: 'Needs crew replacement' },
  VERIFY_CREW: { tone: 'verify', label: 'Crew needs verification' },
};
const CONN_TONE = { MISSED: 'exceeded', CANCELLED: 'exceeded', AT_RISK: 'risk', OK: 'legal' };
const z = (t) => (t ? fmtZ(ms(t)) : '-');

function Step({ label, at, strong }) {
  return (
    <div className={`dr-step ${strong ? 'strong' : ''}`}>
      <span className="k">{label}</span>
      <b>{z(at)}</b>
    </div>
  );
}

function Card({ r, hub }) {
  const dispatch = useAppDispatch();
  const [all, setAll] = useState(false);
  const crew = CREW[r.crew_outcome] ?? CREW.VERIFY_CREW;
  const shown = (r.connections ?? []).filter((c) => all || c.status !== 'OK');
  return (
    <div className="dr-card" data-src="diversion_recovery_plan()">
      <div className="dr-head">
        <b>
          {r.original_flight_no} → {r.alternate_iata}
        </b>
        <span className="k">
          return {r.recovery_flight_no} · {r.registration ?? 'aircraft not known'} · {human(r.diversion_status)}
        </span>
        <Pill tone={crew.tone}>{crew.label}</Pill>
        <button type="button" className="btn ghost" onClick={() => dispatch(selectFlight(r.recovery_flight_id))}>
          Open flight
        </button>
      </div>

      <div className="dr-steps">
        <Step label={`Ready at ${r.alternate_iata}`} at={r.ready_at_alt_utc} />
        <Step label={`${hub} reopens`} at={r.hub_reopen_utc} />
        <Step label="Depart" at={r.projected_dep_utc} strong />
        <Step label={`Arrive ${hub}`} at={r.projected_hub_arrival_utc} strong />
        <Step label="Latest legal departure" at={r.latest_legal_dep_utc} />
        <Step label="With discretion" at={r.latest_dep_with_discretion_utc} />
      </div>

      <p className="dr-action">{r.suggested_action}</p>

      {r.standby?.length > 0 && (
        <div className="dr-standby">
          <b>Standby replacements</b>
          {r.standby.map((s) => (
            <div key={s.crew_id} className="dr-row">
              <span>
                {s.full_name} <span className="k">{s.position_code}</span>
              </span>
              <span className="k">
                sign-in {z(s.new_sign_in_utc)} · positioning {s.positioning_min ?? '-'} min · margin {s.margin_min ?? '-'} min
              </span>
              <Pill tone={s.verdict === 'CANDIDATE' ? 'legal' : s.lvp_qualified === false ? 'exceeded' : 'risk'}>{s.verdict}</Pill>
            </div>
          ))}
        </div>
      )}

      <div className="dr-pax">
        <b>Connecting passengers</b>
        <span>
          <Pill tone={r.pax_missed ? 'exceeded' : 'legal'}>{r.pax_missed} pax miss ({r.connections_missed} flights)</Pill>{' '}
          <Pill tone={r.pax_at_risk ? 'risk' : 'legal'}>
            {r.pax_at_risk} pax at risk ({r.connections_at_risk} flights, under {r.min_connection_min} min)
          </Pill>{' '}
          <span className="k">
            of {r.pax_total} on {r.connections_total} connections
            {r.tightest_slack_min != null ? ` · tightest ${r.tightest_slack_min} min` : ''}
          </span>
        </span>
        {r.connections_total > 0 && (
          <>
            <table className="dr-table">
              <thead>
                <tr>
                  <th>Onward flight</th>
                  <th>To</th>
                  <th>Departs</th>
                  <th>Pax</th>
                  <th>Slack</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {shown.map((c) => (
                  <tr key={c.outbound_flight_id}>
                    <td>{c.outbound_flight}</td>
                    <td>{c.outbound_to}</td>
                    <td>{z(c.outbound_departure_utc)}</td>
                    <td>{c.pax_count}</td>
                    <td>{c.slack_min} min</td>
                    <td>
                      <Pill tone={CONN_TONE[c.status] ?? 'neutral'}>{human(c.status)}</Pill>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            <button type="button" className="btn ghost" onClick={() => setAll(!all)}>
              {all ? 'Show only missed and at risk' : `Show all ${r.connections_total} connections`}
            </button>
          </>
        )}
      </div>
      <p className="k dr-basis">
        {(r.reasons ?? []).join(' · ')}
        {r.reasons?.length ? ' · ' : ''}
        {r.quality}: {r.basis}
      </p>
    </div>
  );
}

export default function DiversionRecovery({ d }) {
  const { data = [], isLoading, isError } = useGetDiversionRecoveryQuery(d.ctx, { skip: !d.ctx?.case_id, pollingInterval: 10000 });
  const hub = d.kase?.hub_iata ?? 'Hub';
  return (
    <section className="divrec" data-src="diversion_recovery_plan()">
      <h2 className="lane-h" style={{ marginTop: 4 }}>
        Diverted flights: return and connections <span className="k">{data.length} diverted</span>
      </h2>
      {isLoading && <p className="k">Loading…</p>}
      {isError && <p className="k">Could not load the diversion recovery plan.</p>}
      {!isLoading && !isError && data.length === 0 && <p className="k">No active diversions in this case.</p>}
      {data.map((r) => (
        <Card key={r.diversion_id} r={r} hub={hub} />
      ))}
    </section>
  );
}
