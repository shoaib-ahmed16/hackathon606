import { useState } from 'react';
import { Stack } from '@mui/material';
import Briefing from '@/components/ops/Briefing';
import ConsoleBar from '@/components/ops/ConsoleBar';
import OpsPage from '@/components/ops/OpsPage';
import BoardLens from '@/components/ops/lenses/BoardLens';
import CrewLens from '@/components/ops/lenses/CrewLens';
import RecoveryLens from '@/components/ops/lenses/RecoveryLens';
import StationLens from '@/components/ops/lenses/StationLens';

function Body({ d }) {
  const [briefing, setBriefing] = useState(true);
  const lens = d.ops.lens;
  return (
    <Stack spacing={1.5}>
      <ConsoleBar d={d} briefing={briefing} onBriefing={() => setBriefing((b) => !b)} />
      {briefing && <Briefing d={d} />}
      {(lens === 'occ' || lens === 'dispatch') && <BoardLens d={d} lens={lens} />}
      {lens === 'crew' && <CrewLens d={d} />}
      {lens === 'station' && <StationLens d={d} />}
      {lens === 'recovery' && <RecoveryLens d={d} />}
    </Stack>
  );
}

export default function Console() {
  return <OpsPage>{(d) => <Body d={d} />}</OpsPage>;
}
