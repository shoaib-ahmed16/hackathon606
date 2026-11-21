import { useEffect } from 'react';
import { Alert, Box, GlobalStyles, Typography } from '@mui/material';
import Loader from '@/components/Loader';
import { useAppDispatch } from '@/app/hooks';
import { OPS_API_URL } from '@/config/env';
import { openPanel } from '@/features/ops/opsSlice';
import { useOps } from '@/features/ops/useOps';
import { NowProvider } from '@/hooks/useNow';
import { getErrorMessage } from '@/utils/getErrorMessage';
import ApprovalsDrawer from './ApprovalsDrawer';
import AskDialog from './AskDialog';
import FlightDrawer from './FlightDrawer';
import OpsHeader from './OpsHeader';
import WhatIfDialog from './WhatIfDialog';

// "Data sources" mode: every block that carries data-src shows which database view feeds it (for judges and engineers).
const sourceStyles = (
  <GlobalStyles
    styles={{
      '[data-src]': { position: 'relative' },
      'body.show-src [data-src]::after': {
        content: 'attr(data-src)',
        position: 'absolute',
        top: -1,
        right: -1,
        zIndex: 5,
        font: '500 10.5px/1.3 system-ui',
        background: '#FFE066',
        color: '#3A2E00',
        padding: '1px 5px',
        borderRadius: 3,
        pointerEvents: 'none',
        maxWidth: 280,
        whiteSpace: 'normal',
        textAlign: 'left',
      },
    }}
  />
);

function Shell({ d, children }) {
  const dispatch = useAppDispatch();
  const { ops } = d;
  useEffect(() => {
    document.body.classList.toggle('show-src', ops.showSources);
    return () => document.body.classList.remove('show-src');
  }, [ops.showSources]);
  useEffect(() => {
    const onKey = (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        dispatch(openPanel('ask'));
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [dispatch]);

  return (
    <Box sx={{ display: 'grid', gap: 2 }}>
      {sourceStyles}
      <OpsHeader d={d} />
      {d.noCase ? (
        <Alert severity="info">
          <Typography variant="subtitle2">No disruption case yet.</Typography>Create one with "New
          case".
        </Alert>
      ) : (
        children(d)
      )}
      <FlightDrawer d={d} />
      {ops.panel === 'ask' && <AskDialog d={d} />}
      {ops.panel === 'approvals' && <ApprovalsDrawer d={d} />}
      {ops.panel === 'whatif' && <WhatIfDialog d={d} />}
    </Box>
  );
}

// Wrapper for every ops screen: loads the selected case + read models, shows the situation strip, runs the shared clock.
export default function OpsPage({ children }) {
  const d = useOps();
  if (d.isLoading) return <Loader />;
  if (d.error)
    return (
      <Alert severity="error">
        Cannot reach the FogOps API at {OPS_API_URL}. {getErrorMessage(d.error)} Start it with the
        steps in backend/API_README.md.
      </Alert>
    );
  return (
    <NowProvider key={d.kase?.case_id ?? 'none'} kase={d.kase}>
      <Shell d={d}>{children}</Shell>
    </NowProvider>
  );
}
