import { memo, useEffect, useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import {
  useGetExplorerCatalogQuery,
  useGetExplorerLinksQuery,
  useGetExplorerProfileQuery,
  useGetExplorerRowsQuery,
} from '@/features/ops/opsApi';
import { useDebounce } from '@/hooks/useDebounce';
import './dataExplorer.css';

// Full-page, read-only view of every table and view in the database, with its relations, for validating the data end to end.
// State lives in the URL (?t=flight&f=flight_id|eq|4&q=..), so a view can be shared and the browser Back button follows jumps.

const SIZES = [50, 100, 250, 500];
const kfmt = (n) => (n == null ? '' : n >= 10000 ? `${(n / 1000).toFixed(n >= 100000 ? 0 : 1)}k` : String(n));
const nm = (t) => (t.schema === 'fogops' ? t.name : t.id); // history tables keep their schema prefix so they never look like ours
const isTs = (ty) => /timestamp with time zone/.test(ty ?? '');

function show(v, ty) {
  if (v === null || v === undefined) return null;
  if (typeof v === 'boolean') return v ? '✓' : '✗';
  if (isTs(ty) && typeof v === 'string') {
    const d = new Date(v);
    return Number.isNaN(d.getTime()) ? v : `${d.toISOString().slice(0, 19).replace('T', ' ')}Z`;
  }
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}

const parseFilter = (s) => {
  const [col, op, ...rest] = s.split('|');
  return { col, op, val: rest.join('|') };
};
const filterText = (x) => (x.op === 'eq' ? `${x.col} = ${x.val}` : x.op === 'like' ? `${x.col} contains "${x.val}"` : x.op === 'null' ? `${x.col} is empty` : `${x.col} is not empty`);

function csvOf(cols, rows) {
  const q = (v) => `"${String(v ?? '').replaceAll('"', '""')}"`;
  return [cols.map((c) => q(c.name)).join(','), ...rows.map((r) => cols.map((c) => q(typeof r[c.name] === 'object' && r[c.name] !== null ? JSON.stringify(r[c.name]) : r[c.name])).join(','))].join('\n');
}

export default function DataExplorer() {
  const navigate = useNavigate();
  const [sp, setSp] = useSearchParams();
  const cat = useGetExplorerCatalogQuery();
  const tables = useMemo(() => cat.data?.tables ?? [], [cat.data]);
  const byId = useMemo(() => Object.fromEntries(tables.map((t) => [t.id, t])), [tables]);
  const [tab, setTab] = useState('tables');
  const [railQ, setRailQ] = useState('');
  const [picked, setPicked] = useState(null); // the row open in the side panel

  const tid = sp.get('t') ?? 'flight';
  const table = byId[tid];
  const filters = sp.getAll('f');
  const sort = sp.get('sort');
  const dir = sp.get('dir') ?? 'asc';
  const size = Number(sp.get('size') ?? 100);
  const page = Number(sp.get('page') ?? 0);
  const urlQ = sp.get('q') ?? '';

  // every navigation goes through here so one jump = one history entry
  const go = (next) => {
    const p = new URLSearchParams();
    const m = { t: tid, q: urlQ, sort, dir, size, page, f: filters, ...next };
    p.set('t', m.t);
    if (m.q) p.set('q', m.q);
    if (m.sort) {
      p.set('sort', m.sort);
      p.set('dir', m.dir);
    }
    if (m.size !== 100) p.set('size', m.size);
    if (m.page) p.set('page', m.page);
    (m.f ?? []).forEach((x) => p.append('f', x));
    setSp(p);
    setPicked(null);
  };
  const openTable = (id, f = []) => {
    setTab('tables');
    go({ t: id, f, q: '', sort: null, dir: 'asc', page: 0 });
  };

  const [qBox, setQBox] = useState(urlQ);
  const dq = useDebounce(qBox, 450);
  useEffect(() => setQBox(urlQ), [urlQ, tid]);
  useEffect(() => {
    if (dq !== urlQ && tab === 'tables') go({ q: dq, page: 0 });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dq]);

  const rows = useGetExplorerRowsQuery({ table: tid, limit: size, offset: page * size, q: urlQ, sort, dir, f: filters }, { skip: !table });
  const [profileOn, setProfileOn] = useState(false);
  const profile = useGetExplorerProfileQuery(tid, { skip: !table || !profileOn });

  if (cat.isError) {
    return (
      <div className="xp xp-msg">
        <p>{cat.error?.status === 403 ? 'The data explorer is for OCC and admin users only.' : 'Could not load the database catalog.'}</p>
        <button className="btn" onClick={() => navigate('/')}>Back to the console</button>
      </div>
    );
  }

  const groups = (cat.data?.domains ?? []).map((d) => ({ d, items: tables.filter((t) => t.domain === d && (!railQ || t.name.toLowerCase().includes(railQ.toLowerCase()) || t.columns.some((c) => c.name.includes(railQ.toLowerCase())))) })).filter((g) => g.items.length);
  const tot = cat.data?.totals;

  return (
    <div className="xp">
      <header className="xp-head">
        <button className="btn ghost" onClick={() => navigate('/')}>← Console</button>
        <div className="xp-title">
          <b>Data explorer</b>
          <span className="k">Read-only view of the whole database, for checking the data and how it connects</span>
        </div>
        <div className="xp-tabs" role="tablist">
          <button role="tab" aria-selected={tab === 'tables'} onClick={() => setTab('tables')}>Tables</button>
          <button role="tab" aria-selected={tab === 'map'} onClick={() => setTab('map')}>Map</button>
        </div>
        <div className="spacer" />
        {tot && <span className="k xp-tot">{tot.tables} tables · {tot.views} views · {tot.foreign_keys} relations · {tot.rows.toLocaleString()} rows</span>}
      </header>

      <aside className="xp-rail">
        <input className="field-in" placeholder="Find a table or column…" value={railQ} onChange={(e) => setRailQ(e.target.value)} aria-label="Find a table or column" />
        <div className="xp-rail-list">
          {cat.isLoading && <p className="k">Loading…</p>}
          {groups.map((g) => (
            <div key={g.d}>
              <h4>{g.d}</h4>
              {g.items.map((t) => (
                <button key={t.id} className={`xp-t ${t.kind} ${tid === t.id && tab === 'tables' ? 'on' : ''}`} onClick={() => openTable(t.id)} title={t.comment ?? t.name}>
                  <span>{nm(t)}</span>
                  <small>{t.kind === 'view' ? 'view' : kfmt(t.rows)}</small>
                </button>
              ))}
            </div>
          ))}
        </div>
      </aside>

      <main className="xp-main">
        {tab === 'map' && <MapView tables={tables} domains={cat.data?.domains ?? []} onOpen={openTable} />}
        {tab === 'tables' && !table && !cat.isLoading && <p className="k" style={{ padding: 20 }}>Unknown table. Pick one on the left.</p>}
        {tab === 'tables' && table && (
          <>
            <div className="xp-bar">
              <div className="xp-name">
                <h2>{nm(table)}</h2>
                <span className={`xp-kind ${table.kind}`}>{table.kind}</span>
                <span className="k">{table.domain}</span>
                <span className="k">
                  {rows.data ? `${rows.data.total.toLocaleString()} ${filters.length || urlQ ? 'matching' : 'rows'}` : '…'}
                  {table.rows != null && (filters.length || urlQ) ? ` of ${table.rows.toLocaleString()}` : ''}
                </span>
              </div>
              {table.comment && <p className="xp-comment">{table.comment}</p>}
              <Relations table={table} byId={byId} onOpen={openTable} />
              <div className="xp-tools">
                <input className="field-in xp-search" placeholder="Search every column…" value={qBox} onChange={(e) => setQBox(e.target.value)} aria-label="Search every column" />
                {filters.map((f) => {
                  const x = parseFilter(f);
                  return (
                    <span className="xp-chip" key={f}>
                      {filterText(x)}
                      <button aria-label={`Remove filter ${filterText(x)}`} onClick={() => go({ f: filters.filter((y) => y !== f), page: 0 })}>×</button>
                    </span>
                  );
                })}
                {(filters.length > 0 || urlQ) && <button className="btn ghost" onClick={() => go({ f: [], q: '', page: 0 })}>Clear all</button>}
                <span className="spacer" />
                <button className="btn" aria-pressed={profileOn} onClick={() => setProfileOn((v) => !v)} title="Show empty and distinct counts per column">Column checks</button>
                <button className="btn" disabled={!rows.data?.rows?.length} onClick={() => {
                  const blob = new Blob([csvOf(table.columns, rows.data.rows)], { type: 'text/csv' });
                  const a = document.createElement('a');
                  a.href = URL.createObjectURL(blob);
                  a.download = `${nm(table)}.csv`;
                  a.click();
                }}>Export page (CSV)</button>
                <label className="k">Rows <select className="field-in" value={size} onChange={(e) => go({ size: Number(e.target.value), page: 0 })}>{SIZES.map((n) => <option key={n}>{n}</option>)}</select></label>
                <Pager page={page} size={size} total={rows.data?.total ?? 0} onPage={(p) => go({ page: p })} />
              </div>
            </div>

            <div className="xp-body">
              <div className="xp-grid">
                {rows.isError && <p className="xp-err">{rows.error?.data?.detail ?? 'Could not load rows.'}</p>}
                <Grid table={table} data={rows.data} loading={rows.isFetching} sort={sort} dir={dir} filters={filters}
                  profile={profileOn ? profile.data : null} picked={picked}
                  onSort={(c) => go({ sort: c, dir: sort === c && dir === 'asc' ? 'desc' : 'asc', page: 0 })}
                  onColFilter={(c, v) => go({ f: [...filters.filter((y) => !y.startsWith(`${c}|like|`)), ...(v ? [`${c}|like|${v}`] : [])], page: 0 })}
                  onJump={(ref, val) => openTable(ref.table, [`${ref.column}|eq|${val}`])}
                  onPick={setPicked} />
              </div>
              {picked && <RowPanel table={table} byId={byId} row={picked} onClose={() => setPicked(null)} onOpen={openTable} />}
            </div>
          </>
        )}
      </main>
    </div>
  );
}

function Pager({ page, size, total, onPage }) {
  const last = Math.max(0, Math.ceil(total / size) - 1);
  return (
    <span className="xp-pager">
      <button className="btn" disabled={page <= 0} onClick={() => onPage(page - 1)} aria-label="Previous page">‹</button>
      <span className="k">{total ? `${page * size + 1}–${Math.min(total, (page + 1) * size)}` : '0'} of {total.toLocaleString()}</span>
      <button className="btn" disabled={page >= last} onClick={() => onPage(page + 1)} aria-label="Next page">›</button>
    </span>
  );
}

// Which tables this one points at, and which point at it (for a view: what it is built from).
function Relations({ table, byId, onOpen }) {
  const refs = table.fks.map((f) => ({ id: f.ref_table, label: f.cols.join(', ') }));
  const by = table.referenced_by.map((f) => ({ id: f.table, label: f.cols.join(', ') }));
  const chip = (x, i, arrow) => (
    <button key={`${x.id}${x.label}${i}`} className="xp-rel" onClick={() => onOpen(x.id)} title={`${arrow} ${x.id} (${x.label})`}>
      {x.id}
      {x.label && <small>{x.label}</small>}
    </button>
  );
  if (!refs.length && !by.length && !table.built_from.length && !table.used_by.length) return null;
  return (
    <div className="xp-rels">
      {table.built_from.length > 0 && <div><span className="k">Built from</span>{table.built_from.filter((x) => byId[x]).map((x, i) => chip({ id: x, label: '' }, i, '←'))}</div>}
      {refs.length > 0 && <div><span className="k">Points at</span>{refs.map((x, i) => chip(x, i, '→'))}</div>}
      {by.length > 0 && <div><span className="k">Referenced by</span>{by.map((x, i) => chip(x, i, '←'))}</div>}
      {table.used_by.length > 0 && <div><span className="k">Used by views</span>{table.used_by.map((x, i) => chip({ id: x, label: '' }, i, '→'))}</div>}
    </div>
  );
}

const Cell = memo(function Cell({ v, col, onJump }) {
  const s = show(v, col.type);
  if (s === null) return <span className="xp-null">null</span>;
  if (col.fk) {
    return (
      <button className="xp-link" onClick={(e) => { e.stopPropagation(); onJump(col.fk, v); }} title={`Open ${col.fk.table} where ${col.fk.column} = ${s}`}>
        {s}
      </button>
    );
  }
  return <span className={col.pk ? 'xp-pk' : ''} title={s.length > 40 ? s : undefined}>{s.length > 90 ? `${s.slice(0, 90)}…` : s}</span>;
});

function Grid({ table, data, loading, sort, dir, filters, profile, picked, onSort, onColFilter, onJump, onPick }) {
  const prof = useMemo(() => Object.fromEntries((profile?.columns ?? []).map((c) => [c.name, c])), [profile]);
  const likeOf = (c) => filters.map(parseFilter).find((x) => x.col === c && x.op === 'like')?.val ?? '';
  const empties = (profile?.columns ?? []).filter((c) => c.all_null).map((c) => c.name);
  return (
    <>
      {profile && empties.length > 0 && <div className="xp-warn">Always empty in this table: {empties.join(', ')}</div>}
      <table className={`xp-table ${loading ? 'busy' : ''}`}>
        <thead>
          <tr>
            {table.columns.map((c) => (
              <th key={c.name} onClick={() => onSort(c.name)} title={c.comment ?? `${c.name} · ${c.type}${c.nullable ? '' : ' · required'}`} aria-sort={sort === c.name ? (dir === 'asc' ? 'ascending' : 'descending') : 'none'}>
                <span className="xp-th">
                  {c.pk && <i className="xp-key" title="Primary key">🔑</i>}
                  {c.name}
                  {sort === c.name && <i>{dir === 'asc' ? ' ▲' : ' ▼'}</i>}
                </span>
                <small>{c.type}{c.fk ? ` → ${c.fk.table}${c.fk.implied ? ' (by name)' : ''}` : ''}</small>
              </th>
            ))}
          </tr>
          <tr className="xp-frow">
            {table.columns.map((c) => (
              <th key={c.name}><ColFilter value={likeOf(c.name)} onChange={(v) => onColFilter(c.name, v)} label={c.name} /></th>
            ))}
          </tr>
          {profile && (
            <tr className="xp-prof">
              {table.columns.map((c) => {
                const p = prof[c.name];
                if (!p) return <th key={c.name} />;
                const pct = p.rows ? Math.round((p.nulls / p.rows) * 100) : 0;
                return (
                  <th key={c.name} title={`min ${p.min ?? '–'}\nmax ${p.max ?? '–'}`}>
                    <span className={p.all_null ? 'bad' : pct > 50 ? 'warn' : ''}>{p.nulls ? `${pct}% empty` : 'no empties'}</span>
                    <small>{p.distinct.toLocaleString()} distinct{p.unique ? ' · unique' : ''}</small>
                  </th>
                );
              })}
            </tr>
          )}
        </thead>
        <tbody>
          {(data?.rows ?? []).map((r, i) => (
            <tr key={i} className={picked === r ? 'on' : ''} onClick={() => onPick(r)}>
              {table.columns.map((c) => (
                <td key={c.name} className={`${typeof r[c.name] === 'number' ? 'num' : ''}`}><Cell v={r[c.name]} col={c} onJump={onJump} /></td>
              ))}
            </tr>
          ))}
          {data && data.rows.length === 0 && <tr><td colSpan={table.columns.length} className="k xp-none">No rows match.</td></tr>}
        </tbody>
      </table>
    </>
  );
}

function ColFilter({ value, onChange, label }) {
  const [v, setV] = useState(value);
  const d = useDebounce(v, 500);
  useEffect(() => setV(value), [value]);
  useEffect(() => {
    if (d !== value) onChange(d);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [d]);
  return <input className="xp-fin" placeholder="filter" aria-label={`Filter ${label}`} value={v} onChange={(e) => setV(e.target.value)} onClick={(e) => e.stopPropagation()} />;
}

// One row, opened: its values, the rows it points at (parents) and the rows that point at it (children, two levels).
function RowPanel({ table, byId, row, onClose, onOpen }) {
  const links = useGetExplorerLinksQuery({ table: table.id, row }, { skip: table.kind === 'view' });
  const fkOf = (name) => table.columns.find((c) => c.name === name)?.fk;
  const label = table.pk.length ? table.pk.map((k) => `${k} ${row[k]}`).join(' · ') : 'row';
  const eqs = (cols, vals) => cols.map((c, i) => `${c}|eq|${vals[i]}`);
  const previewOf = (p) => Object.entries(p.row ?? {}).filter(([, v]) => v !== null && typeof v !== 'object').slice(0, 5).map(([k, v]) => `${k} ${show(v, byId[p.table]?.columns.find((c) => c.name === k)?.type)}`).join(' · ');
  return (
    <aside className="xp-panel" aria-label="Row details">
      <div className="xp-panel-h">
        <div><b>{table.name}</b><span className="k"> · {label}</span></div>
        <button className="btn ghost" onClick={onClose} aria-label="Close">✕</button>
      </div>
      <h4>Values</h4>
      <dl className="xp-dl">
        {table.columns.map((c) => {
          const v = row[c.name];
          const fk = fkOf(c.name);
          const s = show(v, c.type);
          return (
            <div key={c.name}>
              <dt>{c.name}{c.pk ? ' 🔑' : ''}</dt>
              <dd>
                {s === null ? <span className="xp-null">null</span> : fk ? <button className="xp-link" onClick={() => onOpen(fk.table, [`${fk.column}|eq|${v}`])}>{s}</button> : <span>{s}</span>}
              </dd>
            </div>
          );
        })}
      </dl>
      {table.kind === 'view' && <p className="k">This is a view, so it has no rows of its own pointing here. Blue values open the table they come from.</p>}
      {links.isFetching && <p className="k">Looking up related rows…</p>}
      {links.data && (
        <>
          <h4>Points at ({links.data.parents.length})</h4>
          {links.data.parents.length === 0 && <p className="k">Nothing: no filled foreign keys.</p>}
          {links.data.parents.map((p, i) => (
            <button key={i} className="xp-rowlink" onClick={() => onOpen(p.table, eqs(p.ref_cols, p.values))}>
              <b>{p.table}</b> <small>via {p.via.join(', ')}</small>
              <span>{p.row ? previewOf(p) : 'row not found'}</span>
            </button>
          ))}
          <h4>Referenced by ({links.data.children.filter((c) => c.count).length} tables with rows)</h4>
          {links.data.children.map((c, i) => (
            <div key={i} className={c.count ? '' : 'dim'}>
              <button className="xp-rowlink" disabled={!c.count} onClick={() => onOpen(c.table, eqs(c.cols, c.values))}>
                <b>{c.table}</b> <small>by {c.cols.join(', ')}</small>
                <span className="xp-count">{c.count.toLocaleString()}</span>
              </button>
              {c.children.map((g, j) => (
                <div className="xp-grand" key={j}>└ {g.table} <small>by {g.cols.join(', ')}</small><span className="xp-count">{g.count.toLocaleString()}</span></div>
              ))}
            </div>
          ))}
        </>
      )}
    </aside>
  );
}

// All tables by domain. Hover one to light up everything it is connected to; click to open.
function MapView({ tables, domains, onOpen }) {
  const [hover, setHover] = useState(null);
  const near = useMemo(() => {
    const t = tables.find((x) => x.id === hover);
    if (!t) return null;
    return new Set([t.id, ...t.fks.map((f) => f.ref_table), ...t.referenced_by.map((f) => f.table), ...t.built_from, ...t.used_by]);
  }, [hover, tables]);
  const hovered = tables.find((x) => x.id === hover);
  return (
    <div className="xp-map">
      <p className="k xp-maphint">
        {hovered
          ? `${hovered.name}: points at ${hovered.fks.length} table${hovered.fks.length === 1 ? '' : 's'}, referenced by ${new Set(hovered.referenced_by.map((x) => x.table)).size}${hovered.built_from.length ? `, built from ${hovered.built_from.length}` : ''}.`
          : 'Hover a table to see what it connects to (highlighted). Click to open it. Views are dashed. The number is the row count.'}
      </p>
      <div className="xp-domains">
        {domains.map((d) => (
          <section key={d} className="xp-domain">
            <h3>{d}</h3>
            <div className="xp-chips">
              {tables.filter((t) => t.domain === d).map((t) => (
                <button key={t.id} className={`xp-node ${t.kind} ${near ? (near.has(t.id) ? (t.id === hover ? 'self' : 'near') : 'far') : ''}`} onMouseEnter={() => setHover(t.id)} onMouseLeave={() => setHover(null)} onFocus={() => setHover(t.id)} onBlur={() => setHover(null)} onClick={() => onOpen(t.id)}>
                  {nm(t)}
                  <small>{t.kind === 'view' ? `${t.built_from.length} src` : kfmt(t.rows)}</small>
                </button>
              ))}
            </div>
          </section>
        ))}
      </div>
    </div>
  );
}
