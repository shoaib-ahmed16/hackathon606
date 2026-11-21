import { Box, Button, Chip, Drawer, Stack, Typography } from '@mui/material';
import { useAppDispatch } from '@/app/hooks';
import { closePanel, selectFlight } from '@/features/ops/opsSlice';
import { ms } from '@/features/ops/helpers';
import { fmtZL } from '@/features/ops/time';
import EmptyState from '@/components/EmptyState';

// Everything proposed and waiting for an approver (decision.status = PROPOSED). Review opens the flight to approve or reject.
export default function ApprovalsDrawer({ d }) {
  const dispatch = useAppDispatch();
  const items = d.decisions.filter((x) => x.status === 'PROPOSED');
  const review = (x) => {
    dispatch(closePanel());
    dispatch(selectFlight(x.flight_id));
  };
  return (
    <Drawer
      anchor="right"
      open
      onClose={() => dispatch(closePanel())}
      slotProps={{ paper: { sx: { width: { xs: '100%', sm: 440 }, p: 2.5 } } }}
    >
      <Typography variant="h5">Approvals</Typography>
      <Typography variant="body2" sx={{ color: 'text.secondary', mb: 2 }}>
        {items.length
          ? 'Decisions proposed by your teams, waiting for an approver.'
          : 'Nothing is waiting for approval.'}
      </Typography>
      {items.length === 0 && (
        <EmptyState
          title="All clear"
          hint="Proposals appear here as soon as someone records a decision."
        />
      )}
      <Stack spacing={1.5} data-src="decision WHERE status = PROPOSED">
        {items.map((x) => (
          <Box
            key={x.decision_id}
            sx={{ border: 1, borderColor: 'divider', borderRadius: 2, p: 1.5 }}
          >
            <Stack direction="row" sx={{ justifyContent: 'space-between', alignItems: 'center' }}>
              <Typography variant="subtitle1">
                {x.flight_no} - {x.decision_type.replaceAll('_', ' ')}
                {x.alternate_iata ? ` ${x.alternate_iata}` : ''}
              </Typography>
              <Chip
                size="small"
                color={x.followed_recommendation ? 'success' : 'warning'}
                variant="outlined"
                label={x.followed_recommendation ? 'matches engine' : 'differs from engine'}
              />
            </Stack>
            <Typography variant="caption" sx={{ color: 'text.secondary' }}>
              {x.decided_by} ({x.decided_role}) - {fmtZL(ms(x.decided_at))}
            </Typography>
            <Typography variant="body2" sx={{ my: 1 }}>
              {x.rationale}
            </Typography>
            <Button size="small" variant="contained" onClick={() => review(x)}>
              Review and approve
            </Button>
          </Box>
        ))}
      </Stack>
    </Drawer>
  );
}
