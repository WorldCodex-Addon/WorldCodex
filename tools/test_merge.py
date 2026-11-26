"""Tests for tools/merge.py: `python3 -m unittest discover -s tools`."""
import base64
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import merge  # noqa: E402

# Produced by the addon (Report.ExportString) - keeps the Lua and Python codecs in sync.
SHARE = (
    "IDB1:R:e3MzOnVpZHMxNjphYmMxMjNkZWY0NTY3ODkwczE6dm4xO3MxOnRuMTcwMDAwMTAwMDtzMzpzcmN7czc6Z286MTYxN3tzMjpzcHt9"
    "czE6a3M0OmhlcmJzMTpubjEyO3MxOmx7bjc2NTt7bjE7bjEyO24yO24zMDt9fXMyOm5tczEwOlNpbHZlcmxlYWZzMTptbjA7fW4xMjM0O3tz"
    "MjpzcHtuMTQyOTt7bjQxNjE7bjE7fX1zMTprczM6bW9iczE6bm40MDtzMTpse24xMDA7e24xO24xMDtuMjtuMTU7fX1zMjpubXM2OktvYm9s"
    "ZHMxOm1uODAwO319czM6cmV2bjA7fQ=="
)

SAVED = """
ItemsDB = {
	["meta"] = {
		["uid"] = "fff000aaa111bbb2",
		["rev"] = 7,
	},
	["sources"] = {
		[1234] = {
			["name"] = "Kobold \\"Tunnel\\" Rat",
			["kind"] = "mob",
			["kills"] = 60,
			["attempts"] = 58,
			["money"] = 1200,
			["loot"] = {
				[100] = {
					["d"] = 15,
					["q"] = 20,
				},
			},
			["spawns"] = {
				[1429] = {
					[4161] = 3,
				},
			},
			["streak"] = {
			},
		},
		["go:1617"] = {
			["name"] = "Silverleaf",
			["kind"] = "herb",
			["kills"] = 0,
			["attempts"] = 5,
			["loot"] = {
				[765] = { ["d"] = 5, ["q"] = 11 }, -- comment
			},
		},
	},
	["list"] = {
		"a", -- [1]
		"b", -- [2]
	},
}
MobLootDB = nil
"""


class ParseTests(unittest.TestCase):
    def test_saved_variables(self):
        parsed = merge.parse_saved_variables(SAVED)
        db = parsed["ItemsDB"]
        self.assertIsNone(parsed["MobLootDB"])
        self.assertEqual(db["sources"][1234]["name"], 'Kobold "Tunnel" Rat')
        self.assertEqual(db["sources"]["go:1617"]["loot"][765]["q"], 11)
        self.assertEqual(db["list"], {1: "a", 2: "b"})

    def test_share_string_from_addon(self):
        snap = merge.validate(merge.decode_share_string(SHARE))
        self.assertEqual(snap["uid"], "abc123def4567890")
        self.assertEqual(snap["src"][1234]["l"][100][:2], [10, 15])
        self.assertEqual(snap["src"]["go:1617"]["k"], "herb")
        self.assertEqual(snap["src"][1234]["sp"][1429][4161], 1)

    def test_rejects_garbage(self):
        with self.assertRaises(ValueError):
            merge.decode_share_string("hello")
        self.assertIsNone(merge.validate({"v": 1, "uid": "x", "src": {}}))  # uid too short


class BaseTests(unittest.TestCase):
    def test_mob_base_uses_looted_corpses(self):
        self.assertEqual(merge._base({"kind": "mob", "kills": 30, "lb": 25, "attempts": 24}), 25)
        self.assertEqual(merge._base({"kind": "mob", "kills": 30, "attempts": 24}), 30, "old data: kills")
        self.assertEqual(merge._base({"kind": "mine", "kills": 0, "attempts": 12}), 12)


class MergeTests(unittest.TestCase):
    def snap(self, uid, n, d, rev=1, key=1234):
        return {"uid": uid, "rev": rev, "src": {key: {"nm": "Kobold", "k": "mob", "n": n, "m": 0, "l": {100: [d, d]}, "sp": {}}}}

    def test_sums_and_dedupes_by_uid(self):
        data, rejected = merge.merge([
            self.snap("aaaa0001", 100, 10, rev=1),
            self.snap("aaaa0001", 150, 15, rev=2),
            self.snap("bbbb0002", 100, 12),
        ])
        self.assertEqual(rejected, [])
        self.assertEqual(data["sources"][1234]["n"], 250)
        self.assertEqual(data["sources"][1234]["l"][100][:2], [27, 27])
        self.assertEqual(set(data["contributors"]), {"aaaa0001", "bbbb0002"})

    def test_outlier_rejected(self):
        honest = [self.snap(f"hhhh{i:04d}", 200, 20) for i in range(5)]
        cheat = self.snap("cccc9999", 100, 90)
        data, rejected = merge.merge(honest + [cheat])
        self.assertEqual(len(rejected), 1)
        self.assertIn("cccc9999", rejected[0])
        self.assertEqual(data["sources"][1234]["n"], 1000)

    def test_quest_items_count_only_attempts_with_the_quest(self):
        def up(uid, n, l, qb=None):
            return merge.validate({"v": 1, "uid": uid, "rev": 1, "src": {
                3255: {"nm": "Screecher", "k": "mob", "n": n, "l": l, "qb": qb or {}}}})

        data, rejected = merge.merge([
            up("aaaa0001", 100, {5165: [30, 30, {1: 30}], 100: [10, 10]}, {5165: 60}),
            up("bbbb0002", 50, {100: [5, 5]}, {5165: 4}),  # had the quest, nothing dropped
            up("cccc0003", 400, {100: [40, 40]}),          # never had the quest
            up("dddd0004", 500, {5165: [30, 30], 100: [50, 50]}),         # old addon version: every kill counted
            up("eeee0005", 20, {5165: [0, 0]}, {5165: 0, 999: 10}),
        ])
        self.assertEqual(rejected, [])
        s = data["sources"][3255]
        self.assertEqual(s["n"], 1070)
        self.assertEqual(s["l"][5165][:2], [30, 30])
        self.assertEqual(s["qb"], {5165: 64}, "items that never drop here are left out")
        self.assertEqual(s["l"][100][:2], [105, 105])
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "C.lua"
            merge.write_lua(data, out)
            self.assertEqual(merge.read_lua(out.read_text())["sources"][3255]["qb"], {5165: 64})

    def test_quest_items_from_saved_variables(self):
        db = {"meta": {"uid": "fff000aaa111bbb2", "rev": 1},
              "items": {5165: {"n": "Sunscale Feather", "qd": "Sunscale Feather"},
                        5075: {"n": "Blood Shard", "qd": "Blood Shard", "qx": 2}, 100: {"n": "Linen"},
                        5086: {"n": "Zhevra Hooves", "qd": "Zhevra Hooves"}},
              "sources": {3255: {"kind": "mob", "lb": 50, "kills": 50,
                                 "loot": {5165: {"d": 9, "q": 9}, 5075: {"d": 2, "q": 2}, 100: {"d": 20, "q": 30}},
                                 "qb": {5165: {"n": 12, "d": 5, "q": 5, "h": {1: 5}}, 5086: {"n": 7, "d": 0, "q": 0}}}}}
        s = merge.validate(merge.snapshot_from_saved(db))["src"][3255]
        self.assertEqual(s["l"][5165], [5, 5, {1: 5}])
        self.assertEqual(s["qb"], {5165: 12, 5075: 50, 5086: 7})
        self.assertEqual(s["l"][100][:2], [20, 30])

    def test_lua_output_roundtrip(self):
        snaps = [merge.validate(merge.snapshot_from_saved(merge.parse_saved_variables(SAVED)["ItemsDB"])),
                 merge.validate(merge.decode_share_string(SHARE))]
        data, _ = merge.merge(snaps)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "Community.lua"
            merge.write_lua(data, out)
            back = merge.read_lua(out.read_text())
        src = back["sources"][1234]
        self.assertEqual(src["n"], 100)
        self.assertEqual(src["l"][100][1], 25)
        self.assertEqual(src["l"][100][2], 35)
        self.assertEqual(back["sources"]["go:1617"]["n"], 17)

    def test_quest_flags_survive_merge(self):
        a = self.snap("aaaa0001", 1, 1, key="quest:155")
        a["src"]["quest:155"].update({"k": "quest", "ch": {100}, "rp": "daily"})
        b = self.snap("bbbb0002", 1, 1, key="quest:155")
        data, _ = merge.merge([a, b])
        src = data["sources"]["quest:155"]
        self.assertEqual(src["n"], 2)
        self.assertEqual(src["ch"], {100: True})
        self.assertEqual(src["rp"], "daily")

    def test_coin_stats_merge(self):
        a = self.snap("aaaa0001", 10, 2)
        a["src"][1234]["cm"] = [4, 10, 15, 90]
        b = self.snap("bbbb0002", 10, 2)
        b["src"][1234]["cm"] = [6, 10, 5, 60]
        data, _ = merge.merge([merge.validate({**a, "v": 1}), merge.validate({**b, "v": 1})])
        self.assertEqual(data["sources"][1234]["cm"], [10, 20, 5, 90])

    def test_stack_histograms_merge(self):
        a = self.snap("aaaa0001", 10, 4)
        a["src"][1234]["l"][100] = [4, 7, {1: 2, 2: 1, 3: 1}]
        b = self.snap("bbbb0002", 10, 3)
        b["src"][1234]["l"][100] = [3, 5, {1: 1, 2: 2}]
        bad = self.snap("cccc0003", 10, 2)
        bad["src"][1234]["l"][100] = [2, 2, {1: 99}]
        snaps = [merge.validate({**x, "v": 1}) for x in (a, b, bad)]
        self.assertEqual(snaps[2]["src"][1234]["l"][100][2], {}, "histogram larger than drops is dropped")
        data, _ = merge.merge(snaps)
        self.assertEqual(data["sources"][1234]["l"][100], [9, 14, {1: 3, 2: 3, 3: 1}])

    def test_new_fields_merge(self):
        a = self.snap("aaaa0001", 10, 2)
        a["src"][1234].update({"lv": [5, 6], "cl": "elite"})
        b = self.snap("bbbb0002", 10, 2)
        b["src"][1234].update({"lv": {1: 4, 2: 7}, "cl": "elite"})
        q = self.snap("cccc0003", 1, 1, key="quest:155")
        q["src"]["quest:155"].update({"k": "quest", "qg": 4000, "qt": "go:4001", "rq": {765: 10}, "si": 99})
        snaps = [merge.validate({**x, "v": 1}) for x in (a, b, q)]
        data, _ = merge.merge(snaps)
        self.assertEqual(data["sources"][1234]["lv"], [4, 7])
        self.assertEqual(data["sources"][1234]["cl"], "elite")
        quest = data["sources"]["quest:155"]
        self.assertEqual((quest["qg"], quest["qt"], quest["rq"], quest["si"]), (4000, "go:4001", {765: 10}, 99))
        bad = merge.validate({**self.snap("dddd0004", 10, 2), "v": 1})
        bad_src = {**bad["src"][1234]}
        self.assertIsNone(merge.validate({"v": 1, "uid": "dddd0004", "src": {1234: {**bad_src, "lv": [9, 2]}}})["src"][1234]["lv"])

    def test_old_snapshot_without_new_fields_merges(self):
        snap = merge.validate(merge.decode_share_string(SHARE))
        self.assertEqual(snap["vd"], {})
        self.assertEqual(snap["rc"], {})
        data, _ = merge.merge([snap])
        self.assertEqual(data["vendors"], {})
        self.assertEqual(data["schema"], merge.SCHEMA)
        self.assertEqual(data["contributors"], {"abc123def4567890": 0})

    def test_vendor_union_and_caps(self):
        a = self.snap("aaaa0001", 10, 2)
        a["lc"] = "enUS"
        a["vd"] = {777: {"nm": "Innkeeper Farley", "sp": {1429: {4040: 2}},
                         "i": {100: {"p": 4, "st": 1}, 765: {"p": 40, "st": 5, "lim": True, "x": {200: 2}}}}}
        b = self.snap("bbbb0002", 10, 2)
        b["lc"] = "deDE"
        b["vd"] = {777: {"nm": "Gastwirt Farley", "sp": {}, "i": {100: {"p": 5, "st": 1}, 2320: {"p": 10}}},
                   "x": {"nm": "bad key", "i": {}}}
        snaps = [merge.validate({**x, "v": 1}) for x in (a, b)]
        self.assertNotIn("x", snaps[1]["vd"], "string vendor key rejected")
        data, _ = merge.merge(snaps)
        v = data["vendors"][777]
        self.assertEqual(set(v["i"]), {100, 765, 2320}, "union of items")
        self.assertEqual(v["i"][100]["p"], 5, "highest price")
        self.assertEqual(v["i"][100]["c"], 2, "seen by two uploads")
        self.assertTrue(v["i"][765]["lim"])
        self.assertEqual(v["i"][765]["x"], {200: 2})
        self.assertEqual(v["nm"], "Innkeeper Farley", "English name is the default")
        self.assertEqual(data["names"]["deDE"]["vendor:777"], "Gastwirt Farley")

    def test_recipe_merge(self):
        a = self.snap("aaaa0001", 10, 2)
        a["rc"] = {2996: {"pf": "tailoring", "mn": 1, "mx": 1, "r": {100: 2}}, "enchant:7418": {"pf": "enchanting", "r": {10940: 1}}}
        b = self.snap("bbbb0002", 10, 2)
        b["rc"] = {2996: {"pf": "tailoring", "mn": 1, "mx": 2, "r": {100: 2}}, "bad": {"pf": "x", "r": {1: 1}}}
        c = self.snap("cccc0003", 10, 2)
        c["rc"] = {2996: {"pf": "tailoring", "mn": 1, "mx": 1, "r": {100: 3}}}
        snaps = [merge.validate({**x, "v": 1}) for x in (a, b, c)]
        self.assertNotIn("bad", snaps[1]["rc"])
        data, _ = merge.merge(snaps)
        r = data["recipes"][2996]
        self.assertEqual(r["r"], {100: 2}, "most common reagent set")
        self.assertEqual((r["mn"], r["mx"]), (1, 2))
        self.assertEqual(data["recipes"]["enchant:7418"]["pf"], "enchanting")

    def test_locale_names(self):
        en = self.snap("aaaa0001", 10, 2)
        en["lc"] = "enUS"
        de1 = self.snap("bbbb0002", 30, 6)
        de1["lc"] = "deDE"
        de1["src"][1234]["nm"] = "Kobold-Tunnelratte"
        de2 = self.snap("cccc0003", 30, 6)
        de2["lc"] = "deDE"
        de2["src"][1234]["nm"] = "Kobold-Tunnelratte"
        data, _ = merge.merge([merge.validate({**x, "v": 1}) for x in (en, de1, de2)])
        self.assertEqual(data["sources"][1234]["nm"], "Kobold", "English name wins although fewer kills")
        self.assertEqual(data["names"]["deDE"][1234], "Kobold-Tunnelratte")
        self.assertNotIn("enUS", data["names"], "same as default: not repeated")

    def test_npc_locations_merge(self):
        a = self.snap("aaaa0001", 10, 2)
        a["lc"] = "enUS"
        a["np"] = {6740: {"nm": "Innkeeper Allison", "sp": {1429: {5050: 2}}, "lv": [30, 30], "r": "friendly",
                          "f": {"vendor": True}},
                   "go:4001": {"nm": "Wanted Poster", "sp": {12: {101: 1}}, "f": {"quest": True}}}
        b = self.snap("bbbb0002", 10, 2)
        b["lc"] = "deDE"
        b["np"] = {6740: {"nm": "Gastwirtin Allison", "sp": {1429: {5050: 1, 5051: 4}}, "lv": {1: 29, 2: 31},
                          "r": "friendly", "f": {1: "x", "gossip": True, "evil": True}},
                   "bad key": {"nm": "x"},
                   9998: {"nm": "Stormwind Patrol", "sp": {1453: {2222: 9}}, "r": "friendly"}}
        snaps = [merge.validate({**x, "v": 1}) for x in (a, b)]
        self.assertNotIn("bad key", snaps[1]["np"])
        data, _ = merge.merge(snaps)
        n = data["npcs"][6740]
        self.assertEqual(n["sp"][1429], {5051: 4, 5050: 3})
        self.assertEqual(n["lv"], [29, 31])
        self.assertEqual(n["f"], {"gossip": True, "vendor": True}, "unknown roles dropped")
        self.assertEqual(n["nm"], "Innkeeper Allison")
        self.assertEqual(data["names"]["deDE"][6740], "Gastwirtin Allison")
        self.assertIn("go:4001", data["npcs"])
        self.assertEqual(data["npcs"][9998]["sp"], {}, "sighting locations (no role) are dropped")
        self.assertEqual(data["npcs"][9998]["nm"], "Stormwind Patrol")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "C.lua"
            merge.write_lua(data, out)
            self.assertEqual(merge._arr(merge.read_lua(out.read_text())["npcs"][6740]["lv"]), [29, 31])

    def test_prices_merge_per_realm_and_faction(self):
        def with_prices(uid, realm, faction, md, days):
            x = self.snap(uid, 10, 2)
            x.update({"rl": realm, "fc": faction, "ah": {100: {"t": 1700000000 + md, "mi": md - 1, "md": md, "mx": md + 5, "q": 3}},
                      "ahd": {100: days}})
            return merge.validate({**x, "v": 1})
        a = with_prices("aaaa0001", "TestRealm", "Alliance", 10, {19700: {"mi": 8, "md": 10, "mn": 11, "mx": 20, "q": 4, "c": 1}})
        b = with_prices("bbbb0002", "TestRealm", "Alliance", 13, {19700: {"mi": 9, "md": 13, "mn": 14, "mx": 30, "q": 2, "c": 2},
                                                                    19701: {"md": 12, "c": 1}})
        c = with_prices("cccc0003", "TestRealm", "Horde", 50, {19700: {"md": 50, "c": 1}})
        d = with_prices("dddd0004", None, None, 99, {})
        self.assertIsNone(d["rl"])
        data, _ = merge.merge([a, b, c, d])
        ally = data["prices"]["TestRealm|Alliance"][100]
        self.assertEqual(ally["last"]["md"], 13, "newest scan")
        day = ally["days"][19700]
        self.assertEqual((day["md"], day["mi"], day["mx"], day["c"]), (12, 8, 30, 3), "weighted by scans")
        self.assertIn(19701, ally["days"])
        self.assertEqual(data["prices"]["TestRealm|Horde"][100]["last"]["md"], 50, "factions kept apart")
        self.assertEqual(len(data["prices"]), 2, "prices without realm are left out")
        with tempfile.TemporaryDirectory() as tmp:
            merge.write_lua(data, Path(tmp) / "C.lua")
            lua = (Path(tmp) / "C.lua").read_text()
            self.assertNotIn("prices", lua, "prices are for the website only")
            merge.write_json(data, Path(tmp) / "d.json")
            self.assertIn("TestRealm|Alliance", (Path(tmp) / "d.json").read_text())

    def test_items_merge_with_names_per_language(self):
        en = self.snap("aaaa0001", 10, 2)
        en.update({"lc": "enUS", "it": {2589: {"n": "Linen Cloth", "ql": 1, "v": 13, "ic": 132889, "sk": 20, "eq": "INVTYPE_X1"}}})
        de = self.snap("bbbb0002", 10, 2)
        de.update({"lc": "deDE", "it": {2589: {"n": "Leinenstoff", "ql": 1, "v": 13, "ic": 132889}, -5: {"n": "bad"}}})
        snaps = [merge.validate({**x, "v": 1}) for x in (en, de)]
        self.assertNotIn(-5, snaps[1]["it"])
        self.assertNotIn("eq", snaps[0]["it"][2589], "invalid slot token dropped")
        data, _ = merge.merge(snaps)
        item = data["items"][2589]
        self.assertEqual(item["n"], "Linen Cloth")
        self.assertEqual(item["names"], {"enUS": "Linen Cloth", "deDE": "Leinenstoff"})
        self.assertEqual((item["ql"], item["v"], item["ic"], item["sk"]), (1, 13, 132889, 20))

    def test_saved_variables_carry_prices_items_and_realm(self):
        db = merge.parse_saved_variables(SAVED)["ItemsDB"]
        db["meta"].update({"realm": "TestRealm", "faction": "Horde", "locale": "deDE"})
        db["ah"] = {100: {"last": {"t": 1700000000, "mi": 5, "md": 7, "mx": 9, "q": 2},
                          "days": {19675: {"mi": 5, "md": 7, "mn": 7, "mx": 9, "q": 2, "c": 1}}}}
        db["items"] = {100: {"n": "Leinenstoff", "ql": 1, "v": 13, "src": {1234: True}}}
        snap = merge.validate(merge.snapshot_from_saved(db))
        self.assertEqual((snap["rl"], snap["fc"], snap["lc"]), ("TestRealm", "Horde", "deDE"))
        self.assertEqual(snap["ah"][100]["md"], 7)
        self.assertEqual(snap["ahd"][100][19675]["c"], 1)
        self.assertEqual(snap["it"][100], {"n": "Leinenstoff", "ql": 1, "v": 13})

    def test_min_d_prunes_rare_pairs(self):
        a = self.snap("aaaa0001", 100, 1)
        a["src"][1234]["l"][200] = [5, 5]
        data, _ = merge.merge([merge.validate({**a, "v": 1})], min_d=2)
        self.assertEqual(set(data["sources"][1234]["l"]), {200})

    def test_large_dataset_is_chunked_and_loads_in_lua(self):
        snap = {"v": 1, "uid": "bigbig0001", "rev": 3, "lc": "enUS", "src": {}}
        for k in range(1, 3501):
            snap["src"][k] = {"nm": f"Mob {k}", "k": "mob", "n": 100 + k, "m": 1000 + k,
                              "l": {10000 + (k * 7) % 5000: [k % 50 + 1, k % 50 + 1], 20000 + k: [1, 2]}, "sp": {}}
        data, _ = merge.merge([merge.validate(snap)])
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "Community.lua"
            merge.write_lua(data, out)
            text = out.read_text()
            self.assertGreater(text.count('put("sources"'), 1, "sources split into chunks")
            back = merge.read_lua(text)
            self.assertEqual(len(back["sources"]), 3500)
            self.assertEqual(back["sources"][3500]["n"], 3600)
            manifest = merge.write_manifest(data, out, Path(tmp) / "m.json")
            self.assertEqual(manifest["sources"], 3500)
            self.assertEqual(manifest["bytes"], len(out.read_bytes()))
            luajit = shutil.which("luajit") or shutil.which("lua5.1")
            if luajit:
                check = ("dofile(arg[1]); local n = 0; for _ in pairs(WorldCodex_CommunityData.sources) do n = n + 1 end; "
                         "assert(n == 3500, n); assert(WorldCodex_CommunityData.sources[3500].n == 3600)")
                script = Path(tmp) / "check.lua"
                script.write_text(check)
                res = subprocess.run([luajit, str(script), str(out)], capture_output=True, text=True)
                self.assertEqual(res.returncode, 0, res.stderr)

    def test_the_same_kill_uploaded_twice_counts_once(self):
        """Uploads carry lifetime totals and the installation id: uploading again (share string and
        SavedVariables file, minutes apart) replaces the earlier upload instead of adding to it."""
        db = merge.parse_saved_variables(SAVED)["ItemsDB"]
        first = merge.validate(merge.snapshot_from_saved(db))
        again = merge.validate(merge.snapshot_from_saved(db))
        data, _ = merge.merge([first, again])
        self.assertEqual(data["sources"][1234]["n"], 60, "one upload's worth of kills, not two")
        self.assertEqual(data["sources"][1234]["l"][100][0], 15)
        # one more kill later: the newer upload (higher rev) replaces the older one, also when the
        # older file arrives last
        db2 = merge.parse_saved_variables(SAVED)["ItemsDB"]
        db2["meta"]["rev"] = 8
        db2["sources"][1234]["kills"] = 61
        db2["sources"][1234]["attempts"] = 59
        newer = merge.validate(merge.snapshot_from_saved(db2))
        data, _ = merge.merge([newer, first])
        self.assertEqual(data["sources"][1234]["n"], 61, "the newer upload, not both")
        self.assertEqual(data["contributors"], {"fff000aaa111bbb2": 8})

    def delta(self, uid, base, rev, src, **extra):
        return merge.validate({"v": 2, "uid": uid, "base": base, "rev": rev, "src": src, **extra})

    def mob(self, n, d, name="Kobold"):
        return {"nm": name, "k": "mob", "n": n, "m": 0, "l": {100: [d, d]}, "sp": {}}

    def test_delta_is_laid_over_the_upload_it_builds_on(self):
        full = merge.validate({"v": 1, "uid": "aaaa0001", "rev": 10,
                               "src": {1234: self.mob(50, 5), 5678: self.mob(20, 2, "Murloc")}})
        changes = self.delta("aaaa0001", 10, 15, {1234: self.mob(60, 7)})
        self.assertEqual(changes["base"], 10)
        data, notes = merge.merge([changes, full])
        self.assertEqual(notes, [])
        self.assertEqual(data["sources"][1234]["n"], 60, "changed record replaced, not added")
        self.assertEqual(data["sources"][1234]["l"][100][0], 7)
        self.assertEqual(data["sources"][5678]["n"], 20, "unchanged record kept from the earlier upload")
        self.assertEqual(data["contributors"], {"aaaa0001": 15})

    def test_deltas_chain_and_apply_on_newer_full_uploads(self):
        full = merge.validate({"v": 1, "uid": "aaaa0001", "rev": 10, "src": {1234: self.mob(50, 5)}})
        newer_full = merge.validate({"v": 1, "uid": "aaaa0001", "rev": 12,
                                     "src": {1234: self.mob(52, 5), 5678: self.mob(3, 1, "Murloc")}})
        # both deltas build on rev 10 (what the shipped community file had); the second one has
        # everything the first one had and more
        d1 = self.delta("aaaa0001", 10, 14, {1234: self.mob(55, 6)})
        d2 = self.delta("aaaa0001", 10, 20, {1234: self.mob(70, 8), 5678: self.mob(9, 2, "Murloc")})
        data, notes = merge.merge([d2, newer_full, d1, full])
        self.assertEqual(notes, [])
        self.assertEqual(data["sources"][1234]["n"], 70)
        self.assertEqual(data["sources"][5678]["n"], 9)
        self.assertEqual(data["contributors"]["aaaa0001"], 20)

    def test_delta_without_its_base_is_skipped(self):
        other = self.snap("bbbb0002", 40, 4)
        orphan = self.delta("aaaa0001", 10, 15, {1234: self.mob(60, 7)})
        data, notes = merge.merge([merge.validate({**other, "v": 1}), orphan])
        self.assertEqual(data["sources"][1234]["n"], 40, "only the other player's data")
        self.assertNotIn("aaaa0001", data["contributors"])
        self.assertTrue(any("aaaa0001" in n and "missing" in n for n in notes))
        older = merge.validate({"v": 1, "uid": "aaaa0001", "rev": 8, "src": {1234: self.mob(30, 3)}})
        data, notes = merge.merge([older, orphan])
        self.assertEqual(data["sources"][1234]["n"], 30, "an upload older than the base is not enough")
        self.assertEqual(len(notes), 1)

    def test_delta_needs_a_base(self):
        self.assertIsNone(merge.validate({"v": 2, "uid": "aaaa0001", "rev": 3, "src": {}}))
        self.assertIsNone(merge.validate({"v": 3, "uid": "aaaa0001", "rev": 3, "base": 1, "src": {}}))

    def test_delta_prices_overlay_per_market(self):
        def price(md):
            return {"t": 1700000000 + md, "mi": md, "md": md, "mx": md, "q": 1}
        full = merge.validate({"v": 1, "uid": "aaaa0001", "rev": 10, "src": {}, "rl": "R", "fc": "Horde",
                               "ah": {100: price(10), 200: price(20)}})
        same = self.delta("aaaa0001", 10, 12, {}, rl="R", fc="Horde", ah={200: price(25)})
        data, _ = merge.merge([full, same])
        market = data["prices"]["R|Horde"]
        self.assertEqual((market[100]["last"]["md"], market[200]["last"]["md"]), (10, 25))
        moved = self.delta("aaaa0001", 10, 12, {}, rl="Other", fc="Horde", ah={300: price(30)})
        data, _ = merge.merge([full, moved])
        self.assertEqual(set(data["prices"]), {"Other|Horde"}, "another market replaces the prices")
        self.assertEqual(set(data["prices"]["Other|Horde"]), {300})

    def test_zones_without_position_merge(self):
        a = merge.validate({"v": 1, "uid": "aaaa0001", "rev": 1,
                            "src": {11320: {**self.mob(4, 2, "Earthborer"), "zn": {213: 3, "x": 1, 99: 0}}}})
        b = merge.validate({"v": 1, "uid": "bbbb0002", "rev": 1, "src": {11320: {**self.mob(2, 1, "Earthborer"), "zn": {213: 2}}}})
        self.assertEqual(a["src"][11320]["zn"], {213: 3}, "bad zones dropped")
        inst = merge.validate({"v": 1, "uid": "cccc0003", "rev": 1, "src": {11320: {**self.mob(1, 1, "Earthborer"), "zn": {-389: 2}}}})
        self.assertEqual(inst["src"][11320]["zn"], {-389: 2}, "negative instance ids are zones too")
        data, _ = merge.merge([a, b])
        self.assertEqual(data["sources"][11320]["zn"], {213: 5})
        with tempfile.TemporaryDirectory() as tmp:
            merge.write_lua(data, Path(tmp) / "C.lua")
            back = merge.read_lua((Path(tmp) / "C.lua").read_text())
            self.assertEqual(back["sources"][11320]["zn"], {213: 5})

    def test_saved_variables_under_the_new_name(self):
        text = SAVED.replace("ItemsDB = {", "WorldCodexDB = {")
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "WorldCodex.lua").write_text(text)
            (Path(tmp) / "s.txt").write_text(SHARE.replace("IDB1:", "WCX1:"))
            snaps, problems = merge.load_inputs([Path(tmp)])
        self.assertEqual(problems, [])
        self.assertEqual(len(snaps), 2, "new SavedVariables name and new share-string prefix")

    def test_cli(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "in").mkdir()
            (tmp / "in" / "WorldCodex.lua").write_text(SAVED)
            (tmp / "in" / "strings.txt").write_text("from discord: " + SHARE + "\n")
            rc = merge.main([str(tmp / "in"), "--out", str(tmp / "C.lua"), "--json", str(tmp / "d.json"),
                             "--manifest", str(tmp / "m.json")])
            self.assertEqual(rc, 0)
            self.assertIn('"sha256"', (tmp / "m.json").read_text())
            self.assertIn("WorldCodex_CommunityData", (tmp / "C.lua").read_text())
            self.assertIn('"1234"', (tmp / "d.json").read_text())

    def test_item_details_merge(self):
        sword = {"n": "Gnoll Sword", "cl": 2, "iv": 13, "du": 45, "un": 1,
                 "st": {"ITEM_MOD_STRENGTH_SHORT": 3, "ITEM_MOD_DAMAGE_PER_SECOND_SHORT": 5.8, "bad key": 1},
                 "wd": {1: 5, 2: 10, 3: 2600}, "fx": {1: {1: "equip", 2: "Equip: +10 attack power."}, 2: {1: "x", 2: "y"}}}
        de = {**sword, "n": "Gnollschwert", "wd": [5, 10, 2600], "fx": [["equip", "Anlegen: +10 Angriffskraft."]]}
        odd = {**sword, "wd": [5, 11], "du": "x"}
        snaps = [merge.validate({"v": 1, "uid": u, "rev": 1, "lc": lc, "src": {}, "it": {3000: e}})
                 for u, lc, e in (("aaaa0001", "enUS", sword), ("bbbb0002", "deDE", de), ("cccc0003", "enUS", odd))]
        self.assertEqual(snaps[0]["it"][3000]["wd"], [5, 10, 2600])
        self.assertNotIn("bad key", snaps[0]["it"][3000]["st"])
        self.assertEqual(snaps[0]["it"][3000]["fx"], [["equip", "Equip: +10 attack power."]], "unknown trigger dropped")
        self.assertNotIn("du", snaps[2]["it"][3000])
        item = merge.merge(snaps)[0]["items"][3000]
        self.assertEqual(item["n"], "Gnoll Sword")
        self.assertEqual((item["iv"], item["du"], item["un"]), (13, 45, 1))
        self.assertEqual(item["wd"], [5, 10, 2600], "most common weapon damage")
        self.assertEqual(item["st"], {"ITEM_MOD_STRENGTH_SHORT": 3, "ITEM_MOD_DAMAGE_PER_SECOND_SHORT": 5.8})
        self.assertEqual(item["fx"]["deDE"], [["equip", "Anlegen: +10 Angriffskraft."]], "effects per language")
        self.assertEqual(item["fx"]["enUS"], [["equip", "Equip: +10 attack power."]])
        saved = merge.parse_saved_variables(
            'WorldCodexDB = { meta = { uid = "dddd0004", rev = 2 }, sources = {}, items = { [3000] = '
            '{ n = "Gnoll Sword", dv = 1, wd = { 5, 10, 2600 }, st = { ITEM_MOD_STRENGTH_SHORT = 3 }, '
            'fx = { { "equip", "Equip: x" } } } } }')["WorldCodexDB"]
        snap = merge.validate(merge.snapshot_from_saved(saved))
        self.assertEqual(snap["it"][3000]["wd"], [5, 10, 2600], "details from SavedVariables uploads")
        self.assertEqual(snap["it"][3000]["fx"], [["equip", "Equip: x"]])

    def test_lua_file_is_packed_and_reads_back(self):
        a = self.snap("aaaa0001", 100, 20)
        a["src"][1234].update({"l": {100: [20, 31, {1: 15, 2: 3}], 555: [3, 3]}, "qb": {555: 40},
                               "lv": [5, 6], "cl": "rare", "zn": {-389: 2}, "nm": "Gnoll «Ä»"})
        data, _ = merge.merge([merge.validate({**a, "v": 1})])
        data["sources"][1234]["cm"] = [1, 12, None, None]
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "C.lua"
            merge.write_lua(data, out)
            text = out.read_text()
            raw = merge._read_lua_raw(text)
            self.assertEqual(raw["packed"], 1)
            self.assertEqual(set(raw["sources"][1234]), {"nm", "k", "n", "m", "_"}, "only the list fields stay plain")
            self.assertEqual(merge._parse_ser(raw["ix"][555].encode())[0], {1: 1234})
            self.assertEqual(raw["qi"], {555: True})
            self.assertEqual(raw["pairs"], 2)
            self.assertNotIn("\n    ", text.split("local function put")[1].split("end\n", 3)[-1], "no indentation")
            back = merge.read_lua(text)
            s = back["sources"][1234]
            self.assertEqual(s["nm"], "Gnoll «Ä»")
            self.assertEqual(s["l"][100], {1: 20, 2: 31, 3: {1: 15, 2: 3}})
            self.assertEqual((s["qb"], s["cl"], s["zn"], s["cm"]), ({555: 40}, "rare", {-389: 2}, {1: 1, 2: 12}))
            self.assertNotIn("ix", back)
            luajit = shutil.which("luajit") or shutil.which("lua5.1")
            if luajit:  # the addon's own decoder reads what _ser wrote
                check = ("local ns = {}; assert(loadfile('Codec.lua'))('WorldCodex', ns); dofile(arg[1]); "
                         "local s = WorldCodex_CommunityData.sources[1234]; local b = ns.Codec.Deserialize(s._); "
                         "assert(b.l[100][3][1] == 15 and b.qb[555] == 40 and b.cl == 'rare' and b.cm[2] == 12)")
                script = Path(tmp) / "check.lua"
                script.write_text(check)
                res = subprocess.run([luajit, str(script), str(out)], capture_output=True, text=True,
                                     cwd=Path(__file__).resolve().parent.parent)
                self.assertEqual(res.returncode, 0, res.stderr)

    def test_addon_file_has_its_own_limits(self):
        a = self.snap("aaaa0001", 100, 20)
        a["src"][1234]["l"][200] = [1, 1]
        a["src"][1234]["qb"] = {200: 50}
        b = {"v": 1, "uid": "bbbb0002", "rev": 1, "src": {77: self.mob(3, 1, "Rat")}}
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "in").mkdir()
            for i, s in enumerate([{**a, "v": 1}, b]):
                (tmp / "in" / f"{i}.txt").write_text(
                    "WCX1:R:" + base64.b64encode(merge._ser(s).encode()).decode())
            rc = merge.main([str(tmp / "in"), "--out", str(tmp / "C.lua"), "--json", str(tmp / "d.json"),
                             "--manifest", str(tmp / "m.json"), "--lua-min-n", "10", "--lua-min-d", "2"])
            self.assertEqual(rc, 0)
            web = json.loads((tmp / "d.json").read_text())
            self.assertEqual(set(web["sources"]), {"1234", "77"}, "the website keeps everything")
            self.assertIn("200", web["sources"]["1234"]["l"])
            lua = merge.read_lua((tmp / "C.lua").read_text())
            self.assertEqual(set(lua["sources"]), {1234}, "thin sources stay out of the addon")
            self.assertEqual(set(lua["sources"][1234]["l"]), {100})
            self.assertNotIn("qb", lua["sources"][1234], "quest bases follow their pairs")
            self.assertEqual(json.loads((tmp / "m.json").read_text())["pairs"], 1, "manifest describes the addon file")


if __name__ == "__main__":
    unittest.main()
