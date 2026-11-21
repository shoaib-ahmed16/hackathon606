import { useCallback, useMemo } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';

const parse = (search) =>
  (new URLSearchParams(search).get('f') ?? '').split(',').filter(Boolean);

// Board filters live in the URL (?f=crew,lvp) so a view can be shared and survives a reload.
// The KPI bar and the board filter chips both read and write this one place.
// Every change is computed from the LIVE browser location at click time, not from the render it was created in
// (react-router's functional setSearchParams only sees render-time params), so quick successive clicks never stack
// or lose filters.
export function useBoardFilters() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const chips = useMemo(() => parse(params.toString()), [params]);

  const update = useCallback(
    (fn) => {
      const next = fn(parse(window.location.search));
      const n = new URLSearchParams(window.location.search);
      if (next.length) n.set('f', next.join(','));
      else n.delete('f');
      const search = n.toString();
      navigate({ search: search ? `?${search}` : '' }, { replace: true });
    },
    [navigate],
  );

  return {
    chips,
    toggle: (k) => update((cur) => (cur.includes(k) ? cur.filter((x) => x !== k) : [...cur, k])),
    only: (k) => update((cur) => (k ? (cur.length === 1 && cur[0] === k ? [] : [k]) : [])),
    clear: () => update(() => []),
    // single-valued filters ("status:Holding", "sev:50"): replace whatever was set for that prefix
    set: (prefix, value) => update((cur) => [...cur.filter((x) => !x.startsWith(`${prefix}:`)), ...(value ? [`${prefix}:${value}`] : [])]),
    value: (prefix) => chips.find((x) => x.startsWith(`${prefix}:`))?.slice(prefix.length + 1) ?? '',
  };
}
