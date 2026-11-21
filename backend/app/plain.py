"""Plain words for text the database builds (timeline and briefing lines): crew ids become names, internal codes become words.
Used on the way out, so stored audit text is never changed."""
import re

from .db import fetch

PAIR = re.compile(r"Crew replacement: (\d{4,8}) out, (\d{4,8}) in(?: \((\w+)\))?")
TYPES = {"crew_replace": "crew replacement", "divert": "diversion", "hold": "hold", "recover": "departure from the alternate",
         "delay": "delay", "cancel": "cancellation", "commander_discretion": "commander's discretion", "aircraft_swap": "aircraft swap"}
CODE = re.compile(r"\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b")
TYPE_TOKEN = re.compile(r"\b(" + "|".join(TYPES) + r")\b")


def humanize(rows, key="summary"):
    """Rewrite rows[i][key] in place and return rows."""
    ids = {int(x) for r in rows for m in PAIR.findall(r.get(key) or "") for x in m[:2]}
    names = {c["crew_id"]: c["full_name"] for c in fetch("SELECT crew_id, full_name FROM crew_member WHERE crew_id = ANY(%s)", (list(ids),))} if ids else {}
    who = lambda i: names.get(int(i), f"crew #{i}")  # noqa: E731

    def one(s):
        if not s:
            return s
        s = PAIR.sub(lambda m: f"Crew replacement: {who(m.group(2))} replaces {who(m.group(1))}" + (f" ({m.group(3).lower()})" if m.group(3) else ""), s)
        s = TYPE_TOKEN.sub(lambda m: TYPES[m.group(1)], s)
        return CODE.sub(lambda m: m.group(0).replace("_", " ").lower(), s)

    for r in rows:
        if r.get(key):
            r[key] = one(r[key])
    return rows
