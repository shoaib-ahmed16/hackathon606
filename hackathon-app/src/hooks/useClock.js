import { useEffect, useState } from 'react';

// Ticks every second. Returns ms elapsed since mount (drives the live ops clock + "synced Ns ago").
export function useElapsed(tickMs = 1000) {
  const [start] = useState(() => Date.now());
  const [now, setNow] = useState(start);
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), tickMs);
    return () => clearInterval(id);
  }, [tickMs]);
  return now - start;
}
