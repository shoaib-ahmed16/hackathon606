import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { useReadAllNotificationsMutation, useReadNotificationMutation } from '@/features/ops/opsApi';
import { selectFlight } from '@/features/ops/opsSlice';
import { ms } from '@/features/ops/helpers';
import { Drawer, Pill } from '../ui/ui';
import { fmtZ } from '../lib';

// In-app notifications: flights you watch, approvals you owe, data requests addressed to your role.
export default function NotesDrawer({ d, onClose }) {
  const dispatch = useAppDispatch();
  const [readOne] = useReadNotificationMutation();
  const [readAll] = useReadAllNotificationsMutation();
  const { unread, items } = d.notifications;
  const open = (n) => {
    if (n.status === 'PENDING') readOne({ id: n.notification_id });
    if (n.flight_id && d.flights.some((f) => f.flight_id === n.flight_id)) {
      onClose();
      dispatch(selectFlight(n.flight_id));
    } else if (n.flight_id) toast('That flight belongs to another case. Switch case to open it.');
  };
  return (
    <Drawer title="Notifications" sub={`${d.actor?.display_name} · flights you watch and approvals you owe`} onClose={onClose}>
      <div data-src="notification_outbox · notify_flight() · notify_roles()">
        {items.map((n) => (
          <div
            key={n.notification_id}
            className={`note ${n.status === 'PENDING' ? 'unread' : ''}`}
            role="button"
            tabIndex={0}
            onClick={() => open(n)}
            onKeyDown={(e) => e.key === 'Enter' && open(n)}
          >
            <div className="nh">
              {fmtZ(ms(n.created_at))} · {n.flight_no ?? ''} {n.teams && <Pill tone="ai">also Teams</Pill>}
            </div>
            <b>{n.title}</b>
            <span className="k">{n.body}</span>
          </div>
        ))}
        {items.length === 0 && <div className="empty">No notifications. Watch a flight to get its updates.</div>}
        <button className="btn" disabled={unread === 0} onClick={() => readAll()}>
          Mark all read
        </button>
      </div>
    </Drawer>
  );
}
