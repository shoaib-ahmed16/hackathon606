import { useState } from 'react';
import { Alert, Box, Chip } from '@mui/material';
import { useAppSelector } from '@/app/hooks';
import { selectUser } from '@/features/auth/authSlice';
import { useGetAirportCapacityQuery } from '@/features/ops/opsApi';
import { fmtZs } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';
import PageHeader from '@/components/PageHeader';
import Loader from '@/components/Loader';
import AirportDetail from '@/components/capacity/AirportDetail';
import CapacityDialog from '@/components/capacity/CapacityDialog';
import CapacityTable from '@/components/capacity/CapacityTable';
import FlightAssessment from '@/components/capacity/FlightAssessment';
import { WRITERS, ms, scenarioParams } from '@/components/capacity/capacityHelpers';

// Stands, hourly arrival capacity and occupancy for the hub and the alternates, with where every number comes from.
export default function AirportCapacity() {
  const scenarioId = useAppSelector((s) => s.ops.scenarioId);
  const user = useAppSelector(selectUser);
  const canEdit = WRITERS.includes(user?.role);
  const [selected, setSelected] = useState(null);
  const [editing, setEditing] = useState(null);
  const {
    data: rows = [],
    isLoading,
    error,
  } = useGetAirportCapacityQuery(scenarioParams(scenarioId), {
    pollingInterval: 10000,
  });
  const clock = rows[0]?.computed_at_utc;

  return (
    <Box className="page" sx={{ display: 'grid', gap: 2, gridTemplateColumns: 'minmax(0, 1fr)', maxWidth: 'none' }}>
      <PageHeader
        title="Airport capacity"
        subtitle="Stands, arrivals per hour and occupancy for the hub and alternates, with the source of every number"
        actions={
          <>
            {clock && (
              <Chip size="small" variant="outlined" label={`Scenario clock ${fmtZs(ms(clock))}`} />
            )}
            {!canEdit && <Chip size="small" variant="outlined" label="Read only" />}
          </>
        }
      />
      <Alert severity="info">
        A historical peak is a <b>minimum</b> of what an airport has handled, not its limit. Where
        no status entry or assumption exists the capacity is unknown. Occupancy is derived from Air
        Arabia movements and is not verified real-time data.
        {canEdit
          ? ' Use the pencil to assume a capacity.'
          : ' Only OCC and ADMIN can set an assumption.'}
      </Alert>
      {error && <Alert severity="error">{getErrorMessage(error)}</Alert>}
      {isLoading ? (
        <Loader />
      ) : (
        <CapacityTable
          rows={rows}
          canEdit={canEdit}
          selected={selected}
          onSelect={setSelected}
          onEdit={setEditing}
        />
      )}
      <FlightAssessment airports={rows} scenarioId={scenarioId} />
      <AirportDetail
        iata={selected}
        scenarioId={scenarioId}
        canEdit={canEdit}
        onEdit={setEditing}
        onClose={() => setSelected(null)}
      />
      {editing && <CapacityDialog row={editing} onClose={() => setEditing(null)} />}
    </Box>
  );
}
