"""Alternates manager: which airports the engine may divert to, and how (road time, stands, fuel, handling, priority).

OCC and ADMIN can add, edit and switch off an alternate; nothing is deleted (history and old decisions keep pointing at it).
A change queues a reassessment (trigger reassess_alternate, migration 015), so open cases are re-ranked at once.
ADMIN can also create the station login for an alternate (username station.<iata>, the demo password until changed).
"""
import re

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from . import auth, config
from .db import fetch, tx
from .deps import actor, current_user

r = APIRouter(prefix="/api", tags=["alternates"])
EDITORS = ("OCC", "ADMIN")
IATA = re.compile(r"^[A-Z]{3}$")


def _role(conn, user):
    row = conn.execute("SELECT role_code FROM app_user WHERE user_id = %s AND is_active", (int(user),)).fetchone()
    return row["role_code"] if row else None


@r.get("/airport-search", dependencies=[Depends(current_user)])
def airport_search(q: str, limit: int = 12):
    """Find an airport by code, name or country (for the 'add an alternate' form). Only airports the database knows can be added."""
    q = q.strip()
    if len(q) < 2:
        return []
    return fetch(
        """SELECT iata, name, country, is_hub FROM airport
            WHERE iata ILIKE %(p)s OR name ILIKE %(l)s OR country ILIKE %(l)s
            ORDER BY (iata ILIKE %(p)s) DESC, name LIMIT %(n)s""",
        {"p": q, "l": f"%{q}%", "n": max(1, min(limit, 30))},
    )


@r.get("/alternates", dependencies=[Depends(current_user)])
def alternates(hub: str = "SHJ"):
    """Every alternate of a hub (active or not) with its airport name and the station logins that belong to it."""
    return fetch(
        """SELECT a.hub_iata, a.alt_iata, ap.name, ap.country, a.priority, a.road_positioning_min, a.max_parking_stands,
                  a.handling_contract, a.fuel_available, a.customs_24h, a.historical_diversions, a.hist_median_ground_min,
                  a.notes, a.is_active,
                  coalesce((SELECT array_agg(u.username ORDER BY u.username) FROM app_user u
                             WHERE u.station_iata = a.alt_iata AND u.role_code = 'STATION' AND u.is_active), '{}'::text[]) AS station_users
             FROM alternate_airport a JOIN airport ap ON ap.iata = a.alt_iata
            WHERE a.hub_iata = %s ORDER BY a.is_active DESC, a.priority, a.alt_iata""",
        (hub.upper(),),
    )


class AlternateIn(BaseModel):
    hub_iata: str = "SHJ"
    alt_iata: str
    priority: int = Field(100, ge=1, le=999)                      # lower = preferred
    road_positioning_min: int | None = Field(None, ge=0, le=720)  # crew by road from the hub; empty = no road link
    max_parking_stands: int | None = Field(None, ge=0, le=200)
    handling_contract: bool = True
    fuel_available: bool = True
    customs_24h: bool = True
    notes: str | None = Field(None, max_length=300)
    is_active: bool = True


@r.post("/alternates")
def save_alternate(b: AlternateIn, user=Depends(actor)):
    """Add an alternate, or change one that exists (same hub and airport). Re-ranks open cases."""
    hub, alt = b.hub_iata.upper(), b.alt_iata.upper()
    if not IATA.match(alt) or not IATA.match(hub):
        raise HTTPException(422, "Airport codes are three letters, for example RKT")
    if alt == hub:
        raise HTTPException(422, "An airport cannot be its own alternate")
    with tx(user) as conn:
        if _role(conn, user) not in EDITORS:
            raise HTTPException(403, "Only OCC or admin can change the alternates")
        for code in (hub, alt):
            if not conn.execute("SELECT 1 FROM airport WHERE iata = %s", (code,)).fetchone():
                raise HTTPException(404, f"Unknown airport {code}. Only airports in the database can be added.")
        row = conn.execute(
            """INSERT INTO alternate_airport (hub_iata, alt_iata, priority, road_positioning_min, max_parking_stands,
                                              handling_contract, fuel_available, customs_24h, notes, is_active)
               VALUES (%(hub)s, %(alt)s, %(pr)s, %(road)s, %(stands)s, %(hand)s, %(fuel)s, %(cust)s, %(notes)s, %(act)s)
               ON CONFLICT (hub_iata, alt_iata) DO UPDATE
                  SET priority = EXCLUDED.priority, road_positioning_min = EXCLUDED.road_positioning_min,
                      max_parking_stands = EXCLUDED.max_parking_stands, handling_contract = EXCLUDED.handling_contract,
                      fuel_available = EXCLUDED.fuel_available, customs_24h = EXCLUDED.customs_24h,
                      notes = EXCLUDED.notes, is_active = EXCLUDED.is_active
               RETURNING *, (xmax = 0) AS created""",
            {"hub": hub, "alt": alt, "pr": b.priority, "road": b.road_positioning_min, "stands": b.max_parking_stands,
             "hand": b.handling_contract, "fuel": b.fuel_available, "cust": b.customs_24h, "notes": (b.notes or None), "act": b.is_active},
        ).fetchone()
    return row


@r.post("/alternates/{alt}/station-login")
def station_login(alt: str, user=Depends(actor)):
    """Create the station login for an alternate: station.<iata>, role STATION, demo password (admin only)."""
    alt = alt.upper()
    with tx(user) as conn:
        if _role(conn, user) != "ADMIN":
            raise HTTPException(403, "Only an admin can create logins")
        if not conn.execute("SELECT 1 FROM alternate_airport WHERE alt_iata = %s", (alt,)).fetchone():
            raise HTTPException(404, f"{alt} is not an alternate yet. Add it first.")
        name = f"station.{alt.lower()}"
        if conn.execute("SELECT 1 FROM app_user WHERE username = %s", (name,)).fetchone():
            raise HTTPException(409, f"{name} already exists")
        uid = conn.execute(
            "INSERT INTO app_user (username, display_name, role_code, station_iata) VALUES (%s, %s, 'STATION', %s) RETURNING user_id",
            (name, f"{alt} Station", alt),
        ).fetchone()["user_id"]
        conn.execute("INSERT INTO app_credential (user_id, password_hash) VALUES (%s, %s)", (uid, auth.hash_password(config.DEMO_PASSWORD)))
    return {"username": name, "note": "The password is the demo password until it is changed."}
