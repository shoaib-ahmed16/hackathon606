"""Data explorer: every table and view of the database, browsable end to end, with its relations.

Meant for the team that builds and validates the data (OCC and ADMIN users only). It is strictly read-only: every query
runs in a READ ONLY transaction with a statement timeout, table and column names come from the catalog (never from the
request text), values are always bound parameters, and columns that look like secrets are never returned.

  GET /api/explorer/catalog  every table/view: columns, keys, foreign keys both ways, view lineage, row counts, domain
  GET /api/explorer/rows     one table/view: search, column filters, sort, paging
  GET /api/explorer/links    one row: the parent rows it points at and the child rows that point at it (2 levels)
  GET /api/explorer/profile  one table/view: per column nulls, distinct values, min and max
"""
import json
import re
import time
from datetime import date, datetime, time as dtime, timedelta
from decimal import Decimal

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse
from psycopg import sql

from .db import fetch, pool
from .deps import current_user

SCHEMAS = ("fogops", "hist")
STAFF = {"OCC", "ADMIN"}
NEVER_SHOW_TABLES = {"app_credential"}
SECRET_COL = re.compile(r"password|secret|token|hash|api_key", re.I)
TIMEOUT = "10s"

DOMAINS = [
    ("Flights and movements", ["flight", "flight_state", "flight_event", "flight_fuel_estimate", "aircraft", "feed_source", "block_time_reference",
                               "leg_time_reference", "pax_connection", "diversion"]),
    ("Airports", ["airport", "airport_status_event", "alternate_airport"]),
    ("Crew and legality", ["crew_member", "crew_type", "crew_qualification", "crew_duty", "crew_duty_leg", "crew_assignment", "roster_entry", "standby_slot",
                           "crew_replacement", "fdp_calculation", "fdp_rule", "rule_set", "latest_departure_calc"]),
    ("Cases and decisions", ["scenario", "disruption_case", "case_flight", "recommendation", "recommendation_option", "decision", "decision_approval",
                             "approval_policy", "divert_policy", "recovery_plan", "recovery_plan_item", "report", "case_comment", "reassessment_queue"]),
    ("Collaboration", ["flight_subscription", "flight_tag", "data_request", "notification_outbox"]),
    ("Rules and integrations", ["ops_rule", "ops_rule_match", "external_system", "integration_outbox"]),
    ("Data quality and audit", ["data_exception", "audit_log", "schema_migration"]),
    ("Users and roles", ["app_user", "app_role"]),
]
DOMAIN_OF = {t: d for d, ts in DOMAINS for t in ts}

r = APIRouter(prefix="/api/explorer", tags=["explorer"])


def staff(uid: int = Depends(current_user)) -> int:
    rows = fetch("SELECT role_code FROM app_user WHERE user_id = %s AND is_active", (uid,))
    if not rows or rows[0]["role_code"] not in STAFF:
        raise HTTPException(403, "The data explorer is for OCC and admin users only")
    return uid


def _ser(o):
    if isinstance(o, (datetime, date, dtime)):
        return o.isoformat()
    if isinstance(o, Decimal):
        return float(o)
    if isinstance(o, timedelta):
        return str(o)
    if isinstance(o, (bytes, bytearray, memoryview)):
        return "<binary>"
    return str(o)


def _json(data):
    return JSONResponse(json.loads(json.dumps(data, default=_ser)))


def _tid(sch, name):
    return name if sch == "fogops" else f"{sch}.{name}"


class _Ro:
    """A READ ONLY transaction with a statement timeout."""

    def __enter__(self):
        self._cm = pool.connection()
        self.conn = self._cm.__enter__()
        self.conn.execute("SET TRANSACTION READ ONLY")
        self.conn.execute(f"SET LOCAL statement_timeout = '{TIMEOUT}'")
        return self.conn

    def __exit__(self, *a):
        return self._cm.__exit__(*a)


# ---------------------------------------------------------------------------------------------------- catalog
_cat = {"at": 0.0, "data": None}
_counts = {"at": 0.0, "data": {}}


def _load_catalog():
    if _cat["data"] and time.time() - _cat["at"] < 120:
        return _cat["data"]
    with _Ro() as c:
        rels = c.execute(
            """SELECT n.nspname AS sch, c.relname AS name, c.relkind AS kind, obj_description(c.oid) AS comment,
                      (SELECT json_agg(json_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod),
                                                         'nullable', NOT a.attnotnull, 'comment', col_description(c.oid, a.attnum))
                                       ORDER BY a.attnum)
                         FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) AS cols
                 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = ANY(%s) AND c.relkind IN ('r','p','v') ORDER BY n.nspname, c.relname""", (list(SCHEMAS),)).fetchall()
        cons = c.execute(
            """SELECT n.nspname AS sch, c.relname AS name, con.contype AS ctype, con.conname,
                      (SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(con.conkey) WITH ORDINALITY k(attnum, ord)
                         JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum) AS cols,
                      rn.nspname AS rsch, rc.relname AS rname,
                      (SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(con.confkey) WITH ORDINALITY k(attnum, ord)
                         JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum) AS rcols
                 FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                 LEFT JOIN pg_class rc ON rc.oid = con.confrelid LEFT JOIN pg_namespace rn ON rn.oid = rc.relnamespace
                WHERE con.contype IN ('p','f','u') AND n.nspname = ANY(%s)""", (list(SCHEMAS),)).fetchall()
        lineage = c.execute(
            """SELECT DISTINCT vn.nspname AS vsch, v.relname AS vname, sn.nspname AS ssch, s.relname AS sname
                 FROM pg_rewrite rw JOIN pg_class v ON v.oid = rw.ev_class JOIN pg_namespace vn ON vn.oid = v.relnamespace
                 JOIN pg_depend d ON d.objid = rw.oid AND d.classid = 'pg_rewrite'::regclass AND d.refclassid = 'pg_class'::regclass
                 JOIN pg_class s ON s.oid = d.refobjid AND s.oid <> v.oid JOIN pg_namespace sn ON sn.oid = s.relnamespace
                WHERE v.relkind = 'v' AND vn.nspname = ANY(%s) AND sn.nspname = ANY(%s) AND s.relkind IN ('r','p','v')""",
            (list(SCHEMAS), list(SCHEMAS))).fetchall()

    tabs = {}
    for x in rels:
        if x["name"] in NEVER_SHOW_TABLES:
            continue
        tid = _tid(x["sch"], x["name"])
        cols = [{**col, "hidden": bool(SECRET_COL.search(col["name"])), "pk": False, "fk": None} for col in (x["cols"] or [])]
        dom = "Views (read models)" if x["kind"] == "v" else ("History" if x["sch"] == "hist" else DOMAIN_OF.get(x["name"], "Other"))
        tabs[tid] = {"id": tid, "schema": x["sch"], "name": x["name"], "kind": "view" if x["kind"] == "v" else "table", "domain": dom,
                     "comment": x["comment"], "columns": cols, "pk": [], "unique": [], "fks": [], "referenced_by": [], "built_from": [], "used_by": []}
    for x in cons:
        t = tabs.get(_tid(x["sch"], x["name"]))
        if not t:
            continue
        if x["ctype"] == "p":
            t["pk"] = x["cols"]
            for col in t["columns"]:
                col["pk"] = col["name"] in x["cols"]
        elif x["ctype"] == "u":
            t["unique"].append(x["cols"])
        else:
            ref = _tid(x["rsch"], x["rname"])
            if ref not in tabs:
                continue
            t["fks"].append({"name": x["conname"], "cols": x["cols"], "ref_table": ref, "ref_cols": x["rcols"]})
            tabs[ref]["referenced_by"].append({"table": t["id"], "cols": x["cols"], "ref_cols": x["rcols"]})
            if len(x["cols"]) == 1:
                for col in t["columns"]:
                    if col["name"] == x["cols"][0] and col["fk"] is None:
                        col["fk"] = {"table": ref, "column": x["rcols"][0]}
    # a view has no foreign keys of its own: a column that is the single-column key of exactly one table is a link to it
    owner = {}
    for t in tabs.values():
        if t["kind"] == "table" and len(t["pk"]) == 1:
            owner.setdefault(t["pk"][0], []).append(t["id"])
    for t in tabs.values():
        if t["kind"] == "view":
            for col in t["columns"]:
                if len(owner.get(col["name"], [])) == 1:
                    col["fk"] = {"table": owner[col["name"]][0], "column": col["name"], "implied": True}
    for x in lineage:
        v, s = _tid(x["vsch"], x["vname"]), _tid(x["ssch"], x["sname"])
        if v in tabs and s in tabs:
            tabs[v]["built_from"].append(s)
            tabs[s]["used_by"].append(v)
    _cat.update(at=time.time(), data=tabs)
    return tabs


def _counts_now(tabs):
    if time.time() - _counts["at"] < 30 and _counts["data"]:
        return _counts["data"]
    parts = [sql.SQL("SELECT {} AS id, count(*) AS n FROM {}.{}").format(sql.Literal(t["id"]), sql.Identifier(t["schema"]), sql.Identifier(t["name"]))
             for t in tabs.values() if t["kind"] == "table"]
    with _Ro() as c:
        rows = c.execute(sql.SQL(" UNION ALL ").join(parts)).fetchall()
    _counts.update(at=time.time(), data={x["id"]: x["n"] for x in rows})
    return _counts["data"]


def _public(t, counts):
    return {**t, "columns": [col for col in t["columns"] if not col["hidden"]], "rows": counts.get(t["id"])}


@r.get("/catalog")
def catalog(uid: int = Depends(staff)):
    tabs = _load_catalog()
    counts = _counts_now(tabs)
    order = [d for d, _ in DOMAINS] + ["Other", "History", "Views (read models)"]
    return _json({
        "domains": [d for d in order if any(t["domain"] == d for t in tabs.values())],
        "tables": sorted((_public(t, counts) for t in tabs.values()), key=lambda t: (order.index(t["domain"]) if t["domain"] in order else 99, t["name"])),
        "totals": {"tables": sum(1 for t in tabs.values() if t["kind"] == "table"), "views": sum(1 for t in tabs.values() if t["kind"] == "view"),
                   "foreign_keys": sum(len(t["fks"]) for t in tabs.values()), "rows": sum(counts.values())},
    })


def _table(tid):
    t = _load_catalog().get(tid)
    if not t:
        raise HTTPException(404, f"Unknown table or view: {tid}")
    return t


def _cols(t, name):
    c = next((x for x in t["columns"] if x["name"] == name and not x["hidden"]), None)
    if not c:
        raise HTTPException(400, f"Unknown column {name} on {t['name']}")
    return c


def _slow(e):
    return HTTPException(408, f"That query took more than {TIMEOUT}. Add a filter (for a view, filter on scenario_id or case_id) and try again.")


# ---------------------------------------------------------------------------------------------------- rows
@r.get("/rows")
def rows(table: str, limit: int = Query(100, ge=1, le=500), offset: int = Query(0, ge=0), q: str | None = None,
         sort: str | None = None, dir: str = "asc", f: list[str] = Query(default=[]), uid: int = Depends(staff)):
    """Filters: f=column|op|value with op eq (exact, as text), like (contains), null, notnull. `q` searches every shown column."""
    t = _table(table)
    shown = [c for c in t["columns"] if not c["hidden"]]
    where, params = [], []
    for item in f:
        col, _, rest = item.partition("|")
        op, _, val = rest.partition("|")
        _cols(t, col)
        ident = sql.Identifier(col)
        if op == "eq":
            where.append(sql.SQL("{}::text = %s").format(ident)); params.append(val)
        elif op == "like":
            where.append(sql.SQL("{}::text ILIKE %s").format(ident)); params.append(f"%{val}%")
        elif op == "null":
            where.append(sql.SQL("{} IS NULL").format(ident))
        elif op == "notnull":
            where.append(sql.SQL("{} IS NOT NULL").format(ident))
        else:
            raise HTTPException(400, f"Unknown filter operation {op}")
    if q:
        where.append(sql.SQL("concat_ws(' ', {}) ILIKE %s").format(sql.SQL(", ").join(sql.SQL("{}::text").format(sql.Identifier(c["name"])) for c in shown)))
        params.append(f"%{q}%")
    wh = sql.SQL(" WHERE ") + sql.SQL(" AND ").join(where) if where else sql.SQL("")
    order = sql.SQL("")
    if sort:
        _cols(t, sort)
        order = sql.SQL(" ORDER BY {} {} NULLS LAST").format(sql.Identifier(sort), sql.SQL("DESC" if dir == "desc" else "ASC"))
    elif t["pk"]:
        order = sql.SQL(" ORDER BY ") + sql.SQL(", ").join(sql.Identifier(c) for c in t["pk"])
    src = sql.SQL("{}.{}").format(sql.Identifier(t["schema"]), sql.Identifier(t["name"]))
    sel = sql.SQL(", ").join(sql.Identifier(c["name"]) for c in shown)
    try:
        with _Ro() as c:
            data = c.execute(sql.SQL("SELECT {} FROM {}{}{} LIMIT %s OFFSET %s").format(sel, src, wh, order), [*params, limit, offset]).fetchall()
            total = c.execute(sql.SQL("SELECT count(*) AS n FROM {}{}").format(src, wh), params).fetchone()["n"]
    except psycopg.errors.QueryCanceled as e:
        raise _slow(e)
    return _json({"table": t["id"], "total": total, "limit": limit, "offset": offset, "rows": data})


# ---------------------------------------------------------------------------------------------------- links
def _tuple_where(cols, vals):
    return sql.SQL("({}) = ({})").format(sql.SQL(", ").join(sql.Identifier(c) for c in cols), sql.SQL(", ").join(sql.Placeholder() for _ in vals))


def _src(t):
    return sql.SQL("{}.{}").format(sql.Identifier(t["schema"]), sql.Identifier(t["name"]))


@r.get("/links")
def links(table: str, row: str, depth: int = Query(2, ge=1, le=2), uid: int = Depends(staff)):
    """For one row (JSON of column -> value): the parent rows it references and the child rows that reference it."""
    tabs = _load_catalog()
    t = _table(table)
    try:
        vals = json.loads(row)
        assert isinstance(vals, dict)
    except Exception:
        raise HTTPException(400, "row must be a JSON object")
    out = {"parents": [], "children": []}
    try:
        with _Ro() as c:
            for fk in t["fks"]:
                v = [vals.get(x) for x in fk["cols"]]
                if any(x is None for x in v):
                    continue
                p = tabs[fk["ref_table"]]
                shown = [x["name"] for x in p["columns"] if not x["hidden"]][:8]
                rowp = c.execute(sql.SQL("SELECT {} FROM {} WHERE {} LIMIT 1").format(
                    sql.SQL(", ").join(sql.Identifier(x) for x in shown), _src(p), _tuple_where(fk["ref_cols"], v)), v).fetchone()
                out["parents"].append({"table": p["id"], "via": fk["cols"], "ref_cols": fk["ref_cols"], "values": v, "row": rowp})
            for rb in t["referenced_by"]:
                v = [vals.get(x) for x in rb["ref_cols"]]
                if any(x is None for x in v):
                    continue
                ch = tabs[rb["table"]]
                n = c.execute(sql.SQL("SELECT count(*) AS n FROM {} WHERE {}").format(_src(ch), _tuple_where(rb["cols"], v)), v).fetchone()["n"]
                node = {"table": ch["id"], "cols": rb["cols"], "values": v, "count": n, "children": []}
                if depth > 1 and n:
                    for g in ch["referenced_by"]:
                        if g["table"] == ch["id"]:
                            continue
                        gt = tabs[g["table"]]
                        gn = c.execute(sql.SQL("SELECT count(*) AS n FROM {} WHERE ({}) IN (SELECT {} FROM {} WHERE {})").format(
                            _src(gt), sql.SQL(", ").join(sql.Identifier(x) for x in g["cols"]),
                            sql.SQL(", ").join(sql.Identifier(x) for x in g["ref_cols"]), _src(ch), _tuple_where(rb["cols"], v)), v).fetchone()["n"]
                        if gn:
                            node["children"].append({"table": gt["id"], "cols": g["cols"], "via_ref_cols": g["ref_cols"], "count": gn})
                out["children"].append(node)
    except psycopg.errors.QueryCanceled as e:
        raise _slow(e)
    out["children"].sort(key=lambda n: -n["count"])
    return _json(out)


# ---------------------------------------------------------------------------------------------------- profile
@r.get("/profile")
def profile(table: str, uid: int = Depends(staff)):
    """Per column: how many are empty, how many distinct values, smallest and largest. For checking a load at a glance."""
    t = _table(table)
    shown = [c for c in t["columns"] if not c["hidden"]]
    rangeable = lambda ty: not re.search(r"json|bytea|\[\]|tsvector|geometry", ty)  # noqa: E731
    parts = [sql.SQL("count(*) AS rows")]
    for i, c in enumerate(shown):
        ident = sql.Identifier(c["name"])
        parts.append(sql.SQL("count(*) FILTER (WHERE {} IS NULL) AS {}").format(ident, sql.Identifier(f"n{i}")))
        parts.append(sql.SQL("count(DISTINCT {}::text) AS {}").format(ident, sql.Identifier(f"d{i}")))
        if rangeable(c["type"]):
            parts.append(sql.SQL("min({}::text) AS {}").format(ident, sql.Identifier(f"lo{i}")))
            parts.append(sql.SQL("max({}::text) AS {}").format(ident, sql.Identifier(f"hi{i}")))
    try:
        with _Ro() as c:
            res = c.execute(sql.SQL("SELECT {} FROM {}").format(sql.SQL(", ").join(parts), _src(t))).fetchone()
    except psycopg.errors.QueryCanceled as e:
        raise _slow(e)
    n = res["rows"]
    cols = []
    for i, c in enumerate(shown):
        cols.append({"name": c["name"], "type": c["type"], "rows": n, "nulls": res[f"n{i}"], "distinct": res[f"d{i}"],
                     "min": res.get(f"lo{i}"), "max": res.get(f"hi{i}"),
                     "all_null": n > 0 and res[f"n{i}"] == n, "unique": n > 0 and res[f"d{i}"] == n - res[f"n{i}"]})
    return _json({"table": t["id"], "rows": n, "columns": cols})
