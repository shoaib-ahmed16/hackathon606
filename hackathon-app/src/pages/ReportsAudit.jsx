import {
  Box,
  Button,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Typography,
} from '@mui/material';
import toast from 'react-hot-toast';
import { useGenerateReportMutation, useGetTimelineQuery } from '@/features/ops/opsApi';
import { ms } from '@/features/ops/helpers';
import { fmtDateTime } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';
import PageHeader from '@/components/PageHeader';
import StatCard from '@/components/StatCard';
import EmptyState from '@/components/EmptyState';
import OpsPage from '@/components/ops/OpsPage';
import StatusChip from '@/components/ops/StatusChip';

const q = (v) => `"${String(v ?? '').replaceAll('"', '""')}"`;
const exportCsv = (rows) => {
  const head = 'time,flight,decision,alternate,status,decided_by,role,rationale,approvals';
  const lines = rows.map((r) =>
    [
      r.decided_at,
      r.flight_no,
      r.decision_type,
      r.alternate_iata,
      r.status,
      r.decided_by,
      r.decided_role,
      r.rationale,
      (r.approvals ?? []).map((a) => `${a.verdict} ${a.by}`).join('; '),
    ]
      .map(q)
      .join(','),
  );
  const url = URL.createObjectURL(new Blob([[head, ...lines].join('\n')], { type: 'text/csv' }));
  Object.assign(document.createElement('a'), { href: url, download: 'decision-log.csv' }).click();
  URL.revokeObjectURL(url);
};

function Body({ d }) {
  const [gen, { isLoading, data: report }] = useGenerateReportMutation();
  const timeline = useGetTimelineQuery(
    { case_id: d.ctx.case_id },
    { skip: !d.ctx.case_id, pollingInterval: 15000 },
  );
  const decisions = d.decisions;
  const make = async () => {
    try {
      await gen({ caseId: d.ctx.case_id }).unwrap();
      toast.success('Report generated (reproducible snapshot with audit watermark)');
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  return (
    <Box sx={{ display: 'grid', gap: 2 }}>
      <PageHeader
        title="Reports & Audit"
        subtitle="Decision timeline, approvals and exceptions for this case"
        actions={
          <>
            <Button
              variant="outlined"
              disabled={!decisions.length}
              onClick={() => exportCsv(decisions)}
            >
              Export decision log (CSV)
            </Button>
            <Button variant="contained" disabled={isLoading} onClick={make}>
              Generate report
            </Button>
          </>
        }
      />
      <Box
        sx={{
          display: 'grid',
          gap: 2,
          gridTemplateColumns: { xs: 'repeat(2, 1fr)', md: 'repeat(4, 1fr)' },
        }}
      >
        <StatCard label="Decisions" value={decisions.length} />
        <StatCard
          label="Approved / executed"
          value={decisions.filter((x) => ['APPROVED', 'EXECUTED'].includes(x.status)).length}
        />
        <StatCard
          label="Pending approval"
          value={decisions.filter((x) => x.status === 'PROPOSED').length}
        />
        <StatCard label="Open exceptions" value={d.exceptions.length} />
      </Box>
      {report && (
        <Paper sx={{ p: 2 }}>
          <Typography variant="body2">
            Report #{report[0]?.generate_report} created. It is stored in the database with the
            audit watermark, so it can be reproduced.
          </Typography>
        </Paper>
      )}
      <Paper sx={{ p: 2.5, overflow: 'auto' }}>
        <Typography variant="h6" sx={{ mb: 1 }}>
          Decisions and approvals
        </Typography>
        {decisions.length === 0 ? (
          <EmptyState title="No decisions yet" hint="Record one from a flight on Flight Watch" />
        ) : (
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Time</TableCell>
                <TableCell>Flight</TableCell>
                <TableCell>Decision</TableCell>
                <TableCell>By</TableCell>
                <TableCell>Approvals</TableCell>
                <TableCell>Rationale</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {decisions.map((r) => (
                <TableRow key={r.decision_id}>
                  <TableCell>{fmtDateTime(ms(r.decided_at))}</TableCell>
                  <TableCell>{r.flight_no}</TableCell>
                  <TableCell>
                    {r.decision_type} {r.alternate_iata && `via ${r.alternate_iata}`}{' '}
                    <StatusChip status={r.status} />
                  </TableCell>
                  <TableCell>
                    {r.decided_by}
                    <Typography
                      variant="caption"
                      sx={{ display: 'block', color: 'text.secondary' }}
                    >
                      {r.decided_role}
                    </Typography>
                  </TableCell>
                  <TableCell>
                    {(r.approvals ?? []).map((a) => (
                      <Typography key={a.at} variant="caption" sx={{ display: 'block' }}>
                        {a.verdict} - {a.by} ({a.role})
                      </Typography>
                    ))}
                  </TableCell>
                  <TableCell sx={{ maxWidth: 320 }}>{r.rationale}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </Paper>
      <Paper sx={{ p: 2.5, overflow: 'auto' }}>
        <Typography variant="h6" sx={{ mb: 1 }}>
          Case timeline (audit trail)
        </Typography>
        <Stack spacing={0.5} sx={{ maxHeight: 420, overflow: 'auto' }}>
          {(timeline.data ?? [])
            .slice(-120)
            .reverse()
            .map((t, i) => (
              <Stack key={i} direction="row" spacing={1.5}>
                <Typography
                  variant="caption"
                  sx={{ width: 110, color: 'text.secondary', fontFamily: 'monospace' }}
                >
                  {fmtDateTime(ms(t.occurred_at))}
                </Typography>
                <Typography variant="caption" sx={{ width: 120 }} noWrap>
                  {t.actor ?? t.stream}
                </Typography>
                <Typography variant="body2" sx={{ flex: 1 }}>
                  {t.summary}
                </Typography>
              </Stack>
            ))}
        </Stack>
      </Paper>
    </Box>
  );
}

export default function ReportsAudit() {
  return <OpsPage>{(d) => <Body d={d} />}</OpsPage>;
}
