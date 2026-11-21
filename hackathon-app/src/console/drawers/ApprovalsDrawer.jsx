import { useState } from 'react';
import { useAppDispatch } from '@/app/hooks';
import { selectFlight } from '@/features/ops/opsSlice';
import { ms } from '@/features/ops/helpers';
import { Drawer, RoleChips } from '../ui/ui';
import { ApproveSheet, RejectSheet } from '../sheets/DecisionSheets';
import { decisionWhat, fmtZ, roleLabel } from '../lib';

// Everything proposed and waiting for an approver. "Review" opens the approve sheet for decisions this user may approve.
export default function ApprovalsDrawer({ d, onClose }) {
  const dispatch = useAppDispatch();
  const [review, setReview] = useState(null); // { x, f, reject }
  const items = d.approvals.filter((x) => x.status === 'PROPOSED');
  const open = (x) => {
    onClose();
    dispatch(selectFlight(x.flight_id));
  };
  const flightOf = (x) => d.flights.find((f) => f.flight_id === x.flight_id);
  return (
    <>
      <Drawer title="Approvals" sub={items.length ? 'Decisions waiting for approval.' : 'Nothing is waiting.'} onClose={onClose}>
        {items.map((x) => (
          <div className="appr" key={x.decision_id}>
            <h4>
              {x.flight_no} · {decisionWhat(x)}
            </h4>
            <div className="k">
              {x.proposed_by} · {fmtZ(ms(x.decided_at))} · {x.followed_recommendation ? 'matches the engine' : 'differs from the engine'}
            </div>
            <RoleChips roles={x.required_roles} approved={x.approved_roles} rejected={x.rejected_roles} />
            <div className="ai-buttons">
              {x.can_approve ? (
                <button className="btn primary" onClick={() => setReview({ x, f: flightOf(x) })}>
                  Review as {roleLabel(d.actor.role_code)}
                </button>
              ) : (
                <span className="k">Not waiting on you.</span>
              )}
              <button className="btn ghost" onClick={() => open(x)}>Open flight</button>
            </div>
          </div>
        ))}
        {items.length === 0 && <div className="empty">Proposals appear here as soon as someone records a decision.</div>}
      </Drawer>
      {review && !review.reject && review.f && (
        <ApproveSheet d={d} f={review.f} decision={review.x} onClose={() => setReview(null)} onReject={() => setReview({ ...review, reject: true })} />
      )}
      {review?.reject && review.f && <RejectSheet d={d} f={review.f} decision={review.x} onClose={() => setReview(null)} />}
    </>
  );
}
