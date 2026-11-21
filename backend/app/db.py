from contextlib import contextmanager

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from . import config

pool = ConnectionPool(
    config.DSN,
    min_size=1,
    max_size=10,
    kwargs={"row_factory": dict_row, "options": f"-c search_path={config.SEARCH_PATH}"},
    open=False,
)


@contextmanager
def tx(actor=None):
    """One transaction. Writes pass `actor` so audit triggers + role guardrails know who acted."""
    with pool.connection() as conn:
        if actor is not None:
            conn.execute("SELECT fogops.set_actor(%s)", (actor,))
        yield conn


def fetch(sql, params=None):
    with tx() as conn:
        return conn.execute(sql, params or ()).fetchall()


def view(name, filters=None, order=None, limit=1000):
    """SELECT * FROM <view> with optional equality filters. `name` is always code-supplied, never user input."""
    where, params = "", []
    if filters:
        clauses = [f"{col} = %s" for col, v in filters.items() if v is not None]
        params = [v for v in filters.values() if v is not None]
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    sql = f"SELECT * FROM {name} {where} {order or ''} LIMIT {int(limit)}"
    return fetch(sql, params)


def live_scenario_id():
    rows = fetch("SELECT scenario_id FROM scenario WHERE kind = 'LIVE' AND is_active ORDER BY scenario_id LIMIT 1")
    return rows[0]["scenario_id"] if rows else None
