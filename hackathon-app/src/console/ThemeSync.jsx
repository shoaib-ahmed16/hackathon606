import { useEffect } from 'react';
import { useAppSelector } from '@/app/hooks';
import { selectMode } from '@/features/ui/uiSlice';

// The console's stylesheet themes through html[data-theme]; the redux ui slice stays the single source of truth.
export default function ThemeSync() {
  const mode = useAppSelector(selectMode);
  useEffect(() => {
    document.documentElement.dataset.theme = mode;
  }, [mode]);
  return null;
}
