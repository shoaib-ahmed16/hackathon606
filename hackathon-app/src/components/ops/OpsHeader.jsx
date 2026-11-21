import { useState } from 'react';
import {
  Badge,
  Box,
  Button,
  Chip,
  IconButton,
  Menu,
  MenuItem,
  Paper,
  Stack,
  TextField,
  Tooltip,
  Typography,
} from '@mui/material';
import MoreVertIcon from '@mui/icons-material/MoreVert';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import ConfirmDialog from '@/components/ConfirmDialog';
import {
  useAddRecordMutation,
  useCloseCaseMutation,
  useDeleteCaseMutation,
} from '@/features/ops/opsApi';
import { openPanel, selectCase } from '@/features/ops/opsSlice';
import { iso, ms, stampMs } from '@/features/ops/helpers';
import { fmtTime, fmtZ, fmtZs } from '@/features/ops/time';
import { useNow, useWall } from '@/hooks/useNow';
import { getErrorMessage } from '@/utils/getErrorMessage';
import Countdown from './Countdown';
import CreateCaseDialog from './CreateCaseDialog';
import StatusChip from './StatusChip';

// Situation strip, always visible: case, hub status + reopening countdown, alternates, clock, approvals, ask.
export default function OpsHeader({ d }) {
  const dispatch = useAppDispatch();
  const now = useNow();
  const wall = useWall();
  const { ops, kase, cases, airport, actor, decisions, options, refreshedAt } = d;
  const [creating, setCreating] = useState(false);
  const [menu, setMenu] = useState(null);
  const [confirm, setConfirm] = useState(null); // 'close' | 'delete'
  const [add] = useAddRecordMutation();
  const [closeCase, { isLoading: closing }] = useCloseCaseMutation();
  const [deleteCase, { isLoading: deleting }] = useDeleteCaseMutation();
  const canManage = ['OCC', 'ADMIN'].includes(actor?.role_code);

  const hub = airport.find((a) => a.iata === kase?.hub_iata) ?? airport[0];
  const reopen = hub?.expected_reopen_utc ? ms(hub.expected_reopen_utc) : null;
  const pending = decisions.filter((x) => x.status === 'PROPOSED').length;
  // alternates: every airport with a status plus every alternate the engine ranked (unconfirmed ones show "?")
  const altCodes = [
    ...new Set([
      ...airport.filter((a) => a.iata !== hub?.iata).map((a) => a.iata),
      ...options.filter((o) => o.alternate_iata).map((o) => o.alternate_iata),
    ]),
  ].sort();
  const altChip = (code) => {
    const a = airport.find((x) => x.iata === code);
    if (!a)
      return {
        tone: 'default',
        text: `${code} ? unconfirmed`,
        tip: 'No station status entered. The engine will not mark this alternate executable until it is confirmed.',
      };
    if (a.op_status !== 'OPEN')
      return { tone: 'error', text: `${code} ✕ ${a.op_status.toLowerCase()}`, tip: a.reason };
    if (a.fuel_ok === false)
      return { tone: 'error', text: `${code} ✕ no fuel`, tip: 'Fuel not available' };
    return {
      tone: 'success',
      text: `${code} ✓ ${a.parking_available != null ? `${a.parking_available} stands` : 'open'}`,
      tip: a.reason ?? 'Open',
    };
  };

  const moveReopen = async (min) => {
    try {
      await add({
        table: 'airport_status_event',
        body: {
          scenario_id: kase.scenario_id,
          iata: hub.iata,
          op_status: hub.op_status,
          reason: hub.reason,
          visibility_m: hub.visibility_m,
          lvp_in_force: hub.lvp_in_force,
          arrival_capacity_per_hr: hub.arrival_capacity_per_hr,
          parking_available: hub.parking_available,
          effective_from_utc: iso(stampMs(kase)),
          expected_reopen_utc: iso(reopen + min * 60000),
          quality: 'MANUAL',
          entered_by: actor.user_id,
          note: `Reopening forecast moved ${min > 0 ? '+' : ''}${min} min from the console`,
        },
      }).unwrap();
      toast.success(
        `${hub.iata} reopening forecast moved ${min > 0 ? '+' : ''}${min} min. Recommendations re-rank.`,
      );
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  const manage = async () => {
    try {
      if (confirm === 'close') await closeCase({ caseId: kase.case_id }).unwrap();
      else await deleteCase({ caseId: kase.case_id }).unwrap();
      toast.success(
        confirm === 'close' ? 'Case closed. It stays in the audit trail.' : 'Case deleted',
      );
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
    setConfirm(null);
  };

  const refreshedS = refreshedAt ? Math.max(0, Math.floor((wall - refreshedAt) / 1000)) : null;

  return (
    <Paper
      sx={{
        p: 1.5,
        display: 'grid',
        gap: 1.25,
        borderColor: kase?.scenario_kind === 'LIVE' ? 'divider' : 'warning.main',
        borderWidth: kase?.scenario_kind === 'LIVE' ? 1 : 2,
        borderStyle: 'solid',
      }}
    >
      {kase && kase.scenario_kind !== 'LIVE' && (
        <Typography variant="caption" sx={{ color: 'warning.main', fontWeight: 700 }}>
          {kase.scenario_kind} SCENARIO - nothing here affects live operations
        </Typography>
      )}
      <Stack
        direction={{ xs: 'column', xl: 'row' }}
        spacing={2}
        sx={{ alignItems: { xl: 'center' } }}
      >
        <Stack
          direction="row"
          spacing={1}
          sx={{ alignItems: 'center', minWidth: 0 }}
          data-src="scenario / disruption_case"
        >
          <TextField
            select
            size="small"
            label="Case / scenario"
            value={ops.caseId ?? ''}
            onChange={(e) => dispatch(selectCase(cases.find((c) => c.case_id === e.target.value)))}
            sx={{ minWidth: 240, maxWidth: 320 }}
          >
            {cases.map((c) => (
              <MenuItem key={c.case_id} value={c.case_id}>
                #{c.case_id} {c.title} ({c.scenario_kind}){c.phase === 'CLOSED' ? ' [closed]' : ''}
              </MenuItem>
            ))}
          </TextField>
          <Button
            variant="outlined"
            size="small"
            onClick={() => setCreating(true)}
            sx={{ whiteSpace: 'nowrap' }}
          >
            New case
          </Button>
          {canManage && kase && (
            <>
              <IconButton
                size="small"
                aria-label="Case actions"
                onClick={(e) => setMenu(e.currentTarget)}
              >
                <MoreVertIcon />
              </IconButton>
              <Menu anchorEl={menu} open={Boolean(menu)} onClose={() => setMenu(null)}>
                <MenuItem
                  disabled={kase.phase === 'CLOSED'}
                  onClick={() => {
                    setMenu(null);
                    setConfirm('close');
                  }}
                >
                  Close this case (keep history)
                </MenuItem>
                <MenuItem
                  onClick={() => {
                    setMenu(null);
                    setConfirm('delete');
                  }}
                  sx={{ color: 'error.main' }}
                >
                  Delete this case...
                </MenuItem>
                {reopen && (
                  <MenuItem
                    onClick={() => {
                      setMenu(null);
                      moveReopen(-30);
                    }}
                  >
                    Reopening forecast: 30 min earlier
                  </MenuItem>
                )}
                {reopen && (
                  <MenuItem
                    onClick={() => {
                      setMenu(null);
                      moveReopen(30);
                    }}
                  >
                    Reopening forecast: 30 min later
                  </MenuItem>
                )}
              </Menu>
            </>
          )}
        </Stack>

        {hub && (
          <Box data-src="v_airport_status_current (hub)" sx={{ minWidth: 220 }}>
            <Stack
              direction="row"
              spacing={1}
              sx={{ alignItems: 'center', flexWrap: 'wrap', rowGap: 0.5 }}
            >
              <Typography variant="h6">{hub.iata}</Typography>
              <StatusChip status={hub.op_status} />
              {hub.lvp_in_force && <Chip size="small" color="warning" label="LVP in force" />}
              {hub.visibility_m != null && (
                <Typography variant="caption" sx={{ color: 'text.secondary' }}>
                  vis {hub.visibility_m} m
                </Typography>
              )}
            </Stack>
            <Typography variant="caption" component="div" sx={{ color: 'text.secondary' }}>
              {reopen ? (
                <>
                  Reopens ~{fmtZ(reopen)} / {fmtTime(reopen)} SHJ (
                  {String(hub.quality ?? '').toLowerCase()}) - <Countdown at={reopen} />
                </>
              ) : (
                'No reopening forecast'
              )}
              {hub.arrival_capacity_per_hr != null &&
                ` - arrivals ${hub.arrival_capacity_per_hr}/h`}
            </Typography>
          </Box>
        )}

        <Box
          data-src="v_airport_status_current (alternates) + engine alternates"
          sx={{ minWidth: 0 }}
        >
          <Typography variant="caption" sx={{ color: 'text.secondary' }}>
            Alternates
          </Typography>
          <Stack direction="row" sx={{ gap: 0.5, flexWrap: 'wrap' }}>
            {altCodes.length === 0 && <Typography variant="caption">none ranked yet</Typography>}
            {altCodes.map((c) => {
              const x = altChip(c);
              return (
                <Tooltip key={c} title={x.tip ?? ''}>
                  <Chip size="small" variant="outlined" color={x.tone} label={x.text} />
                </Tooltip>
              );
            })}
          </Stack>
        </Box>

        <Box sx={{ flex: 1, minWidth: 0 }} />
        <Box sx={{ textAlign: 'right' }} data-src="scenario_now()">
          <Typography
            variant="h5"
            sx={{ fontFamily: 'monospace', fontVariantNumeric: 'tabular-nums', lineHeight: 1.1 }}
          >
            {fmtZs(now)}
          </Typography>
          <Typography variant="caption" sx={{ color: 'text.secondary' }}>
            {fmtTime(now)} SHJ{refreshedS != null ? ` - data refreshed ${refreshedS} s ago` : ''}
          </Typography>
        </Box>
        <Stack direction="row" spacing={1}>
          <Badge
            badgeContent={pending}
            color="warning"
            invisible={pending === 0}
            data-src="decision WHERE status = PROPOSED"
          >
            <Button variant="outlined" onClick={() => dispatch(openPanel('approvals'))}>
              Approvals
            </Button>
          </Badge>
          <Button variant="contained" onClick={() => dispatch(openPanel('ask'))}>
            Ask{' '}
            <Typography component="span" variant="caption" sx={{ ml: 0.75, opacity: 0.8 }}>
              Ctrl K
            </Typography>
          </Button>
        </Stack>
      </Stack>

      <ConfirmDialog
        open={Boolean(confirm)}
        loading={closing || deleting}
        title={confirm === 'close' ? 'Close this case?' : 'Delete this case?'}
        message={
          confirm === 'close'
            ? 'The case is marked closed. Decisions, comments and the audit trail are kept.'
            : 'Only cases nobody has decided on or commented on can be deleted. Otherwise the database keeps them for the audit trail and you must close the case instead.'
        }
        confirmText={confirm === 'close' ? 'Close case' : 'Delete'}
        onConfirm={manage}
        onClose={() => setConfirm(null)}
      />
      {creating && <CreateCaseDialog kase={kase} onClose={() => setCreating(false)} />}
    </Paper>
  );
}
