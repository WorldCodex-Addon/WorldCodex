#!/usr/bin/env python3
"""Merge WorldCodex uploads into the community dataset shipped with the addon.

Inputs can be SavedVariables files (WTF/Account/<name>/SavedVariables/WorldCodex.lua), text files
containing share strings from `/worldcodex export` (one per line), or directories containing either.

    python3 tools/merge.py uploads/ --out Data/Community.lua --json dataset.json

Every upload carries a random installation id (meta.uid) and no character names. The newest
upload per id wins, so re-uploads never double count. A delta upload (v = 2: only what changed after
the installation's upload with revision `base`) is laid over that earlier upload, so keep it.
Contributions that disagree wildly with everyone else's data for the same source are rejected
(binomial z-test against the pooled rate).

The JSON output is the interchange format for the website (see docs/dataset.md); the Lua output is
the same dataset as the addon loads it.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import re
import sys
import time
import zlib
from pathlib import Path
from typing import Any

# --------------------------------------------------------------------------- Lua table parsing


class LuaParseError(ValueError):
    pass


_TOKEN = re.compile(
    r"""
    (?P<ws>\s+|--\[\[.*?\]\]|--[^\n]*)
  | (?P<str>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')
  | (?P<num>-?0[xX][0-9a-fA-F]+|-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<sym>[{}\[\]=,;])
    """,
    re.VERBOSE | re.DOTALL,
)

_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n", "a": "\a", "b": "\b", "f": "\f", "v": "\v"}


def _unescape(body: str) -> str:
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        nxt = body[i + 1] if i + 1 < len(body) else ""
        if nxt.isdigit():
            m = re.match(r"\d{1,3}", body[i + 1 :])
            out.append(chr(int(m.group(0))))
            i += 1 + len(m.group(0))
        else:
            out.append(_ESCAPES.get(nxt, nxt))
            i += 2
    raw = "".join(out)
    try:
        return raw.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return raw


def _tokens(text: str):
    pos = 0
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m:
            raise LuaParseError(f"unexpected character {text[pos]!r} at {pos}")
        pos = m.end()
        kind = m.lastgroup
        if kind == "ws":
            continue
        yield kind, m.group(kind)
    yield "eof", None


class _Parser:
    def __init__(self, text: str):
        self.toks = list(_tokens(text))
        self.i = 0

    def peek(self):
        return self.toks[self.i]

    def take(self, kind=None, value=None):
        tok = self.toks[self.i]
        if (kind and tok[0] != kind) or (value is not None and tok[1] != value):
            raise LuaParseError(f"expected {value or kind}, got {tok[1]!r}")
        self.i += 1
        return tok

    def value(self):
        kind, val = self.peek()
        if kind == "str":
            self.i += 1
            return _unescape(val[1:-1])
        if kind == "num":
            self.i += 1
            if val.lower().lstrip("-").startswith("0x"):
                return int(val, 16)
            f = float(val)
            return int(f) if f.is_integer() and "." not in val and "e" not in val.lower() else f
        if kind == "name":
            self.i += 1
            if val in ("true", "false"):
                return val == "true"
            if val == "nil":
                return None
            raise LuaParseError(f"unexpected name {val}")
        if kind == "sym" and val == "{":
            return self.table()
        raise LuaParseError(f"unexpected token {val!r}")

    def table(self):
        self.take("sym", "{")
        result: dict[Any, Any] = {}
        index = 1
        while True:
            kind, val = self.peek()
            if kind == "sym" and val == "}":
                self.i += 1
                return result
            if kind == "sym" and val == "[":
                self.i += 1
                key = self.value()
                self.take("sym", "]")
                self.take("sym", "=")
                result[key] = self.value()
            elif kind == "name" and self.toks[self.i + 1] == ("sym", "="):
                self.i += 2
                result[val] = self.value()
            else:
                result[index] = self.value()
                index += 1
            kind, val = self.peek()
            if kind == "sym" and val in (",", ";"):
                self.i += 1

    def assignments(self):
        out = {}
        while self.peek()[0] != "eof":
            _, name = self.take("name")
            self.take("sym", "=")
            out[name] = self.value()
        return out


def parse_saved_variables(text: str) -> dict[str, Any]:
    """Parses `Name = value` assignments as written by WoW into Python values."""
    return _Parser(text).assignments()


def _lua_number_key(key: Any) -> Any:
    if isinstance(key, float) and key.is_integer():
        return int(key)
    return key


# --------------------------------------------------------------------------- share strings

_PREFIX = "WCX1:"
_OLD_PREFIX = "IDB1:"  # share strings from before the rename (ItemsDB)


def _parse_ser(s: bytes, i: int = 0, depth: int = 0):
    c = s[i : i + 1]
    if c == b"n":
        j = s.index(b";", i + 1)
        num = float(s[i + 1 : j])
        return (int(num) if num.is_integer() else num), j + 1
    if c == b"s":
        j = s.index(b":", i + 1)
        n = int(s[i + 1 : j])
        if j + n >= len(s) + 1:
            raise ValueError("bad string length")
        return s[j + 1 : j + 1 + n].decode("utf-8", "replace"), j + 1 + n
    if c == b"T":
        return True, i + 1
    if c == b"F":
        return False, i + 1
    if c == b"{":
        if depth > 12:
            raise ValueError("too deep")
        t: dict[Any, Any] = {}
        i += 1
        while True:
            if s[i : i + 1] == b"}":
                return t, i + 1
            k, i = _parse_ser(s, i, depth + 1)
            v, i = _parse_ser(s, i, depth + 1)
            t[k] = v
    raise ValueError(f"unexpected {c!r} at {i}")


def decode_share_string(text: str) -> dict[str, Any]:
    text = re.sub(r"\s", "", text)
    if text.startswith(_OLD_PREFIX):
        text = _PREFIX + text[len(_OLD_PREFIX):]
    if not text.startswith(_PREFIX):
        raise ValueError("not a WorldCodex share string")
    mode, data = text[len(_PREFIX)], text[len(_PREFIX) + 2 :]
    raw = base64.b64decode(data)
    if mode == "Z":
        raw = zlib.decompress(raw, -15)
    elif mode != "R":
        raise ValueError("unknown mode")
    value, end = _parse_ser(raw)
    if end != len(raw):
        raise ValueError("trailing data")
    return value


# --------------------------------------------------------------------------- snapshots


def _base(rec: dict) -> int:
    """Same as Store.Base: looted-or-empty corpses for mobs, attempts otherwise."""
    if rec.get("kind") == "mob":
        if rec.get("lb") is not None:
            return int(rec["lb"])
        if (rec.get("kills") or 0) > 0:
            return int(rec["kills"])
    return int(rec.get("attempts") or 0)


def _quest_state(items: dict, item_id) -> str | None:
    """Same as Store.QuestState: "gated" (drops only with its quest), "free" or None."""
    it = items.get(item_id)
    if not isinstance(it, dict):
        return None
    if (it.get("qx") or 0) >= 2:
        return "free"
    return "gated" if it.get("qd") else None


def _shared_loot(rec: dict, n: int, items: dict) -> tuple[dict, dict]:
    """Same as Store.SharedLoot: loot, and the attempts of quest items (only while the quest was active)."""
    loot, bases = {}, {}
    counted = {_lua_number_key(i): b for i, b in (rec.get("qb") or {}).items() if isinstance(b, dict)}
    is_quest = rec.get("kind") == "quest"
    for item_id, x in (rec.get("loot") or {}).items():
        if not isinstance(x, dict):
            continue
        item_id = _lua_number_key(item_id)
        state = None if is_quest else _quest_state(items, item_id)
        if state == "gated":
            b = counted.get(item_id) or {}
            bases[item_id] = b.get("n", 0)
            loot[item_id] = [min(b.get("d", 0), b.get("n", 0)), b.get("q", 0), b.get("h") or {}]
            continue
        if state == "free":
            bases[item_id] = n
        loot[item_id] = [x.get("d", 0), x.get("q", 0), x.get("h") or {}]
    if not is_quest:
        for item_id, b in counted.items():
            if item_id not in loot and _quest_state(items, item_id) == "gated":
                bases[item_id] = b.get("n", 0)
    return loot, bases


def snapshot_from_saved(db: dict) -> dict:
    """Builds the same compact snapshot the addon shares (Store.Snapshot) from SavedVariables."""
    meta = db.get("meta") or {}
    src = {}
    quest_items = {_lua_number_key(i): e for i, e in (db.get("items") or {}).items()}
    for key, rec in (db.get("sources") or {}).items():
        if not isinstance(rec, dict):
            continue
        n = _base(rec)
        if n <= 0:
            continue
        loot, bases = _shared_loot(rec, n, quest_items)
        src[_lua_number_key(key)] = {
            "nm": rec.get("name"), "k": rec.get("kind", "other"), "n": n, "m": rec.get("money", 0),
            "l": loot, "qb": bases, "sp": rec.get("spawns") or {}, "zn": rec.get("zn") or {},
            "ch": rec.get("choice") or {}, "rp": rec.get("rep"),
            "cm": [rec.get("mc", 0), rec["ca"], rec.get("mmin"), rec.get("mmax")] if rec.get("ca") else None,
            "lv": [rec["lmin"], rec.get("lmax", rec["lmin"])] if rec.get("lmin") else None,
            "cl": rec.get("cls"), "qg": rec.get("gid"), "qt": rec.get("tid"), "rq": rec.get("req"), "si": rec.get("si"),
        }
    vendors = {}
    for npc, v in (db.get("vendors") or {}).items():
        if isinstance(v, dict) and isinstance(v.get("i"), dict):
            vendors[_lua_number_key(npc)] = {"nm": v.get("nm"), "sp": v.get("sp") or {}, "i": v["i"]}
    ah, ahd = {}, {}
    for item_id, r in (db.get("ah") or {}).items():
        if isinstance(r, dict):
            if isinstance(r.get("last"), dict):
                ah[_lua_number_key(item_id)] = r["last"]
            if isinstance(r.get("days"), dict):
                ahd[_lua_number_key(item_id)] = r["days"]
    items = {}
    for item_id, e in (db.get("items") or {}).items():
        if isinstance(e, dict) and e.get("n"):
            items[_lua_number_key(item_id)] = {k: e.get(k) for k in _ITEM_FIELDS + _ITEM_DETAILS}
    npcs = {}
    for key, r in (db.get("npcs") or {}).items():
        if isinstance(r, dict):
            npcs[_lua_number_key(key)] = {k: r.get(k) for k in ("nm", "sp", "lv", "cl", "r", "f")}
    recipes = {}
    for key, r in (db.get("recipes") or {}).items():
        if isinstance(r, dict):
            recipes[_lua_number_key(key)] = {k: r.get(k) for k in ("pf", "mn", "mx", "r", "sid")}
    spells = {}
    for spell_id, r in (db.get("spells") or {}).items():
        if isinstance(r, dict) and r.get("n"):
            spells[_lua_number_key(spell_id)] = {k: r.get(k) for k in ("n", "rk", "ic", "ds")}
    trainers = {}
    for npc, r in (db.get("trainers") or {}).items():
        if isinstance(r, dict) and isinstance(r.get("s"), dict) and r["s"]:
            services = {
                _lua_number_key(k): {f: e.get(f) for f in _TRAINER_SERVICE_FIELDS}
                for k, e in r["s"].items() if isinstance(e, dict)
            }
            trainers[_lua_number_key(npc)] = {k: r.get(k) for k in ("nm", "tt", "pf", "cls")} | {"s": services}
    return {
        "v": 1, "uid": meta.get("uid"), "rev": meta.get("rev", 0), "t": meta.get("saved", 0),
        "lc": meta.get("locale"), "src": src, "vd": vendors, "rc": recipes, "np": npcs,
        "tr": trainers, "sl": spells, "ah": ah, "ahd": ahd, "it": items, "rl": meta.get("realm"), "fc": meta.get("faction"),
    }


def _num(v, maxv=None):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or v < 0:
        return None
    if maxv is not None and v > maxv:
        return None
    return v


_CLASSIFICATIONS = {"elite", "rare", "rareelite", "worldboss"}
_ITEM_FIELDS = ("n", "ql", "v", "il", "rq", "cl", "sc", "eq", "ic", "sk", "bd")
# item details (Items.lua, docs/export.md): numbers voted like the facts above, st/wd voted as a whole,
# fx (effect texts) kept per locale
_ITEM_DETAIL_NUMBERS = (("iv", 40), ("du", 1000), ("set", 1e6), ("un", 100), ("us", 1e7))
_ITEM_DETAILS = tuple(f for f, _ in _ITEM_DETAIL_NUMBERS) + ("st", "wd", "fx")
_EFFECT_TRIGGERS = ("use", "equip", "proc", "learn")
_PRICE_FIELDS = ("mi", "md", "mn", "mx", "q")


def _arr(v) -> list | None:
    """Lua arrays arrive as lists (SavedVariables) or {1: .., 2: ..} dicts (share strings)."""
    if isinstance(v, list):
        return v
    if isinstance(v, dict):
        return [v.get(i) for i in range(1, len(v) + 1)]
    return None


def _npc_key(v):
    v = _lua_number_key(v)
    if isinstance(v, int) and not isinstance(v, bool) and 0 < v < 10**8:
        return v
    if isinstance(v, str) and re.fullmatch(r"go:\d{1,9}", v):
        return v
    return None


def _item_counts(t, limit: int, max_count: float) -> dict | None:
    if not isinstance(t, dict):
        return None
    out = {}
    for item_id, n in list(t.items())[:limit]:
        item_id = _lua_number_key(item_id)
        if isinstance(item_id, int) and item_id > 0 and _num(n, max_count) and n >= 1:
            out[item_id] = n
    return out or None


def _cells(cells, limit: int) -> dict:
    out = {}
    if isinstance(cells, dict):
        for c, cnt in list(cells.items())[:limit]:
            c = _lua_number_key(c)
            if _num(c, 9999) is not None and _num(cnt, 1e7):
                out[c] = int(cnt)
    return out


def _clean_vendors(vd) -> dict:
    out = {}
    if not isinstance(vd, dict):
        return out
    for npc, v in list(vd.items())[:5000]:
        npc = _lua_number_key(npc)
        if not (isinstance(npc, int) and npc > 0) or not isinstance(v, dict) or not isinstance(v.get("i"), dict):
            continue
        items = {}
        for item_id, e in list(v["i"].items())[:300]:
            item_id = _lua_number_key(item_id)
            if isinstance(item_id, int) and isinstance(e, dict) and _num(e.get("p"), 1e9) is not None:
                entry = {"p": e["p"], "st": _num(e.get("st"), 1000) or 1}
                if e.get("lim") is True:
                    entry["lim"] = True
                x = _item_counts(e.get("x"), 5, 1e6)
                if x:
                    entry["x"] = x
                items[item_id] = entry
        spawns = {}
        for m, cells in (v.get("sp") or {}).items():
            m = _lua_number_key(m)
            if isinstance(m, int):
                spawns[m] = _cells(cells, 16)
        name = v.get("nm")
        out[npc] = {"nm": name.replace("|", "")[:80] if isinstance(name, str) else None, "sp": spawns, "i": items}
    return out


_REACTIONS = {"hostile", "neutral", "friendly"}
_ROLES = {"gossip", "vendor", "quest", "trainer", "taxi", "banker"}


def _clean_npcs(np) -> dict:
    out = {}
    if not isinstance(np, dict):
        return out
    for key, r in list(np.items())[:20000]:
        key = _npc_key(key)
        if key is None or not isinstance(r, dict):
            continue
        roles = sorted(k for k, v in (r.get("f") or {}).items() if k in _ROLES and v is True)
        # locations come from interactions only (the addon's Npcs.lua); records without a role
        # are sightings, whose locations older addon versions stored and are dropped here
        spawns = {}
        for m, cells in list((r.get("sp") or {}).items())[:8] if roles else []:
            m = _lua_number_key(m)
            if isinstance(m, int):
                spawns[m] = _cells(cells, 24)
        lv = _arr(r.get("lv"))
        level = None
        if lv and len(lv) >= 2:
            a, b = _num(lv[0], 100), _num(lv[1], 100)
            if a and b and 1 <= a <= b:
                level = [int(a), int(b)]
        name = r.get("nm")
        out[key] = {
            "nm": name.replace("|", "")[:80] if isinstance(name, str) else None,
            "sp": spawns, "lv": level,
            "cl": r.get("cl") if r.get("cl") in _CLASSIFICATIONS else None,
            "r": r.get("r") if r.get("r") in _REACTIONS else None,
            "f": roles,
        }
    return out


def _clean_prices(ah) -> dict:
    """Latest scan per item: {t, mi, md, mn, mx, q}."""
    out = {}
    if not isinstance(ah, dict):
        return out
    for item_id, a in list(ah.items())[:50000]:
        item_id = _lua_number_key(item_id)
        if not isinstance(item_id, int) or not isinstance(a, dict):
            continue
        t, md = _num(a.get("t"), 4e9), _num(a.get("md"), 1e12)
        if t and md:
            e = {"t": int(t)}
            for f in _PRICE_FIELDS:
                v = _num(a.get(f), 1e12)
                if v is not None:
                    e[f] = int(v)
            out[item_id] = e
    return out


def _clean_history(ahd) -> dict:
    """Daily rollups per item: {day: {mi, md, mn, mx, q, c}}, day = unix time // 86400."""
    out = {}
    if not isinstance(ahd, dict):
        return out
    for item_id, days in list(ahd.items())[:50000]:
        item_id = _lua_number_key(item_id)
        if not isinstance(item_id, int) or not isinstance(days, dict):
            continue
        clean = {}
        for day, d in list(days.items())[:90]:
            day = _lua_number_key(day)
            if isinstance(day, int) and 10000 < day < 50000 and isinstance(d, dict) and _num(d.get("md"), 1e12):
                e = {f: int(d[f]) for f in _PRICE_FIELDS if _num(d.get(f), 1e12) is not None}
                e["c"] = int(_num(d.get("c"), 1e6) or 1)
                clean[day] = e
        if clean:
            out[item_id] = clean
    return out


def _clean_item_details(e: dict) -> dict:
    """Same as CleanItemDetails in Store.lua."""
    out: dict = {}
    for f, cap in _ITEM_DETAIL_NUMBERS:
        v = _num(e.get(f), cap)
        if v is not None:
            out[f] = int(v)
    st = e.get("st")
    if isinstance(st, dict):
        clean = {}
        for k, v in list(st.items())[:40]:
            if (isinstance(k, str) and len(k) <= 48 and re.fullmatch(r"[A-Z0-9_]+", k)
                    and isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and abs(v) < 1e6):
                clean[k] = int(v) if float(v).is_integer() else round(float(v), 1)
        if clean:
            out["st"] = clean
    wd = _arr(e.get("wd"))
    if wd and len(wd) >= 2:
        lo, hi = _num(wd[0], 1e5), _num(wd[1], 1e5)
        speed = _num(wd[2], 10000) if len(wd) > 2 else None
        if lo is not None and hi is not None and hi >= lo:
            out["wd"] = [int(lo), int(hi)] + ([int(speed)] if speed is not None else [])
    fx = _arr(e.get("fx"))
    if fx:
        clean_fx = []
        for x in fx[:8]:
            x = _arr(x)
            if x and len(x) >= 2 and x[0] in _EFFECT_TRIGGERS and isinstance(x[1], str) and x[1].strip():
                clean_fx.append([x[0], x[1].replace("|", "")[:250]])
        if clean_fx:
            out["fx"] = clean_fx
    return out


def _clean_items(it) -> dict:
    out = {}
    if not isinstance(it, dict):
        return out
    for item_id, e in list(it.items())[:50000]:
        item_id = _lua_number_key(item_id)
        if not isinstance(item_id, int) or item_id <= 0 or not isinstance(e, dict) or not isinstance(e.get("n"), str):
            continue
        entry = {"n": e["n"].replace("|", "")[:80]}
        for f, cap in (("ql", 10), ("v", 1e9), ("il", 1000), ("rq", 100), ("cl", 100), ("sc", 100), ("sk", 10000), ("bd", 10)):
            v = _num(e.get(f), cap)
            if v is not None:
                entry[f] = int(v)
        if isinstance(e.get("eq"), str) and re.fullmatch(r"INVTYPE_[A-Z_]+", e["eq"]):
            entry["eq"] = e["eq"]
        icon = e.get("ic")
        if (isinstance(icon, int) and not isinstance(icon, bool) and icon > 0) or (isinstance(icon, str) and len(icon) <= 120):
            entry["ic"] = icon
        entry.update(_clean_item_details(e))
        out[item_id] = entry
    return out


def _clean_recipes(rc) -> dict:
    out = {}
    if not isinstance(rc, dict):
        return out
    for key, r in list(rc.items())[:5000]:
        key = _lua_number_key(key)
        ok_key = (isinstance(key, int) and key > 0) or (isinstance(key, str) and re.fullmatch(r"enchant:\d{1,9}", key))
        if not ok_key or not isinstance(r, dict):
            continue
        reagents = _item_counts(r.get("r"), 12, 1000)
        pf = r.get("pf")
        if not reagents or not isinstance(pf, str) or not re.fullmatch(r"\w{1,24}", pf):
            continue
        mn = _num(r.get("mn"), 100) or 1
        mx = _num(r.get("mx"), 100) or 1
        out[key] = {"pf": pf, "mn": mn, "mx": max(mn, mx), "r": reagents}
        sid = _lua_number_key(r.get("sid"))
        if isinstance(sid, int) and not isinstance(sid, bool) and 1 <= sid <= 10**8:
            out[key]["sid"] = sid
    return out


def _clean_spells(sl) -> dict:
    """Spells in the uploader's language (the addon's Spells.lua, Store CleanSpells)."""
    out = {}
    if not isinstance(sl, dict):
        return out
    for spell_id, r in list(sl.items())[:20000]:
        spell_id = _lua_number_key(spell_id)
        if not (isinstance(spell_id, int) and not isinstance(spell_id, bool) and 0 < spell_id < 10**8):
            continue
        if not isinstance(r, dict) or not isinstance(r.get("n"), str) or not r["n"]:
            continue
        entry = {"n": r["n"].replace("|", "")[:80]}
        if isinstance(r.get("rk"), str) and r["rk"]:
            entry["rk"] = r["rk"].replace("|", "")[:80]
        icon = _lua_number_key(r.get("ic"))
        if isinstance(icon, int) and not isinstance(icon, bool) and 1 <= icon <= 10**9:
            entry["ic"] = icon
        if isinstance(r.get("ds"), str) and r["ds"]:
            entry["ds"] = r["ds"][:1000].replace("|", "")
        out[spell_id] = entry
    return out


_TRAINER_KINDS = {"class", "profession", "pet", "general"}
_TRAINER_SERVICE_FIELDS = ("c", "lv", "sk", "it", "nm")


def _clean_trainers(tr) -> dict:
    """What trainers teach (the addon's Trainers.lua, Store CleanTrainers): services keyed by spell id,
    or "n:<name>" when the client gave no spell id."""
    out = {}
    if not isinstance(tr, dict):
        return out
    for npc, r in list(tr.items())[:5000]:
        npc = _lua_number_key(npc)
        if not (isinstance(npc, int) and not isinstance(npc, bool) and 0 < npc < 10**8):
            continue
        if not isinstance(r, dict) or not isinstance(r.get("s"), dict):
            continue
        services = {}
        for key, e in list(r["s"].items())[:400]:
            key = _lua_number_key(key)
            if isinstance(key, int) and not isinstance(key, bool) and 0 < key < 10**8:
                named = False
            elif isinstance(key, str) and len(key) <= 80 and key.startswith("n:") and len(key) > 2:
                key, named = key.replace("|", ""), True
            else:
                continue
            if not isinstance(e, dict):
                continue
            entry = {}
            for f, maxv in (("c", 1e9), ("lv", 100), ("sk", 1000)):
                v = _num(e.get(f), maxv)
                if v is not None:
                    entry[f] = int(v)
            item = _lua_number_key(e.get("it"))
            if isinstance(item, int) and not isinstance(item, bool) and 1 <= item <= 10**8:
                entry["it"] = item
            name = e.get("nm")
            if named and isinstance(name, str) and name:
                entry["nm"] = name.replace("|", "")[:80]
            services[key] = entry
        if not services:
            continue
        kind = r.get("tt") if r.get("tt") in _TRAINER_KINDS else "general"
        pf, cls = r.get("pf"), r.get("cls")
        name = r.get("nm")
        out[npc] = {
            "nm": name.replace("|", "")[:80] if isinstance(name, str) else None,
            "tt": kind,
            "pf": pf if kind == "profession" and isinstance(pf, str) and re.fullmatch(r"[A-Za-z0-9]{1,24}", pf) else None,
            "cls": cls if kind == "class" and isinstance(cls, str) and re.fullmatch(r"[A-Z]{1,20}", cls) else None,
            "s": services,
        }
    return out


def validate(snap: dict) -> dict | None:
    if not isinstance(snap, dict) or not isinstance(snap.get("src"), dict):
        return None
    # v = 2: a delta holding only the records changed after revision `base` (Store.Snapshot opts.since)
    base = _num(snap.get("base"), 1e12) if snap.get("v") == 2 else None
    if snap.get("v") != 1 and not base:
        return None
    uid = snap.get("uid")
    if not isinstance(uid, str) or not re.fullmatch(r"[0-9a-zA-Z]{4,40}", uid):
        return None
    out = {"uid": uid, "rev": _num(snap.get("rev")) or 0, "base": int(base) if base else None, "src": {}}
    for key, x in snap["src"].items():
        if not isinstance(x, dict):
            continue
        key = _lua_number_key(key)
        if not ((isinstance(key, int) and key > 0) or (isinstance(key, str) and len(key) <= 80)):
            continue
        n = _num(x.get("n"), 1e7)
        if not n:
            continue
        # attempts of quest items (0 is valid: known to drop, never tried with the quest)
        bases = {}
        for item_id, qn in list(x["qb"].items())[:500] if isinstance(x.get("qb"), dict) else []:
            item_id = _lua_number_key(item_id)
            if isinstance(item_id, int) and not isinstance(item_id, bool) and item_id > 0 and _num(qn, n) is not None:
                bases[item_id] = int(qn)
        loot = {}
        for item_id, e in (x.get("l") or {}).items():
            item_id = _lua_number_key(item_id)
            if not isinstance(item_id, int) or not isinstance(e, (dict, list)):
                continue
            vals = [e.get(1), e.get(2), e.get(3)] if isinstance(e, dict) else list(e) + [None]
            if len(vals) < 3:
                continue
            d, q = _num(vals[0]), _num(vals[1])
            if d is not None and q is not None and d <= bases.get(item_id, n):
                hist = {}
                if isinstance(vals[2], dict):
                    for size, cnt in list(vals[2].items())[:50]:
                        size = _lua_number_key(size)
                        if isinstance(size, int) and 1 <= size <= 10000 and _num(cnt, 1e7):
                            hist[size] = int(cnt)
                    if sum(hist.values()) > d:
                        hist = {}
                loot[item_id] = [int(d), int(q), hist]
        spawns = {}
        for m, cells in (x.get("sp") or {}).items():
            m = _lua_number_key(m)
            if isinstance(m, int) and isinstance(cells, dict):
                spawns[m] = {
                    _lua_number_key(c): int(cnt) for c, cnt in cells.items()
                    if _num(_lua_number_key(c), 9999) is not None and _num(cnt, 1e7)
                }
        # zones without a position (instances): {mapId: count}
        zones = {}
        for m, cnt in list((x.get("zn") or {}).items())[:16] if isinstance(x.get("zn"), dict) else []:
            m = _lua_number_key(m)
            # map ids, or negative instance ids (instances give addons no map id)
            if isinstance(m, int) and not isinstance(m, bool) and m != 0 and -10**7 < m < 10**7 and _num(cnt, 1e7) and cnt >= 1:
                zones[m] = int(cnt)
        name = x.get("nm")
        choices = {
            _lua_number_key(i) for i, v in (x.get("ch") or {}).items()
            if v is True and _lua_number_key(i) in loot
        }
        repeat = x.get("rp") if x.get("rp") in ("daily", "weekly") else None
        cm = x.get("cm")
        if isinstance(cm, dict):
            cm = [cm.get(i) for i in range(1, 5)]
        coin = None
        if isinstance(cm, list) and len(cm) >= 2:
            mc, ca = _num(cm[0], 1e7), _num(cm[1], 1e7)
            if mc is not None and ca and mc <= ca:
                lo = _num(cm[2], 1e9) if len(cm) > 2 else None
                hi = _num(cm[3], 1e9) if len(cm) > 3 else None
                coin = [int(mc), int(ca), lo, hi]
        lv = _arr(x.get("lv"))
        level = None
        if lv and len(lv) >= 2:
            a, b = _num(lv[0], 100), _num(lv[1], 100)
            if a and b and 1 <= a <= b:
                level = [int(a), int(b)]
        si = _lua_number_key(x.get("si"))
        out["src"][key] = {
            "lv": level,
            "cl": x.get("cl") if x.get("cl") in _CLASSIFICATIONS else None,
            "qg": _npc_key(x.get("qg")), "qt": _npc_key(x.get("qt")),
            "rq": _item_counts(x.get("rq"), 20, 1000),
            "si": si if isinstance(si, int) and not isinstance(si, bool) and si > 0 else None,
            "ch": choices, "rp": repeat, "cm": coin,
            "nm": name.replace("|", "")[:80] if isinstance(name, str) else None,
            "k": x.get("k") if isinstance(x.get("k"), str) else "other",
            "n": int(n), "m": _num(x.get("m"), 1e12) or 0, "l": loot, "qb": bases, "sp": spawns, "zn": zones,
        }
    lc = snap.get("lc")
    out["lc"] = lc if isinstance(lc, str) and re.fullmatch(r"[a-zA-Z]{4}", lc) else None
    out["vd"] = _clean_vendors(snap.get("vd"))
    out["rc"] = _clean_recipes(snap.get("rc"))
    out["np"] = _clean_npcs(snap.get("np"))
    out["tr"] = _clean_trainers(snap.get("tr"))
    out["sl"] = _clean_spells(snap.get("sl"))
    out["ah"] = _clean_prices(snap.get("ah"))
    out["ahd"] = _clean_history(snap.get("ahd"))
    out["it"] = _clean_items(snap.get("it"))
    realm = snap.get("rl")
    out["rl"] = realm if isinstance(realm, str) and 0 < len(realm) <= 40 and "|" not in realm else None
    out["fc"] = snap.get("fc") if snap.get("fc") in ("Alliance", "Horde") else None
    return out


def load_inputs(paths: list[Path]) -> tuple[list[dict], list[str]]:
    snaps, problems = [], []
    files: list[Path] = []
    for p in paths:
        if p.is_dir():
            files.extend(sorted(x for x in p.rglob("*") if x.suffix in (".lua", ".txt")))
        else:
            files.append(p)
    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        if f.suffix == ".lua" and _PREFIX not in text[:200] and _OLD_PREFIX not in text[:200]:
            try:
                parsed = parse_saved_variables(text)
            except LuaParseError as e:
                problems.append(f"{f}: {e}")
                continue
            db = parsed.get("WorldCodexDB") or parsed.get("ItemsDB")  # ItemsDB: name before the rename
            if not isinstance(db, dict):
                problems.append(f"{f}: no WorldCodexDB table")
                continue
            snap = validate(snapshot_from_saved(db))
            if snap:
                snaps.append(snap)
            else:
                problems.append(f"{f}: invalid data")
        else:
            for line_no, line in enumerate(text.splitlines(), 1):
                start = max(line.find(_PREFIX), line.find(_OLD_PREFIX))
                if start < 0:
                    continue
                try:
                    snap = validate(decode_share_string(line[start:]))
                except (ValueError, zlib.error) as e:
                    problems.append(f"{f}:{line_no}: {e}")
                    continue
                if snap:
                    snaps.append(snap)
                else:
                    problems.append(f"{f}:{line_no}: invalid data")
    return snaps, problems


# --------------------------------------------------------------------------- merging


def is_outlier(d: float, n: float, p: float, z_limit: float) -> bool:
    if n < 20 or p <= 0 or p >= 1:
        return False
    sd = math.sqrt(n * p * (1 - p))
    return sd > 0 and abs(d - n * p) / sd > z_limit


SCHEMA = 2  # dataset format version (docs/dataset.md); the addon reads every schema >= 1


def _vote(counter: dict):
    """Most common value (ties: the first seen)."""
    best, best_n = None, -1
    for value, n in counter.items():
        if n > best_n:
            best, best_n = value, n
    return best


def _count(counter: dict, value, weight=1):
    if value is not None:
        counter[value] = counter.get(value, 0) + weight


def _overlay(state: dict, delta: dict) -> dict:
    """A delta's records replace the same records of the state they build on (whole records, not sums:
    each one holds that installation's lifetime totals)."""
    out = dict(state)
    out["rev"], out["base"] = max(state["rev"], delta["rev"]), None
    for field in ("src", "vd", "rc", "np", "tr", "sl", "it"):
        merged = dict(state.get(field) or {})
        merged.update(delta.get(field) or {})
        out[field] = merged
    if delta.get("ah"):
        if (delta.get("rl"), delta.get("fc")) == (state.get("rl"), state.get("fc")):
            prices = dict(state.get("ah") or {})
            prices.update(delta["ah"])
            out["ah"] = prices
        else:  # prices belong to one realm and faction: those of another market are not kept
            out["ah"], out["ahd"], out["rl"], out["fc"] = dict(delta["ah"]), {}, delta.get("rl"), delta.get("fc")
    out["lc"] = delta.get("lc") or state.get("lc")
    return out


def compose(snaps: list[dict]) -> tuple[dict[str, dict], list[str]]:
    """One snapshot per installation id. A full upload holds the installation's lifetime totals and
    replaces older ones (highest rev wins). A delta (`base` set) holds the records changed after
    revision `base`; it is laid over the newest state of the same id when that state has at least
    revision `base` (any later upload already contains everything from before `base`). A delta whose
    base is missing is skipped and reported."""
    by_uid: dict[str, list[dict]] = {}
    for s in snaps:
        by_uid.setdefault(s["uid"], []).append(s)
    latest: dict[str, dict] = {}
    notes: list[str] = []
    for uid, uploads in by_uid.items():
        # by revision; on a tie the full upload first, so a delta of the same revision still applies
        uploads.sort(key=lambda s: (s["rev"], s.get("base") is not None))
        state = None
        for s in uploads:
            if s.get("base") is None:
                state = s
            elif state is None or state["rev"] < s["base"]:
                notes.append(f"{uid}: changes after rev {s['base']} skipped, the upload they build on is missing")
            else:
                state = _overlay(state, s)
        if state is not None:
            latest[uid] = state
    return latest, notes


def merge(snaps: list[dict], z_limit: float = 5.0, max_cells: int = 32, min_n: int = 1,
          min_d: int = 1) -> tuple[dict, list[str]]:
    latest, rejected = compose(snaps)

    # Quest items: attempts are counted per item, only while the quest was active (qb). As soon as
    # one upload has such a count, uploads without it (no quest, or older addon versions) say nothing
    # about that item's rate at that source.
    counted: dict[Any, set] = {}
    for s in latest.values():
        for key, x in s["src"].items():
            counted.setdefault(key, set()).update(x.get("qb") or {})

    def sample(key, x, item_id) -> int | None:
        """Attempts of this upload that count for the item, None = the upload says nothing about it."""
        if item_id in counted[key]:
            return (x.get("qb") or {}).get(item_id)
        return x["n"]

    # pooled totals per (source, item) to test each contribution against everyone else
    totals: dict[Any, dict] = {}
    for s in latest.values():
        for key, x in s["src"].items():
            t = totals.setdefault(key, {"n": 0, "l": {}, "qb": {}})
            t["n"] += x["n"]
            for item_id, qn in (x.get("qb") or {}).items():
                t["qb"][item_id] = t["qb"].get(item_id, 0) + qn
            for item_id, (d, *_rest) in x["l"].items():
                if sample(key, x, item_id) is not None:
                    t["l"][item_id] = t["l"].get(item_id, 0) + d

    out: dict[Any, dict] = {}
    names: dict[Any, dict] = {}
    locale_names: dict[Any, dict] = {}  # key -> locale -> name -> weight
    for uid, s in latest.items():
        for key, x in s["src"].items():
            t = totals[key]
            bad = False
            for item_id in set(t["l"]) | set(x["l"]):
                n = sample(key, x, item_id)
                if n is None:
                    continue
                rest_n = t["qb"].get(item_id, t["n"]) - n
                if rest_n < 20:
                    continue
                d = x["l"].get(item_id, [0, 0])[0]
                p_rest = (t["l"].get(item_id, 0) - d) / rest_n
                if is_outlier(d, n, p_rest, z_limit):
                    bad = True
                    rejected.append(f"{uid}: source {key} item {item_id} ({d}/{n} vs pooled {p_rest:.3f})")
                    break
            if bad:
                continue
            o = out.setdefault(key, {"n": 0, "m": 0, "l": {}, "qb": {}, "sp": {}, "zn": {}, "ch": set(), "rp": None,
                                     "lv": None, "cl": {}, "qg": {}, "qt": {}, "si": {}, "rq": {}})
            if x.get("lv"):
                lo, hi = x["lv"]
                o["lv"] = [lo, hi] if not o["lv"] else [min(o["lv"][0], lo), max(o["lv"][1], hi)]
            _count(o["cl"], x.get("cl"))
            _count(o["qg"], x.get("qg"))
            _count(o["qt"], x.get("qt"))
            _count(o["si"], x.get("si"))
            if x.get("rq"):
                _count(o["rq"], json.dumps(sorted(x["rq"].items())))
            o["ch"] |= set(x.get("ch") or ())
            o["rp"] = o["rp"] or x.get("rp")
            if x.get("cm"):
                c = o.setdefault("cm", [0, 0, None, None])
                c[0] += x["cm"][0]
                c[1] += x["cm"][1]
                for i, f in ((2, min), (3, max)):
                    if x["cm"][i] is not None:
                        c[i] = x["cm"][i] if c[i] is None else f(c[i], x["cm"][i])
            o["n"] += x["n"]
            o["m"] += x["m"]
            for item_id, qn in (x.get("qb") or {}).items():
                o["qb"][item_id] = o["qb"].get(item_id, 0) + qn
            for item_id, (d, q, *rest) in x["l"].items():
                if sample(key, x, item_id) is None:
                    continue
                cur = o["l"].setdefault(item_id, [0, 0, {}])
                cur[0] += d
                cur[1] += q
                for size, cnt in (rest[0] if rest else {}).items():
                    cur[2][size] = cur[2].get(size, 0) + cnt
            for m, cells in x["sp"].items():
                om = o["sp"].setdefault(m, {})
                for c, cnt in cells.items():
                    om[c] = om.get(c, 0) + cnt
            for m, cnt in (x.get("zn") or {}).items():
                o["zn"][m] = o["zn"].get(m, 0) + cnt
            nm = names.setdefault(key, {})
            label = (x["nm"], x["k"])
            nm[label] = nm.get(label, 0) + x["n"]
            if x.get("nm"):
                _count(locale_names.setdefault(key, {}).setdefault(s.get("lc") or "?", {}), x["nm"], x["n"])

    sources = {}
    for key, o in out.items():
        if o["n"] < min_n:
            continue
        (nm, kind), _ = max(names[key].items(), key=lambda kv: kv[1])
        sp = {}
        for m, cells in o["sp"].items():
            top = sorted(cells.items(), key=lambda kv: -kv[1])[:max_cells]
            sp[m] = dict(top)
        loot = {i: (v if v[2] else v[:2]) for i, v in o["l"].items()}
        sources[key] = {"nm": nm, "k": kind, "n": o["n"], "m": int(o["m"]), "l": loot, "sp": sp}
        if o["zn"]:
            sources[key]["zn"] = dict(sorted(o["zn"].items()))
        if o["ch"]:
            sources[key]["ch"] = {i: True for i in sorted(o["ch"])}
        if o["rp"]:
            sources[key]["rp"] = o["rp"]
        if o.get("cm"):
            sources[key]["cm"] = o["cm"]  # [coin drops, looted attempts, min copper, max copper]
        if o["lv"]:
            sources[key]["lv"] = o["lv"]
        for field in ("cl", "qg", "qt", "si"):
            if o[field]:
                sources[key][field] = _vote(o[field])
        if o["rq"]:
            sources[key]["rq"] = {int(i): n for i, n in json.loads(_vote(o["rq"]))}
        if min_d > 1:
            sources[key]["l"] = {i: v for i, v in sources[key]["l"].items() if v[0] >= min_d}
        bases = {i: n for i, n in sorted(o["qb"].items()) if i in sources[key]["l"]}
        if bases:
            sources[key]["qb"] = bases

    vendors, vendor_names = _merge_vendors(latest.values(), max_cells)
    npcs, npc_names = _merge_npcs(latest.values(), max_cells)
    dataset = {
        "version": 1,
        "schema": SCHEMA,
        "generated": int(time.time()),
        # rev of each contributor's merged upload (the addon only needs the key to be present)
        "contributors": {uid: int(s["rev"]) for uid, s in latest.items()},
        "sources": sources,
        "vendors": vendors,
        "recipes": _merge_recipes(latest.values()),
        "trainers": _merge_trainers(latest.values()),
        "npcs": npcs,
        "names": _localized_names(sources, locale_names, vendors, vendor_names, npcs, npc_names),
        # website only (not written to the addon's Lua file)
        "prices": _merge_prices(latest.values()),
        "items": _merge_items(latest.values()),
        "spells": _merge_spells(latest.values()),
    }
    return dataset, rejected


def _merge_prices(snaps) -> dict:
    """prices["<realm>|<faction>"][itemId] = {"last": newest scan, "days": {day: rollup}}. Days seen by
    several uploads: medians and averages weighted by the number of scans, min of mins, max of maxes.
    Uploads without realm and faction are left out: prices of unknown origin are worthless."""
    out: dict[str, dict] = {}
    for s in snaps:
        if not s.get("rl") or not s.get("fc"):
            continue
        market = out.setdefault(f"{s['rl']}|{s['fc']}", {})
        for item_id, last in (s.get("ah") or {}).items():
            e = market.setdefault(item_id, {"last": None, "days": {}})
            if e["last"] is None or last["t"] > e["last"]["t"]:
                e["last"] = last
        for item_id, days in (s.get("ahd") or {}).items():
            e = market.setdefault(item_id, {"last": None, "days": {}})
            for day, d in days.items():
                cur = e["days"].get(day)
                if cur is None:
                    e["days"][day] = dict(d)
                    continue
                c1, c2 = cur.get("c", 1), d.get("c", 1)
                for f in ("md", "mn", "q"):
                    if f in d and f in cur:
                        cur[f] = round((cur[f] * c1 + d[f] * c2) / (c1 + c2))
                if "mi" in d:
                    cur["mi"] = min(cur.get("mi", d["mi"]), d["mi"])
                if "mx" in d:
                    cur["mx"] = max(cur.get("mx", d["mx"]), d["mx"])
                cur["c"] = c1 + c2
        for item_id in list(market):
            if market[item_id]["last"] is None:
                del market[item_id]["last"]
    return out


def _merge_items(snaps) -> dict:
    """Item facts by vote; names per locale: items[id]["n"] is the English name when known and
    items[id]["names"] = {locale: name} holds every language that was uploaded."""
    acc: dict[int, dict] = {}
    for s in snaps:
        loc = s.get("lc") or "?"
        for item_id, e in (s.get("it") or {}).items():
            a = acc.setdefault(item_id, {f: {} for f in _ITEM_FIELDS + _ITEM_DETAILS} | {"names": {}})
            for f in _ITEM_FIELDS + tuple(f for f, _ in _ITEM_DETAIL_NUMBERS):
                if f != "n" and e.get(f) is not None:
                    _count(a[f], e[f])
            for f in ("st", "wd"):
                if e.get(f):
                    _count(a[f], json.dumps(e[f], sort_keys=True))
            if e.get("fx"):
                _count(a["fx"].setdefault(loc, {}), json.dumps(e["fx"]))
            _count(a["names"].setdefault(loc, {}), e["n"])
    out = {}
    for item_id, a in acc.items():
        entry = {f: _vote(a[f]) for f in _ITEM_FIELDS + tuple(f for f, _ in _ITEM_DETAIL_NUMBERS) if f != "n" and a[f]}
        for f in ("st", "wd"):
            if a[f]:
                entry[f] = json.loads(_vote(a[f]))
        effects = {loc: json.loads(_vote(c)) for loc, c in a["fx"].items() if loc != "?"}
        if effects:
            entry["fx"] = effects  # {locale: [[trigger, text], ...]}
        names = {loc: _vote(c) for loc, c in a["names"].items() if loc != "?"}
        en = names.get("enUS") or names.get("enGB")
        if not en:
            totals: dict = {}
            for counter in a["names"].values():
                for name, n in counter.items():
                    totals[name] = totals.get(name, 0) + n
            en = _vote(totals)
        entry["n"] = en
        if names:
            entry["names"] = names
        out[item_id] = entry
    return out


def _merge_npcs(snaps, max_cells: int) -> tuple[dict, dict]:
    """Locations summed per cell (busiest cells kept), level range widened, roles united,
    classification / reaction / name by vote."""
    acc: dict[Any, dict] = {}
    for s in snaps:
        for key, r in (s.get("np") or {}).items():
            a = acc.setdefault(key, {"nm": {}, "sp": {}, "lv": None, "cl": {}, "r": {}, "f": set(), "loc": {}})
            if r.get("nm"):
                _count(a["nm"], r["nm"])
                _count(a["loc"].setdefault(s.get("lc") or "?", {}), r["nm"])
            for m, cells in r.get("sp", {}).items():
                am = a["sp"].setdefault(m, {})
                for c, n in cells.items():
                    am[c] = am.get(c, 0) + n
            if r.get("lv"):
                lo, hi = r["lv"]
                a["lv"] = [lo, hi] if not a["lv"] else [min(a["lv"][0], lo), max(a["lv"][1], hi)]
            _count(a["cl"], r.get("cl"))
            _count(a["r"], r.get("r"))
            a["f"] |= set(r.get("f") or ())
    npcs, names = {}, {}
    for key, a in acc.items():
        entry = {"nm": _vote(a["nm"]),
                 "sp": {m: dict(sorted(c.items(), key=lambda kv: -kv[1])[:max_cells]) for m, c in a["sp"].items()}}
        if a["lv"]:
            entry["lv"] = a["lv"]
        for field in ("cl", "r"):
            if a[field]:
                entry[field] = _vote(a[field])
        if a["f"]:
            entry["f"] = {role: True for role in sorted(a["f"])}
        npcs[key] = entry
        names[key] = a["loc"]
    return npcs, names


def _merge_vendors(snaps, max_cells: int) -> tuple[dict, dict]:
    """Union of everything each vendor was seen selling. Price: the highest seen (reputation
    discounts only lower it); stack: most common; limited if anyone saw a limit."""
    acc: dict[int, dict] = {}
    for s in snaps:
        for npc, v in (s.get("vd") or {}).items():
            a = acc.setdefault(npc, {"nm": {}, "sp": {}, "i": {}, "loc": {}})
            if v.get("nm"):
                _count(a["nm"], v["nm"])
                _count(a["loc"].setdefault(s.get("lc") or "?", {}), v["nm"])
            for m, cells in v.get("sp", {}).items():
                am = a["sp"].setdefault(m, {})
                for c, n in cells.items():
                    am[c] = am.get(c, 0) + n
            for item_id, e in v["i"].items():
                ai = a["i"].setdefault(item_id, {"p": 0, "st": {}, "lim": False, "x": None, "c": 0})
                if e["p"] >= ai["p"]:
                    ai["p"], ai["x"] = e["p"], e.get("x") or ai["x"]
                _count(ai["st"], e.get("st", 1))
                ai["lim"] = ai["lim"] or bool(e.get("lim"))
                ai["c"] += 1
    vendors, names = {}, {}
    for npc, a in acc.items():
        items = {}
        for item_id, ai in a["i"].items():
            entry = {"p": ai["p"], "st": _vote(ai["st"]), "c": ai["c"]}
            if ai["lim"]:
                entry["lim"] = True
            if ai["x"]:
                entry["x"] = ai["x"]
            items[item_id] = entry
        sp = {m: dict(sorted(cells.items(), key=lambda kv: -kv[1])[:max_cells]) for m, cells in a["sp"].items()}
        vendors[npc] = {"nm": _vote(a["nm"]), "sp": sp, "i": items}
        names[npc] = a["loc"]
    return vendors, names


def _merge_recipes(snaps) -> dict:
    """Most common reagent set per product (recipes can differ slightly between uploads when a
    window was read half loaded); made-count range widened over all uploads."""
    acc: dict[Any, dict] = {}
    for s in snaps:
        for key, r in (s.get("rc") or {}).items():
            a = acc.setdefault(key, {"pf": {}, "r": {}, "mn": None, "mx": None, "sid": {}})
            _count(a["pf"], r["pf"])
            _count(a["sid"], r.get("sid"))
            _count(a["r"], json.dumps(sorted(r["r"].items())))
            a["mn"] = r["mn"] if a["mn"] is None else min(a["mn"], r["mn"])
            a["mx"] = r["mx"] if a["mx"] is None else max(a["mx"], r["mx"])
    out = {}
    for key, a in acc.items():
        out[key] = {"pf": _vote(a["pf"]), "mn": a["mn"], "mx": a["mx"], "r": {int(i): n for i, n in json.loads(_vote(a["r"]))}}
        if a["sid"]:
            out[key]["sid"] = _vote(a["sid"])  # the recipe's spell id
    return out


def _merge_spells(snaps) -> dict:
    """spells[id] = {"n": English name when known, "names": {locale: name}, "rk": {locale: rank},
    "ds": {locale: description}, "ic": icon}, each by vote over the uploads of that language."""
    acc: dict[int, dict] = {}
    for s in snaps:
        loc = s.get("lc") or "?"
        for spell_id, r in (s.get("sl") or {}).items():
            a = acc.setdefault(spell_id, {"names": {}, "rk": {}, "ds": {}, "ic": {}})
            _count(a["names"].setdefault(loc, {}), r["n"])
            if r.get("rk"):
                _count(a["rk"].setdefault(loc, {}), r["rk"])
            if r.get("ds"):
                _count(a["ds"].setdefault(loc, {}), r["ds"])
            _count(a["ic"], r.get("ic"))
    out = {}
    for spell_id, a in acc.items():
        names = {loc: _vote(c) for loc, c in a["names"].items() if loc != "?"}
        en = names.get("enUS") or names.get("enGB")
        if not en:
            totals: dict = {}
            for counter in a["names"].values():
                for name, n in counter.items():
                    totals[name] = totals.get(name, 0) + n
            en = _vote(totals)
        entry = {"n": en}
        if names:
            entry["names"] = names
        for f in ("rk", "ds"):
            per = {loc: _vote(c) for loc, c in a[f].items() if loc != "?"}
            if per:
                entry[f] = per
        if a["ic"]:
            entry["ic"] = _vote(a["ic"])
        out[spell_id] = entry
    return out


def _merge_trainers(snaps) -> dict:
    """Union of every service each trainer was seen teaching. Kind, profession and class by vote (a
    class or profession beats "general", which a window without a readable title gives); cost: the
    highest seen (reputation discounts only lower it); required level and skill: the highest seen."""
    acc: dict[int, dict] = {}
    for s in snaps:
        for npc, r in (s.get("tr") or {}).items():
            a = acc.setdefault(npc, {"nm": {}, "tt": {}, "pf": {}, "cls": {}, "s": {}})
            _count(a["nm"], r.get("nm"))
            _count(a["tt"], r["tt"])
            _count(a["pf"], r.get("pf"))
            _count(a["cls"], r.get("cls"))
            for key, e in r["s"].items():
                ae = a["s"].setdefault(key, {"it": {}, "nm": {}})
                for f in ("c", "lv", "sk"):
                    if e.get(f) is not None:
                        ae[f] = max(ae.get(f, e[f]), e[f])
                _count(ae["it"], e.get("it"))
                _count(ae["nm"], e.get("nm"))
    out = {}
    for npc, a in acc.items():
        specific = {k: n for k, n in a["tt"].items() if k != "general"}
        kind = _vote(specific or a["tt"])
        services = {}
        for key, ae in a["s"].items():
            entry = {f: ae[f] for f in ("c", "lv", "sk") if f in ae}
            for f in ("it", "nm"):
                if ae[f]:
                    entry[f] = _vote(ae[f])
            services[key] = entry
        entry = {"tt": kind, "s": services}
        if a["nm"]:
            entry["nm"] = _vote(a["nm"])
        if kind == "profession" and a["pf"]:
            entry["pf"] = _vote(a["pf"])
        if kind == "class" and a["cls"]:
            entry["cls"] = _vote(a["cls"])
        out[npc] = entry
    return out


def _localized_names(sources: dict, locale_names: dict, vendors: dict, vendor_names: dict,
                     npcs: dict | None = None, npc_names: dict | None = None) -> dict:
    """names[locale][key] for every name that differs from the default `nm` (the enUS name when one
    exists). Vendors use the key "vendor:<npc>"; NPCs share the npc id with mob sources."""
    out: dict[str, dict] = {}

    def add(key, default, per_locale, store_key):
        for loc, counter in per_locale.items():
            if loc == "?":
                continue
            name = _vote(counter)
            if name and name != default:
                out.setdefault(loc, {})[store_key] = name

    for key, per_locale in locale_names.items():
        if key not in sources:
            continue
        en = per_locale.get("enUS") or per_locale.get("enGB")
        if en:
            sources[key]["nm"] = _vote(en)
        add(key, sources[key]["nm"], per_locale, key)
    for npc, per_locale in vendor_names.items():
        en = per_locale.get("enUS") or per_locale.get("enGB")
        if en:
            vendors[npc]["nm"] = _vote(en)
        add(npc, vendors[npc]["nm"], per_locale, f"vendor:{npc}")
    for key, per_locale in (npc_names or {}).items():
        en = per_locale.get("enUS") or per_locale.get("enGB")
        if en:
            npcs[key]["nm"] = _vote(en)
        if key not in sources:  # a mob's localized name is already listed under the same key
            add(key, npcs[key]["nm"], per_locale, key)
    return out


# --------------------------------------------------------------------------- output


def _lua_key(k: Any) -> str:
    if isinstance(k, bool):
        raise TypeError("bool key")
    if isinstance(k, (int, float)):
        return f"[{k}]"
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k) and k not in {"and", "end", "nil", "true", "false", "for", "if", "in", "or", "not", "do", "then", "else", "elseif", "while", "repeat", "until", "local", "function", "return", "break", "goto"}:
        return k
    return "[" + _lua_str(k) + "]"


def _lua_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def to_lua(value: Any, indent: int = 0) -> str:
    pad = "    " * indent
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return _lua_str(value)
    if isinstance(value, list):
        return "{ " + ", ".join(to_lua(v, indent + 1) for v in value) + " }"
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = sorted(value.items(), key=lambda kv: (isinstance(kv[0], str), kv[0]))
        inner = ",\n".join(f"{pad}    {_lua_key(k)} = {to_lua(v, indent + 1)}" for k, v in items)
        return "{\n" + inner + ",\n" + pad + "}"
    raise TypeError(f"cannot serialize {type(value)}")


def _lua_compact(value: Any) -> str:
    """Same as to_lua without any whitespace (the shipped file; one record per line, see write_lua)."""
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return _lua_str(value)
    if isinstance(value, list):
        return "{" + ",".join(_lua_compact(v) for v in value) + "}"
    if isinstance(value, dict):
        return "{" + ",".join(f"{_lua_key(k)}={_lua_compact(v)}" for k, v in _sorted(value)) + "}"
    raise TypeError(f"cannot serialize {type(value)}")


def _ser(value: Any) -> str:
    """Codec.Serialize in Python (the addon's safe serializer, read back by Codec.Deserialize and _parse_ser).
    Lists become Lua arrays (keys 1..n); None entries are left out, as Lua drops nil."""
    if isinstance(value, bool):
        return "T" if value else "F"
    if isinstance(value, int):
        return f"n{value};"
    if isinstance(value, float):
        return f"n{int(value)};" if value.is_integer() else f"n{value:.6g};"
    if isinstance(value, str):
        return f"s{len(value.encode('utf-8'))}:{value}"
    if isinstance(value, list):
        return "{" + "".join(f"n{i};{_ser(v)}" for i, v in enumerate(value, 1) if v is not None) + "}"
    if isinstance(value, dict):
        return "{" + "".join(_ser(k) + _ser(v) for k, v in _sorted(value) if v is not None) + "}"
    raise TypeError(f"cannot serialize {type(value)}")


# Source fields the addon reads for every source (lists, names, sample sizes) stay plain Lua values; all
# others are packed into one string "_" that the addon decodes only when a page or tooltip needs the record
# (Store.Community). One string per record instead of a table per loot entry: about a seventh of the memory.
_SOURCE_PLAIN = ("nm", "k", "n", "m")


def _pack_source(rec: dict) -> dict:
    out = {k: rec[k] for k in _SOURCE_PLAIN if k in rec}
    body = {k: v for k, v in rec.items() if k not in _SOURCE_PLAIN}
    if body:
        out["_"] = _ser(body)
    return out


def _unpack_source(rec: dict) -> dict:
    if not isinstance(rec, dict) or "_" not in rec:
        return rec
    out = {k: v for k, v in rec.items() if k != "_"}
    body, _end = _parse_ser(rec["_"].encode("utf-8"))
    out.update(body)
    return out


def prune(dataset: dict, min_n: int = 1, min_d: int = 1) -> dict:
    """A copy of the dataset without sources below min_n and source/item pairs below min_d (merge()
    already applied its own, usually lower, limits). Used for the addon's file, while the website's JSON
    keeps the long tail."""
    if min_n <= 1 and min_d <= 1:
        return dataset
    sources = {}
    for key, s in dataset["sources"].items():
        if s["n"] < min_n:
            continue
        s = dict(s)
        s["l"] = {i: v for i, v in s["l"].items() if v[0] >= min_d}
        if s.get("qb"):
            s["qb"] = {i: n for i, n in s["qb"].items() if i in s["l"]}
            if not s["qb"]:
                del s["qb"]
        sources[key] = s
    keep = set(sources) | set(dataset.get("npcs") or {}) | {f"vendor:{v}" for v in dataset.get("vendors") or {}}
    names = {loc: {k: v for k, v in t.items() if k in keep} for loc, t in (dataset.get("names") or {}).items()}
    return {**dataset, "sources": sources, "names": {loc: t for loc, t in names.items() if t}}


def _item_index(sources: dict) -> tuple[dict, dict]:
    """ix[itemId] = serialized list of the source keys that drop it, qi = items with quest sample sizes: the
    addon's item index (Store.RebuildIndex) and quest test (Store.IsGated) without decoding every record."""
    by_item: dict[Any, list] = {}
    quest: dict[Any, bool] = {}
    for key, s in _sorted(sources):
        for item_id in s.get("l") or {}:
            by_item.setdefault(item_id, []).append(key)
        for item_id in s.get("qb") or {}:
            quest[item_id] = True
    return {i: _ser(keys) for i, keys in by_item.items()}, quest


CHUNK_CONSTANTS = 20000  # scalars per Lua function; LuaJIT allows 65536 constants, WoW's Lua 5.1 more
_CHUNKED = ("contributors", "sources", "vendors", "recipes", "trainers", "npcs", "ix")
_WEB_ONLY = ("prices", "items", "spells")  # in the JSON for the website, not in the addon's Lua file
_PUT = (
    "local function put(section, sub, part)\n"
    "    local t = WorldCodex_CommunityData[section]\n"
    "    if sub then\n"
    "        t[sub] = t[sub] or {}\n"
    "        t = t[sub]\n"
    "    end\n"
    "    for k, v in pairs(part()) do\n"
    "        t[k] = v\n"
    "    end\n"
    "end\n"
)


def _scalars(value: Any) -> int:
    if isinstance(value, dict):
        return sum(1 + _scalars(v) for v in value.values())
    if isinstance(value, list):
        return sum(_scalars(v) for v in value)
    return 1


def _chunks(items: list) -> list[dict]:
    """Splits (key, value) pairs so that no chunk holds more than CHUNK_CONSTANTS scalars."""
    out, cur, size = [], {}, 0
    for k, v in items:
        n = 1 + _scalars(v)
        if cur and size + n > CHUNK_CONSTANTS:
            out.append(cur)
            cur, size = {}, 0
        cur[k] = v
        size += n
    if cur:
        out.append(cur)
    return out


def _sorted(d: dict) -> list:
    return sorted(d.items(), key=lambda kv: (isinstance(kv[0], str), kv[0]))


def write_lua(dataset: dict, path: Path, min_n: int = 1, min_d: int = 1) -> None:
    """The addon's file. Sources are packed (_pack_source) and indexed by item (_item_index); min_n/min_d
    leave out what is too thin for the addon (prune). The big sections are written in chunks, each
    wrapped in its own function, because Lua limits the number of constants per function and a single
    huge table constructor would hit it. One record per line without whitespace: small, and a new
    release still diffs record by record."""
    dataset = prune(dataset, min_n, min_d)
    ix, qi = _item_index(dataset["sources"])
    data = {k: v for k, v in dataset.items() if k not in _WEB_ONLY}
    data["sources"] = {k: _pack_source(s) for k, s in dataset["sources"].items()}
    data["ix"], data["qi"], data["packed"] = ix, qi, 1
    data["pairs"] = sum(len(s["l"]) for s in dataset["sources"].values())
    head = {k: v for k, v in data.items() if k not in _CHUNKED and k != "names"}
    for k in _CHUNKED + ("names",):
        head[k] = {}
    parts = [
        "-- Generated by tools/merge.py from player uploads. Do not edit by hand.\n",
        "WorldCodex_CommunityData = " + to_lua(head) + "\n",
        _PUT,
    ]

    def emit(section, sub, items):
        label = "nil" if sub is None else _lua_str(sub)
        for chunk in _chunks(items):
            rows = ",\n".join(f"{_lua_key(k)}={_lua_compact(v)}" for k, v in chunk.items())
            parts.append(f'put("{section}", {label}, function() return {{\n{rows}\n}} end)\n')

    for section in _CHUNKED:
        emit(section, None, _sorted(data.get(section) or {}))
    for locale, names in sorted((data.get("names") or {}).items()):
        emit("names", locale, _sorted(names))
    path.write_text("".join(parts), encoding="utf-8")


def read_lua(text: str) -> dict:
    """Reads a file written by write_lua back into the dataset (used by tests and the website): packed
    sources come back unpacked, the addon-only index (ix, qi, pairs, packed) is left out."""
    dataset = _read_lua_raw(text)
    if dataset.get("packed"):
        dataset["sources"] = {k: _unpack_source(s) for k, s in (dataset.get("sources") or {}).items()}
    for k in ("ix", "qi", "pairs", "packed"):
        dataset.pop(k, None)
    return dataset


def _read_lua_raw(text: str) -> dict:
    split = text.find(_PUT)
    p = _Parser(text if split < 0 else text[:split])
    p.take("name", "WorldCodex_CommunityData")
    p.take("sym", "=")
    dataset = p.value()
    put = re.compile(r'put\("(\w+)", (?:nil|"([^"]+)"), function\(\) return ')
    pos = 0
    rest = "" if split < 0 else text[split + len(_PUT):]
    while True:
        m = put.search(rest, pos)
        if not m:
            break
        end = rest.index(" end)\n", m.end())
        part = _Parser(rest[m.end():end]).value()
        target = dataset.setdefault(m.group(1), {})
        if m.group(2):
            target = target.setdefault(m.group(2), {})
        target.update(part)
        pos = end
    return dataset


def write_manifest(dataset: dict, lua_path: Path, path: Path) -> dict:
    """Small summary the release workflow checks before shipping a new data file."""
    raw = lua_path.read_bytes()
    manifest = {
        "schema": dataset.get("schema", 1),
        "generated": dataset["generated"],
        "sha256": hashlib.sha256(raw).hexdigest(),
        "bytes": len(raw),
        "contributors": len(dataset["contributors"]),
        "sources": len(dataset["sources"]),
        "pairs": sum(len(s["l"]) for s in dataset["sources"].values()),
        "vendors": len(dataset.get("vendors") or {}),
        "recipes": len(dataset.get("recipes") or {}),
        "trainers": len(dataset.get("trainers") or {}),
        "npcs": len(dataset.get("npcs") or {}),
        "items": len(dataset.get("items") or {}),
        "markets": len(dataset.get("prices") or {}),
        "spells": len(dataset.get("spells") or {}),
    }
    path.write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    return manifest


def write_json(dataset: dict, path: Path) -> None:
    def keys_to_str(v):
        if isinstance(v, dict):
            return {str(k): keys_to_str(x) for k, x in v.items()}
        if isinstance(v, list):
            return [keys_to_str(x) for x in v]
        return v
    path.write_text(json.dumps(keys_to_str(dataset), indent=1, sort_keys=True), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", type=Path, help="SavedVariables files, share-string files or directories")
    ap.add_argument("--out", type=Path, default=Path("Data/Community.lua"))
    ap.add_argument("--json", type=Path, help="also write the dataset as JSON")
    ap.add_argument("--z", type=float, default=5.0, help="outlier threshold in standard deviations")
    ap.add_argument("--min-n", type=int, default=1, help="drop sources with fewer attempts in total")
    ap.add_argument("--min-d", type=int, default=1, help="drop source/item pairs seen fewer times (size control)")
    ap.add_argument("--lua-min-n", type=int, help="like --min-n, only for the addon's Lua file (default: --min-n)")
    ap.add_argument("--lua-min-d", type=int, help="like --min-d, only for the addon's Lua file (default: --min-d)")
    ap.add_argument("--manifest", type=Path, help="also write a manifest (sha256, counts) for the release workflow")
    args = ap.parse_args(argv)

    snaps, problems = load_inputs(args.inputs)
    for p in problems:
        print("skipped:", p, file=sys.stderr)
    if not snaps:
        print("no valid uploads found", file=sys.stderr)
        return 1
    dataset, rejected = merge(snaps, z_limit=args.z, min_n=args.min_n, min_d=args.min_d)
    for r in rejected:
        print("rejected:", r, file=sys.stderr)
    lua_n = args.min_n if args.lua_min_n is None else args.lua_min_n
    lua_d = args.min_d if args.lua_min_d is None else args.lua_min_d
    write_lua(dataset, args.out, min_n=lua_n, min_d=lua_d)
    if args.json:
        write_json(dataset, args.json)
    if args.manifest:
        write_manifest(prune(dataset, lua_n, lua_d), args.out, args.manifest)
    pairs = sum(len(s["l"]) for s in dataset["sources"].values())
    print(f"{len(dataset['contributors'])} contributors, {len(dataset['sources'])} sources, {pairs} source/item pairs -> {args.json or args.out}")
    if (lua_n, lua_d) != (args.min_n, args.min_d):
        shipped = prune(dataset, lua_n, lua_d)
        lua_pairs = sum(len(s["l"]) for s in shipped["sources"].values())
        print(f"addon file: {len(shipped['sources'])} sources, {lua_pairs} source/item pairs -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
