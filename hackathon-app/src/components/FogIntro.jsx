import { useEffect, useState } from 'react';
import { useLocation } from 'react-router-dom';
import { useAppDispatch, useAppSelector } from '@/app/hooks';
import { LogoMark } from '@/components/Logo';
import { APP_NAME } from '@/config/brand';
import { setReady } from '@/features/ops/opsSlice';
import './fog.css';

// The loader. On every page load and after every sign-in, fog covers the screen (instead of grey skeleton blocks), drifts gently while the
// first data loads, then drifts apart and clears to reveal the console: the product is about fog lifting over SHJ.
// A progress bar under the logo shows the page is loading. It stays at least ~1.1 s so it never flashes, clears as soon as the console reports its data ready, and never waits more than 8 s.
export default function FogIntro() {
  const dispatch = useAppDispatch();
  const path = useLocation().pathname;
  const ready = useAppSelector((s) => s.ops.ready) || path.startsWith('/data');   // the data explorer has no console data to wait for
  const [phase, setPhase] = useState('cover');   // cover | clearing | gone
  const [minDone, setMinDone] = useState(false);
  const [pct, setPct] = useState(6);   // progress: eases towards 92% while loading, 100% when the data is in

  useEffect(() => {
    dispatch(setReady(false));   // a new load or sign-in: wait for fresh data
    const a = setTimeout(() => setMinDone(true), 1100);
    const b = setTimeout(() => setPhase((p) => (p === 'cover' ? 'clearing' : p)), 8000);
    return () => {
      clearTimeout(a);
      clearTimeout(b);
    };
  }, [dispatch]);
  useEffect(() => {
    if (phase !== 'cover') {
      setPct(100);
      return undefined;
    }
    const t = setInterval(() => setPct((p) => p + (92 - p) * 0.07), 120);
    return () => clearInterval(t);
  }, [phase]);
  useEffect(() => {
    if (phase === 'cover' && ready && minDone) setPhase('clearing');
  }, [ready, minDone, phase]);
  useEffect(() => {
    if (phase !== 'clearing') return undefined;
    const t = setTimeout(() => setPhase('gone'), 1750);
    return () => clearTimeout(t);
  }, [phase]);

  if (phase === 'gone') return null;
  return (
    <div className={`fog ${phase}`} role="status" aria-label="Loading" onClick={() => ready && setPhase('gone')}>
      <i className="fog-c c1" /><i className="fog-c c2" /><i className="fog-c c3" /><i className="fog-c c4" /><i className="fog-c c5" /><i className="fog-c c6" />
      <div className="fog-brand">
        <LogoMark size={64} />
        <b>{APP_NAME}</b>
        <div className="fog-bar" role="progressbar" aria-label="Loading" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(pct)}>
          <i style={{ width: `${pct}%` }} />
        </div>
        <span className="fog-pct">Loading {Math.round(pct)}%</span>
      </div>
    </div>
  );
}
