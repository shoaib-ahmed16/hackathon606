import { createContext, createElement, useContext, useEffect, useState } from 'react';
import { scenarioNowMs } from '@/features/ops/helpers';

// Mount with key={case_id} so the clock restarts when the case changes.
// One shared 1-second ticker for the whole console. Provides the scenario clock (ms since epoch, UTC):
// replay/LIVE scenarios run on their stored clock and tick forward from the moment the page loaded.
const NowContext = createContext(Date.now());
// Same clock rounded down to the minute. Components that only show minutes (fuel left, lanes) use this one, so they
// re-render once a minute instead of every second.
const MinuteContext = createContext(Math.floor(Date.now() / 60000) * 60000);

export function NowProvider({ kase, children }) {
  const [now, setNow] = useState(() => scenarioNowMs(kase));
  useEffect(() => {
    const id = setInterval(() => setNow(scenarioNowMs(kase)), 1000);
    return () => clearInterval(id);
  }, [kase]);
  const minute = Math.floor(now / 60000) * 60000;
  return createElement(
    NowContext.Provider,
    { value: now },
    createElement(MinuteContext.Provider, { value: minute }, children),
  );
}

export const useNow = () => useContext(NowContext);
export const useMinuteNow = () => useContext(MinuteContext);

// Wall-clock ticker (ms) for "refreshed N s ago" style ages that must not follow the scenario clock.
export function useWall() {
  const [wall, setWall] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setWall(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);
  return wall;
}
