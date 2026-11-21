import { Chip } from '@mui/material';

// Flight status, crew legality, decision/recommendation state and severities -> one colour language:
// red = act now / illegal, amber = tight / waiting, green = fine, blue = info.
const MAP = {
  // flight_status
  SCHEDULED: ['Scheduled', 'default'],
  TAXI_OUT: ['Taxi out', 'info'],
  AIRBORNE: ['Airborne', 'info'],
  HOLDING: ['Holding', 'warning'],
  DIVERTING: ['Diverting', 'error'],
  LANDED: ['Landed', 'success'],
  ON_BLOCKS: ['On blocks', 'default'],
  CANCELLED: ['Cancelled', 'error'],
  // legality_status
  LEGAL: ['Legal', 'success'],
  AT_RISK: ['At risk', 'warning'],
  DISCRETION_REQUIRED: ['Discretion needed', 'warning'],
  EXCEEDED: ['Exceeded', 'error'],
  VERIFICATION_REQUIRED: ['Verify', 'warning'],
  // decision / recommendation
  PROPOSED: ['Proposed', 'warning'],
  APPROVED: ['Approved', 'success'],
  REJECTED: ['Rejected', 'default'],
  EXECUTED: ['Executed', 'success'],
  REVOKED: ['Revoked', 'default'],
  ACCEPTED: ['Accepted', 'success'],
  SUPERSEDED: ['Superseded', 'default'],
  EXPIRED: ['Expired', 'default'],
  // data_exception severity
  BLOCKING: ['Blocking', 'error'],
  WARN: ['Warning', 'warning'],
  INFO: ['Info', 'info'],
  // airport
  OPEN: ['Open', 'success'],
  RESTRICTED: ['Restricted', 'warning'],
  CLOSED: ['Closed', 'error'],
  // recommendation type
  HOLD: ['Hold', 'warning'],
  DIVERT: ['Divert', 'error'],
  MONITOR: ['Monitor', 'info'],
  RECOVER: ['Recover', 'success'],
  CREW_REPLACE: ['Replace crew', 'error'],
  DELAY_DEPARTURE: ['Delay departure', 'warning'],
  NO_ACTION: ['No action', 'default'],
};

export default function StatusChip({ status }) {
  if (!status) return null;
  const [label, color] = MAP[status] ?? [String(status).replaceAll('_', ' '), 'default'];
  return (
    <Chip
      size="small"
      label={label}
      color={color}
      variant={color === 'default' ? 'outlined' : 'filled'}
    />
  );
}
