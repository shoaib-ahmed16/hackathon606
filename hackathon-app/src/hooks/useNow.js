import { createContext, createElement, useContext, useEffect, useState } from 'react';
import { scenarioNowMs } from '@/features/ops/helpers';

// Mount with key={case_id} so the clock restarts when the case changes.
// One shared 1-second ticker for the whole console. Provides the scenario clock (ms since epoch, UTC):
// replay/LIVE scenarios run on their stored clock and tick forward from the moment the page loaded.
const NowContext = createContext(Date.now());

export function NowProvider({ kase, children }) {
  const [now, setNow] = useState(() => scenarioNowMs(kase));
  useEffect(() => {
    const id = setInterval(() => setNow(scenarioNowMs(kase)), 1000);
    return () => clearInterval(id);
  }, [kase]);
  return createElement(NowContext.Provider, { value: now }, children);
}

export const useNow = () => useContext(NowContext);

// Wall-clock ticker (ms) for "refreshed N s ago" style ages that must not follow the scenario clock.
export function useWall() {
  const [wall, setWall] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setWall(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);
  return wall;
}
