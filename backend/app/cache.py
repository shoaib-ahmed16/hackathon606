"""A tiny shared cache for the heaviest read models, with single-flight.

Several screens, tabs and the follow-up refreshes after an action ask for the same flight list within a second or two. Computing it takes
about half a second, so identical requests inside a short window are answered from one computation (and requests that arrive while it is being
computed wait for it instead of starting their own). The cache is dropped the moment anything changes: any saved action (audit middleware),
a finished re-check by the worker, and any database notification the live stream receives. A result computed while a change landed is never kept.
"""
import threading
import time

_lock = threading.Lock()
_store: dict = {}
_inflight: dict = {}
_gen = 0


def clear() -> None:
    global _gen
    with _lock:
        _gen += 1
        _store.clear()


def cached(key, ttl: float, fn):
    now = time.time()
    with _lock:
        hit = _store.get(key)
        if hit and hit[0] > now:
            return hit[1]
        ev = _inflight.get(key)
        owner = ev is None
        if owner:
            ev = _inflight[key] = threading.Event()
        gen = _gen
    if not owner:
        ev.wait(20)
        with _lock:
            hit = _store.get(key)
        return hit[1] if hit and hit[0] > time.time() else fn()
    try:
        val = fn()
        with _lock:
            if gen == _gen:   # nothing changed while it was computed
                if len(_store) > 100:
                    _store.clear()
                _store[key] = (time.time() + ttl, val)
        return val
    finally:
        with _lock:
            _inflight.pop(key, None)
        ev.set()
