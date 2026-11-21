import { useState } from 'react';
import { Box, Paper, Stack, ToggleButton, ToggleButtonGroup, Typography } from '@mui/material';
import { ms } from '@/features/ops/helpers';
import { fmtDateTime } from '@/features/ops/time';
import PageHeader from '@/components/PageHeader';
import EmptyState from '@/components/EmptyState';
import OpsPage from '@/components/ops/OpsPage';
import StatusChip from '@/components/ops/StatusChip';

// Data-quality and "verification required" items raised by the database (never hidden, never guessed).
function Body({ d }) {
  const [sev, setSev] = useState('ALL');
  const [code, setCode] = useState('ALL');
  const codes = ['ALL', ...new Set(d.exceptions.map((e) => e.code))];
  const rows = d.exceptions.filter(
    (e) => (sev === 'ALL' || e.severity === sev) && (code === 'ALL' || e.code === code),
  );
  return (
    <Box sx={{ display: 'grid', gap: 2 }}>
      <PageHeader
        title="Alerts & Exceptions"
        subtitle={`${rows.length} of ${d.exceptions.length} open - anything unverified is shown here instead of being treated as legal`}
      />
      <Paper sx={{ p: 2, display: 'flex', gap: 2, flexWrap: 'wrap' }}>
        <ToggleButtonGroup exclusive size="small" value={sev} onChange={(_, v) => v && setSev(v)}>
          {['ALL', 'BLOCKING', 'WARN', 'INFO'].map((s) => (
            <ToggleButton key={s} value={s}>
              {s}
            </ToggleButton>
          ))}
        </ToggleButtonGroup>
        <ToggleButtonGroup
          exclusive
          size="small"
          value={code}
          onChange={(_, v) => v && setCode(v)}
          sx={{ flexWrap: 'wrap' }}
        >
          {codes.map((c) => (
            <ToggleButton key={c} value={c}>
              {c}
            </ToggleButton>
          ))}
        </ToggleButtonGroup>
      </Paper>
      <Paper sx={{ p: 2 }}>
        {rows.length === 0 ? (
          <EmptyState title="No exceptions" hint="Nothing needs verification" />
        ) : (
          <Stack spacing={1}>
            {rows.slice(0, 200).map((e) => (
              <Box
                key={e.exception_id}
                sx={{
                  display: 'flex',
                  gap: 1.5,
                  alignItems: 'flex-start',
                  p: 1.25,
                  border: 1,
                  borderColor: 'divider',
                  borderRadius: 2,
                }}
              >
                <StatusChip status={e.severity} />
                <Box sx={{ flex: 1, minWidth: 0 }}>
                  <Typography variant="subtitle2">
                    {e.code}{' '}
                    <Typography component="span" variant="caption" sx={{ color: 'text.secondary' }}>
                      {e.entity_type} {e.entity_id}
                    </Typography>
                  </Typography>
                  <Typography variant="body2" sx={{ color: 'text.secondary' }}>
                    {e.message}
                  </Typography>
                  <Typography variant="caption" sx={{ color: 'text.secondary' }}>
                    raised {fmtDateTime(ms(e.raised_at))}
                  </Typography>
                </Box>
              </Box>
            ))}
          </Stack>
        )}
      </Paper>
    </Box>
  );
}

export default function Alerts() {
  return <OpsPage>{(d) => <Body d={d} />}</OpsPage>;
}
