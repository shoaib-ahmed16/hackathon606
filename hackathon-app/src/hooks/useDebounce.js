import { useEffect, useState } from 'react';

// const debounced = useDebounce(search);  -> use `debounced` in the query so typing doesn't spam the API
export function useDebounce(value, delay = 400) {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setDebounced(value), delay);
    return () => clearTimeout(t);
  }, [value, delay]);
  return debounced;
}
