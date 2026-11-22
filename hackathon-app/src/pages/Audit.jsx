import { useMemo, useState } from 'react';
import {
  Box,
  Button,
  Chip,
  Collapse,
  FormControlLabel,
  MenuItem,
  Paper,
  Stack,
  Switch,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  ToggleButton,
  ToggleButtonGroup,
  Typography,
} from '@mui/material';
import { useGetAuditQuery } from '@/features/ops/opsApi';
import { ms } from '@/features/ops/helpers';
import { fmtDate, fmtZ, fmtTime } from '@/features/ops/time';
import { useDebounce } from '@/hooks/useDebounce';
import EmptyState from '@/components/EmptyState';
import { useConsole } from '@/console/ConsoleContext';

const q = (v) => `"${String(v ?? '').replaceAll('"', '""')}"`;
const exportCsv = (rows) => {
  const head = 'time_utc,actor,role,kind,summary,outcome,entity_type,entity_id,scenario_id,case_id';
  const lines = rows.map((r) =>
    [
      r.scenario_time_utc ?? r.occurred_at,
      r.actor,
      r.actor_role,
      r.kind,
      r.summary,
      r.kind === 'action'
        ? r.after_data?.ok === false
          ? `REFUSED ${r.after_data.status}`
          : 'OK'
        : '',
      r.entity_type,
      r.entity_id,
      r.scenario_id,
      r.case_id,
    ]
      .map(q)
      .join(','),
  );
  const url = URL.createObjectURL(new Blob([[head, ...lines].join('\n')], { type: 'text/csv' }));
  Object.assign(document.createElement('a'), { href: url, download: 'audit-trail.csv' }).click();
  URL.revokeObjectURL(url);
};

function Body() {
  const d = useConsole();
  const [kind, setKind] = useState('all');
  const [thisCase, setThisCase] = useState(true);
  const [system, setSystem] = useState(false);
  const [who, setWho] = useState('ALL');
  const [text, setText] = useState('');
  const [open, setOpen] = useState(null);
  const dq = useDebounce(text, 300);
  const { data = [], isFetching } = useGetAuditQuery(
    {
      scenario_id: thisCase ? d.ctx.scenario_id : undefined,
      case_id: thisCase ? d.ctx.case_id : undefined,
      kind,
      q: dq || undefined,
      include_system: system,
      limit: 500,
    },
  );
  const people = useMemo(
    () => [
      ...new Map(
        data.filter((r) => r.actor_user_id).map((r) => [r.actor_user_id, r.actor]),
      ).entries(),
    ],
    [data],
  );
  const rows = data.filter((r) => who === 'ALL' || String(r.actor_user_id) === who);

  return (
    <Box className="page page-wide" sx={{ display: 'grid', gap: 2, alignContent: 'start' }}>
      <div>
        <h2>Audit trail</h2>
        <p className="lead">
          Everything people did (actions, refused attempts included) and everything that changed in the data, with who and when. It
          cannot be edited or deleted.
        </p>
        <Button variant="outlined" disabled={!rows.length} onClick={() => exportCsv(rows)}>
          Export CSV
        </Button>
      </div>
      <Paper sx={{ p: 1.5 }} data-src="audit_log (append-only) + API action log">
        <Stack
          direction={{ xs: 'column', lg: 'row' }}
          spacing={2}
          sx={{ alignItems: { lg: 'center' } }}
        >
          <ToggleButtonGroup
            exclusive
            size="small"
            value={kind}
            onChange={(_, v) => v && setKind(v)}
          >
            <ToggleButton value="all">Everything</ToggleButton>
            <ToggleButton value="action">Actions</ToggleButton>
            <ToggleButton value="change">Data changes</ToggleButton>
          </ToggleButtonGroup>
          <TextField
            select
            size="small"
            label="Who"
            value={who}
            onChange={(e) => setWho(e.target.value)}
            sx={{ minWidth: 190 }}
          >
            <MenuItem value="ALL">Everyone</MenuItem>
            {people.map(([id, name]) => (
              <MenuItem key={id} value={String(id)}>
                {name}
              </MenuItem>
            ))}
          </TextField>
          <TextField
            size="small"
            label="Search"
            value={text}
            onChange={(e) => setText(e.target.value)}
            sx={{ minWidth: 220 }}
          />
          <FormControlLabel
            control={
              <Switch
                size="small"
                checked={thisCase}
                onChange={(e) => setThisCase(e.target.checked)}
              />
            }
            label="This case only"
          />
          <FormControlLabel
            control={
              <Switch size="small" checked={system} onChange={(e) => setSystem(e.target.checked)} />
            }
            label="Include engine and import rows"
          />
          <Typography variant="caption" sx={{ color: 'text.secondary' }}>
            {rows.length} shown{isFetching ? ' - refreshing' : ''}, updates every 10 s
          </Typography>
        </Stack>
      </Paper>
      <Paper sx={{ overflow: 'auto' }}>
        {rows.length === 0 ? (
          <EmptyState
            title="Nothing recorded yet"
            hint="Actions appear here the moment they happen."
          />
        ) : (
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Time (UTC / SHJ)</TableCell>
                <TableCell>Who</TableCell>
                <TableCell>Kind</TableCell>
                <TableCell>What</TableCell>
                <TableCell>Outcome</TableCell>
                <TableCell />
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map((r) => {
                const t = ms(r.scenario_time_utc ?? r.occurred_at); // scenario time: the same clock as the briefing and the screen
                const refused = r.kind === 'action' && r.after_data?.ok === false;
                return [
                  <TableRow
                    key={r.audit_id}
                    hover
                    sx={{ cursor: 'pointer', '& td': { verticalAlign: 'top' } }}
                    onClick={() => setOpen(open === r.audit_id ? null : r.audit_id)}
                  >
                    <TableCell sx={{ whiteSpace: 'nowrap', fontVariantNumeric: 'tabular-nums' }}>
                      {fmtDate(t)} {fmtZ(t)}{' '}
                      <Typography
                        component="span"
                        variant="caption"
                        sx={{ color: 'text.secondary' }}
                      >
                        / {fmtTime(t)}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      {r.actor ?? <i>system</i>}
                      <Typography
                        variant="caption"
                        sx={{ display: 'block', color: 'text.secondary' }}
                      >
                        {r.actor_role}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      <Chip
                        size="small"
                        variant="outlined"
                        color={r.kind === 'action' ? 'primary' : 'default'}
                        label={r.kind === 'action' ? 'Action' : 'Data change'}
                      />
                    </TableCell>
                    <TableCell sx={{ maxWidth: 520 }}>{r.summary}</TableCell>
                    <TableCell>
                      {r.kind === 'action' ? (
                        <Chip
                          size="small"
                          color={refused ? 'error' : 'success'}
                          label={refused ? `Refused ${r.after_data.status}` : 'OK'}
                        />
                      ) : (
                        '-'
                      )}
                    </TableCell>
                    <TableCell>
                      <Typography variant="caption" sx={{ color: 'text.secondary' }}>
                        {open === r.audit_id ? 'hide' : 'details'}
                      </Typography>
                    </TableCell>
                  </TableRow>,
                  <TableRow key={`${r.audit_id}-d`}>
                    <TableCell colSpan={6} sx={{ p: 0, border: 0 }}>
                      <Collapse in={open === r.audit_id} unmountOnExit>
                        <Box
                          component="pre"
                          sx={{
                            m: 0,
                            p: 1.5,
                            bgcolor: 'action.hover',
                            fontSize: 12,
                            overflow: 'auto',
                            maxHeight: 280,
                          }}
                        >
                          {JSON.stringify(
                            {
                              entity: `${r.entity_type} ${r.entity_id}`,
                              scenario: r.scenario_id,
                              case: r.case_id,
                              changed_fields: r.changed_fields,
                              before: r.before_data,
                              after: r.after_data,
                            },
                            null,
                            2,
                          )}
                        </Box>
                      </Collapse>
                    </TableCell>
                  </TableRow>,
                ];
              })}
            </TableBody>
          </Table>
        )}
      </Paper>
    </Box>
  );
}

export default function Audit() {
  return <Body />;
}
