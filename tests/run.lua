-- Test runner: `luajit tests/run.lua [name filter]` (or lua5.1) from the repository root.
package.path = "./tests/?.lua;" .. package.path
local Stub = require("wowstub")
local ROOT = "."

local tests, failures = {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function eq(a, b, msg)
    if a ~= b then error((msg or "values differ") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function ok(v, msg)
    if not v then error(msg or "assertion failed", 2) end
end
local function near(a, b, eps, msg)
    if math.abs(a - b) > (eps or 1e-6) then
        error((msg or "not close") .. ": " .. tostring(a) .. " vs " .. tostring(b), 2)
    end
end

local CORE_ONLY = function(path) return not path:match("^UI/") and path ~= "Slash.lua" end

local MOB = "Creature-0-1-0-1-1234-0000AAAA01"
local MOB2 = "Creature-0-1-0-1-1234-0000AAAA02"
local OTHER = "Creature-0-1-0-1-5678-0000BBBB01"
local NODE = "GameObject-0-1-0-1-1617-0000CCCC01"

local function Env(extra)
    local env = {
        saved = { settings = { useCombatLog = true } },
        items = {
            [100] = { name = "Linen Cloth", sell = 13 },
            [200] = { name = "Rare Ring", sell = 500 },
            [765] = { name = "Silverleaf", sell = 5 },
        },
        units = {},
        money = 0,
    }
    for k, v in pairs(extra or {}) do
        env[k] = v
    end
    return env
end

local function Damage(env, ns, guid, name)
    env.cleu = { 0, "SWING_DAMAGE", false, "Player-1-1", "Tester", 0x511, 0, guid, name or "Kobold", 0xa48, 0 }
    ns.Dispatch("COMBAT_LOG_EVENT_UNFILTERED")
end

local function Die(env, ns, guid, name)
    env.cleu = { 0, "UNIT_DIED", false, "", "", 0, 0, guid, name or "Kobold", 0xa48, 0 }
    ns.Dispatch("COMBAT_LOG_EVENT_UNFILTERED")
end

local function Loot(env, ns, slots)
    env.loot = slots
    ns.Dispatch("LOOT_READY")
    ns.Dispatch("LOOT_OPENED")
    ns.Dispatch("LOOT_CLOSED")
    env.loot = {}
end

local function Advance(ns, seconds)
    local step = 0.1
    local t = 0
    while t < seconds do
        Stub.T.now = Stub.T.now + step
        ns.Tick(step)
        t = t + step
    end
end

-- ---------------------------------------------------------------- statistics

test("wilson interval", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local lo, hi = ns.Stats.Wilson(0, 0)
    eq(lo, 0)
    eq(hi, 0)
    lo, hi = ns.Stats.Wilson(5, 100)
    ok(lo > 0.015 and lo < 0.05 and hi > 0.05 and hi < 0.12, "5/100 interval " .. lo .. " " .. hi)
    lo, hi = ns.Stats.Wilson(100, 100)
    ok(hi == 1 and lo > 0.95)
end)

test("summarize trims outliers but keeps min", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local s = ns.Stats.Summarize({ { p = 100, q = 10 }, { p = 110, q = 10 }, { p = 100000, q = 1 }, { p = 90, q = 1 } })
    eq(s.mi, 90)
    eq(s.mx, 110, "troll listing excluded from max")
    ok(s.mn >= 100 and s.mn <= 110, "trimmed mean")
    eq(s.q, 22)
    eq(ns.Stats.Summarize({}), nil)
end)

test("attempts and probabilities", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    eq(ns.Stats.AttemptsFor(0.1, 0.95), 29)
    near(ns.Stats.PNoDrop(0.5, 2), 0.25)
    near(ns.Stats.EWMA({ { x = 1, v = 10 }, { x = 2, v = 20 } }, 1), (10 * 0.5 + 20) / 1.5)
    ok(ns.Stats.IsOutlier(90, 100, 0.1))
    ok(not ns.Stats.IsOutlier(12, 100, 0.1))
end)

-- ---------------------------------------------------------------- codec

test("codec roundtrip and rejection", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local C = ns.Codec
    local data = {
        v = 1,
        src = { [1234] = { nm = "A:{b}s3:", l = { [5] = { 1, 2 } } }, ["go:9"] = { n = 3.5 } },
        t = true,
        f = false,
    }
    local back = C.Deserialize(C.Serialize(data))
    eq(back.src[1234].nm, "A:{b}s3:")
    eq(back.src[1234].l[5][2], 2)
    eq(back.src["go:9"].n, 3.5)
    eq(back.t, true)
    eq(back.f, false)
    for len = 0, 7 do
        local s = string.rep("x\0\255", len):sub(1, len)
        eq(C.Base64Decode(C.Base64Encode(s)), s, "base64 len " .. len)
    end
    local enc = C.Encode(data)
    ok(enc:sub(1, 7) == "WCX1:R:")
    eq(C.Decode(enc).src[1234].l[5][1], 1)
    ok(not C.Decode("hello"))
    ok(not C.Deserialize("n1;n2;"), "trailing data rejected")
    ok(not C.Deserialize("{n1;"), "unterminated rejected")
    ok(not C.Deserialize(string.rep("{n1;", 30) .. string.rep("}", 30)), "depth limit")
end)

-- ---------------------------------------------------------------- store / migration

test("v2 data from MobLootDB is migrated", function()
    local legacy = {
        version = 2,
        sources = {
            [1234] = {
                name = "Kobold",
                kind = "mob",
                kills = 10,
                attempts = 9,
                loot = { [100] = { d = 4, q = 6 } },
                streak = {},
            },
        },
        itemNames = { [100] = "Linen Cloth" },
        prices = { [100] = 13 },
        ah = { [100] = { t = 1700000000, listings = { [50] = 3, [60] = 1 } } },
        totals = { kills = 10, attempts = 9, items = 6 },
    }
    local ns = Stub.Boot(ROOT, Env({ legacy = legacy }), { filter = CORE_ONLY })
    local db = ns.db
    eq(db.version, 3)
    eq(_G.MobLootDB, nil)
    eq(db.items[100].n, "Linen Cloth")
    eq(db.items[100].v, 13)
    ok(db.items[100].src[1234])
    eq(db.ah[100].last.mi, 50)
    eq(db.itemNames, nil)
    eq(db.sources[1234].kills, 10)
    ok(db.meta.uid and #db.meta.uid == 16)
end)

test("v1 data is migrated", function()
    local legacy = {
        kills = { [77] = 5 },
        corpses = { [77] = 4 },
        names = { [77] = "Wolf" },
        loot = { [77] = { [100] = { d = 2, q = 2 } } },
    }
    local ns = Stub.Boot(ROOT, Env({ saved = legacy }), { filter = CORE_ONLY })
    eq(ns.db.sources[77].name, "Wolf")
    eq(ns.db.sources[77].loot[100].d, 2)
    eq(ns.db.kills, nil)
end)

-- ---------------------------------------------------------------- collection

test("data saved under the old name ItemsDB is taken over once", function()
    local old = {
        version = 3,
        meta = { uid = "olduid0000000001", rev = 7 },
        sources = {
            [1234] = { name = "Kobold", kind = "mob", kills = 12, lb = 12, loot = { [100] = { d = 3, q = 3 } } },
        },
    }
    local ns = Stub.Boot(ROOT, Env({ saved = false, oldSaved = old }), { filter = CORE_ONLY })
    eq(ns.db.meta.uid, "olduid0000000001", "same installation id, so uploads keep replacing each other")
    eq(ns.db.sources[1234].kills, 12)
    eq(_G.WorldCodexDB, ns.db, "saved under the new name from now on")
    eq(_G.ItemsDB, nil, "the old variable is not saved again")
    local fresh = Stub.Boot(ROOT, Env({ oldSaved = old }), { filter = CORE_ONLY })
    eq(fresh.db.sources[1234], nil, "existing WorldCodex data wins over the old file")
end)

test("share strings from before the rename (IDB1:) are still accepted", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local rec = ns.Store.EnsureSource(1234, "Kobold", "mob")
    rec.kills, rec.attempts, rec.lb, rec.loot[100] = 30, 30, 30, { d = 3, q = 3 }
    local str = ns.Report.ExportString()
    eq(str:sub(1, 5), "WCX1:")
    local snap = ns.Codec.Decode("IDB1:" .. str:sub(6))
    ok(snap and snap.src[1234], "old prefix decodes")
end)

test("solo kill counted once, corpse loot deduplicated", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    Damage(env, ns, MOB)
    Die(env, ns, MOB)
    Die(env, ns, MOB)
    local rec = ns.db.sources[1234]
    eq(rec.kills, 1)
    eq(rec.name, "Kobold")
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 2, src = { { MOB, 2 } } } })
    eq(rec.kills, 1, "loot does not count the kill twice")
    eq(rec.attempts, 1)
    eq(rec.loot[100].d, 1)
    eq(rec.loot[100].q, 2)
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 2, src = { { MOB, 2 } } } })
    eq(rec.attempts, 1, "reopened corpse not counted")
    eq(rec.loot[100].d, 1)
    eq(ns.Collector.stats.dupes, 1)
    ok(next(rec.spawns[1429]), "spawn recorded")
end)

test("kill by others (no damage from us) is not counted", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    Die(env, ns, MOB)
    eq(ns.db.sources[1234], nil)
end)

test("tap-denied mob is not counted", function()
    local env = Env({ units = { target = { guid = MOB, name = "Kobold", denied = true } } })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    Damage(env, ns, MOB)
    Die(env, ns, MOB)
    eq(ns.db.sources[1234], nil)
end)

test("group kills are counted when looted", function()
    local env = Env({ grouped = true })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    Damage(env, ns, MOB)
    Die(env, ns, MOB)
    eq(ns.db.sources[1234], nil, "not counted at death in a group")
    Loot(env, ns, { { id = 200, name = "Rare Ring", q = 1, src = { { MOB, 1 } } } })
    local rec = ns.db.sources[1234]
    eq(rec.kills, 1)
    eq(rec.gk, 1)
    eq(rec.loot[200].g, 1)
end)

test("dungeon: corpse looted while targeting the next mob, client without loot source guids", function()
    local env = Env({ grouped = true })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local sourceInfo = _G.GetLootSourceInfo
    _G.GetLootSourceInfo = nil
    Damage(env, ns, MOB)
    Die(env, ns, MOB)
    env.units.target = { guid = OTHER, name = "Defias Pillager" } -- already on the next pull
    Loot(env, ns, { { id = 200, name = "Rare Ring", q = 1 } })
    _G.GetLootSourceInfo = sourceInfo
    eq(ns.db.sources[5678], nil, "not credited to the living target")
    local rec = ns.db.sources[1234]
    ok(rec, "credited to the mob that died")
    eq(rec.loot[200].d, 1)
    eq(rec.lb, 1)
    local log = ns.Collector.LootLog()
    eq(log[1].keys[1], "1234(1)", "loot log names the source")
    ok(log[1].noSource, "loot log flags the missing source guid")
end)

test("dungeon: the corpse under the cursor wins over the last death", function()
    local env = Env({ grouped = true })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local sourceInfo = _G.GetLootSourceInfo
    _G.GetLootSourceInfo = nil
    for _, g in ipairs({ MOB, OTHER }) do
        Damage(env, ns, g)
        Die(env, ns, g)
    end
    env.units.mouseover = { guid = MOB, name = "Kobold", dead = true }
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 2 } })
    _G.GetLootSourceInfo = sourceInfo
    eq(ns.db.sources[1234].loot[100].q, 2)
    eq(ns.db.sources[5678], nil)
end)

test("slots unreadable at LOOT_READY are read at LOOT_OPENED", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    Damage(env, ns, MOB)
    Die(env, ns, MOB)
    _G.GetLootSlotType = function() return 1 end -- an item slot, not coin
    env.loot = { { name = "Rare Ring", q = 1, src = { { MOB, 1 } } } } -- no link yet
    ns.Dispatch("LOOT_READY")
    env.loot[1].id = 200
    ns.Dispatch("LOOT_OPENED")
    ns.Dispatch("LOOT_CLOSED")
    env.loot = {}
    _G.GetLootSlotType = nil
    eq(ns.db.sources[1234].loot[200].d, 1)
end)

test("AoE loot splits items by source", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    for _, g in ipairs({ MOB, MOB2, OTHER }) do
        Damage(env, ns, g)
        Die(env, ns, g)
    end
    Loot(env, ns, {
        { id = 100, name = "Linen Cloth", q = 3, src = { { MOB, 1 }, { MOB2, 2 } } },
        { id = 200, name = "Rare Ring", q = 1, src = { { OTHER, 1 } } },
    })
    local kob, other = ns.db.sources[1234], ns.db.sources[5678]
    eq(kob.kills, 2)
    eq(kob.attempts, 2)
    eq(kob.loot[100].d, 2)
    eq(kob.loot[100].q, 3)
    eq(other.loot[200].d, 1)
    eq(other.loot[100], nil)
end)

test("gathering cast attributes node loot", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    ns.Dispatch("UNIT_SPELLCAST_SENT", "player", "Silverleaf", "Cast-3-1", 2366)
    ns.Dispatch("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-1", 2366)
    Loot(env, ns, { { id = 765, name = "Silverleaf", q = 2, src = { { NODE, 2 } } } })
    local rec = ns.db.sources["go:1617"]
    ok(rec, "node source exists")
    eq(rec.kind, "herb")
    eq(rec.name, "Silverleaf")
    eq(rec.attempts, 1)
    eq(rec.loot[765].q, 2)
end)

test("fishing is tracked per zone", function()
    local env = Env({ map = 1411 })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    ns.Dispatch("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-2", 7620)
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 1, src = { { "GameObject-0-1-0-1-35591-01", 1 } } } })
    ok(ns.db.sources["fish:1411"], "fish source keyed by map")
    eq(ns.db.sources["fish:1411"].kind, "fish")
end)

test("only own loot messages count as received", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local got = {}
    ns.On("RECEIVED", function(id, q) got[#got + 1] = { id, q } end)
    ns.Dispatch("CHAT_MSG_LOOT", "Bob receives loot: |cffffffff|Hitem:100::|h[Linen Cloth]|h|r.")
    eq(#got, 0)
    ns.Dispatch("CHAT_MSG_LOOT", "You receive loot: |cffffffff|Hitem:100::|h[Linen Cloth]|h|rx3.")
    ns.Dispatch("CHAT_MSG_LOOT", "You receive loot: |cffffffff|Hitem:200::|h[Rare Ring]|h|r.")
    eq(#got, 2)
    eq(got[1][1], 100)
    eq(got[1][2], 3)
    eq(got[2][1], 200)
    eq(got[2][2], 1)
end)

test("coin looted is attributed to the source", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    Damage(env, ns, MOB)
    Die(env, ns, MOB)
    env.loot = { { name = "12 Copper", q = 0, src = { { MOB, 0 } } } }
    ns.Dispatch("LOOT_OPENED")
    env.money = 12
    ns.Dispatch("PLAYER_MONEY")
    ns.Dispatch("LOOT_CLOSED")
    eq(ns.db.sources[1234].money, 12)
end)

test("dry streak and calibration recorded", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    for i = 1, 40 do
        local g = string.format("Creature-0-1-0-1-1234-%010d", i)
        Damage(env, ns, g)
        Die(env, ns, g)
        local slots = { { id = 100, name = "Linen Cloth", q = 1, src = { { g, 1 } } } }
        if i % 4 == 0 then slots[2] = { id = 200, name = "Rare Ring", q = 1, src = { { g, 1 } } } end
        Loot(env, ns, slots)
        Stub.T.now = Stub.T.now + 20
    end
    local rec = ns.db.sources[1234]
    eq(rec.kills, 40)
    eq(rec.loot[200].d, 10)
    eq(rec.streak[200], 0)
    ok(ns.db.kpi.cal[10] and ns.db.kpi.cal[10].c == 10, "100% bin calibrated for linen")
    ok(rec.pk >= 30, "pace measured")
    local pace = ns.Nav.Pace(1234)
    near(pace, 180, 1, "one kill every 20s = 180/h")
end)

-- ---------------------------------------------------------------- prices / AH

test("price history rollup", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local P = ns.Prices
    P.Commit(100, { { p = 100, q = 5 }, { p = 120, q = 5 } })
    P.Commit(100, { { p = 80, q = 5 }, { p = 140, q = 5 } })
    local day = P.Day()
    local d = ns.db.ah[100].days[day]
    eq(d.c, 2)
    eq(d.mi, 80)
    eq(d.mx, 140)
    local g = P.Get(100)
    eq(g.min, 80)
    eq(g.max, 140)
    ok(g.market > 0 and g.avg > 0)
    Stub.T.now = Stub.T.now + 86400
    P.Commit(100, { { p = 200, q = 1 } })
    eq(#P.History(100), 2)
    ok(P.Get(100).market > 150, "market leans to latest day")
    P.Commit(100, {})
    eq(P.Get(100).min, nil, "empty scan = nothing listed now")
    eq(P.Get(100).max, 200, "history kept")
end)

-- Fake C_AuctionHouse: results[itemId] = { rows = {...}, batches = { n1, n2, ... } } (rows visible per answer)
local function FakeAH(results, opts)
    opts = opts or {}
    local ah = { sent = {}, more = 0, replicated = 0, shown = {} }
    _G.Enum = { AuctionHouseSortOrder = { Price = 0 } }
    _G.C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id } end,
        SendSearchQuery = function(key)
            if opts.fail then error(opts.fail) end
            ah.sent[#ah.sent + 1] = key.itemID
            ah.shown[key.itemID] = 1
        end,
        IsThrottledMessageSystemReady = function() return true end,
        GetNumCommoditySearchResults = function(id)
            local r = results[id]
            return r and r.batches[ah.shown[id] or 1] or 0
        end,
        HasFullCommoditySearchResults = function(id)
            local r = results[id]
            return not r or (ah.shown[id] or 1) >= #r.batches
        end,
        RequestMoreCommoditySearchResults = function(id)
            ah.more = ah.more + 1
            ah.shown[id] = (ah.shown[id] or 1) + 1
        end,
        GetCommoditySearchResultInfo = function(id, i) return results[id].rows[i] end,
        ReplicateItems = function() ah.replicated = ah.replicated + 1 end,
        -- opts.replicate: full scan rows { itemId, count, buyout }
        GetNumReplicateItems = function() return opts.replicate and #opts.replicate or 0 end,
        GetReplicateItemInfo = function(i)
            -- r[4]: the row's item name (default "x", false = not in the item cache), r[5] icon, r[6] quality
            local r = opts.replicate[i + 1]
            local name = r[4]
            if name == nil then
                name = "x"
            elseif name == false then
                name = nil
            end
            return name, r[5], r[2], r[6] or 1, true, 0, nil, 0, 0, r[3], 0, false, 0, 0, nil, true, r[1], true
        end,
    }
    local info = _G.C_AuctionHouse.GetCommoditySearchResultInfo
    _G.C_AuctionHouse.GetCommoditySearchResultInfo = function(id, i)
        ah.rowReads = (ah.rowReads or 0) + 1
        return info(id, i)
    end
    return ah
end

local function Rows(n, price)
    local rows = {}
    for i = 1, n do
        rows[i] = { unitPrice = price + i, quantity = 2 }
    end
    return rows
end

local function OpenAH(ns, lastFullScan)
    ns.db.meta.lastFullScan = lastFullScan
    ns.Dispatch("AUCTION_HOUSE_SHOW")
    Advance(ns, 2)
end

test("modern adapter follows up with *_ADDED results", function()
    local env = Env()
    local fake = FakeAH({ [100] = { rows = Rows(6, 50), batches = { 3, 6 } } })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    OpenAH(ns, Stub.T.epoch + Stub.T.now)
    eq(ns.AH.adapter.name, "modern")
    ns.AH.Stop()
    ns.AH.Queue(100)
    Advance(ns, 0.2)
    eq(#fake.sent, 1)
    ns.Dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 100)
    eq(fake.more, 1, "asked for more rows")
    eq(ns.db.ah[100], nil, "not committed while incomplete")
    ns.Dispatch("COMMODITY_SEARCH_RESULTS_ADDED", 100)
    eq(ns.db.ah[100].last.q, 12, "all 6 rows committed")
    eq(ns.db.ah[100].last.mi, 51)
    eq(ns.AH.stats.done, 1)
end)

test("timed-out search keeps partial results", function()
    local env = Env()
    FakeAH({ [100] = { rows = Rows(6, 50), batches = { 3, 6 } } })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    OpenAH(ns, Stub.T.epoch + Stub.T.now)
    ns.AH.Stop()
    ns.AH.Queue(100)
    Advance(ns, 0.2)
    ns.Dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 100)
    Advance(ns, 11)
    eq(ns.db.ah[100].last.q, 6, "first 3 rows kept")
    eq(ns.AH.stats.partial, 1)
end)

test("failing searches are reported and stop the queue", function()
    local env = Env()
    FakeAH({}, { fail = "search not allowed" })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    OpenAH(ns, Stub.T.epoch + Stub.T.now)
    ns.AH.Stop()
    for id = 1, 10 do
        ns.AH.Queue(id)
    end
    Advance(ns, 1)
    eq(ns.AH.stats.errors, 5)
    eq(#ns.AH.queue, 0, "queue stopped")
    ok(ns.AH.Status():find("search not allowed"), "error shown in status")
    local found
    for _, m in ipairs(Stub.chat) do
        if m:find("not answered") then found = true end
    end
    ok(found, "player told")
end)

test("auto scan runs full scan when old, else searches stale items", function()
    local env = Env()
    local fake = FakeAH({})
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    ns.Store.Item(100).src[1234] = true
    OpenAH(ns, nil)
    eq(fake.replicated, 1, "full scan on first open")
    ns.Dispatch("AUCTION_HOUSE_CLOSED")
    OpenAH(ns, Stub.T.epoch + Stub.T.now - 60)
    eq(fake.replicated, 1, "no second full scan within the hour")
    eq(fake.sent[1], 100, "stale item searched instead")
end)

test("full scan: rows are read and saved a few milliseconds per frame, as price levels", function()
    local rows = {}
    for i = 1, 3000 do
        -- item 100: 2000 auctions at 10 different unit prices; item 200: 1000 auctions of 5 at 50 each
        if i <= 2000 then
            rows[i] = { 100, 2, 2 * (100 + i % 10) }
        else
            rows[i] = { 200, 5, 250 }
        end
    end
    local fake = FakeAH({}, { replicate = rows })
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local clock = 0
    _G.debugprofilestop = function()
        clock = clock + 0.05 -- 20 clock reads per millisecond
        return clock
    end
    OpenAH(ns, nil)
    eq(fake.replicated, 1)
    ns.Dispatch("REPLICATE_ITEM_LIST_UPDATE")
    local frames = 0
    while not ns.db.ah[200] and frames < 2000 do
        frames = frames + 1
        ns.Tick(0.016)
        Stub.T.now = Stub.T.now + 0.016
    end
    ok(frames > 3, "spread over frames: " .. frames)
    local a, b = ns.db.ah[100].last, ns.db.ah[200].last
    eq(a.q, 4000)
    eq(a.mi, 100)
    eq(a.mx, 109)
    eq(b.q, 5000)
    eq(b.md, 50)
    local listings = {}
    for i = 1, 2000 do
        listings[i] = { p = rows[i][3] / rows[i][2], q = rows[i][2] }
    end
    local s = ns.Stats.Summarize(listings)
    eq(a.md, s.md, "same median as from single listings")
    eq(a.mn, s.mn, "same trimmed mean")
end)

test("price summary from levels equals the one from listings", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local listings, levels = {}, {}
    for i = 1, 400 do
        local p, q = 100 + (i * 37) % 50, 1 + i % 4
        listings[i] = { p = p, q = q }
        levels[p] = (levels[p] or 0) + q
    end
    listings[401], levels[99999] = { p = 99999, q = 1 }, 1
    local a, b = ns.Stats.Summarize(listings), ns.Stats.SummarizeLevels(levels)
    for _, f in ipairs({ "mi", "md", "mn", "mx", "q" }) do
        eq(a[f], b[f], f)
    end
    eq(a.l, 401, "listings counted")
    eq(ns.Stats.SummarizeLevels({}), nil)
end)

test("the AH window's own results are only read when they will be recorded", function()
    local fake = FakeAH({ [200] = { rows = Rows(400, 90), batches = { 400 } } })
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    OpenAH(ns, Stub.T.epoch + Stub.T.now)
    ns.AH.Stop()
    fake.shown[200] = 1
    ns.Dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 200)
    eq(ns.AH.stats.passive, 1)
    local reads = fake.rowReads
    for _ = 1, 10 do
        ns.Dispatch("COMMODITY_SEARCH_RESULTS_ADDED", 200) -- scrolling in the AH window
    end
    eq(fake.rowReads, reads, "no rows read during the cooldown")
end)

test("guild sync only shares prices of items WorldCodex tracks", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local rec = ns.Store.EnsureSource(1234, "Kobold", "mob")
    rec.kills, rec.lb, rec.attempts = 30, 30, 30
    ns.Store.AddDrop(1234, rec, 100, 1, "Linen Cloth") -- item 100 drops from the kobold
    for id = 5000, 5100 do
        ns.Prices.Commit(id, { { p = 10, q = 1 } })
    end
    ns.Prices.Commit(100, { { p = 12, q = 1 } })
    ns.db.farm.goals[765] = { count = 20 }
    ns.Prices.Commit(765, { { p = 7, q = 1 } })
    local snap = ns.Store.Snapshot({ minN = 3, ah = true, ahRelevant = true })
    ok(snap.ah[100] and snap.ah[765], "drops and farming goals")
    eq(snap.ah[5000], nil, "not every item of a full scan")
    ok(ns.Store.Snapshot({ ah = true }).ah[5000], "share strings keep all prices")
end)

test("watchdog records slow WorldCodex calls and long frames with WorldCodex's share", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local clock = 0
    _G.debugprofilestop = function() return clock end
    ns.RegisterEvent("BAG_UPDATE", function() clock = clock + 120 end)
    ns.Dispatch("BAG_UPDATE")
    local call = ns.slow.calls[1]
    ok(call and call.ms == 120 and call.what:find("event BAG_UPDATE", 1, true), call and call.what)
    Stub.T.now = Stub.T.now + 10 -- well after the loading screen
    ns.Tick(0.8)
    local fr = ns.slow.frames[1]
    ok(fr, "long frame kept")
    eq(fr.ms, 800)
    eq(fr.mine, 120, "WorldCodex's part of it")
    ok(fr.top:find("BAG_UPDATE", 1, true))
    ns.Tick(0.016)
    eq(#ns.slow.frames, 1, "short frames are not kept")
    eq(ns.db.perfLog, ns.slow, "kept in the saved file")
end)

test("an empty realm name from the client falls back to GetRealmName", function()
    local env = Env({ saved = { settings = {}, meta = { uid = "abcd00001111", rev = 1, realm = "" } } })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    _G.GetNormalizedRealmName = function() return "" end
    _G.GetRealmName = function() return "Die Aldor" end
    ns.Dispatch("PLAYER_LOGIN")
    eq(ns.db.meta.realm, "DieAldor")
    _G.GetRealmName = nil
end)

test("a handler that fails over and over reaches the error handler once a minute", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local reported = 0
    _G.geterrorhandler = function()
        return function() reported = reported + 1 end
    end
    ns.RegisterEvent("UNIT_AURA", function() error("boom") end)
    for _ = 1, 200 do
        ns.Dispatch("UNIT_AURA", "nameplate1")
    end
    eq(reported, 1, "passed on once")
    local msg, e = next(ns.errors)
    ok(msg:find("boom", 1, true))
    eq(e.n, 200, "but counted")
    Advance(ns, 61)
    ns.Dispatch("UNIT_AURA", "nameplate1")
    eq(reported, 2, "again after a minute")
end)

test("secret values from unit, loot and tooltip APIs are ignored without errors", function()
    local env = Env()
    local calls = {}
    _G.TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) calls[kind] = fn end }
    _G.Enum = { TooltipDataType = { Item = 0, Unit = 2, Object = 4 } }
    local ns = Stub.Boot(ROOT, env)
    _G.issecretvalue = function(v) return v == MOB end -- the client hides this GUID (combat, instance)
    env.units.target = { guid = MOB, name = "Kobold" }
    ns.Dispatch("PLAYER_TARGET_CHANGED")
    ns.Dispatch("UNIT_HEALTH", "target")
    eq(ns.Collector._State().tagged[MOB], nil, "secret unit not tracked")
    eq(ns.GuidType(MOB), nil)
    -- loot whose source GUID is secret is not credited to that mob
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 1, src = { { MOB, 1 } } } })
    eq(ns.db.sources[1234], nil)
    -- tooltip of a unit with a secret GUID: no lines, no error
    local lines = {}
    _G.GameTooltip.AddLine = function(_, text) lines[#lines + 1] = tostring(text) end
    _G.GameTooltip.AddDoubleLine = function(_, a) lines[#lines + 1] = tostring(a) end
    calls[2](_G.GameTooltip, { guid = MOB })
    eq(#lines, 0)
    eq(next(ns.errors), nil, "no errors")
    _G.issecretvalue = nil
    _G.TooltipDataProcessor, _G.Enum = nil, nil
end)

test("mobs recorded without a name (secret unit names in instances) get it from the npc id", function()
    local env = Env({
        saved = {
            settings = {},
            -- recorded in a dungeon before: npc id only
            sources = {
                [11321] = { kind = "mob", kills = 3, lb = 3, attempts = 3, loot = { [100] = { d = 1, q = 1 } } },
            },
        },
    })
    local cached, asked = {}, 0
    _G.C_TooltipInfo = {
        GetHyperlink = function(link)
            asked = asked + 1
            if not cached[link] then
                cached[link] = true -- not in the creature cache yet: the client asks the server
                return { lines = {} }
            end
            local id = tonumber(link:match("(%d+)$"))
            local names = { [11321] = "Molten Elemental", [11320] = "Earthborer" }
            return names[id] and { lines = { { leftText = names[id] } } } or nil
        end,
    }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    eq(ns.db.sources[11321].name, nil, "not cached yet at login")
    local skin = ns.Store.EnsureSource("skin:11321", nil, "skin")
    ns.Store.EnsureSource("go:1617", nil, "herb") -- objects are not creatures
    Advance(ns, 4) -- a retry after a few seconds, also in combat
    eq(ns.db.sources[11321].name, "Molten Elemental")
    eq(skin.name, "Molten Elemental", "corpse gathering sources too")
    -- a creature the client already knows is named when it is recorded
    cached["unit:Creature-0-0-0-0-11320"] = true
    eq(ns.Store.EnsureSource(11320, nil, "mob").name, "Earthborer", "named right away")
    local before = asked
    Advance(ns, 30)
    eq(asked, before, "nothing left to look up")
    _G.C_TooltipInfo = nil
end)

test("displays never show a bare npc id when the creature cache knows the name", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local rec = ns.Store.EnsureSource(11320, nil, "mob")
    rec.kills, rec.lb, rec.attempts = 2, 2, 2
    eq((ns.Store.SourceMeta(11320)), "11320", "no name anywhere yet")
    _G.C_TooltipInfo = {
        GetHyperlink = function() return { lines = { { leftText = "Erdbohrer" } } } end,
    }
    Advance(ns, 4)
    eq((ns.Store.SourceMeta(11320)), "Erdbohrer")
    _G.C_TooltipInfo = nil
end)

test("dungeon mob tooltip: hidden GUID, the mob is found by its name", function()
    local calls = {}
    _G.TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) calls[kind] = fn end }
    _G.Enum = { TooltipDataType = { Item = 0, Unit = 2, Object = 4 } }
    local ns = Stub.Boot(ROOT, Env())
    local rec = ns.Store.EnsureSource(11320, "Erdbohrer", "mob")
    rec.kills, rec.lb, rec.attempts = 2, 2, 2
    ns.Store.AddDrop(11320, rec, 100, 2, "Linen Cloth")
    local hidden = "Creature-0-1-0-1-11320-0000ABCD01"
    _G.issecretvalue = function(v) return v == hidden end
    local lines = {}
    _G.GameTooltip.AddLine = function(_, text) lines[#lines + 1] = tostring(text) end
    _G.GameTooltip.AddDoubleLine = function(_, a, b) lines[#lines + 1] = tostring(a) .. " | " .. tostring(b) end
    calls[2](_G.GameTooltip, { guid = hidden, lines = { { leftText = "Erdbohrer" } } })
    local text = table.concat(lines, "\n")
    ok(text:find("Linen Cloth", 1, true), "drops shown: " .. text)
    eq(ns.secrets["tooltip guid"], 1, "hidden GUID counted for the diagnostics")
    _G.issecretvalue, _G.TooltipDataProcessor, _G.Enum = nil, nil, nil
end)

test("in instances (no position) the zone is recorded and shown as the location", function()
    local env = Env({ map = 213 }) -- e.g. Ragefire Chasm
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    _G.C_Map.GetPlayerMapPosition = function() return nil end -- instances: no coordinates for addons
    _G.C_Map.GetMapInfo = function(id) return { name = id == 213 and "Flammenschlund" or ("Map" .. id) } end
    Damage(env, ns, MOB)
    Die(env, ns, MOB)
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 1, src = { { MOB, 1 } } } })
    local rec = ns.db.sources[1234]
    eq(rec.zn[213], 1, "zone counted")
    eq(next(rec.spawns), nil, "no position invented")
    eq(ns.Lookup.Zones(1234)[1].name, "Flammenschlund")
    local facts = ns.Report.SourceFacts(1234)
    ok(ns.Report.FactsText(facts):find("Location: Flammenschlund", 1, true), "location in the details")
    ok(ns.Report.ItemDetail(100):find("Flammenschlund", 1, true), "zone next to the item's source")
    local snap = ns.Store.ValidateSnapshot(ns.Codec.Decode(ns.Report.ExportString()))
    eq(snap.src[1234].zn[213], 1, "shared")
    ns.db.meta.uid = "someoneelse00000"
    ns.db.sources[1234] = nil
    ns.Store.indexDirty = true
    ok(ns.Store.ImportPeer("p1", snap))
    eq(ns.Store.ZoneCounts(1234)[213], 1, "zone from a peer")
end)

test("instances without even a map id: the instance is the zone", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    _G.C_Map.GetBestMapForUnit = function() return nil end -- confirmed on WoW Forever in dungeons
    _G.IsInInstance = function() return true, "party" end
    _G.GetInstanceInfo = function() return "Flammenschlund", "party", 1, "Normal", 5, 0, false, 389 end
    Damage(env, ns, MOB)
    Die(env, ns, MOB)
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 1, src = { { MOB, 1 } } } })
    eq(ns.db.sources[1234].zn[-389], 1, "keyed by the negative instance id")
    eq(ns.Lookup.Zones(1234)[1].name, "Flammenschlund")
    ok(ns.Report.ItemDetail(100):find("Flammenschlund", 1, true), "where the item drops")
    eq(ns.Collector.LootLog()[1].zone, -389, "loot log says which instance")
    local snap = ns.Store.ValidateSnapshot(ns.Codec.Decode(ns.Report.ExportString()))
    eq(snap.src[1234].zn[-389], 1, "negative instance ids survive validation")
    ns.db.maps[-389] = nil
    eq(ns.MapName(-389), "Instance 389", "an instance this client has no name for")
    _G.IsInInstance, _G.GetInstanceInfo = nil, nil
end)

test("names hidden inside the dungeon are looked up after leaving it", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local inside = true
    _G.issecretvalue = function(v) return v == "HIDDEN" end
    _G.C_TooltipInfo = {
        GetHyperlink = function()
            if inside then return { lines = { { leftText = "HIDDEN" } } } end
            return { lines = { { leftText = "Ragefire Trogg" } } }
        end,
    }
    local rec = ns.Store.EnsureSource(11318, nil, "mob")
    rec.kills, rec.lb, rec.attempts = 2, 2, 2
    Advance(ns, 300) -- a long dungeon run: far more than the tries a normal miss gets
    eq(rec.name, nil, "hidden in the dungeon")
    inside = false
    Advance(ns, 5)
    eq(rec.name, "Ragefire Trogg", "hidden lookups were not counted as failures")
    _G.C_TooltipInfo.GetHyperlink = function() return nil end
    local other = ns.Store.EnsureSource(11319, nil, "mob")
    Advance(ns, 300)
    _G.C_TooltipInfo.GetHyperlink = function() return { lines = { { leftText = "Ragefire Shaman" } } } end
    Advance(ns, 10)
    eq(other.name, nil, "a real miss gives up after a while")
    ns.Dispatch("PLAYER_ENTERING_WORLD")
    Advance(ns, 5)
    eq(other.name, "Ragefire Shaman", "and is asked again in the next zone")
    _G.issecretvalue, _G.C_TooltipInfo = nil, nil
end)

test("an empty loot window without any source records nothing", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    Loot(env, ns, {})
    eq(ns.db.sources["kind:other"], nil)
    ok(ns.Collector.LootLog()[1].empty, "but it is in the loot log")
end)

test("the sources list has a zone column (instances: the dungeon)", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env)
    _G.C_Map.GetBestMapForUnit = function() return nil end
    _G.IsInInstance = function() return true, "party" end
    _G.GetInstanceInfo = function() return "Flammenschlund", "party", 1, "Normal", 5, 0, false, 389 end
    Damage(env, ns, MOB)
    Die(env, ns, MOB)
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 1, src = { { MOB, 1 } } } })
    ns.Browser.Toggle("sources")
    local row
    for _, r in ipairs(ns.Page._State().rows) do
        if r.id == 1234 then row = r end
    end
    ok(row, "kobold listed")
    local zone
    for _, col in ipairs(ns.Page.types.list.Columns["list:sources"]) do
        if col.key == "zone" then zone = col.text(row) end
    end
    eq(zone, "Flammenschlund")
    _G.IsInInstance, _G.GetInstanceInfo = nil, nil
end)

test("dungeon mobs get level and classification from the looted corpse under the mouse", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local hidden = "Creature-0-1-0-1-1234-HIDDEN"
    env.units.mouseover = { guid = hidden, dead = true, level = 15, classification = "elite" }
    _G.issecretvalue = function(v) return v == hidden end
    -- the loot window still names the corpse
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 1, src = { { MOB, 1 } } } })
    local rec = ns.db.sources[1234]
    eq(rec.lmin, 15)
    eq(rec.lmax, 15)
    eq(rec.cls, "elite")
    ok(ns.Collector.LootLog()[1].corpse, "noted in the loot log")
    -- several corpses in one window: whose level it is would be a guess
    env.units.mouseover.level = 60
    Loot(env, ns, {
        { id = 100, name = "Linen Cloth", q = 1, src = { { MOB2, 1 } } },
        { id = 200, name = "Rare Ring", q = 1, src = { { OTHER, 1 } } },
    })
    eq(rec.lmax, 15, "not taken")
    _G.issecretvalue = nil
end)

test("mob tooltip through the tooltip data callback (readable GUID)", function()
    local calls = {}
    _G.TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) calls[kind] = fn end }
    _G.Enum = { TooltipDataType = { Item = 0, Unit = 2, Object = 4 } }
    local ns = Stub.Boot(ROOT, Env())
    local rec = ns.Store.EnsureSource(1234, "Kobold", "mob")
    rec.kills, rec.lb, rec.attempts = 10, 10, 10
    ns.Store.AddDrop(1234, rec, 100, 1, "Linen Cloth")
    local lines = {}
    _G.GameTooltip.AddLine = function(_, text) lines[#lines + 1] = tostring(text) end
    _G.GameTooltip.AddDoubleLine = function(_, a, b) lines[#lines + 1] = tostring(a) .. " | " .. tostring(b) end
    calls[2](_G.GameTooltip, { guid = MOB, lines = { { leftText = "Kobold" } } })
    ok(table.concat(lines, "\n"):find("Linen Cloth", 1, true), "drops shown")
    eq(ns.counts["unit tooltip"], 1)
    eq(ns.counts["unit tooltip: lines added"], 1)
    _G.TooltipDataProcessor, _G.Enum = nil, nil
end)

test("scan button searches immediately and own searches are recorded", function()
    local env = Env()
    local fake =
        FakeAH({ [100] = { rows = Rows(2, 10), batches = { 2 } }, [200] = { rows = Rows(4, 90), batches = { 4 } } })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    OpenAH(ns, Stub.T.epoch + Stub.T.now)
    ns.AH.Stop()
    ok(ns.AH.SearchNow(100), "started without waiting for a frame")
    eq(fake.sent[#fake.sent], 100)
    ns.Dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 100)
    eq(ns.db.ah[100].last.q, 4)
    fake.shown[200] = 1
    ns.Dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 200)
    eq(ns.db.ah[200].last.mi, 91, "search made in the AH window recorded")
    eq(ns.AH.stats.passive, 1)
    ns.Dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 200)
    eq(ns.AH.stats.passive, 1, "repeated events not double recorded")
end)

-- ---------------------------------------------------------------- layers / sync

local function SeedKobold(ns, kills, drops)
    local rec = ns.Store.EnsureSource(1234, "Kobold", "mob")
    rec.kills, rec.attempts, rec.lb = kills, kills, kills
    rec.loot[100] = { d = drops, q = drops }
    ns.Store.Item(100).src[1234] = true
    ns.Store.AddSpawn(rec, 1429, 0.40, 0.60)
    ns.Store.indexDirty = true
    return rec
end

test("sync transfers a snapshot and never double counts", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    SeedKobold(ns, 50, 10)
    ns.Sync.SendSnapshot("WHISPER", "Bob")
    Advance(ns, 60)
    local chunks = {}
    for _, m in ipairs(Stub.sent) do
        if m.msg:sub(1, 2) == "D:" then chunks[#chunks + 1] = m.msg end
    end
    ok(#chunks >= 1, "chunks sent")
    for _, m in ipairs(Stub.sent) do
        ok(#m.msg <= 255, "message size")
    end
    ns.db.meta.uid = "receiveruid00000"
    for _, msg in ipairs(chunks) do
        ns.Sync.OnMessage("WorldCodex", msg, "WHISPER", "Alice-TestRealm")
    end
    ok(ns.db.peers["Alice-TestRealm"], "peer imported")
    local d, n = ns.Store.Combined(1234, 100)
    eq(n, 100)
    eq(d, 20)
    for _, msg in ipairs(chunks) do
        ns.Sync.OnMessage("WorldCodex", msg:gsub("^D:(%w+)", "D:%1x"), "WHISPER", "Alice-TestRealm")
    end
    d, n = ns.Store.Combined(1234, 100)
    eq(n, 100, "re-sent data replaces, not adds")
    eq(d, 20)
end)

test("advertise triggers a request for newer data", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    ns.Sync.OnMessage("WorldCodex", "V:abcdef0123456789:5", "GUILD", "Bob-TestRealm")
    Advance(ns, 2)
    local found
    for _, m in ipairs(Stub.sent) do
        if m.msg == "Q:abcdef0123456789" and m.target == "Bob-TestRealm" then found = true end
    end
    ok(found, "request whispered")
end)

test("no addon messages inside instances (the client blocks them): they wait until outside", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local inside = true
    _G.IsInInstance = function() return inside, inside and "party" or "none" end
    ns.Sync.Advertise()
    ns.Sync.OnMessage("WorldCodex", "V:abcdef0123456789:5", "GUILD", "Bob-TestRealm")
    Advance(ns, 30)
    eq(#Stub.sent, 0, "nothing sent in the dungeon")
    inside = false
    Advance(ns, 3)
    local found
    for _, m in ipairs(Stub.sent) do
        if m.msg == "Q:abcdef0123456789" then found = true end
    end
    ok(found, "the request went out after leaving")
    _G.IsInInstance = nil
end)

test("client restriction state and hidden unit identity are read through the client's own API", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    eq(ns.Restricted("Combat"), nil, "unknown without the API")
    _G.Enum = { AddOnRestrictionType = { Combat = 0, Map = 4, Chat = 5 } }
    local active = {}
    _G.C_RestrictedActions = {
        GetAddOnRestrictionState = function(kind) return active[kind] or 0 end,
    }
    eq(ns.Restricted("Combat"), false)
    eq(ns.Sync.CanSend(), true)
    active[5] = 2 -- Enum.AddOnRestrictionState.Active
    eq(ns.Restricted("Chat"), true)
    eq(ns.Sync.CanSend(), false, "addon chat restricted: no addon messages")
    active[5], active[4] = 0, 1 -- Activating counts as restricted
    eq(ns.Sync.CanSend(), false, "restricted map")
    _G.C_Secrets = { ShouldUnitIdentityBeSecret = function(unit) return unit == "nameplate1" end }
    env.units.nameplate1 = { guid = MOB, name = "Kobold" }
    ns.Collector.ObserveUnit("nameplate1")
    eq(ns.Collector._State().tagged[MOB], nil, "hidden unit skipped")
    eq(ns.counts["units hidden"], 1)
    _G.Enum, _G.C_RestrictedActions, _G.C_Secrets = nil, nil, nil
end)

test("farming goals count items through C_Item (no global GetItemCount on WoW Forever)", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local global = _G.GetItemCount
    _G.GetItemCount = nil
    _G.C_Item = _G.C_Item or {}
    local cItem = _G.C_Item.GetItemCount
    _G.C_Item.GetItemCount = function(id) return id == 100 and 7 or 0 end
    ns.Farm.SetGoal(100, 20)
    eq((ns.Farm.GoalProgress(100)), 7)
    _G.GetItemCount, _G.C_Item.GetItemCount = global, cItem
end)

test("snapshot validation rejects bad data", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local clean = ns.Store.ValidateSnapshot({
        v = 1,
        uid = "x",
        src = {
            [1] = { n = 10, l = { [100] = { 20, 20 } } },
            [2] = { n = -5, l = {} },
            [3] = { n = 10, l = { [100] = { 3, 4 } }, nm = "A|cffff0000B" },
        },
    })
    eq(clean.src[1].l[100], nil, "d > n rejected")
    eq(clean.src[2], nil, "negative n rejected")
    eq(clean.src[3].l[100][1], 3)
    eq(clean.src[3].nm, "Acffff0000B", "escape codes stripped")
    ok(not ns.Store.ValidateSnapshot({ v = 2, src = {} }))
end)

test("import string from another player", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    SeedKobold(ns, 30, 3)
    local str = ns.Report.ExportString()
    ns.db.meta.uid = "someoneelse00000"
    local okk, n = ns.Report.Import(str)
    ok(okk, tostring(n))
    eq(n, 1)
    local d, nn = ns.Store.Combined(1234, 100)
    eq(nn, 60)
    eq(d, 6)
end)

test("community layer with own upload uses a baseline", function()
    local env = Env()
    env.saved = {
        version = 3,
        meta = { uid = "me00000000000000", rev = 1 },
        sources = {
            [1234] = {
                name = "Kobold",
                kind = "mob",
                kills = 100,
                attempts = 100,
                loot = { [100] = { d = 20, q = 20 } },
            },
        },
    }
    env.community = {
        version = 1,
        generated = 42,
        contributors = { me00000000000000 = true },
        sources = {
            [1234] = { nm = "Kobold", k = "mob", n = 1100, l = { [100] = { 220, 220 } } },
        },
    }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local d, n = ns.Store.Combined(1234, 100)
    eq(n, 1100, "own data already in community is not added again")
    eq(d, 220)
    ns.db.sources[1234].kills, ns.db.sources[1234].lb = 110, 110
    ns.db.sources[1234].loot[100].d = 21
    d, n = ns.Store.Combined(1234, 100)
    eq(n, 1110, "new data on top of baseline")
    eq(d, 221)
    -- the sources of the numbers: the player's own data stays "me", the upload leaves the community part
    local parts = ns.Store.Parts(1234, 100)
    eq(#parts, 2)
    eq(parts[1].layer, "me")
    eq(parts[1].n, 110, "all own kills, uploaded or not")
    eq(parts[1].d, 21)
    eq(parts[2].layer, "community")
    eq(parts[2].n, 1000, "community without the player's upload")
    eq(parts[2].d, 200)
    local cmp = ns.Store.Compare(1234, 100)
    eq(cmp.mine.n, parts[1].n, "same sides as the you-vs-everyone-else comparison")
    eq(cmp.others.n, parts[2].n)
end)

test("packed community records read like plain ones and are found through the shipped item index", function()
    local env = Env()
    env.saved = {
        version = 3,
        sources = { [5678] = { name = "Gnoll", kind = "mob", kills = 4, lb = 4, loot = { [100] = { d = 1, q = 1 } } } },
    }
    local sources = {
        -- as tools/merge.py write_lua packs them: nm, k, n, m plain, the rest Codec-serialized in "_"
        [1234] = {
            nm = "Kobold",
            k = "mob",
            n = 1100,
            m = 50,
            _ = "{s1:l{n100;{n1;n220;n2;n230;n3;{n1;n210;n2;n10;}}n555;{n1;n3;n2;n3;}}"
                .. "s2:qb{n555;n40;}s2:sp{n1429;{n4040;n3;}}s2:lv{n1;n5;n2;n6;}}",
        },
    }
    for i = 1, 1000 do -- more than the decode cache holds
        sources[20000 + i] =
            { nm = "Mob " .. i, k = "mob", n = i, m = 0, _ = "{s1:l{n" .. (30000 + i) .. ";{n1;n1;n2;n1;}}}" }
    end
    env.community = {
        version = 1,
        generated = 42,
        packed = 1,
        pairs = 1002,
        contributors = {},
        sources = sources,
        ix = { [100] = "{n1;n1234;}", [555] = "{n1;n1234;}" },
        qi = { [555] = true },
    }
    for i = 1, 1000 do
        env.community.ix[30000 + i] = "{n1;n" .. (20000 + i) .. ";}"
    end
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local d, n = ns.Store.Combined(1234, 100)
    eq(n, 1100, "plain field")
    eq(d, 220, "loot from the packed body")
    eq(ns.Store.QtyHist(1234, 100)[2], 10, "stack sizes from the packed body")
    local srcs = ns.Store.SourcesForItem(100)
    ok(srcs[1234] and srcs[5678], "community index and own index together")
    ok(ns.Store.IsGated(555), "quest items of the community file")
    d, n = ns.Store.Combined(1234, 555)
    eq(n, 40, "quest item uses its own sample size")
    eq(d, 3)
    eq(ns.Store.Spawns(1234)[1429][4040], 3, "spawns from the packed body")
    ok(ns.Store.AllItemIds()[30500], "item ids of the community index")
    for i = 1, 1000 do
        local dd, nn = ns.Store.Combined(20000 + i, 30000 + i)
        if dd ~= 1 or nn ~= i then
            error("record " .. i .. " after cache eviction: " .. tostring(dd) .. "/" .. tostring(nn))
        end
    end
    eq(ns.Store.Combined(1234, 100), 220, "evicted records decode again")
    eq(ns.KPI.Compute().communityPairs, 1002, "pair count from the file, nothing decoded")
    ns.db.settings.useCommunity = false
    ns.Fire("SETTINGS_CHANGED", "useCommunity")
    ok(not ns.Store.SourcesForItem(100)[1234], "the community index follows the layer switch")
    ok(ns.Store.SourcesForItem(100)[5678])
end)

test("the shipped community file loads packed and matches its item index", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY, realCommunity = true })
    local c = ns.Store.Community()
    ok(c and c.packed, "the shipped file is packed (regenerate it with tools/merge.py)")
    local checked = 0
    for id, packed in pairs(c.ix) do
        local keys = ns.Codec.Deserialize(packed)
        for _, key in ipairs(keys) do
            ok(type(c.sources[key].l) == "table" and c.sources[key].l[id], "item " .. id .. " at " .. tostring(key))
            checked = checked + 1
        end
    end
    eq(checked, c.pairs, "every pair is in the index")
end)

-- C_Item / C_TooltipInfo for item details (Items.lua); removed again by the test.
local function ItemApis(env, opts)
    local requested = {}
    local function Id(link) return tonumber(tostring(link):match("item:(%d+)")) end
    _G.C_Item = {
        GetItemStats = function(link) return opts.stats[Id(link)] end,
        GetItemInventoryTypeByID = function(id) return opts.slots[id] end,
        GetItemUniqueness = function(id) return 0, opts.unique[id] or 0 end,
        GetItemSpell = function(id)
            if opts.spells[id] then return "Spell", opts.spells[id] end
        end,
        GetItemInfoInstant = function(id)
            local it = env.items[id] or opts.instant[id]
            return id, "", "", "", 0, it and it.classId
        end,
        RequestLoadItemDataByID = function(id) requested[id] = true end,
        IsItemDataCachedByID = function(id) return env.items[id] ~= nil end,
    }
    _G.C_TooltipInfo = { GetItemByID = function(id) return opts.tooltips[id] end }
    _G.DAMAGE_TEMPLATE, _G.SPEED, _G.DURABILITY_TEMPLATE = "%s - %s Schaden", "Tempo", "Haltbarkeit %d / %d"
    _G.ITEM_MOD_STRENGTH_SHORT = "Stärke"
    return requested
end

local function NoItemApis()
    _G.C_Item, _G.C_TooltipInfo = nil, nil
    _G.DAMAGE_TEMPLATE, _G.SPEED, _G.DURABILITY_TEMPLATE, _G.ITEM_MOD_STRENGTH_SHORT = nil, nil, nil, nil
end

local function WeaponTooltip(lo, hi, speed, durability, effect)
    local lines = {
        { leftText = "Gnollschwert", type = 22 },
        { leftText = "Einhand", rightText = "Schwert", type = 21 },
        { leftText = lo .. " - " .. hi .. " Schaden", rightText = "Tempo " .. speed },
        { leftText = "(5,8 Schaden pro Sekunde)" },
        { leftText = "+3 Stärke" },
        { leftText = "Haltbarkeit " .. durability .. " / " .. durability },
    }
    if effect then lines[#lines + 1] = { leftText = "|cff00ff00" .. effect .. "|r", type = 45 } end
    return { lines = lines }
end

test("item details are read from chat links, inspected players, received items and the auction house", function()
    local env = Env()
    env.saved = { version = 3, meta = { uid = "me00000000000000", rev = 1 } }
    env.items[3000] = { name = "Gnollschwert", classId = 2 }
    env.items[4000] = { name = "Heiltrank", classId = 0 }
    env.items[3002] = { name = "Lederhelm", classId = 4 }
    env.units.target = { guid = "Player-1-00000001", name = "Someone" }
    local requested = ItemApis(env, {
        stats = {
            [3000] = { ITEM_MOD_STRENGTH_SHORT = 3, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 5.7692, RESISTANCE0_NAME = 0 },
            [3001] = { RESISTANCE0_NAME = 120 },
            [3002] = { RESISTANCE0_NAME = 40 },
        },
        slots = { [3000] = 13, [3001] = 20, [3002] = 1 },
        unique = { [3000] = 1 },
        spells = { [4000] = 439 },
        instant = { [3001] = { classId = 4 } },
        tooltips = {
            [3000] = WeaponTooltip(5, 10, "2,60", 45, "Anlegen: Erhöht Eure Angriffskraft um 10."),
            [3001] = { lines = { { leftText = "Robe" }, { leftText = "Haltbarkeit 70 / 70" } } },
            [4000] = { lines = { { leftText = "Benutzen: Stellt 70 Gesundheit wieder her.", type = 44 } } },
        },
    })
    _G.GetInventoryItemLink = function(unit, slot)
        if unit == "target" and slot == 5 then return "|cff1eff00|Hitem:3001:0:0:0|h[Robe]|h|r" end
    end
    local ok, err = pcall(function()
        local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
        ns.Dispatch("CHAT_MSG_CHANNEL", "WTS |cff1eff00|Hitem:3000::::::::|h[Gnollschwert]|h|r and |Hitem:100|h[x]|h")
        ns.Dispatch("INSPECT_READY", "Player-1-00000001")
        ns.Fire("RECEIVED", 4000, 1)
        Advance(ns, 1)
        local it = ns.db.items[3000]
        ok(it and it.dv == ns.Items.VERSION, "chat link read")
        eq(it.wd[1], 5)
        eq(it.wd[2], 10)
        eq(it.wd[3], 2600, "German speed with a decimal comma")
        eq(it.du, 45)
        eq(it.st.ITEM_MOD_STRENGTH_SHORT, 3)
        eq(it.st.ITEM_MOD_DAMAGE_PER_SECOND_SHORT, 5.8, "rounded")
        eq(it.st.RESISTANCE0_NAME, nil, "zero stats left out")
        eq(it.iv, 13)
        eq(it.un, 1)
        eq(it.fx[1][1], "equip")
        eq(it.fx[1][2], "Anlegen: Erhöht Eure Angriffskraft um 10.", "colour codes removed")
        eq(it.n, "Gnollschwert", "the item facts are recorded too (the export needs the name)")
        eq(ns.db.items[100], nil, "trade goods without a use spell get no record")
        eq(ns.db.items[4000].us, 439, "use spell of a consumable")
        eq(ns.db.items[4000].fx[1][1], "use")
        eq(ns.db.items[4000].st, nil)
        -- the inspected robe was not in the item cache: requested, read once the client has it
        ok(requested[3001], "item data requested")
        eq(ns.db.items[3001], nil)
        env.items[3001] = { name = "Robe", classId = 4 }
        ns.Dispatch("GET_ITEM_INFO_RECEIVED", 3001, true)
        Advance(ns, 1)
        eq(ns.db.items[3001].st.RESISTANCE0_NAME, 120, "inspected item read after the cache answered")
        eq(ns.db.items[3001].du, 70)
        eq(ns.db.items[3001].wd, nil, "no weapon damage on armour")
        -- an auction house full scan queues its gear
        ns.db.ah[3002] = { last = { t = 1 } }
        ns.db.ah[100] = { last = { t = 1 } }
        ns.Fire("PRICES_UPDATED")
        Advance(ns, 1)
        eq(ns.db.items[3002].st.RESISTANCE0_NAME, 40, "gear from a full scan")
        eq(ns.db.items[100], nil)
        -- read once: a second link does not read again
        local rv = it.rv
        ns.Dispatch("CHAT_MSG_GUILD", "|Hitem:3000|h[x]|h")
        Advance(ns, 1)
        eq(it.rv, rv)

        -- shared: snapshot -> validation keeps the details and drops what is malformed
        -- (a copy: the snapshot shares tables with the saved data)
        local snap = ns.Codec.Deserialize(ns.Codec.Serialize(ns.Store.Snapshot({ items = true })))
        eq(snap.it[3000].wd[3], 2600)
        eq(snap.it[3000].fx[1][1], "equip")
        snap.it[3000].st.BAD_KEY_ = "x"
        snap.it[3000].st["lower"] = 1
        snap.it[3000].fx[2] = { "hack", "text" }
        snap.it[3000].wd = { 10, 5 }
        local clean = ns.Store.ValidateSnapshot(snap)
        eq(clean.it[3000].st.ITEM_MOD_STRENGTH_SHORT, 3)
        eq(clean.it[3000].st.BAD_KEY_, nil)
        eq(clean.it[3000].st.lower, nil)
        eq(#clean.it[3000].fx, 1, "unknown trigger dropped")
        eq(clean.it[3000].wd, nil, "max below min dropped")
        eq(clean.it[4000].us, 439)

        -- the item page shows them with the client's own stat names
        local rows = ns.Report.ItemDetailRows(3000)
        local byLabel = {}
        for _, r in ipairs(rows) do
            if r.label then byLabel[r.label] = r.value end
        end
        eq(byLabel["Damage"], "5 - 10")
        eq(byLabel["Speed"], "2.60")
        eq(byLabel["Damage per second"], "5.8")
        eq(byLabel["Stärke"], "+3")
        eq(byLabel["Durability"], "45")

        local csv = ns.Export.Csv("items")
        local header = csv:match("^[^\n]+")
        local row = csv:match("\n3000,[^\n]+")
        eq(select(2, row:gsub(",", "")), select(2, header:gsub(",", "")), "as many columns as the header")
        ok(row:find(",13,,5,10,2600,45,1,,$"), "detail columns: " .. row)
    end)
    NoItemApis()
    _G.GetInventoryItemLink = nil
    if not ok then error(err, 0) end
end)

test("items the auction house shows are recorded, not only priced", function()
    local env = Env()
    local requested = ItemApis(env, {
        stats = {},
        slots = {},
        unique = {},
        spells = {},
        instant = { [5000] = { classId = 7 }, [6000] = { classId = 7 } },
        tooltips = {},
    })
    local fake = FakeAH({ [765] = { rows = Rows(3, 10), batches = { 3 } } }, {
        replicate = {
            { 100, 1, 10 },
            { 5000, 2, 50, "Kupfererz", 123, 2 }, -- not cached: named by the auction house
            { 5000, 4, 100, "Kupfererz", 123, 2 },
            { 6000, 1, 30, false }, -- not cached, no name either
        },
    })
    local ok, err = pcall(function()
        local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
        OpenAH(ns, nil)
        eq(fake.replicated, 1)
        ns.Dispatch("REPLICATE_ITEM_LIST_UPDATE")
        for _ = 1, 50 do
            Advance(ns, 0.5)
        end
        eq(ns.db.ah[5000].last.q, 6, "priced")
        local it = ns.db.items[5000]
        ok(it, "an item that never dropped gets a record")
        eq(it.n, "Kupfererz", "name from the auction row")
        eq(it.ql, 2)
        eq(it.ic, 123)
        eq(it.cl, 7, "class from GetItemInfoInstant (no cache needed)")
        eq(ns.db.items[100].n, "Linen Cloth", "cached items: the full facts")
        eq(ns.db.items[100].v, 13)
        eq(ns.db.items[6000], nil, "nothing known yet")
        eq(requested[5000], nil, "no load requests for a whole full scan")
        eq(requested[6000], nil)
        -- the client loads the item later (e.g. the player looks at it)
        env.items[6000] = { name = "Zinnerz", classId = 7 }
        ns.Dispatch("GET_ITEM_INFO_RECEIVED", 6000, true)
        eq(ns.db.items[6000].n, "Zinnerz", "completed once cached")
        env.items[5000] = { name = "Kupfererz", classId = 7, ilvl = 10 }
        ns.Dispatch("GET_ITEM_INFO_RECEIVED", 5000, true)
        eq(ns.db.items[5000].il, 10, "facts from the auction row completed")
        local snap = ns.Store.Snapshot({ items = true })
        eq(snap.it[5000].n, "Kupfererz", "shared with the website")
        eq(snap.it[6000].n, "Zinnerz")

        -- browse results (categories, name searches): items without prices
        C_AuctionHouse.GetBrowseResults = function()
            return {
                { itemKey = { itemID = 7000 }, minPrice = 10, totalQuantity = 5 },
                { itemKey = { itemID = 82800, battlePetSpeciesID = 55 }, minPrice = 10, totalQuantity = 1 },
            }
        end
        C_AuctionHouse.GetItemKeyInfo = function(key)
            if key.itemID == 7000 then
                return { itemID = 7000, itemName = "Zauberstoff", quality = 1, iconFileID = 55 }
            end
        end
        ns.Dispatch("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        eq(ns.db.items[7000].n, "Zauberstoff", "browsed item recorded")
        eq(ns.db.items[7000].ic, 55)
        eq(ns.db.ah[7000], nil, "no price from the lowest price alone")
        eq(ns.db.items[82800], nil, "pet cages are skipped")
        ns.Dispatch("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", { { itemKey = { itemID = 765 } } })
        eq(ns.db.items[765].n, "Silverleaf", "added browse results")

        -- the player's own item search
        ns.AH.Stop()
        fake.shown[765] = 1
        ns.db.items[765] = nil
        ns.Dispatch("COMMODITY_SEARCH_RESULTS_UPDATED", 765)
        eq(ns.db.items[765].n, "Silverleaf", "searched item recorded")
    end)
    NoItemApis()
    if not ok then error(err, 0) end
end)

test("item details: trade goods are passed over cheaply and remembered once they have a record", function()
    local env = Env()
    ItemApis(env, { stats = {}, slots = {}, unique = {}, spells = {}, instant = {}, tooltips = {} })
    local ok, err = pcall(function()
        for id = 8000, 8199 do
            env.items[id] = { name = "Ware " .. id, classId = 7 }
        end
        local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
        for id = 8000, 8199 do
            ns.Store.NoteItem(id)
            ns.Items.Queue(id)
        end
        Advance(ns, 1.1) -- a few steps
        eq(ns.Items.Pending(), 0, "200 trade goods checked within a second")
        eq(ns.db.items[8000].dv, ns.Items.VERSION, "remembered: not queued again")
        ns.Items.Queue(8000)
        eq(ns.Items.Pending(), 0)
        eq(ns.db.items[8000].st, nil)
    end)
    NoItemApis()
    if not ok then error(err, 0) end
end)

test("an item page shows the item's own details until a row is selected; equipped gear counts as carried", function()
    local env = Env()
    env.items[3000] = { name = "Gnollschwert", classId = 2 }
    ItemApis(env, {
        stats = { [3000] = { ITEM_MOD_STRENGTH_SHORT = 3 } },
        slots = {},
        unique = {},
        spells = {},
        instant = {},
        tooltips = { [3000] = WeaponTooltip(5, 10, "2,60", 45) },
    })
    _G.GetInventoryItemID = function(unit, slot)
        if unit == "player" and slot == 16 then return 3000 end
    end
    local ok, err = pcall(function()
        local ns = Stub.Boot(ROOT, env)
        ok(ns.BagItems()[3000], "equipped weapon is among the carried items (Bags only list)")
        ok(ns.Page.Show({ type = "item", id = 3000 }), "item page")
        local facts = ns.Page.details
        ok(facts and facts.sections[1], "details panel shown without a selected row")
        local labels = {}
        for _, r in ipairs(facts.sections[1].rows) do
            if r.label then labels[r.label] = r.value end
        end
        eq(labels["Damage"], "5 - 10", "read when the page opened, not only from the queue")
        eq(labels["Stärke"], "+3")
        local diag = ns.Items.Diagnose(3000)
        ok(diag[#diag]:find("wd={n1;n5;", 1, true), "diagnosis shows the record: " .. diag[#diag])

        -- with drops the first source is selected and the right page shows it: the details get a tab
        ns.db.sources[1234] = {
            name = "Kobold",
            kind = "mob",
            kills = 3,
            lb = 3,
            attempts = 0,
            loot = { [3000] = { d = 1, q = 1 } },
            streak = {},
        }
        ns.Store.indexDirty = true
        ns.Fire("DATA_CHANGED")
        local tabs = ns.PageItem.Tabs(3000, "all")
        local ids = {}
        for _, tab in ipairs(tabs) do
            ids[#ids + 1] = tab.id
        end
        eq(table.concat(ids, ","), "drop,details", "drops first, then the item's own tab")
        ok(ns.Page.Show({ type = "item", id = 3000, tab = "details" }), "details tab opens")
        eq(next(ns.errors or {}), nil, "no errors while rendering the tab")
        eq(ns.Page._State().tab, "details")
        eq(table.concat(ns.Page._State().tabs, ","), "drop,details")
    end)
    NoItemApis()
    _G.GetInventoryItemID = nil
    if not ok then error(err, 0) end
end)

test("item details wait for the end of combat", function()
    local env = Env()
    env.items[3000] = { name = "Gnollschwert", classId = 2 }
    ItemApis(env, {
        stats = {},
        slots = {},
        unique = {},
        spells = {},
        instant = {},
        tooltips = { [3000] = WeaponTooltip(5, 10, "2.60", 45) },
    })
    local ok, err = pcall(function()
        local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
        _G.InCombatLockdown = function() return true end
        ns.Dispatch("CHAT_MSG_SAY", "|Hitem:3000|h[x]|h")
        Advance(ns, 1)
        eq(ns.db.items[3000], nil, "nothing read in combat")
        _G.InCombatLockdown = function() return false end
        Advance(ns, 1)
        eq(ns.db.items[3000].wd[3], 2600, "English speed")
    end)
    NoItemApis()
    _G.InCombatLockdown = nil
    if not ok then error(err, 0) end
end)

test("item detail patterns follow the client's format strings", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local p = ns.Items.Pattern("%1$s - %2$s Schaden", "x")
    local lo, hi = ("12 - 23 Schaden"):match(p)
    eq(lo, "12")
    eq(hi, "23")
    eq(("Haltbarkeit 30 / 45"):match(ns.Items.Pattern(nil, "Haltbarkeit %d / %d")), "30")
    ok(not ("(5.8 damage per second)"):match(ns.Items.Pattern(nil, "%s - %s Damage")))
end)

test("analysis explains where the numbers come from in words (German client)", function()
    local env = Env()
    env.locale = "deDE"
    env.items[100] = { name = "Wollstoff" }
    env.saved = {
        version = 3,
        meta = { uid = "me00000000000000", rev = 2 },
        sources = { [1234] = { name = "Pfadfinder", kind = "mob", kills = 1, lb = 1, loot = {} } },
    }
    env.community = {
        version = 1,
        generated = 42,
        contributors = { me00000000000000 = 1 },
        sources = { [1234] = { nm = "Pfadfinder", k = "mob", n = 6, l = { [100] = { 1, 1 } } } },
    }
    local ns = Stub.Boot(ROOT, env)
    ok(ns.Page.Show({ type = "item", id = 100 }), "item page")
    local a = ns.Page.Frame().analysis
    local rate, layers = a.rate:GetText(), a.layersText:GetText()
    ok(rate:find("6 Kills, davon 1 mit Wollstoff", 1, true), "the rate in words: " .. rate)
    ok(rate:find("wahrscheinlich zwischen", 1, true), "the interval in words: " .. rate)
    ok(layers:find("Eigene Daten:|r 1 Kill, davon 0 mit Wollstoff (0.0%)", 1, true), "own data: " .. layers)
    ok(layers:find("Andere Spieler:|r 5 Kills, davon 1 mit Wollstoff (20.0%)", 1, true), "others: " .. layers)
    ok(not layers:find("0/1", 1, true), "no bare fractions")
    eq(
        ns.Report.PartsText(ns.Store.Parts(1234, 100), "mob"),
        "Eigene Daten: 0 von 1 Kill · Andere Spieler: 1 von 5 Kills",
        "short form for tooltips"
    )
end)

test("sources of the numbers leave out a community part that is only the player's upload", function()
    local env = Env()
    env.saved = {
        version = 3,
        meta = { uid = "me00000000000000", rev = 1 },
        sources = {
            [1234] = { name = "Kobold", kind = "mob", kills = 3, lb = 3, loot = { [100] = { d = 1, q = 1 } } },
        },
    }
    env.community = {
        version = 1,
        generated = 42,
        contributors = { me00000000000000 = 1 },
        sources = { [1234] = { nm = "Kobold", k = "mob", n = 3, l = { [100] = { 1, 1 } } } },
    }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local parts = ns.Store.Parts(1234, 100)
    eq(#parts, 1)
    eq(parts[1].layer, "me")
    eq(parts[1].n, 3)
    local d, n = ns.Store.Combined(1234, 100)
    eq(n, 3, "counted once")
    eq(d, 1)
end)

-- ---------------------------------------------------------------- lookup (item and source pages)

-- Personal Kobold data, a guild peer with Kobold data and a community file with Kobold, a Gnoll,
-- skinning of the Kobold and a quest; the player is not a contributor.
local function LayeredEnv()
    local env = Env()
    env.community = {
        version = 1,
        generated = 42,
        contributors = { peer000000000001 = true },
        sources = {
            [1234] = {
                nm = "Kobold",
                k = "mob",
                n = 1000,
                l = { [100] = { 100, 120 } },
                sp = { [1429] = { [4060] = 5 } },
            },
            [5678] = { nm = "Gnoll", k = "mob", n = 4, l = { [100] = { 3, 3 } } },
            ["skin:1234"] = { nm = "Kobold", k = "skin", n = 50, l = { [100] = { 10, 10 } } },
            ["quest:155"] = {
                nm = "The Defias",
                k = "quest",
                n = 10,
                l = { [100] = { 10, 50 } },
                ch = { [100] = true },
            },
        },
    }
    return env
end

local function AddPeer(ns, name, uid, src)
    ns.db.peers[name] = { uid = uid, rev = 1, t = 0, src = src }
    ns.Store.indexDirty = true
end

test("layer switches hide guild and community everywhere, contributor spawns count once", function()
    local ns = Stub.Boot(ROOT, LayeredEnv(), { filter = CORE_ONLY })
    SeedKobold(ns, 40, 8)
    AddPeer(ns, "Alice-TestRealm", "peer000000000001", {
        [1234] = { nm = "Kobold", k = "mob", n = 999, l = { [100] = { 99, 99 } }, sp = { [1429] = { [4060] = 99 } } },
    })
    AddPeer(ns, "Bob-TestRealm", "peer000000000002", {
        [9999] = { nm = "Murloc", k = "mob", n = 30, l = { [100] = { 3, 3 } }, sp = { [12] = { [101] = 2 } } },
    })
    local S = ns.Store
    ok(S.SourcesForItem(100)[5678], "community source indexed")
    ok(S.SourcesForItem(100)[9999], "guild source indexed")
    eq(S.Spawns(1234)[1429][4060], 5 + 1, "contributor peer spawns are not added on top of the community")
    local _, n = S.Combined(1234, 100)
    eq(n, 1040, "contributor peer skipped in counts")

    ns.db.settings.useCommunity = false
    ns.Fire("SETTINGS_CHANGED", "useCommunity", false)
    ok(not S.SourcesForItem(100)[5678], "community source gone from index")
    ok(not S.AllSourceKeys()["skin:1234"], "community keys gone")
    ok(not S.SourceItems(5678)[100], "community items gone")
    eq(next(S.Spawns(5678)), nil, "community spawns gone")
    ok(not S.HasSource(5678))
    ok(S.SourcesForItem(100)[9999], "guild still there")

    ns.db.settings.useGuild = false
    ns.Fire("SETTINGS_CHANGED", "useGuild", false)
    ok(not S.SourcesForItem(100)[9999], "guild source gone")
    eq(S.SourceBaseCombined(9999), 0)
    ok(S.SourcesForItem(100)[1234], "personal stays")
end)

test("item model groups sources into sections and ranks by lower bound", function()
    local ns = Stub.Boot(ROOT, LayeredEnv(), { filter = CORE_ONLY })
    SeedKobold(ns, 40, 8)
    local m = ns.Lookup.ItemModel(100)
    eq(m.order[1], "drop")
    eq(m.order[2], "gather")
    eq(m.order[3], "quest")
    local drops = m.sections.drop
    eq(drops[1].key, 1234, "many observations rank first")
    eq(drops[1].n, 1040)
    eq(drops[2].key, 5678, "few observations last despite 75%")
    local lo, hi = ns.Stats.Wilson(108, 1040)
    near(drops[1].lo, lo)
    near(drops[1].hi, hi)
    eq(m.sections.gather[1].key, "skin:1234")
    local q = m.sections.quest[1]
    ok(q.choice, "quest choice flag")
    eq(m.best.key, "quest:155", "best is the surest rate")
    eq(m.counts.drop, 2)
    eq(ns.Lookup.ItemModel(100), m, "cached")
end)

test("item model cache refreshes after new data", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local rec = SeedKobold(ns, 40, 8)
    local m = ns.Lookup.ItemModel(100)
    eq(m.sections.drop[1].n, 40)
    ns.Store.CountLootBase(1234, rec)
    m = ns.Lookup.ItemModel(100)
    eq(m.sections.drop[1].n, 41, "rev change rebuilds the model")
end)

test("source model lists drops, coin and related skinning", function()
    local ns = Stub.Boot(ROOT, LayeredEnv(), { filter = CORE_ONLY })
    local rec = SeedKobold(ns, 40, 8)
    rec.money, rec.mc, rec.ca, rec.mmin, rec.mmax = 4000, 20, 40, 50, 300
    rec.lmin, rec.lmax, rec.cls = 5, 7, "elite"
    local m = ns.Lookup.SourceModel(1234)
    eq(m.name, "Kobold")
    eq(m.items[1].itemId, 100)
    eq(m.items[1].n, 1040)
    eq(m.related[1].key, "skin:1234", "skinning listed")
    eq(m.personal.kills, 40)
    eq(m.lmin, 5)
    eq(m.cls, "elite")
    eq(m.coin.mine.m, 4000)
    eq(m.zones[1].map, 1429)
    local skin = ns.Lookup.SourceModel("skin:1234")
    eq(skin.parent, 1234, "skinning knows its mob")
    eq(skin.related[1].key, 1234)
    local mine = ns.Lookup.SourceModel(1234, "mine")
    eq(mine.items[1].n, 40, "mine layer only has personal counts")
    local others = ns.Lookup.SourceModel(1234, "others")
    eq(others.items[1].n, 1000)
end)

test("compare takes the own upload out of the community side", function()
    local env = LayeredEnv()
    env.community.contributors.me00000000000000 = true
    env.saved = {
        version = 3,
        meta = { uid = "me00000000000000", rev = 1 },
        sources = {
            [1234] = {
                name = "Kobold",
                kind = "mob",
                kills = 100,
                lb = 100,
                loot = { [100] = { d = 40, q = 40, h = { [1] = 40 } } },
            },
        },
    }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local c = ns.Store.Compare(1234, 100)
    eq(c.mine.n, 100)
    eq(c.mine.d, 40)
    eq(c.others.n, 900, "own 100 corpses removed from the community 1000")
    eq(c.others.d, 60)
    local _, n = ns.Store.Combined(1234, 100)
    eq(n, c.mine.n + c.others.n, "all = mine + others")
    local r = ns.Lookup.Row(1234, 100)
    eq(r.diff, 1, "40% vs 6.7% flagged as above")
    ok(r.luck > 0.99, "very lucky")
    eq(#ns.Lookup.Differences(), 1)
    local s = ns.Store.CompareSource(1234)
    eq(s.mine.n, 100)
    eq(s.others.n, 900)
end)

test("search finds items and sources by name, id and link", function()
    local ns = Stub.Boot(ROOT, LayeredEnv(), { filter = CORE_ONLY })
    SeedKobold(ns, 40, 8)
    local res = ns.Lookup.Search("kob")
    eq(res[1].type, "source")
    eq(res[1].key, 1234, "more data first among equal matches")
    res = ns.Lookup.Search("linen cloth")
    eq(res[1].type, "item")
    eq(res[1].id, 100)
    res = ns.Lookup.Search("#765")
    eq(res[1].id, 765)
    res = ns.Lookup.Search("|cffffffff|Hitem:200::::|h[Rare Ring]|h|r")
    eq(#res, 1)
    eq(res[1].id, 200)
    eq(#ns.Lookup.Search(""), 0)
end)

test("rate helpers: log scale, cumulative chance, difference test, luck", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local S = ns.Stats
    near(S.LogPos(0.001), 0)
    near(S.LogPos(1), 1)
    near(S.LogPos(0.01), 1 / 3)
    near(S.LogPos(0.1), 2 / 3)
    near(S.CumChance(0.1, 10), 0.6513, 1e-4)
    eq(S.Confidence(0, 0), "none")
    eq(S.Confidence(1, 5), "low")
    eq(S.Confidence(500, 1000), "high")
    local z, p = S.TwoProportion(30, 100, 10, 100)
    ok(z > 3 and p < 0.001, "clear difference")
    ok(not S.Differs(3, 10, 1, 10), "too few samples")
    near(S.NormalCDF(0), 0.5, 1e-6)
    near(S.NormalCDF(1.96), 0.975, 1e-3)
    near(S.LuckPercentile(5, 10, 0.5), 0.5, 1e-9)
    ok(S.LuckPercentile(0, 50, 0.1) < 0.01, "dry run is unlucky")
    for _, case in ipairs({ { 0.01, 0.02, 0.05 }, { 0, 0.0005, 0.002 }, { 0.5, 0.9, 1 } }) do
        local text, total = ns.Report.RateBarText(case[1], case[2], case[3], 60, 8, "medium")
        eq(total, 60, "segments fill the width")
        ok(not text:find(":8:0:0:0:8:8"), "no zero-width segment")
    end
end)

-- ---------------------------------------------------------------- pages (UI)

local function PageEnv()
    local env = LayeredEnv()
    local ns = Stub.Boot(ROOT, env)
    local rec = SeedKobold(ns, 40, 8)
    rec.money, rec.mc, rec.ca, rec.mmin, rec.mmax = 4000, 20, 40, 50, 300
    return env, ns, rec
end

test("item page renders a tab per section with rate rows", function()
    local _, ns = PageEnv()
    ok(ns.Page.Show({ type = "item", id = 100 }), "shown")
    local st = ns.Page._State()
    eq(st.type, "item")
    eq(st.tabs[1], "drop")
    eq(st.tabs[2], "gather")
    eq(st.tabs[3], "quest")
    eq(st.tab, "drop")
    eq(st.rows[1].key, 1234, "surest source first")
    eq(st.rows[2].key, 5678)
    eq(st.analysis, st.rows[1], "first row analysed")
    ok(st.title:find("Linen Cloth"), "title")
    ok(st.info:find("3 sources") or st.info:find("4 sources"), "summary line: " .. tostring(st.info))
    ns.Page.Show({ type = "item", id = 100, tab = "gather" })
    st = ns.Page._State()
    eq(st.rows[1].key, "skin:1234")
    eq(st.history, 1, "same page is not added to history twice")
end)

test("page history goes back and forward", function()
    local _, ns = PageEnv()
    ns.Page.Show({ type = "item", id = 100 })
    ns.Page.Show({ type = "source", id = 1234 })
    eq(ns.Page._State().type, "source")
    ns.Page.Back()
    eq(ns.Page._State().type, "item")
    ns.Page.Forward()
    eq(ns.Page._State().id, 1234)
    ns.Page.Back()
    ns.Page.Show({ type = "item", id = 765 })
    ns.Page.Forward()
    eq(ns.Page._State().id, 765, "new page cuts the forward history")
    eq(ns.Page._State().history, 2)
end)

test("layer switch shows only personal or only others' counts", function()
    local _, ns = PageEnv()
    ns.Page.Show({ type = "item", id = 100 })
    ns.Page.SetLayer("mine")
    local st = ns.Page._State()
    eq(st.layer, "mine")
    eq(#st.rows, 1, "only the personally looted source")
    eq(st.rows[1].n, 40)
    ns.Page.SetLayer("others")
    st = ns.Page._State()
    eq(st.rows[1].n, 1000)
    ns.Page.SetLayer("all")
    eq(ns.Page._State().rows[1].n, 1040)
end)

test("slash item opens the page, print writes to chat", function()
    local _, ns = PageEnv()
    _G.SlashCmdList.WORLDCODEX("item linen")
    eq(ns.Page._State().id, 100)
    local before = #Stub.chat
    _G.SlashCmdList.WORLDCODEX("print linen")
    ok(#Stub.chat > before, "printed")
    _G.SlashCmdList.WORLDCODEX("mob kobold")
    eq(ns.Page._State().type, "source")
    eq(ns.Page._State().id, 1234)
end)

test("hover binding opens the item or npc page", function()
    local env, ns = PageEnv()
    _G.GameTooltip:Show()
    _G.GameTooltip.GetItem = function() return "Linen Cloth", "|cffffffff|Hitem:100::::|h[Linen Cloth]|h|r" end
    ok(_G.WorldCodexAPI.OpenHovered())
    eq(ns.Page._State().id, 100)
    _G.GameTooltip:Hide()
    env.units.mouseover = { guid = MOB, name = "Kobold" }
    ok(_G.WorldCodexAPI.OpenHovered())
    eq(ns.Page._State().type, "source")
    eq(ns.Page._State().id, 1234)
    env.units.mouseover = nil
    env.units.target = { guid = MOB, name = "Kobold" }
    ns.Page.Show({ type = "item", id = 100 })
    _G.SlashCmdList.WORLDCODEX("target")
    eq(ns.Page._State().id, 1234, "/wcx target")
end)

test("item link popup gets a button that opens the page", function()
    local _, ns = PageEnv()
    _G.ItemRefTooltip = CreateFrame("GameTooltip")
    ns.Tooltip.ShowRefButton(765)
    local b = ns.Tooltip.RefButton()
    ok(b:IsShown())
    b:GetScript("OnClick")(b)
    eq(ns.Page._State().id, 765)
end)

test("source page lists drops, related skinning, coin and a map tab", function()
    local _, ns = PageEnv()
    ns.Page.Show({ type = "source", id = 1234 })
    local st = ns.Page._State()
    eq(st.tabs[1], "drops")
    eq(st.tabs[2], "rel:skin:1234")
    eq(st.tabs[#st.tabs - 1], "map")
    eq(st.tabs[#st.tabs], "model", "3D model of the npc")
    eq(st.picture, "model", "npc shown as model when not around")
    eq(st.rows[1].itemId, 100)
    ok(st.info:find("corpses looted"), "counts line: " .. tostring(st.info))
    ok(st.info:find("You: 40 kills"), "personal line")
    ns.Page.Show({ type = "source", id = 1234, tab = "map" })
    eq(#ns.Page._State().rows, 0, "custom tab has no table")
end)

local function FakeWorldMap(map)
    local wm = CreateFrame("Frame")
    wm.ScrollContainer = { Child = CreateFrame("Frame") }
    wm.GetMapID = function() return map end
    wm:Show()
    _G.WorldMapFrame = wm
    return wm
end

test("map focus draws spawns of a source without a waypoint", function()
    local _, ns = PageEnv()
    FakeWorldMap(1429)
    ok(ns.MapPins.ShowSource(1234), "focused")
    eq(ns.Nav.active, nil, "no waypoint")
    eq(ns.MapPins.used, 1, "own and community spawns share one cell")
    ns.MapPins.ClearFocus()
    eq(ns.MapPins.used, 0)
end)

test("item map merges spawns of its sources and caps the pins", function()
    local _, ns, rec = PageEnv()
    FakeWorldMap(1429)
    for i = 1, 10 do
        ns.Store.AddSpawn(rec, 1429, i / 20, 0.5)
    end
    ns.MapPins.MAX_PINS = 4
    ns.MapPins.ShowItem(100)
    local n = 0
    for _, cells in pairs(ns.MapPins.FocusCells()) do
        for _ in pairs(cells) do
            n = n + 1
        end
    end
    eq(n, 4, "capped")
    eq(ns.MapPins.used, 4)
end)

test("compare page lists pairs where the player differs", function()
    local env = LayeredEnv()
    env.saved = {
        version = 3,
        meta = { uid = "me00000000000000", rev = 1 },
        sources = {
            [1234] = { name = "Kobold", kind = "mob", kills = 100, lb = 100, loot = { [100] = { d = 40, q = 40 } } },
        },
    }
    local ns = Stub.Boot(ROOT, env)
    _G.SlashCmdList.WORLDCODEX("compare")
    local st = ns.Page._State()
    eq(st.type, "compare")
    eq(#st.rows, 1)
    eq(st.rows[1].diff, 1)
end)

test("lists and pages share one window and one history", function()
    local _, ns = PageEnv()
    ns.db.settings.browserBagsOnly = false
    ns.Browser.Toggle("sources")
    local st = ns.Page._State()
    eq(st.type, "list")
    eq(st.id, "sources")
    eq(st.section, "sources")
    eq(st.chrome, "dialog", "stub client has no Blizzard frame template")
    local kobold
    for _, r in ipairs(st.rows) do
        if r.id == 1234 then kobold = r end
    end
    ok(kobold, "kobold listed")
    ns.Page.types.list.Click(kobold, "LeftButton")
    local shown = ns.Page._State()
    eq(shown.panel, "details", "details in the side panel")
    ok(shown.details.title:find("Kobold", 1, true), "of the kobold")
    ns.Browser.OpenPage(kobold)
    st = ns.Page._State()
    eq(st.type, "source")
    eq(st.id, 1234)
    eq(st.section, "sources")
    eq(st.preview, false, "pages show the analysis panel")
    ns.Page.Back()
    eq(ns.Page._State().id, "sources", "back returns to the list")

    ns.Browser.Toggle("items")
    ns.Browser.SetFilter("linen")
    eq(#ns.Browser._State().data, 1)
    eq(ns.Page._State().filter, "linen")
    ok((ns.Page._State().search or "") == "", "the window's search box is not the list filter")
    local hits = ns.Page.Search("kob")
    ok(hits[1] and hits[1].type == "source", "the window's search finds sources while a list is shown")
    eq(#ns.Browser._State().data, 1, "and leaves the list filter alone")
    eq(ns.Page._State().filter, "linen")
    ns.Browser.OpenPage(ns.Browser._State().data[1])
    st = ns.Page._State()
    eq(st.type, "item")
    eq(st.section, "items")
    eq(st.filter, nil, "pages have no list filter")
    ns.Page.Back()
    st = ns.Page._State()
    eq(st.filter, "linen", "the list keeps its filter")
    eq(#st.rows, 1)

    ns.Browser.Toggle("ah")
    ns.Page.Show({ type = "item", id = 100 })
    eq(ns.Page._State().section, "ah", "item opened from the AH list stays in that section")
    ns.Browser.Toggle()
    ok(not ns.Page.IsShown(), "toggle closes")
    ns.Browser.Toggle()
    eq(ns.Page._State().id, 100, "toggle reopens the last page")
end)

test("KPI page shows every KPI with a gauge and its chart in the side panel", function()
    local _, ns = PageEnv()
    ns.db.kpi.cal[3] = { pred = 10, obs = 9, c = 40 } -- 25% predicted, 22.5% observed: inside
    ns.db.kpi.days[math.floor(ns.time() / 86400)] = true
    _G.SlashCmdList.WORLDCODEX("kpi")
    local st = ns.Page._State()
    eq(st.type, "kpi")
    eq(st.section, "kpi")
    local function Ids()
        local ids = {}
        for _, r in ipairs(ns.Page._State().rows) do
            ids[#ids + 1] = r.id
        end
        return table.concat(ids, ",")
    end
    eq(Ids(), "1,2,3,4,5,6,7,8,9,10,11,12")
    ns.db.settings.farming, ns.db.settings.farmingAuto = false, false
    ns.Page.Refresh()
    eq(Ids(), "1,2,5,6,7,8,9,10,11,12", "farming KPIs only with farming on")
    st = ns.Page._State()
    local cal
    for _, r in ipairs(st.rows) do
        if r.id == 5 then cal = r end
    end
    eq(cal.ok, true, "calibration bin inside the interval")
    eq(cal.chart.kind, "columns")
    eq(cal.chart.values[3].v, 0.225)
    ok(cal.chart.values[3].lo < 0.225 and cal.chart.values[3].hi > 0.25, "predicted interval as whiskers")
    eq(st.panel, "kpi", "first KPI shown in the side panel")
    ns.Page.types.kpi.Select(cal)
    eq(ns.Page._State().panel, "kpi")
    local days = st.rows[#st.rows]
    eq(days.id, 12)
    eq(days.chart.values[14].v, 1, "today is active")
    ok(st.sub:find("targets met"), st.sub)
    ns.Browser.Toggle("items")
    eq(ns.Page._State().panel, false, "lists use the preview again")
end)

test("list rows get their names when the client loads them", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env)
    ns.db.settings.browserBagsOnly = false
    ns.Prices.Commit(4242, { { p = 100, q = 1 } })
    ns.Browser.Toggle("ah")
    local row = ns.Browser._State().data[1]
    eq(row.id, 4242)
    ok(row.unnamed, "not cached yet")
    eq(row.label:match("item:4242") ~= nil, true)
    env.items[4242] = { name = "Elementium Ore", quality = 2 }
    ns.Dispatch("GET_ITEM_INFO_RECEIVED", 4242, true)
    Advance(ns, 1)
    ok(row.label:find("Elementium Ore"), "label updated in place: " .. row.label)
    eq(row.unnamed, false)
    eq(ns.Page._State().rows[1].label, row.label, "the table shows the same row")
end)

test("list filter scans cached rows; unnamed rows match only their id", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env)
    ns.db.settings.browserBagsOnly = false
    ns.Prices.Commit(100, { { p = 100, q = 1 } })
    ns.Prices.Commit(4242, { { p = 100, q = 1 } })
    ns.Browser.Toggle("items")
    ns.Browser.SetFilter("lin")
    local linen = ns.Browser._State().data[1]
    eq(linen.id, 100)
    ns.Browser.SetFilter("e")
    eq(#ns.Browser._State().data, 1, "item:4242 does not match a letter")
    ns.Browser.SetFilter("424")
    eq(ns.Browser._State().data[1].id, 4242, "but its id")
    ns.Fire("DATA_CHANGED", "loot")
    ns.Browser.SetFilter("lin")
    ok(ns.Browser._State().data[1] == linen, "an unrelated loot keeps the cached row")
end)

test("item lists show the item icon, looked up for rows on screen", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env)
    _G.C_Item = _G.C_Item or {}
    local saved = _G.C_Item.GetItemIconByID
    local asked = {}
    _G.C_Item.GetItemIconByID = function(id)
        asked[#asked + 1] = id
        return id == 4242 and 134400 or nil
    end
    ns.db.settings.browserBagsOnly = false
    ns.Prices.Commit(4242, { { p = 100, q = 1 } })
    ns.Prices.Commit(4343, { { p = 100, q = 1 } })
    ns.Browser.Toggle("ah")
    local rows = {}
    for _, r in ipairs(ns.Browser._State().data) do
        rows[r.id] = r
    end
    eq(rows[4242].icon, 134400, "icon from the client's item data, without the item cache")
    eq(rows[4343].icon, false, "no icon known yet")
    local n = #asked
    ns.Page.RenderRows()
    eq(#asked, n, "looked up once per row")
    env.items[4343] = { name = "Iron Ore", quality = 1, texture = 135232 }
    ns.Dispatch("GET_ITEM_INFO_RECEIVED", 4343, true)
    Advance(ns, 1)
    eq(rows[4343].icon, 135232, "looked up again once the item is known")
    _G.C_Item.GetItemIconByID = saved
end)

test("the book uses the spellbook art, else the journal, the quest paper or the dark inset", function()
    local ns = Stub.Boot(ROOT, Env())
    local W = ns.Widgets
    local origCreate, origTexture = _G.CreateFrame, _G.C_Texture
    local known, atlases = {}, {}
    _G.C_Texture = { GetAtlasInfo = function(name) return atlases[name] and { width = 1 } or nil end }
    _G.CreateFrame = function(...)
        local f = origCreate(...)
        f.CreateTexture = function()
            local t = origCreate("Texture")
            t.SetTexture = function(self, file)
                self.file = file
                return true
            end
            t.SetAtlas = function(self, atlas) self.atlas = atlas end
            t.GetTextureFileID = function(self) return known[self.file] and 4711 or nil end
            t.SetTexCoord = function(self, ...) self.coords = { ... } end
            return t
        end
        return f
    end
    local fonts = { "SystemFont_Med1", "SystemFont_Huge1", "GameFontHighlight", "GameFontHighlightSmall" }
    for _, name in ipairs(fonts) do
        _G[name] = _G[name] or origCreate("Font")
    end
    local white = "|cffffffffLinen Cloth|r"

    atlases = { ["spellbook-Page-Left-C60"] = true, ["spellbook-Page-Right-C60"] = true }
    W.pageStyle = false
    local book = W.Book(origCreate("Frame"))
    eq(W.pageStyle, "spellbook")
    eq(book.pages[1].atlas, "spellbook-Page-Left-C60", "no file known: the whole atlas")
    eq(book.pages[2].atlas, "spellbook-Page-Right-C60")
    -- with the atlas's file and coordinates its dark top band is cut off
    _G.C_Texture.GetAtlasInfo = function(name)
        if not atlases[name] then return nil end
        return { file = 777, leftTexCoord = 0.5, rightTexCoord = 1, topTexCoord = 0, bottomTexCoord = 0.5 }
    end
    book = W.Book(origCreate("Frame"))
    eq(book.pages[1].file, 777)
    eq(book.pages[1].coords[1], 0.5)
    ok(math.abs(book.pages[1].coords[3] - 0.5 * W.SPELLBOOK_CROP_TOP) < 1e-9, "top band cut off")
    eq(book.pages[1].coords[4], 0.5)
    eq(W.Font("body"), "WorldCodexPage_body", "Blizzard's font in the spellbook ink")
    eq(W.Font("pageTitle"), "WorldCodexPage_pageTitle")
    eq(W.Font("frameBody"), "GameFontHighlightSmall", "light font on the window frame")
    ok(W.Ink(white) ~= white, "light colour codes darkened on paper")
    eq(W.PAPER, W.PAGE_COLORS.paper)

    atlases = {}
    known["Interface\\EncounterJournal\\UI-EJ-JournalBG"] = true
    W.pageStyle = false
    book = W.Book(origCreate("Frame"))
    eq(W.pageStyle, "journal")
    eq(book.pages[1].file, "Interface\\EncounterJournal\\UI-EJ-JournalBG")
    ok(book.pages[1].coords[2] > 0.38 and book.pages[1].coords[2] < 0.39, "left page ends at the spine")
    ok(book.pages[2].coords[1] > 0.38 and book.pages[2].coords[2] > 0.76, "right page")

    known = { ["Interface\\QuestFrame\\QuestBG"] = true }
    W.pageStyle = false
    book = W.Book(origCreate("Frame"))
    eq(W.pageStyle, "quest")
    eq(book.pages[2].file, "Interface\\QuestFrame\\QuestBG")

    known = {}
    W.pageStyle = false
    W.Book(origCreate("Frame"))
    eq(W.pageStyle, "inset", "no book art: the client's inset frame")
    eq(W.Font("body"), "GameFontHighlight", "light text on the dark inset")
    eq(W.Ink(white), white, "colour codes unchanged on the dark inset")
    eq(W.PAPER, W.PAGE_COLORS.inset)

    _G.CreateFrame, _G.C_Texture = origCreate, origTexture
    for _, name in ipairs(fonts) do
        _G[name] = nil
    end
end)

test("price columns show coin icons", function()
    local ns = Stub.Boot(ROOT, Env())
    _G.C_CurrencyInfo = _G.C_CurrencyInfo or {}
    local saved = _G.C_CurrencyInfo.GetCoinTextureString
    local asked = {}
    _G.C_CurrencyInfo.GetCoinTextureString = function(c)
        asked[#asked + 1] = c
        return "coins:" .. c
    end
    eq(ns.CoinShort(2000), "coins:2000", "20 silver")
    eq(ns.CoinShort(14436), "coins:14400", "1 gold 44 silver: copper dropped")
    eq(ns.CoinShort(1234567), "coins:1230000", "123 gold: whole gold")
    _G.C_CurrencyInfo.GetCoinTextureString = nil
    eq(ns.CoinShort(2000), "20s00c", "without the client function: letters")
    _G.C_CurrencyInfo.GetCoinTextureString = saved
end)

test("NPC portraits: display ids from a hidden model, cached, redrawn once", function()
    local ns = Stub.Boot(ROOT, Env())
    local origCreate = _G.CreateFrame
    local display = { [1234] = 5555 }
    local fired = 0
    ns.On("PORTRAITS", function() fired = fired + 1 end)
    _G.CreateFrame = function(kind, ...)
        local f = origCreate(kind, ...)
        if kind == "PlayerModel" then
            f.SetCreature = function(self, npc) self.npc = npc end
            f.GetDisplayInfo = function(self) return display[self.npc] or 0 end
        end
        return f
    end
    eq(ns.Portraits.DisplayId(1234), nil, "not known yet: looked up in the background")
    eq(ns.Portraits.DisplayId(1234), nil, "asked again while queued")
    eq(ns.Portraits.DisplayId(9999), nil)
    Advance(ns, 2)
    eq(ns.db.displays[1234], 5555, "display id kept")
    eq(ns.Portraits.DisplayId(1234), 5555)
    eq(ns.db.displays[9999], nil, "a creature without a model gets none")
    eq(fired, 1, "one redraw for the batch")
    eq(ns.Portraits.DisplayId("go:12"), nil, "objects have no portrait")
    _G.CreateFrame = origCreate
end)

test("ink makes light colour codes readable on paper", function()
    local _, ns = PageEnv()
    local W = ns.Widgets
    W.pageStyle = "journal"
    local function rgb(s)
        local h = s:match("|cff(%x%x%x%x%x%x)")
        return tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255
    end
    local function lum(r, g, b) return 0.2126 * r + 0.7152 * g + 0.0722 * b end
    local r, g, b = rgb(W.Ink("|cffffffffLinen Cloth|r"))
    ok(lum(r, g, b) < 0.2, "white becomes dark ink")
    r, g, b = rgb(W.Ink("|cff1eff00Green|r"))
    ok(g > r and g > b and lum(r, g, b) <= 0.21, "uncommon stays green but dark")
    r, g, b = rgb(W.Ink("|cffffd100Prices|r"))
    ok(r > g and g > b and lum(r, g, b) <= 0.21, "gold becomes brown")
    local gr = lum(rgb(W.Ink("|cff888888#123|r")))
    ok(gr > lum(rgb(W.Ink("|cffffffffx|r"))), "grey stays lighter than former white")
    eq(W.Ink("|cff331100dark|r"), "|cff331100dark|r", "dark colours unchanged")
    eq(W.Ink("plain"), "plain")
end)

-- ---------------------------------------------------------------- vendors, quests, recipes

local VENDOR = "Creature-0-1-0-1-777-0000DDDD01"

local function ItemLinkOf(id, name) return "|cffffffff|Hitem:" .. id .. "::::|h[" .. (name or "x") .. "]|h|r" end

local function MerchantUI(env, list)
    env.units.npc = { guid = VENDOR, name = "Innkeeper Farley" }
    _G.GetMerchantNumItems = function() return #list end
    _G.GetMerchantItemLink = function(i) return list[i].id and ItemLinkOf(list[i].id) or nil end
    _G.GetMerchantItemInfo = function(i) return "x", nil, list[i].p, list[i].st or 1, list[i].avail or -1 end
    _G.GetMerchantItemCostInfo = function(i) return list[i].token and 1 or 0 end
    _G.GetMerchantItemCostItem = function(i) return nil, list[i].token[2], ItemLinkOf(list[i].token[1]) end
end

local function ClearMerchantUI()
    for _, k in ipairs({
        "GetMerchantNumItems",
        "GetMerchantItemLink",
        "GetMerchantItemInfo",
        "GetMerchantItemCostInfo",
        "GetMerchantItemCostItem",
    }) do
        _G[k] = nil
    end
end

test("merchant items are recorded per vendor and replaced on revisit, never by a partial list", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    MerchantUI(env, { { id = 100, p = 5, st = 1 }, { id = 765, p = 40, st = 5, avail = 3, token = { 200, 2 } } })
    ns.Dispatch("MERCHANT_SHOW")
    Advance(ns, 1)
    local v = ns.db.vendors[777]
    ok(v, "vendor stored")
    eq(v.nm, "Innkeeper Farley")
    eq(v.v, 1)
    eq(v.i[100].p, 5)
    eq(v.i[765].st, 5)
    ok(v.i[765].lim, "limited stock")
    eq(v.i[765].x[200], 2, "item cost")
    ok(next(v.sp[1429]), "location")
    ok(ns.Vendors.ForItem(765)[777], "reverse index")
    ns.Dispatch("MERCHANT_CLOSED")

    MerchantUI(env, { { id = 100, p = 6 }, { id = nil, p = 1 } })
    ns.Dispatch("MERCHANT_SHOW")
    Advance(ns, 3)
    eq(v.i[100].p, 5, "a list with missing links does not replace the stored one")
    eq(v.v, 1)
    ns.Dispatch("MERCHANT_CLOSED")

    MerchantUI(env, { { id = 100, p = 6 } })
    ns.Dispatch("MERCHANT_SHOW")
    Advance(ns, 1)
    ns.Dispatch("MERCHANT_UPDATE")
    Advance(ns, 1)
    eq(v.i[100].p, 6, "replaced")
    eq(v.i[765], nil, "items no longer sold are gone")
    eq(v.v, 2, "one visit, even with updates")
    ClearMerchantUI()
end)

-- Fake C_TradeSkillUI (WoW Forever has no GetTradeSkill*/GetCraft* functions): an open tailoring window.
local function ProfessionUI(opts)
    opts = opts or {}
    _G.Enum = {
        Profession = { Tailoring = 7, Enchanting = 9 },
        TradeskillRecipeType = { Item = 1, Salvage = 2, Enchant = 3 },
        CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2 },
    }
    local function slot(id, n, kind)
        return { reagentType = kind or 1, quantityRequired = n, reagents = { { itemID = id } } }
    end
    local recipes = {
        [2963] = { recipeType = 1, outputItemID = 2996, quantityMin = 1, quantityMax = 1, slots = { slot(100, 2) } },
        [3755] = { -- Linen Bag, with an optional reagent that is not part of the recipe
            recipeType = 1,
            outputItemID = 4238,
            quantityMin = 1,
            quantityMax = 1,
            slots = { slot(2996, 3), slot(2320, 3), slot(9999, 1, 0) },
        },
        [7418] = { recipeType = 3, quantityMin = 1, quantityMax = 1, slots = { slot(10940, 1) } }, -- an enchant
        [8000] = { recipeType = 2, outputItemID = 555, slots = { slot(100, 1) }, salvage = true },
        [8001] = { -- a currency reagent: not representable, the recipe is left out
            recipeType = 1,
            outputItemID = 556,
            slots = { { reagentType = 1, quantityRequired = 1, reagents = { { currencyID = 3 } } } },
        },
    }
    local fake = { schematics = 0, changing = opts.changing or false }
    local ids = { 2963, 3755, 7418, 8000, 8001 }
    _G.C_TradeSkillUI = {
        IsTradeSkillReady = function() return true end,
        IsDataSourceChanging = function() return fake.changing end,
        IsNPCCrafting = function() return false end,
        IsRuneforging = function() return false end,
        GetAllRecipeIDs = function() return ids end,
        GetBaseProfessionInfo = function()
            return { profession = 7, professionID = 197, professionName = "Schneiderei" }
        end,
        GetProfessionInfoByRecipeID = function(id) return { profession = id == 7418 and 9 or 7 } end,
        GetRecipeInfo = function(id) return { recipeID = id, isSalvageRecipe = recipes[id].salvage } end,
        GetRecipeSchematic = function(id)
            fake.schematics = fake.schematics + 1
            local r = recipes[id]
            return {
                recipeID = id,
                recipeType = r.recipeType,
                outputItemID = r.outputItemID,
                quantityMin = r.quantityMin or 1,
                quantityMax = r.quantityMax or 1,
                reagentSlotSchematics = r.slots,
            }
        end,
    }
    fake.ids, fake.recipes = ids, recipes
    return fake
end

local function ClearProfessionUI()
    _G.C_TradeSkillUI, _G.Enum = nil, nil
end

test("profession recipes are read through C_TradeSkillUI with reagents and a reverse index", function()
    local fake = ProfessionUI()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    ns.Dispatch("TRADE_SKILL_SHOW")
    ns.Dispatch("TRADE_SKILL_LIST_UPDATE")
    Advance(ns, 1)
    local r = ns.db.recipes[2996]
    ok(r, "bolt recorded")
    eq(r.pf, "tailoring", "locale-neutral profession key from Enum.Profession")
    eq(r.r[100], 2)
    eq(ns.db.recipes[4238].r[2996], 3)
    eq(ns.db.recipes[4238].r[9999], nil, "optional reagents are not part of the recipe")
    eq(ns.db.recipes["enchant:7418"].r[10940], 1, "enchants keyed by spell")
    eq(ns.db.recipes[555], nil, "salvage skipped")
    eq(ns.db.recipes[556], nil, "currency reagents: left out instead of stored incomplete")
    ok(ns.Crafting.Using(100)[2996])
    ok(ns.Crafting.Using(2996)[4238])
    eq(ns.Crafting.lastScan.stored, 3)
    local reads = fake.schematics
    ns.Dispatch("TRADE_SKILL_LIST_UPDATE") -- filters, crafting: the same list again
    Advance(ns, 1)
    eq(fake.schematics, reads, "an unchanged profession is not read again")
    local all = ns.Store.AllItemIds()
    ok(all[4238] and all[2996] and all[2320] and all[10940], "recipe products and reagents are items")
    eq(all[9999], nil, "optional reagents are not")
    ns.db.vendors[77] = { nm = "Vendor", i = { [159] = { p = 25 } } }
    ok(ns.Store.AllItemIds()[159], "vendor items are items")
    ok(ns.Search.AllItems()[4238], "advanced search sees the same items")
    ClearProfessionUI()
end)

test("recipes wait while the profession data is changing; a learned recipe is read at once", function()
    local fake = ProfessionUI({ changing = true })
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    ns.Dispatch("TRADE_SKILL_SHOW")
    Advance(ns, 1)
    eq(ns.db.recipes[2996], nil, "nothing while the data source changes")
    fake.changing = false
    ns.Dispatch("TRADE_SKILL_LIST_UPDATE")
    Advance(ns, 1)
    ok(ns.db.recipes[2996], "read with the next list update")
    fake.recipes[9100] = {
        recipeType = 1,
        outputItemID = 777,
        slots = { { reagentType = 1, quantityRequired = 4, reagents = { { itemID = 100 } } } },
    }
    ns.Dispatch("NEW_RECIPE_LEARNED", 9100)
    eq(ns.db.recipes[777].r[100], 4, "learned recipe stored right away")
    eq(ns.db.recipes[777].pf, "tailoring")
    ClearProfessionUI()
end)

test("item and npc pages show sold by, crafting, objectives, sells and quests", function()
    local _, ns = PageEnv()
    ns.db.vendors[777] =
        { nm = "Innkeeper Farley", sp = { [1429] = { [4040] = 1 } }, i = { [100] = { p = 5, st = 1 } } }
    ns.db.recipes[2996] = { pf = "tailoring", mn = 1, mx = 1, r = { [100] = 2 } }
    local q = ns.Store.EnsureSource("quest:155", "The Defias Brotherhood", "quest")
    q.attempts, q.gid, q.req = 1, 777, { [100] = 5 }
    ns.Vendors.indexDirty, ns.Crafting.indexDirty = true, true
    ns.Fire("DATA_CHANGED", "test")
    ns.Page.Show({ type = "item", id = 100 })
    local tabs = table.concat(ns.Page._State().tabs, ",")
    ok(tabs:find("vendors"), tabs)
    ok(tabs:find("crafting"), tabs)
    ok(tabs:find("objective"), tabs)
    ns.Page.Show({ type = "item", id = 100, tab = "vendors" })
    eq(ns.Page._State().rows[1].key, 777)
    ns.Page.Show({ type = "source", id = 777 })
    local st = ns.Page._State()
    eq(st.title, "Innkeeper Farley", "vendor-only npc named")
    tabs = table.concat(st.tabs, ",")
    ok(tabs:find("sells"), tabs)
    ok(tabs:find("quests"), tabs)
end)

-- ---------------------------------------------------------------- sharing the new facts

local function SeedFacts(ns)
    local rec = SeedKobold(ns, 40, 8)
    rec.lmin, rec.lmax, rec.cls = 5, 7, "elite"
    local q = ns.Store.EnsureSource("quest:155", "The Defias Brotherhood", "quest")
    q.attempts, q.gid, q.tid, q.req = 1, 4000, "go:4001", { [765] = 10 }
    q.loot[100] = { d = 1, q = 3 }
    ns.db.vendors[777] =
        { nm = "Innkeeper Farley", sp = { [1429] = { [4040] = 1 } }, i = { [100] = { p = 5, st = 1 } } }
    ns.db.recipes[2996] = { pf = "tailoring", mn = 1, mx = 1, r = { [100] = 2 } }
    return rec
end

test("export string carries vendors, recipes, levels and quest npcs; they validate and import", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    SeedFacts(ns)
    local str = ns.Report.ExportString()
    local snap = ns.Codec.Decode(str)
    local clean = ns.Store.ValidateSnapshot(snap)
    eq(clean.lc, "enUS")
    eq(clean.src[1234].lv[1], 5)
    eq(clean.src[1234].cl, "elite")
    eq(clean.src["quest:155"].qg, 4000)
    eq(clean.src["quest:155"].qt, "go:4001")
    eq(clean.src["quest:155"].rq[765], 10)
    eq(clean.vd[777].i[100].p, 5)
    eq(clean.rc[2996].r[100], 2)
    -- someone else imports it
    ns.db.meta.uid = "someoneelse00000"
    ns.db.vendors, ns.db.recipes = {}, {}
    ns.db.sources = {}
    ok(ns.Report.Import(str))
    ns.Vendors.indexDirty, ns.Crafting.indexDirty = true, true
    local v, layer = ns.Vendors.Get(777)
    eq(layer, "guild")
    eq(v.i[100].p, 5)
    eq(ns.Crafting.Get(2996).pf, "tailoring")
    local lmin, lmax, cls = ns.Store.SourceLevel(1234)
    eq(lmin, 5)
    eq(lmax, 7)
    eq(cls, "elite")
    local gid, tid, req = ns.Quests.Fields("quest:155")
    eq(gid, 4000)
    eq(tid, "go:4001")
    eq(req[765], 10)
end)

test("bad new fields are dropped, old snapshots still import", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local clean = ns.Store.ValidateSnapshot({
        v = 1,
        uid = "x1",
        lc = "<script>",
        src = { [1] = { n = 10, l = {}, lv = { 9, 2 }, cl = "boss", qg = "evil", rq = { [5] = -1 } } },
        vd = { ["x"] = { i = {} }, [5] = { nm = "A|cffB", i = { [100] = { p = -3 }, [101] = { p = 7, st = 99999 } } } },
        rc = { [10] = { pf = "bad pf!", r = { [1] = 1 } }, ["enchant:5"] = { pf = "enchanting", r = { [1] = 2 } } },
    })
    eq(clean.lc, nil)
    eq(clean.src[1].lv, nil)
    eq(clean.src[1].cl, nil)
    eq(clean.src[1].qg, nil)
    eq(clean.src[1].rq, nil)
    eq(clean.vd.x, nil)
    eq(clean.vd[5].i[100], nil, "negative price")
    eq(clean.vd[5].i[101].st, 1, "absurd stack size reset")
    eq(clean.vd[5].nm, "AcffB")
    eq(clean.rc[10], nil, "bad profession key")
    eq(clean.rc["enchant:5"].r[1], 2)
    local old = ns.Store.ValidateSnapshot({ v = 1, uid = "x2", src = { [1] = { n = 5, l = { [100] = { 1, 1 } } } } })
    ok(old and old.src[1], "old format accepted")
    eq(old.vd, nil)
end)

test("guild sync snapshot leaves vendors and recipes out", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    SeedFacts(ns)
    local snap = ns.Store.Snapshot({ minN = 3, ah = true, cells = 8 })
    eq(snap.vd, nil)
    eq(snap.rc, nil)
    ok(snap.src[1234].lv, "levels are small enough to sync")
end)

test("a German client shows German community names", function()
    local env = LayeredEnv()
    env.community.names = { deDE = { [5678] = "Gnollspäher", ["vendor:777"] = "Gastwirt Farley" } }
    env.community.vendors = { [777] = { nm = "Innkeeper Farley", sp = {}, i = { [100] = { p = 5, st = 1 } } } }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    eq((ns.Store.SourceMeta(5678)), "Gnoll")
    _G.GetLocale = function() return "deDE" end
    eq((ns.Store.SourceMeta(5678)), "Gnollspäher")
    eq(ns.Vendors.Name(777), "Gastwirt Farley")
end)

test("details panel on a German client: clear sections, no English leftovers", function()
    local env = LayeredEnv()
    env.locale = "deDE"
    env.items[100] = { name = "Leinenstoff", sell = 13 }
    local ns = Stub.Boot(ROOT, env)
    SeedKobold(ns, 40, 8)
    ns.Prices.Commit(100, { { p = 200, q = 5 }, { p = 250, q = 3 } })
    ns.db.settings.browserBagsOnly = false
    local function Select(list, id)
        ns.Browser.Toggle(list)
        for _, r in ipairs(ns.Page._State().rows) do
            if r.id == id then ns.Page.types.list.Click(r, "LeftButton") end
        end
        local st = ns.Page._State()
        eq(st.panel, "details", list .. ": details panel")
        return ns.Report.FactsText(st.details), st.details
    end
    local english = { "pace", "estimated", "/drop", "n=", " more", " ago", "per drop", "attempts", "Avg", "dry " }
    local function German(text, words)
        for _, w in ipairs(words) do
            ok(text:find(w, 1, true), w .. " missing in:\n" .. text)
        end
        for _, w in ipairs(english) do
            ok(not text:find(w, 1, true), "English '" .. w .. "' in:\n" .. text)
        end
    end
    local text, facts = Select("items", 100)
    German(text, { "Preis", "Marktwert", "Angebot", "Quellen", "von", "Kills", "pro Drop" })
    eq(facts.sections[1].title, "Preis")
    local entry = facts.sections[2].rows[1]
    ok(entry.entry and entry.value:find("%%"), "sources are entries with a rate")
    text = Select("sources", 1234)
    German(text, { "Überblick", "Wert pro Kill", "Drops", "Eigene Daten", "Leinenstoff" })
    _G.GetLocale = function() return "enUS" end
end)

test("community vendors and recipes follow the community switch", function()
    local env = LayeredEnv()
    env.community.vendors = { [777] = { nm = "Innkeeper Farley", sp = {}, i = { [100] = { p = 5, st = 1 } } } }
    env.community.recipes = { [2996] = { pf = "tailoring", mn = 1, mx = 1, r = { [100] = 2 } } }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    ok(ns.Vendors.ForItem(100)[777])
    ok(ns.Crafting.Using(100)[2996])
    ns.db.settings.useCommunity = false
    ns.Fire("SETTINGS_CHANGED", "useCommunity", false)
    eq(ns.Vendors.Get(777), nil)
    eq(next(ns.Vendors.ForItem(100)), nil)
    eq(ns.Crafting.Get(2996), nil)
    eq(next(ns.Crafting.Using(100)), nil)
end)

test("a guild member with newer community data is announced once", function()
    local env = LayeredEnv()
    env.community.generated = 1700000000
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local function Count()
        local n = 0
        for _, line in ipairs(Stub.chat) do
            if line:find("newer community data", 1, true) then n = n + 1 end
        end
        return n
    end
    ns.Sync.OnMessage("WorldCodex", "G:" .. (1700000000 + 3600), "GUILD", "Bob-TestRealm")
    eq(Count(), 0, "same day is not newer")
    ns.Sync.OnMessage("WorldCodex", "G:" .. (1700000000 + 3 * 86400), "GUILD", "Bob-TestRealm")
    ns.Sync.OnMessage("WorldCodex", "G:" .. (1700000000 + 4 * 86400), "GUILD", "Carl-TestRealm")
    eq(Count(), 1)
    ns.Sync.Advertise()
    Advance(ns, 30)
    local sent
    for _, m in ipairs(Stub.sent) do
        if m.msg == "G:1700000000" then sent = true end
    end
    ok(sent, "own data date advertised")
    ns.Report.PrintStatus()
    local found
    for _, line in ipairs(Stub.chat) do
        if line:find("Community data from", 1, true) then found = true end
    end
    ok(found, "status shows the community data date")
end)

test("web links appear only once a website address is set", function()
    local _, ns = PageEnv()
    local function Labels()
        local out = {}
        for _, a in ipairs(ns.PageItem.Actions(100)) do
            out[#out + 1] = a.label
        end
        return table.concat(out, ",")
    end
    ok(not Labels():find("Web link"), "hidden without a site")
    eq(ns.WebUrl("item", 100), nil)
    ns.WEB_BASE = "https://worldcodex.example"
    ok(Labels():find("Web link"), "shown with a site")
    eq(ns.WebUrl("item", 100), "https://worldcodex.example/item/100")
    eq(ns.WebUrl("source", "skin:1234"), "https://worldcodex.example/source/skin:1234")
    ns.WebLink("item", 100)
    eq(_G.WorldCodexWebLinkFrame.input:GetText(), "https://worldcodex.example/item/100")
end)

test("shipped community data loads, indexes quickly and fits the memory budget", function()
    collectgarbage("collect")
    local before = collectgarbage("count")
    local t0 = os.clock()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY, realCommunity = true })
    local c = ns.Store.Community()
    ok(c, "community table present")
    ns.Store.indexDirty = true
    ns.Store.RebuildIndex()
    local seconds = os.clock() - t0
    collectgarbage("collect")
    local mb = (collectgarbage("count") - before) / 1024
    local n = 0
    for _ in pairs(c.sources) do
        n = n + 1
    end
    print(string.format("      shipped data: %d sources, boot + index %.2f s, %.1f MB", n, seconds, mb))
    ok(seconds < 5, "boot and index in under 5 s")
    ok(mb < 200, "under 200 MB")
end)

-- ---------------------------------------------------------------- chests and npc locations

local CHEST = "GameObject-0-1-0-1-2843-0000FFFF01"

local function HoverText(text)
    _G.GameTooltipTextLeft1 = { GetText = function() return text end }
    _G.GameTooltip:Show()
end

local function SeedChest(ns, key, n, d)
    local rec = ns.Store.EnsureSource(key, "Battered Chest", "object")
    rec.attempts = n
    rec.loot[100] = { d = d, q = d * 2 }
    ns.Store.indexDirty = true
    ns.Lookup.Invalidate()
    return rec
end

local function CaptureTooltip()
    local lines = {}
    _G.GameTooltip.AddLine = function(_, text) lines[#lines + 1] = tostring(text) end
    _G.GameTooltip.AddDoubleLine = function(_, a, b) lines[#lines + 1] = tostring(a) .. " | " .. tostring(b) end
    return lines
end

test("a chest opened without a cast is its own source, named from the tooltip, counted once", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    HoverText("Battered Chest")
    env.loot = {
        { name = "15 Copper", q = 0, src = { { CHEST, 0 } } },
        { id = 100, name = "Linen Cloth", q = 3, src = { { CHEST, 3 } } },
    }
    ns.Dispatch("LOOT_READY")
    ns.Dispatch("LOOT_OPENED")
    env.money = 15
    ns.Dispatch("PLAYER_MONEY")
    ns.Dispatch("LOOT_CLOSED")
    env.loot = {}
    _G.GameTooltip:Hide()
    local rec = ns.db.sources["go:2843"]
    ok(rec, "chest source")
    eq(rec.kind, "object")
    eq(rec.name, "Battered Chest")
    eq(rec.attempts, 1)
    eq(rec.loot[100].q, 3)
    eq(rec.money, 15)
    ok(next(rec.spawns[1429]), "where it was opened")
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 3, src = { { CHEST, 3 } } } })
    eq(rec.attempts, 1, "reopening the same chest does not count again")
    eq(rec.loot[100].d, 1)
    eq(ns.Lookup.ItemModel(100).sections.contained[1].key, "go:2843", "listed under Contained in")
end)

test("hovering a chest: the key opens its page and the tooltip shows its drops", function()
    local _, ns = PageEnv()
    SeedChest(ns, "go:2843", 20, 10)
    SeedChest(ns, "go:2844", 5, 1)
    eq(ns.Tooltip.objectRoute, "show", "old client route: lines added when the tooltip shows")
    local lines = CaptureTooltip()
    HoverText("Battered Chest")
    for _, fn in ipairs(_G.GameTooltip.__hooks.OnShow or {}) do
        fn(_G.GameTooltip)
    end
    local text = table.concat(lines, "\n")
    ok(text:find("n=20", 1, true), "the chest type with most data: " .. text)
    ok(text:find("Linen Cloth", 1, true), "its drops")
    ok(text:find("1 more object types", 1, true), "other chests with the same name")
    ok(_G.WorldCodexAPI.OpenHovered())
    eq(ns.Page._State().type, "source")
    eq(ns.Page._State().id, "go:2843")
    HoverText("Some Rock")
    _G.GameTooltip.GetUnit = function() return nil end
    ok(not ns.Lookup.ObjectsByName("Some Rock")[1], "unknown objects are ignored")
end)

test("object tooltips use the client's object tooltip data when it exists", function()
    local calls = {}
    _G.TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) calls[kind] = fn end }
    _G.Enum = { TooltipDataType = { Item = 0, Unit = 2, Object = 4 } }
    local _, ns = PageEnv()
    SeedChest(ns, "go:2843", 20, 10)
    eq(ns.Tooltip.objectRoute, "data")
    eq(_G.GameTooltip.__hooks.OnShow, nil, "no OnShow hook on modern clients")
    local lines = CaptureTooltip()
    calls[4](_G.GameTooltip, { lines = { { leftText = "Battered Chest" } } })
    ok(table.concat(lines, "\n"):find("Linen Cloth", 1, true))
end)

test("mob tooltip lists quest items first, then by rarity and item level", function()
    local env = Env()
    env.items[300] = { name = "Kobold Ear", quality = 1, classId = 12 }
    env.items[400] = { name = "Old Sword", quality = 2, ilvl = 10 }
    env.items[401] = { name = "Shiny Sword", quality = 2, ilvl = 18 }
    env.items[402] = { name = "Epic Axe", quality = 4, ilvl = 5 }
    local ns = Stub.Boot(ROOT, env)
    local rec = ns.Store.EnsureSource(1234, "Kobold", "mob")
    rec.kills, rec.lb = 100, 100
    rec.loot[100] = { d = 90, q = 90 }
    rec.loot[300] = { d = 20, q = 20 }
    rec.loot[400] = { d = 5, q = 5 }
    rec.loot[401] = { d = 3, q = 3 }
    rec.loot[402] = { d = 1, q = 1 }
    ns.Store.indexDirty = true
    local lines = CaptureTooltip()
    ns.Tooltip.AddUnitLines(_G.GameTooltip, "Creature-0-1-0-1-1234-0000BBBB22")
    local text = table.concat(lines, "\n")
    local function at(name) return text:find(name, 1, true) or math.huge end
    ok(at("Kobold Ear") < at("Epic Axe"), "quest item first: " .. text)
    ok(at("Epic Axe") < at("Shiny Sword"), "then the highest rarity")
    ok(at("Shiny Sword") < math.huge, "then the highest item level among equal rarity")
    ok(not text:find("Linen Cloth", 1, true) and text:find("... +2", 1, true), "rest summarised")
end)

local INNKEEPER = "Creature-0-1-0-1-6740-0000AAAA11"

local function NpcEnv(extra)
    local env = Env(extra)
    _G.UnitReaction = function(unit) return env.units[unit] and env.units[unit].reaction or 5 end
    _G.CheckInteractDistance = function(unit) return env.units[unit] and env.units[unit].near or false end
    return env
end

test("talking to an NPC records where it stands and what it does", function()
    local env = NpcEnv()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    env.units.npc = { guid = INNKEEPER, name = "Innkeeper Allison", level = 30 }
    ns.Dispatch("GOSSIP_SHOW")
    local rec = ns.db.npcs[6740]
    ok(rec, "npc recorded")
    eq(rec.nm, "Innkeeper Allison")
    eq(rec.lv[1], 30)
    eq(rec.r, "friendly")
    ok(rec.f.gossip)
    eq(rec.sp[1429][5050], 1)
    ns.Dispatch("GOSSIP_SHOW")
    eq(rec.sp[1429][5050], 1, "same spot within two minutes counts once")
    ns.Dispatch("MERCHANT_SHOW")
    ok(rec.f.vendor, "merchant role")
    env.units.npc = { guid = "Creature-0-1-0-1-4000-0000EEEE01", name = "Gryan Stoutmantle", level = 20 }
    ns.Dispatch("QUEST_DETAIL")
    ok(ns.db.npcs[4000].f.quest, "quest giver")
    ok(ns.db.npcs[4000].sp[1429], "quest giver location")
    eq(ns.Store.Spawns(4000)[1429][5050], 1, "locations reach maps and pages")
    env.units.npc = { guid = "GameObject-0-1-0-1-4001-0000EEEE02", name = "Wanted Poster" }
    ns.Dispatch("QUEST_DETAIL")
    ok(ns.db.npcs["go:4001"], "quest objects too")
end)

test("NPCs nearby are recorded out of combat only, without a location; pets and far units are not", function()
    local env = NpcEnv()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    env.units.mouseover = { guid = INNKEEPER, name = "Innkeeper Allison", near = false, friendly = true }
    ns.Dispatch("UPDATE_MOUSEOVER_UNIT")
    eq(ns.db.npcs[6740], nil, "too far away")
    env.units.mouseover.near = true
    _G.InCombatLockdown = function() return true end
    ns.Dispatch("UPDATE_MOUSEOVER_UNIT")
    eq(ns.db.npcs[6740], nil, "not in combat")
    _G.InCombatLockdown = function() return false end
    ns.Dispatch("UPDATE_MOUSEOVER_UNIT")
    ok(ns.db.npcs[6740], "near and out of combat")
    eq(ns.db.npcs[6740].f, nil, "a sighting gives no role")
    eq(next(ns.db.npcs[6740].sp), nil, "a sighting gives no location")
    eq(ns.db.npcs[6740].nm, "Innkeeper Allison", "but name, level and reaction")
    env.units.npc = env.units.mouseover
    ns.Dispatch("GOSSIP_SHOW")
    eq(ns.db.npcs[6740].sp[1429][5050], 1, "talking to it records where it stands")
    env.units.nameplate1 = { guid = "Creature-0-1-0-1-416-0000CCCC01", name = "Imp", near = true }
    _G.UnitPlayerControlled = function(unit) return unit == "nameplate1" end
    ns.Dispatch("NAME_PLATE_UNIT_ADDED", "nameplate1")
    eq(ns.db.npcs[416], nil, "pets and totems are not NPCs")
    _G.CheckInteractDistance = nil
    env.units.target = { guid = "Creature-0-1-0-1-9999-0000CCCC02", name = "Guard", near = true }
    ns.Dispatch("PLAYER_TARGET_CHANGED")
    eq(ns.db.npcs[9999], nil, "without a distance check only interactions count")
end)

test("NPC pages: name, zones, map and model for NPCs known only from sightings or vendors", function()
    local _, ns = PageEnv()
    _G.SetPortraitTexture = function() end
    ns.db.npcs[6740] = {
        nm = "Innkeeper Allison",
        sp = { [1429] = { [5050] = 3 } },
        lv = { 30, 30 },
        r = "friendly",
        f = { vendor = true },
    }
    ns.Page.Show({ type = "source", id = 6740 })
    local st = ns.Page._State()
    eq(st.title, "Innkeeper Allison")
    local tabs = table.concat(st.tabs, ",")
    ok(tabs:find("map"), tabs)
    ok(tabs:find("model"), tabs)
    eq(st.picture, "model")
    ok(st.info ~= nil)
    eq(ns.Lookup.Search("allison")[1].key, 6740, "search finds NPCs that drop nothing")
    -- the npc right in front of the player: a real portrait
    _G.UnitGUID = function(unit) return unit == "target" and INNKEEPER or nil end
    ns.Page.Refresh()
    eq(ns.Page._State().picture, "portrait")
    _G.UnitGUID = function() return nil end
    -- vendor known only from the merchant window: its location shows on the page (was missing)
    ns.db.vendors[777] =
        { nm = "Innkeeper Farley", sp = { [1429] = { [4040] = 1 } }, i = { [100] = { p = 5, st = 1 } } }
    ns.Vendors.indexDirty = true
    ns.Lookup.Invalidate()
    ns.Page.Show({ type = "source", id = 777 })
    ok(table.concat(ns.Page._State().tabs, ","):find("map"), "vendor map tab")
    eq(ns.Lookup.Zones(777)[1].map, 1429)
end)

test("NPC locations are shared through export strings and the community data", function()
    local env = NpcEnv()
    env.community = {
        version = 1,
        generated = 1,
        contributors = {},
        sources = {},
        npcs = {
            [9999] = { nm = "Stormwind Guard", sp = { [1453] = { [1111] = 3 } }, r = "friendly", f = { gossip = true } },
            [9998] = { nm = "Stormwind Patrol", sp = { [1453] = { [2222] = 9 } }, r = "friendly" },
        },
    }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    eq(ns.Store.Spawns(9999)[1453][1111], 3, "community npc location")
    eq(next(ns.Store.Spawns(9998)), nil, "sighting locations of older versions are not shown")
    eq(ns.Lookup.Name(9999), "Stormwind Guard")
    env.units.npc = { guid = INNKEEPER, name = "Innkeeper Allison", level = 30 }
    ns.Dispatch("TRAINER_SHOW")
    local snap = ns.Store.ValidateSnapshot(ns.Codec.Decode(ns.Report.ExportString()))
    eq(snap.np[6740].nm, "Innkeeper Allison")
    ok(snap.np[6740].f.trainer)
    eq(snap.np[6740].sp[1429][5050], 1)
    eq(ns.Store.Snapshot({ minN = 3, ah = true }).np, nil, "not in guild sync")
    ns.db.meta.uid = "someoneelse00000"
    ns.db.npcs = {}
    ok(ns.Report.Import(ns.Codec.Encode(snap)))
    eq(ns.Store.Spawns(6740)[1429][5050], 1, "imported npc location")
    eq(ns.Npcs.Info(6740).f.trainer, true)
end)

test("sighting-only NPC locations from older versions are dropped once", function()
    local env = NpcEnv()
    env.saved.npcs = {
        [6740] = { nm = "Innkeeper Allison", sp = { [1429] = { [5050] = 3 } }, f = { gossip = true } },
        [9998] = { nm = "Stormwind Patrol", sp = { [1453] = { [2222] = 9 } } },
    }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    eq(ns.db.npcs[6740].sp[1429][5050], 3, "interaction locations kept")
    eq(next(ns.db.npcs[9998].sp), nil, "sighting locations dropped")
    eq(ns.db.npcs[9998].nm, "Stormwind Patrol", "the rest of the record stays")
    ok(ns.db.meta.npcInteractOnly)
end)

-- ---------------------------------------------------------------- export

-- ---------------------------------------------------------------- trainers

local TRAINER = "Creature-0-1-0-1-914-0000BBBB22"

-- Trainer window APIs that are tables in the client (the stub's globals stay plain functions);
-- restored afterwards so other tests keep their own C_TooltipInfo.
local function WithTrainerApi(fn)
    local oldTip, oldEnum = _G.C_TooltipInfo, _G.Enum
    local tip = {}
    for k, v in pairs(oldTip or {}) do
        tip[k] = v
    end
    tip.GetTrainerService = function(i)
        local list = {}
        for _, sv in ipairs(_G.__trainerEnv.trainer.services) do
            if _G.__trainerEnv.trainerFilters[sv.type or "available"] then list[#list + 1] = sv end
        end
        local sv = list[i]
        return sv and sv.spell and { type = 1, id = sv.spell } or nil
    end
    tip.GetUnit = function(unit)
        local env = _G.__trainerEnv
        if unit ~= "npc" or not env.trainer then return nil end
        local lines = { { leftText = "Trainer" } }
        if env.trainer.title then lines[2] = { leftText = env.trainer.title } end
        lines[#lines + 1] = { leftText = "Level 40" }
        return { lines = lines }
    end
    local enum = {}
    for k, v in pairs(oldEnum or {}) do
        enum[k] = v
    end
    enum.TrainerType = { General = 0, TalentsObsolete = 1, Tradeskills = 2, Pet = 3 }
    enum.TooltipDataType = { Item = 0, Spell = 1, Unit = 2 }
    _G.C_TooltipInfo, _G.Enum = tip, enum
    local okRun, err = pcall(fn)
    _G.C_TooltipInfo, _G.Enum, _G.__trainerEnv = oldTip, oldEnum, nil
    if not okRun then error(err, 0) end
end

local function OpenTrainer(ns, env, trainer)
    env.trainer = trainer
    _G.__trainerEnv = env
    env.units.npc = { guid = TRAINER, name = trainer.npcName or "Frang", level = 40 }
    ns.Dispatch("TRAINER_SHOW")
    Advance(ns, 0.3)
    ns.Dispatch("TRAINER_CLOSED")
end

test("class trainers: every service is read with all filters on, and the filters are put back", function()
    WithTrainerApi(function()
        local env = NpcEnv()
        local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
        OpenTrainer(ns, env, {
            kind = "general",
            title = "Warrior Trainer",
            services = {
                { name = "Battle Shout", type = "available", level = 6, spell = 6673, cost = 100 },
                { name = "Rend", type = "used", level = 4, spell = 772, cost = 10 },
                { name = "Cleave", type = "unavailable", level = 20, spell = 845, cost = 2000 },
            },
        })
        local rec = ns.db.trainers[914]
        ok(rec, "trainer recorded")
        eq(rec.tt, "class")
        eq(rec.cls, "WARRIOR")
        eq(rec.s[6673].c, 100)
        eq(rec.s[6673].lv, 6)
        eq(rec.s[845].c, 2000)
        ok(rec.s[772], "known spells are read too (filter opened)")
        eq(env.trainerFilters.used, false, "player's filter put back")
        eq(env.trainerFilters.available, true)
        eq(ns.Trainers.Label(ns.Trainers.Get(914)), "Warrior trainer")
        ok(ns.db.npcs[914].f.trainer, "the npc has the trainer role")
        -- a riding trainer's title does not name the class
        OpenTrainer(ns, env, {
            kind = "general",
            title = "Riding Trainer",
            services = { { name = "Apprentice Riding", spell = 33388, cost = 40000, level = 20 } },
        })
        eq(ns.db.trainers[914].tt, "general")
        eq(ns.db.trainers[914].cls, nil)
    end)
end)

test("spell ranks and levels: recorded from the trainer and found by the search", function()
    WithTrainerApi(function()
        local env = NpcEnv()
        env.spells = { [772] = "Rend", [6546] = "Rend", [6673] = "Battle Shout" }
        local ns = Stub.Boot(ROOT, env)
        OpenTrainer(ns, env, {
            kind = "general",
            title = "Warrior Trainer",
            services = {
                { name = "Rend", sub = "Rank 1", level = 4, spell = 772, cost = 10 },
                { name = "Rend", sub = "Rank 2", level = 10, spell = 6546, cost = 100 },
                { name = "Battle Shout", level = 6, spell = 6673, cost = 100 },
            },
        })
        eq(ns.db.spells[6546].rk, "Rank 2", "rank from the trainer window")
        eq(ns.Spells.Level(6546), 10)
        local function Find(q)
            local ids = {}
            for _, e in ipairs(ns.Lookup.Search(q)) do
                if e.type == "spell" then ids[#ids + 1] = e.id end
            end
            return ids
        end
        local both = Find("rend")
        eq(#both, 2)
        eq(both[1], 772, "lower level first")
        eq(table.concat(Find("rend rank 2"), ","), "6546")
        eq(table.concat(Find("rend (rank 1)"), ","), "772")
        eq(table.concat(Find("rend level 10"), ","), "6546")
        eq(#Find("rend rank 3"), 0)
        ns.Page.Search("rend rank 2")
        ns.Page.Show({ type = "spell", id = 6546 })
        local sub = ns.Page._State().sub
        ok(sub:find("Rank 2", 1, true) and sub:find("Level 10", 1, true), sub)
    end)
end)

test("profession trainers: profession, skill requirement, recipe product and the pages", function()
    WithTrainerApi(function()
        local env = NpcEnv()
        env.spells = { [3908] = "Tailoring", [7623] = "Brown Linen Robe" }
        local ns = Stub.Boot(ROOT, env)
        OpenTrainer(ns, env, {
            kind = "profession",
            title = "Tailoring Trainer",
            services = {
                { name = "Apprentice Tailoring", spell = 3908, cost = 10, level = 5, line = "Tailoring" },
                {
                    name = "Brown Linen Robe",
                    spell = 7623,
                    cost = 50,
                    skill = { "Tailoring", 30 },
                    item = 2996,
                    line = "Tailoring",
                },
                -- no spell id from the tooltip: kept by name
                { name = "Linen Belt", sub = "Rank 1", cost = 75, line = "Tailoring" },
            },
        })
        local rec = ns.db.trainers[914]
        eq(rec.tt, "profession")
        eq(rec.pf, "tailoring")
        eq(rec.s[7623].sk, 30)
        eq(rec.s[7623].it, 2996)
        eq(rec.s[3908].sk, nil)
        eq(rec.s["n:Linen Belt (Rank 1)"].nm, "Linen Belt")
        eq(ns.Trainers.ForItem(2996)[914], 7623)
        local before = rec.rv
        OpenTrainer(ns, env, env.trainer)
        eq(rec.rv, before, "the same window again is no news")
        ns.Page.Show({ type = "item", id = 2996 })
        local tabs = table.concat(ns.Page._State().tabs, ",")
        ok(tabs:find("taught"), tabs)
        ns.Page.Show({ type = "item", id = 2996, tab = "taught" })
        eq(ns.Page._State().rows[1].key, 914)
        ns.Page.Show({ type = "source", id = 914 })
        tabs = table.concat(ns.Page._State().tabs, ",")
        ok(tabs:find("teaches"), tabs)
        ns.Page.Show({ type = "source", id = 914, tab = "teaches" })
        local rows = ns.Page._State().rows
        eq(#rows, 3)
        local byName = {}
        for _, r in ipairs(rows) do
            byName[r.name] = r
        end
        -- the profession itself is a spell, never an item (spell 3908 is no item 3908)
        local prof = byName["Tailoring"]
        ok(prof, "spell name from the client")
        eq(prof.openType, "spell")
        eq(prof.openId, 3908)
        ns.PageSource.Open(prof)
        eq(ns.Page._State().type, "spell")
        eq(ns.Page._State().id, 3908)
        eq(ns.Page._State().title, "Tailoring")
        ok(table.concat(ns.Page._State().tabs, ","):find("taught"))
        -- a service without spell id opens nothing
        ns.Page.Show({ type = "source", id = 914, tab = "teaches" })
        for _, r in ipairs(ns.Page._State().rows) do
            if r.name == "Linen Belt" then
                eq(r.openType, nil)
                eq(ns.PageSource.Open(r), false)
            end
        end
        eq(ns.Page._State().type, "source", "still on the trainer page")
        -- a recipe spell: taught by, and the item it creates
        ns.Page.Show({ type = "spell", id = 7623, tab = "recipe" })
        local st = ns.Page._State()
        ok(table.concat(st.tabs, ","):find("recipe"), table.concat(st.tabs, ","))
        eq(st.rows[1].openType, "item")
        eq(st.rows[1].openId, 2996)
        eq(ns.db.spells[7623].n, "Brown Linen Robe", "spells taught are recorded")
        -- search finds spells
        local found
        for _, e in ipairs(ns.Lookup.Search("brown linen")) do
            if e.type == "spell" and e.id == 7623 then found = true end
        end
        ok(found, "spell in search results")
    end)
end)

test("spells: recorded with rank and description, loaded later when the client has not cached them", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local old = _G.C_Spell
    local cached = { [6673] = true }
    local requested = {}
    _G.C_Spell = {
        GetSpellInfo = function(id)
            if id == 6673 or id == 772 then
                return { name = id == 6673 and "Battle Shout" or "Rend", iconID = 132333 }
            end
            return nil
        end,
        GetSpellSubtext = function(id) return id == 772 and "Rank 2" or nil end,
        GetSpellDescription = function(id) return cached[id] and ("Desc " .. id) or "" end,
        IsSpellDataCached = function(id) return cached[id] == true end,
        RequestLoadSpellData = function(id) requested[id] = true end,
    }
    local okRun, err = pcall(function()
        ok(ns.Spells.Record(6673))
        eq(ns.db.spells[6673].n, "Battle Shout")
        eq(ns.db.spells[6673].ds, "Desc 6673")
        eq(ns.db.spells[6673].ic, 132333)
        eq(ns.Spells.Record(6673), false, "nothing new")
        eq(ns.Spells.Record(772), false, "not cached: asked the client first")
        ok(requested[772])
        eq(ns.db.spells[772], nil)
        cached[772] = true
        ns.Dispatch("SPELL_DATA_LOAD_RESULT", 772, true)
        eq(ns.db.spells[772].rk, "Rank 2")
        eq(ns.Spells.Title(772), "Rend (Rank 2)")
        -- shared through the export string, recipes keep their spell id
        ns.db.recipes[2996] = { pf = "tailoring", mn = 1, mx = 1, r = { [100] = 2 }, sid = 7623 }
        local clean = ns.Store.ValidateSnapshot(ns.Codec.Decode(ns.Report.ExportString()))
        eq(clean.sl[772].rk, "Rank 2")
        eq(clean.sl[6673].ds, "Desc 6673")
        eq(clean.rc[2996].sid, 7623)
        ns.Crafting.indexDirty = true
        eq(ns.Crafting.ForSpell(7623), 2996)
        eq(ns.Crafting.SpellOf(2996), 7623)
        local bad = ns.Store.ValidateSnapshot({
            v = 1,
            uid = "x1",
            src = {},
            sl = { x = { n = "a" }, [5] = { n = "A|r", ds = "x|cffy", ic = -1 }, [6] = { rk = "r" } },
        })
        eq(bad.sl.x, nil)
        eq(bad.sl[6], nil, "no name")
        eq(bad.sl[5].n, "Ar")
        eq(bad.sl[5].ds, "xcffy")
        eq(bad.sl[5].ic, nil)
    end)
    _G.C_Spell = old
    if not okRun then error(err, 0) end
end)

test("trainers are shared through the export string, validated and imported", function()
    WithTrainerApi(function()
        local env = NpcEnv()
        local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
        OpenTrainer(ns, env, {
            kind = "general",
            title = "Warrior Trainer",
            services = { { name = "Battle Shout", level = 6, spell = 6673, cost = 100 } },
        })
        local str = ns.Report.ExportString()
        local clean = ns.Store.ValidateSnapshot(ns.Codec.Decode(str))
        eq(clean.tr[914].tt, "class")
        eq(clean.tr[914].cls, "WARRIOR")
        eq(clean.tr[914].s[6673].c, 100)
        eq(ns.Store.Snapshot({ minN = 3, ah = true }).tr, nil, "not in guild sync")
        ns.db.meta.uid = "someoneelse00000"
        ns.db.trainers = {}
        ok(ns.Report.Import(str))
        ns.Trainers.indexDirty = true
        local info = ns.Trainers.Get(914)
        eq(info.cls, "WARRIOR")
        eq(info.s[6673].lv, 6)
        local bad = ns.Store.ValidateSnapshot({
            v = 1,
            uid = "x1",
            src = {},
            tr = {
                x = { s = { [1] = { c = 1 } } },
                [5] = {
                    tt = "bogus",
                    cls = "WARRIOR",
                    s = { [-1] = { c = 1 }, ["n:Foo|r"] = { c = -5, lv = 3, nm = "Foo|cff" }, [77] = { c = 9, it = 0 } },
                },
                [6] = { tt = "class", s = {} },
            },
        })
        eq(bad.tr.x, nil)
        eq(bad.tr[6], nil, "no services")
        eq(bad.tr[5].tt, "general")
        eq(bad.tr[5].cls, nil)
        eq(bad.tr[5].s[-1], nil)
        eq(bad.tr[5].s["n:Foor"].c, nil, "negative cost")
        eq(bad.tr[5].s["n:Foor"].nm, "Foocff")
        eq(bad.tr[5].s[77].it, nil)
    end)
end)

test("community trainers are shown and indexed by recipe item", function()
    local env = Env()
    env.community = {
        generated = 1,
        contributors = {},
        sources = {},
        trainers = {
            [3004] = { nm = "Tailor", tt = "profession", pf = "tailoring", s = { [7623] = { c = 50, it = 2996 } } },
        },
    }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    eq(ns.Trainers.ForItem(2996)[3004], 7623)
    eq(ns.Trainers.Get(3004).pf, "tailoring")
    ns.db.settings.useCommunity = false
    ns.Fire("SETTINGS_CHANGED")
    eq(ns.Trainers.Get(3004), nil, "community switched off")
    eq(next(ns.Trainers.ForItem(2996)), nil)
end)

local function SeedEverything(ns)
    local rec = SeedKobold(ns, 40, 8)
    rec.loot[100].h = { [1] = 6, [2] = 2 }
    local q = ns.Store.EnsureSource("quest:155", "The Defias Brotherhood", "quest")
    q.attempts, q.gid, q.tid, q.req, q.giver, q.money = 2, 4000, "go:4001", { [765] = 10 }, "Gryan", 500
    q.loot[300] = { d = 2, q = 2 }
    q.choice = { [300] = true }
    ns.db.questStarts[156] = { t = 1, map = 1429, x = 0.4, y = 0.5, title = "Red Linen Goods", giver = "Sara" }
    ns.db.vendors[777] = {
        nm = "Innkeeper Farley",
        sp = { [1429] = { [4040] = 1 } },
        i = { [765] = { p = 40, st = 5, x = { [200] = 2 } } },
    }
    ns.db.recipes[2996] = { pf = "tailoring", mn = 1, mx = 1, r = { [100] = 2 } }
    ns.db.spells[6673] = { n = "Battle Shout", rk = "Rank 1", ic = 132333, ds = "Shout." }
    ns.db.trainers[914] = { nm = "Frang", tt = "class", cls = "WARRIOR", s = { [6673] = { c = 100, lv = 6 } } }
    ns.db.npcs[6740] = { nm = "Innkeeper Allison", sp = { [1429] = { [5050] = 3 } }, lv = { 30, 30 }, r = "friendly" }
    ns.Prices.Commit(100, { { p = 10, q = 5 }, { p = 12, q = 5 } }, ns.time() - 86400)
    ns.Prices.Commit(100, { { p = 11, q = 4 } }, ns.time())
    ns.Store.RefreshItemInfo(100)
    ns.Farm.SetGoal(100, 20)
    ns.MapName(1429)
    return rec
end

test("full export contains every kind of collected data", function()
    local env = Env()
    env.items[300] = { name = "Defias Boots", sell = 200 }
    local ns = Stub.Boot(ROOT, env)
    SeedEverything(ns)
    local x = ns.Export.Collect()
    eq(x.format, 1)
    eq(x.realm, "TestRealm")
    eq(x.sources[1234].n, 40, "rate denominator included")
    eq(x.sources[1234].loot[100].h[2], 2, "stack sizes")
    eq(x.sources["quest:155"], nil, "quests have their own section")
    eq(x.quests[155].required[765], 10)
    eq(x.quests[155].giverKey, 4000)
    ok(x.quests[155].rewards[300].choice)
    eq(x.quests[155].rewards[300].perTurnIn, 1)
    ok(x.quests[156].inProgress, "accepted, not turned in")
    eq(x.items[100].n, "Linen Cloth")
    eq(x.items[100].v, 13)
    eq(x.items[200].n, "Rare Ring", "items known only from a vendor cost are described too")
    eq(x.prices[100].md, 11)
    local days = 0
    for _ in pairs(x.history[100]) do
        days = days + 1
    end
    eq(days, 2, "two days of price history")
    eq(x.vendors[777].i[765].x[200], 2)
    eq(x.recipes[2996].r[100], 2)
    eq(x.npcs[6740].nm, "Innkeeper Allison")
    eq(x.maps[1429], "Map1429")
    eq(x.personal.goals[100].target, 20)
    -- sections can be chosen
    local only = ns.Export.Collect({ prices = true })
    ok(only.prices and not only.sources and not only.history)
    -- the Lua export loads back
    local chunk = assert(loadstring(ns.Export.Lua()))
    local sandbox = {}
    setfenv(chunk, sandbox)
    chunk()
    eq(sandbox.WorldCodex_Export.quests[155].required[765], 10)
    eq(sandbox.WorldCodex_Export.npcs[6740].sp[1429][5050], 3)
end)

test("JSON export encodes arrays, objects and special values correctly", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local J = ns.Export.JsonEncode
    eq(J({ 1, 2, 3 }), "[1,2,3]")
    eq(J({ [1] = "a", [3] = "c" }), '{"1":"a","3":"c"}', "sparse arrays become objects")
    eq(J({ b = 1, a = { x = true } }), '{"a":{"x":true},"b":1}')
    eq(J('say "hi"\n\tbye\\'), '"say \\"hi\\"\\n\\tbye\\\\"')
    eq(J("\1"), '"\\u0001"')
    eq(J(0 / 0), "null")
    eq(J(1.5), "1.5")
    eq(J({ [1234] = { lv = { 5, 7 } }, ["go:1"] = {} }), '{"1234":{"lv":[5,7]},"go:1":{}}')
    SeedKobold(ns, 10, 2)
    local json = ns.Export.Json({ sources = true })
    ok(json:sub(1, 1) == "{" and json:sub(-1) == "}")
    ok(json:find('"sources":{"1234":{', 1, true), json:sub(1, 200))
end)

test("CSV export has a table for every kind of data", function()
    local env = Env()
    env.items[300] = { name = "Defias Boots", sell = 200 }
    local ns = Stub.Boot(ROOT, env)
    SeedEverything(ns)
    local headers = {
        drops = "source_key,",
        quests = "quest_id,",
        items = "item_id,name,",
        prices = "item_id,item_name,scanned_at",
        history = "item_id,item_name,day",
        vendors = "npc_id,vendor_name",
        recipes = "product,product_name",
        trainers = "npc_id,trainer_name",
        spells = "spell_id,name",
        npcs = "npc_key,name",
    }
    for _, id in ipairs(ns.Export.CSV) do
        local csv = ns.Export.Csv(id)
        ok(csv:sub(1, #headers[id]) == headers[id], id .. " header: " .. csv:sub(1, 60))
        local rows = select(2, csv:gsub("\n", ""))
        ok(rows >= 1, id .. " has data rows")
    end
    ok(
        ns.Export
            .Csv("quests")
            :find('155,"The Defias Brotherhood",,"Gryan",4000,"go:4001",2,500,"required",765', 1, true)
    )
    ok(ns.Export.Csv("history"):find('100,"Linen Cloth","20', 1, true), "dates")
    ok(ns.Export.Csv("npcs"):find('6740,"Innkeeper Allison",30,30,,"friendly",,1429,"Map1429",50.5,50.5,3', 1, true))
end)

test("export window: formats, CSV tables and slash options", function()
    local _, ns = PageEnv()
    _G.SlashCmdList.WORLDCODEX("export json")
    local st = ns.UI.ExportState()
    eq(st.fmt, "json")
    ok(st.text:find('"format":1', 1, true))
    _G.SlashCmdList.WORLDCODEX("export csv npcs")
    st = ns.UI.ExportState()
    eq(st.fmt, "csv")
    eq(st.dataset, "npcs")
    ok(st.text:find("^npc_key"))
    _G.SlashCmdList.WORLDCODEX("export")
    ok(ns.UI.ExportState().text:find("^WCX1:"), "share string by default")
    _G.SlashCmdList.WORLDCODEX("export lua")
    ok(ns.UI.ExportState().text:find("^WorldCodex_Export = "))
end)

test("upload address: export window, /wcx upload and the welcome guide", function()
    local _, ns = PageEnv()
    _G.SlashCmdList.WORLDCODEX("export")
    local st = ns.UI.ExportState()
    eq(st.upload, ns.UPLOAD_URL, "copyable address next to the share string")
    ok(st.text:find("^WCX1:%S+$"), "share string stays clean (no appended comment)")
    _G.SlashCmdList.WORLDCODEX("export json")
    eq(ns.UI.ExportState().upload, nil, "only with the share string")
    _G.SlashCmdList.WORLDCODEX("upload")
    st = ns.UI.ExportState()
    eq(st.fmt, "string")
    eq(st.upload, "https://worldcodex.net/upload")
    local found
    for _, s in ipairs(ns.Welcome.Sections()) do
        if s.text:find(ns.UPLOAD_URL, 1, true) then found = true end
    end
    ok(found, "welcome guide names the upload page")
end)

-- ---------------------------------------------------------------- share strings: deltas, speed

local ME = "me00000000000001"

-- An installation whose upload with revision `rev` is in the shipped community file.
local function UploadedEnv(rev)
    return Env({
        saved = {
            settings = { useCombatLog = true },
            meta = { uid = ME, rev = rev },
            sources = {
                [1234] = {
                    name = "Kobold",
                    kind = "mob",
                    kills = 30,
                    lb = 30,
                    attempts = 30,
                    loot = { [100] = { d = 3, q = 3 } },
                },
                [5678] = {
                    name = "Murloc",
                    kind = "mob",
                    kills = 10,
                    lb = 10,
                    attempts = 10,
                    loot = { [200] = { d = 1, q = 1 } },
                },
            },
        },
        community = { version = 1, generated = 1, contributors = { [ME] = rev }, sources = {} },
    })
end

local function KillMurloc(env, ns)
    Damage(env, ns, OTHER, "Murloc")
    Die(env, ns, OTHER, "Murloc")
    Loot(env, ns, { { id = 200, name = "Rare Ring", q = 1, src = { { OTHER, 1 } } } })
end

test("once the upload is in the community file, share strings only carry what changed since", function()
    local env = UploadedEnv(40)
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    eq(ns.Store.DeltaBase(), 40)
    local _, info = ns.Report.ExportString()
    eq(info.base, 40)
    eq(info.sources, 0, "nothing new yet")
    KillMurloc(env, ns)
    ns.Prices.Commit(100, { { p = 10, q = 1 } })
    local text
    text, info = ns.Report.ExportString()
    local snap = ns.Store.ValidateSnapshot(ns.Codec.Decode(text))
    eq(snap.v, 2)
    eq(snap.base, 40)
    ok(snap.src[5678] and not snap.src[1234], "only the mob that changed")
    eq(snap.src[5678].n, 11, "whole record with lifetime totals, not just the new kill")
    ok(snap.ah[100], "new price")
    eq(info.sources, 1)
    local full = ns.Codec.Decode((ns.Report.ExportString(true)))
    eq(full.v, 1)
    ok(full.src[1234] and full.src[5678], "everything on request")
    -- a built string seals its revision: a price scanned right after is news for the next string
    ns.Prices.Commit(765, { { p = 5, q = 1 } })
    ok(ns.db.ah[765].rv > info.rev, "new revision after the export")
    _G.WorldCodex_CommunityData.contributors[ME] = info.rev -- the next release has that upload
    snap = ns.Codec.Decode((ns.Report.ExportString()))
    eq(snap.base, info.rev)
    eq(next(snap.src), nil, "the murloc is in the community file now")
    ok(snap.ah[765] and not snap.ah[100], "only the price scanned after that upload")
end)

test("share strings are cached until something changes", function()
    local env = UploadedEnv(40)
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local a = ns.Report.ExportString(true)
    local calls, snapshot = 0, ns.Store.Snapshot
    ns.Store.Snapshot = function(...)
        calls = calls + 1
        return snapshot(...)
    end
    eq(ns.Report.ExportString(true), a, "same string")
    eq(calls, 0, "not built again")
    KillMurloc(env, ns)
    ok(ns.Report.ExportString(true) ~= a, "rebuilt after a kill")
    eq(calls, 1)
    ns.Store.Snapshot = snapshot
end)

test("a delta string is imported on top of the full string it builds on", function()
    local env = UploadedEnv(40)
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local full = ns.Report.ExportString(true)
    KillMurloc(env, ns)
    local delta = ns.Report.ExportString()
    ns.db.meta.uid = "someoneelse00000"
    local okD, why = ns.Report.Import(delta)
    ok(not okD and tostring(why):find("only holds changes", 1, true), tostring(why))
    ok(ns.Report.Import(full))
    ok(ns.Report.Import(delta))
    local peer = ns.db.peers["import:" .. ME]
    eq(peer.src[5678].n, 11, "changed record replaced")
    eq(peer.src[1234].n, 30, "the rest kept")
    eq(peer.rev, ns.Codec.Decode(delta).rev)
end)

test("revisiting a merchant or an NPC without news does not mark them as changed", function()
    local env = NpcEnv()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    MerchantUI(env, { { id = 100, p = 5, st = 1 } })
    ns.Dispatch("MERCHANT_SHOW")
    Advance(ns, 1)
    local gen = ns.Store.gen
    ns.Dispatch("MERCHANT_UPDATE")
    Advance(ns, 1)
    eq(ns.Store.gen, gen, "same list in the same visit")
    MerchantUI(env, { { id = 100, p = 6, st = 1 } })
    ns.Dispatch("MERCHANT_UPDATE")
    Advance(ns, 1)
    ok(ns.Store.gen > gen, "price changed")
    ns.Dispatch("MERCHANT_CLOSED")
    ClearMerchantUI()
    env.units.npc = { guid = INNKEEPER, name = "Innkeeper Allison", level = 30 }
    ns.Dispatch("GOSSIP_SHOW")
    gen = ns.Store.gen
    ns.Dispatch("GOSSIP_SHOW")
    eq(ns.Store.gen, gen, "same NPC, same spot, same role")
    ns.Dispatch("MERCHANT_SHOW")
    ok(ns.Store.gen > gen, "new role")
end)

-- Raw DEFLATE made of stored blocks: valid for every inflater (zlib -15, LibDeflate).
local function StoredDeflate(s)
    local out, i, n = {}, 1, #s
    repeat
        local chunk = s:sub(i, i + 65534)
        i = i + #chunk
        local len = #chunk
        out[#out + 1] = string.char(
            i > n and 1 or 0,
            len % 256,
            math.floor(len / 256),
            255 - len % 256,
            255 - math.floor(len / 256)
        ) .. chunk
    until i > n
    return table.concat(out)
end

local function StoredInflate(b)
    local out, i = {}, 1
    while b:byte(i) do
        local final = b:byte(i) % 2 == 1
        local len = b:byte(i + 1) + b:byte(i + 2) * 256
        out[#out + 1] = b:sub(i + 5, i + 4 + len)
        i = i + 5 + len
        if final then return table.concat(out) end
    end
    return nil
end

local function FakeEncodingUtil(ns, wrap)
    local calls = { compress = 0, base64 = 0 }
    _G.Enum = _G.Enum or {}
    _G.Enum.CompressionMethod = { Deflate = 0 }
    _G.C_EncodingUtil = {
        CompressString = function(s)
            calls.compress = calls.compress + 1
            return wrap and ("\120\156" .. StoredDeflate(s) .. "adlr") or StoredDeflate(s)
        end,
        DecompressString = function(b) return StoredInflate(wrap and b:sub(3, -5) or b) end,
        EncodeBase64 = function(s)
            calls.base64 = calls.base64 + 1
            return ns.Codec.Base64Encode(s)
        end,
        DecodeBase64 = function(s) return ns.Codec.Base64Decode(s) end,
    }
    return calls
end

test("share strings use the client's native DEFLATE and base64 when they fit", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    SeedKobold(ns, 30, 3)
    local calls = FakeEncodingUtil(ns, false)
    local str = ns.Report.ExportString()
    eq(str:sub(1, 7), "WCX1:Z:", "compressed without LibDeflate")
    ok(calls.compress >= 2 and calls.base64 >= 2, "self-check, then the string")
    eq(ns.Codec.Decode(str).src[1234].n, 30)
    _G.C_EncodingUtil = nil
end)

test("a native compressor that is not raw DEFLATE (zlib header) is not used", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    SeedKobold(ns, 30, 3)
    FakeEncodingUtil(ns, true)
    local str = ns.Report.ExportString()
    eq(str:sub(1, 7), "WCX1:R:", "falls back: uncompressed without LibDeflate")
    eq(ns.Codec.Decode(str).src[1234].n, 30)
    _G.C_EncodingUtil = nil
end)

test("the share string is built over several frames while the game goes on", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    for i = 1, 400 do
        local rec = ns.Store.EnsureSource(10000 + i, "Mob " .. i, "mob")
        rec.kills, rec.lb, rec.attempts = 5, 5, 5
        rec.loot[100] = { d = 1, q = 1 }
    end
    local clock = 0
    _G.debugprofilestop = function()
        clock = clock + 4
        return clock
    end
    local got, info
    ns.Report.ExportStringAsync(true, function(text, i)
        got, info = text, i
    end)
    eq(got, nil, "not finished in the first frame")
    ns.Store.EnsureSource(99999, "Late", "mob") -- new sources while the job waits for a frame
    local frames = 0
    while not got and frames < 200 do
        frames = frames + 1
        ns.Tick(0.016)
    end
    ok(got, "finished")
    ok(frames > 1, "spread over frames: " .. frames)
    eq(info.sources, 400)
    local n = 0
    for _ in pairs(ns.Codec.Decode(got).src) do
        n = n + 1
    end
    eq(n, 400)
end)

test("export window: only new data when the upload is in the community file", function()
    local env = UploadedEnv(40)
    local ns = Stub.Boot(ROOT, env)
    KillMurloc(env, ns)
    _G.SlashCmdList.WORLDCODEX("export")
    local st = ns.UI.ExportState()
    ok(st.onlyNew, "option shown and on")
    ok(st.hint:find("1 sources", 1, true), st.hint)
    eq(ns.Codec.Decode(st.text:match("^(%S+)")).v, 2)
end)

test("share string carries items, prices and realm; prices from another realm are not imported", function()
    local env = Env()
    env.items[300] = { name = "Defias Boots", sell = 200 }
    _G.UnitFactionGroup = function() return "Alliance" end
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    ns.Dispatch("PLAYER_LOGIN")
    SeedEverything(ns)
    local snap = ns.Store.ValidateSnapshot(ns.Codec.Decode(ns.Report.ExportString()))
    eq(snap.it[100].n, "Linen Cloth")
    eq(snap.it[100].v, 13)
    eq(snap.ah[100].md, 11)
    eq(snap.rl, "TestRealm")
    eq(snap.fc, "Alliance")
    ns.db.meta.uid = "someoneelse00000"
    ok(ns.Store.ImportPeer("p1", snap))
    ok(ns.db.peers.p1.ah[100], "same realm and faction: prices kept")
    snap.rl = "OtherRealm"
    ok(ns.Store.ImportPeer("p2", snap))
    eq(next(ns.db.peers.p2.ah), nil, "other realm: prices dropped")
    snap.rl, snap.fc = "TestRealm", "Horde"
    ok(ns.Store.ImportPeer("p3", snap))
    eq(next(ns.db.peers.p3.ah), nil, "other faction: prices dropped")
end)

-- ---------------------------------------------------------------- repositioning (farming optional)

local function FakeAddOns(list)
    _G.C_AddOns = {
        GetNumAddOns = function() return #list end,
        GetAddOnInfo = function(i) return list[i].name, list[i].title end,
        IsAddOnLoaded = function(name)
            for _, a in ipairs(list) do
                if a.name == name then return a.loaded end
            end
            return false
        end,
    }
end

local BLACKTHORNES = {
    { name = "BlackthornesTradeskills", title = "Blackthornes Tradeskills", loaded = true },
    { name = "BlackthornesFarmer", title = "Blackthornes Farmer", loaded = true },
}

test("farming defaults off when Blackthornes Farmer is loaded and says so once", function()
    local ns = Stub.Boot(ROOT, Env())
    FakeAddOns(BLACKTHORNES)
    ns.Dispatch("PLAYER_LOGIN")
    eq(ns.db.settings.farming, false)
    ok(not ns.FarmingOn())
    local notes = 0
    for _, line in ipairs(Stub.chat) do
        if line:find("Blackthornes Farmer", 1, true) then notes = notes + 1 end
    end
    eq(notes, 1)
    ns.Dispatch("PLAYER_LOGIN")
    local again = 0
    for _, line in ipairs(Stub.chat) do
        if line:find("Blackthornes Farmer", 1, true) then again = again + 1 end
    end
    eq(again, 1, "note shown only once")
end)

test("farming stays on without a farming addon and follows it while not chosen", function()
    local ns = Stub.Boot(ROOT, Env())
    FakeAddOns({ { name = "BlackthornesTradeskills", title = "Blackthornes Tradeskills", loaded = true } })
    ns.Dispatch("PLAYER_LOGIN")
    eq(ns.db.settings.farming, true, "tradeskills alone does not count")
    FakeAddOns(BLACKTHORNES)
    ns.Dispatch("PLAYER_LOGIN")
    eq(ns.db.settings.farming, false, "installed later: switched off while the player never chose")
end)

test("an explicit farming choice survives login", function()
    local env = Env()
    env.saved.settings.farming = true
    env.saved.settings.farmingAuto = false
    local ns = Stub.Boot(ROOT, env)
    FakeAddOns(BLACKTHORNES)
    ns.Dispatch("PLAYER_LOGIN")
    eq(ns.db.settings.farming, true)
end)

test("farming off hides tracker, best farm and farming tab but keeps pace data", function()
    local env = Env()
    env.saved.settings.farming = false
    env.saved.settings.farmingAuto = false
    local ns = Stub.Boot(ROOT, env)
    local rec = SeedKobold(ns, 40, 8)
    ns.Farm.SetGoal(100, 10)
    ns.Tracker.Update()
    ok(not (_G.WorldCodexTrackerFrame and _G.WorldCodexTrackerFrame:IsShown()), "tracker hidden")
    local lines = {}
    _G.GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
    _G.GameTooltip.AddDoubleLine = function(_, a, b) lines[#lines + 1] = tostring(a) .. " | " .. tostring(b) end
    _G.GameTooltip.GetItem = function() return "Linen Cloth", "|cffffffff|Hitem:100::::|h[Linen Cloth]|h|r" end
    for _, fn in ipairs(_G.GameTooltip.__hooks.OnTooltipSetItem or {}) do
        fn(_G.GameTooltip)
    end
    local text = table.concat(lines, "\n")
    ok(text:find("Kobold"), "sources listed: " .. text)
    ok(not text:find("Best farm"), "no best farm line")
    ok(not text:find("Goal"), "no goal line")
    ns.Browser.Toggle("farming")
    eq(ns.Browser._State().tab, "items", "farming tab not reachable")
    Stub.T.now = Stub.T.now + 10
    ns.Store.CountKill(1234, rec)
    Stub.T.now = Stub.T.now + 10
    ns.Store.CountKill(1234, rec)
    ok((rec.pk or 0) >= 1, "pace still recorded")
end)

test("farming page: session facts on the left page, recent sessions as a table on the right", function()
    local env = Env()
    env.saved.settings.farming = true
    env.saved.settings.farmingAuto = false
    local ns = Stub.Boot(ROOT, env)
    SeedKobold(ns, 40, 8)
    local now = ns.time()
    ns.db.farm.cur = {
        start = now - 1800,
        last = now - 10,
        kills = 30,
        attempts = 30,
        drops = 12,
        value = 5000,
        vendor = 0,
        money = 2500,
        items = { [100] = 12 },
    }
    ns.db.farm.hist = {
        {
            start = now - 90000,
            last = now - 86400,
            kills = 80,
            attempts = 80,
            drops = 70,
            value = 3000,
            money = 600,
            items = {},
        },
    }
    ns.Farm.SetGoal(100, 40)
    local facts = ns.Farm.Facts()
    local titles = {}
    for i, sec in ipairs(facts.sections) do
        titles[i] = sec.title
    end
    eq(table.concat(titles, ","), "Current session,Most valuable loot,Goals")
    local session = facts.sections[1].rows
    eq(session[2].label, "Duration")
    eq(session[2].value, ns.Duration(29.8333))
    ok(session[3].value:find("^30"), "kills with the pace: " .. session[3].value)
    eq(facts.sections[2].rows[1].itemId, 100, "loot entries open the item page")
    eq(facts.sections[3].rows[1].itemId, 100, "goal entry")
    eq(facts.sections[3].rows[1].value, "0/40")

    ns.Browser.Toggle("farming")
    local st = ns.Page._State()
    eq(st.id, "farming")
    eq(st.panel, "farmHistory", "recent sessions on the right page")
end)

for _, loc in ipairs({ "deDE", "frFR", "esES" }) do
    test("every localized string has a " .. loc .. " translation with the same placeholders", function()
        local used = {}
        for path in io.popen("ls *.lua AH/*.lua UI/*.lua"):lines() do
            local src = io.open(path):read("*a")
            for k in src:gmatch('L%["(.-)"%]') do
                used[k] = path
            end
        end
        local text = io.open("Locales/" .. loc .. ".lua"):read("*a")
        local have = {}
        -- key and value may be split over two lines by the formatter
        for k, v in text:gmatch('L%["(.-)"%]%s*=%s*"(.-)"\n') do
            have[k] = v
        end
        local missing, bad = {}, {}
        local function specs(s)
            local out = {}
            for spec in s:gmatch("%%[%-%.%d]*[dsfx%%]") do
                out[#out + 1] = spec
            end
            return table.concat(out, " ")
        end
        for k, path in pairs(used) do
            if not have[k] then
                missing[#missing + 1] = path .. ": " .. k
            elseif specs(k) ~= specs(have[k]) then
                bad[#bad + 1] = k
            end
        end
        table.sort(missing)
        eq(#missing, 0, "untranslated:\n" .. table.concat(missing, "\n"))
        eq(#bad, 0, "placeholders differ:\n" .. table.concat(bad, "\n"))
    end)
end

-- ---------------------------------------------------------------- navigation / farming

test("ranking prefers fastest source and finds hotspot", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    local a = SeedKobold(ns, 200, 20)
    local b = ns.Store.EnsureSource(5678, "Gnoll", "mob")
    b.kills, b.attempts, b.lb, b.loot[100] = 20, 20, 20, { d = 4, q = 4 }
    ns.Store.Item(100).src[5678] = true
    ns.Store.indexDirty = true
    a.pk, a.ps = 100, 1800 -- 200/h
    b.pk, b.ps = 10, 3600 -- 10/h
    local fastest, highest = ns.Nav.Best(100)
    eq(fastest.key, 1234)
    eq(highest.key, 5678)
    for i = 1, 5 do
        ns.Store.AddSpawn(a, 1429, 0.41, 0.61)
    end
    ns.Store.AddSpawn(a, 1429, 0.90, 0.10)
    local spots = ns.Nav.Hotspots(1234)
    eq(#spots, 2)
    ok(math.abs(spots[1].x - 0.41) < 0.02, "hotspot x")
    local used = ns.Nav.SetWaypoint(1429, spots[1].x, spots[1].y, "Kobold", 1234)
    eq(used, "arrow")
    local _, bearing = ns.Nav.Relative(ns.Nav.active)
    ok(bearing, "bearing computed")
end)

test("goal ETA and session gold per hour", function()
    local env = Env({ bags = { [100] = 5 } })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local rec = SeedKobold(ns, 100, 50)
    rec.pk, rec.ps = 60, 3600
    ns.Farm.SetGoal(100, 15)
    local have, target, minutes = ns.Farm.GoalProgress(100)
    eq(have, 5)
    eq(target, 15)
    near(minutes, 20, 0.01, "10 needed at 0.5/kill and 60 kills/h")
    ns.Fire("RECEIVED", 100, 10)
    ns.Fire("MONEY", 1000)
    local s = ns.Farm.Current()
    eq(s.money, 1000)
    eq(s.value, 130)
    env.bags[100] = 15
    ns.Farm.CheckGoals()
    ok(ns.db.farm.goals[100].done, "goal completed")
end)

test("combat log is not registered unless enabled", function()
    local env = Env()
    env.saved = nil
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    eq(ns.db.settings.useCombatLog, false)
    Damage(env, ns, MOB)
    Die(env, ns, MOB)
    eq(ns.db.sources[1234], nil, "no combat-log handler active")
end)

test("unit tracking counts own solo kill without combat log", function()
    local env = Env()
    env.saved = nil
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    env.units.target = { guid = MOB, name = "Kobold", threat = 3 }
    ns.Dispatch("PLAYER_TARGET_CHANGED")
    ns.Dispatch("UNIT_HEALTH", "target")
    env.units.target.dead, env.units.target.threat = true, nil
    ns.Dispatch("UNIT_HEALTH", "target")
    ns.Dispatch("UNIT_HEALTH", "target")
    Advance(ns, 1)
    local rec = ns.db.sources[1234]
    ok(rec, "kill recorded")
    eq(rec.kills, 1)
    eq(rec.name, "Kobold")
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 1, src = { { MOB, 1 } } } })
    eq(rec.kills, 1, "looting does not count it again")
    eq(rec.attempts, 1)
end)

test("unit tracking ignores mobs tapped by others or never fought", function()
    local env = Env()
    env.saved = nil
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    env.units.target = { guid = MOB, name = "Kobold", threat = 1, denied = true }
    ns.Dispatch("UNIT_HEALTH", "target")
    env.units.target.dead = true
    ns.Dispatch("UNIT_HEALTH", "target")
    env.units.nameplate1 = { guid = OTHER, name = "Gnoll" }
    ns.Dispatch("NAME_PLATE_UNIT_ADDED", "nameplate1")
    env.units.nameplate1.dead = true
    Advance(ns, 1)
    env.units.mouseover = { guid = MOB2, name = "Kobold", dead = true }
    ns.Dispatch("UPDATE_MOUSEOVER_UNIT")
    eq(ns.db.sources[1234], nil, "tap-denied and already-dead corpses not counted")
    eq(ns.db.sources[5678], nil, "mob we never fought not counted")
end)

test("blocked action is reported with context", function()
    local ns = Stub.Boot(ROOT, Env())
    _G.debugstack = function()
        return "Interface/AddOns/WorldCodex/UI/Browser.lua:10: in function Create\nInterface/FrameXML/Foo.lua:1"
    end
    ns.context = "browser open"
    ns.Dispatch("ADDON_ACTION_FORBIDDEN", "OtherAddon", "Foo")
    eq(#ns.blocked, 0, "other addons ignored")
    ns.Dispatch("ADDON_ACTION_FORBIDDEN", "WorldCodex", "UNKNOWN")
    eq(#ns.blocked, 1)
    eq(ns.blocked[1].func, "UNKNOWN")
    eq(ns.blocked[1].context, "browser open", "context of the blocked call recorded")
    ok(ns.blocked[1].stack:find("Browser.lua"), "our stack lines kept")
    ok(not ns.blocked[1].stack:find("FrameXML"), "foreign lines dropped")
    eq(ns.db.diag[1].func, "UNKNOWN")
    ns.Slash("diag clear")
    eq(ns.db.diag, nil, "diag cleared")
    eq(#ns.blocked, 0)
    _G.debugstack = nil
end)

test("opened container is detected without hooking Blizzard functions", function()
    local env = Env()
    _G.C_Container = { GetContainerItemID = function(bag, slot) return bag == 0 and slot == 3 and 5523 or nil end }
    env.items[5523] = { name = "Small Barnacled Clam" }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    ns.Dispatch("ITEM_LOCK_CHANGED", 0, 3)
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 1, src = { { "Item-1-0-ABCDEF", 1 } } } })
    local rec = ns.db.sources["item:5523"]
    ok(rec, "container source")
    eq(rec.kind, "container")
    eq(rec.name, "Small Barnacled Clam")
    _G.C_Container = nil
end)

test("disenchanting records the input item, pooled when it is unknown", function()
    local env = Env()
    _G.C_Container = { GetContainerItemID = function() return 2589 end }
    env.items[2589] = { name = "Green Gloves" }
    env.items[10940] = { name = "Strange Dust" }
    local ns = Stub.Boot(ROOT, env)
    local function Disenchant(lock)
        ns.Dispatch("UNIT_SPELLCAST_SENT", "player", "", "Cast-3-9", 13262)
        if lock then ns.Dispatch("ITEM_LOCK_CHANGED", 0, 1) end
        Advance(ns, 3)
        ns.Dispatch("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-9", 13262)
        Advance(ns, 1)
        Loot(env, ns, { { id = 10940, name = "Strange Dust", q = 2, src = { { "Item-1-0-ABCDEF", 2 } } } })
    end
    Disenchant(true)
    local rec = ns.db.sources["de:2589"]
    ok(rec, "keyed by the disenchanted item")
    eq(rec.kind, "disenchant")
    eq(rec.name, "Green Gloves")
    eq(rec.attempts, 1)
    eq(rec.loot[10940].q, 2)
    Advance(ns, 30)
    Disenchant(false)
    ok(ns.db.sources["kind:disenchant"], "unknown input: pooled as before")
    eq(ns.db.sources["de:2589"].attempts, 1)
    ns.Page.Show({ type = "item", id = 2589 })
    local st = ns.Page._State()
    ok(table.concat(st.tabs, ","):find("de"), "input item page shows what it disenchants into")
    ns.Page.Show({ type = "item", id = 2589, tab = "de" })
    eq(ns.Page._State().rows[1].itemId, 10940)
    ns.Page.Show({ type = "item", id = 10940 })
    ok(table.concat(ns.Page._State().tabs, ","):find("process"), "dust page lists where it comes from")
    _G.C_Container = nil
end)

test("goals can be removed from slash, browser and tracker", function()
    local env = Env({ bags = { [100] = 1 } })
    local ns = Stub.Boot(ROOT, env)
    ns.Farm.SetGoal(100, 5)
    ns.Farm.SetGoal(200, 2)
    ns.Slash("goal clear nonsense")
    ok(ns.db.farm.goals[100] and ns.db.farm.goals[200], "unknown name removes nothing")
    ns.Slash("goal clear linen")
    eq(ns.db.farm.goals[100], nil, "slash removes one goal")
    ok(ns.db.farm.goals[200], "other goal kept")
    ns.Tracker.Update()
    local row = _G.WorldCodexTrackerFrame and true
    ok(row, "tracker shown")
    ns.Slash("goal clear")
    eq(next(ns.db.farm.goals), nil, "all goals removed")
end)

test("browser shows bag items by default, all items when searching or unticked", function()
    local env = Env()
    _G.C_Container = {
        GetContainerNumSlots = function(bag) return bag == 0 and 2 or 0 end,
        GetContainerItemID = function(_, slot) return ({ 100, 765 })[slot] end,
    }
    for id = 1, 15000 do
        env.items[100000 + id] = { name = "Auction Thing " .. id }
    end
    local ns = Stub.Boot(ROOT, env)
    for id = 1, 15000 do
        ns.Prices.Commit(100000 + id, { { p = id, q = 1 } })
    end
    ns.Prices.Commit(100, { { p = 50, q = 3 } })
    ns.Prices.Commit(200, { { p = 900, q = 1 } })
    eq(ns.db.settings.browserBagsOnly, true, "bags only is the default")
    ns.Browser.Toggle("items")
    local st = ns.Browser._State()
    eq(#st.data, 2, "only the two bag items")
    ns.Browser.Toggle("ah")
    eq(#st.data, 1, "AH tab: bag items with prices")
    ns.Browser.SetFilter("ring")
    eq(#st.data, 1)
    eq(st.data[1].id, 200, "search covers items outside the bags")
    ns.Browser.SetFilter("")
    ns.db.settings.browserBagsOnly = false
    local t0 = os.clock()
    ns.Browser.Toggle("items")
    local first = os.clock() - t0
    eq(#st.data, 15002, "all known items (15000 AH items + 100 + 200)")
    t0 = os.clock()
    ns.Browser.Refresh()
    local second = os.clock() - t0
    ok(second < first / 2, string.format("cached rebuild faster (%.3fs vs %.3fs)", second, first))
    ns.Browser.SetFilter("thing 1499")
    ok(#st.data >= 1 and #st.data <= 20, "search narrows the list")
    print(string.format("      15k items: first build %.0f ms, cached %.0f ms", first * 1000, second * 1000))
    _G.C_Container = nil
end)

-- Quest log with item objectives: quests[id] = { { "Sunscale Feather", have, need }, ... }
local function QuestLog(env, ns, quests)
    local ids = {}
    for id in pairs(quests) do
        ids[#ids + 1] = id
    end
    _G.C_QuestLog = {
        GetNumQuestLogEntries = function() return #ids, #ids end,
        GetQuestIDForLogIndex = function(i) return ids[i] end,
        GetQuestObjectives = function(id)
            local out = {}
            for i, o in ipairs(quests[id] or {}) do
                out[i] = {
                    text = string.format(env.questFormat or "%s: %d/%d", o[1], o[2], o[3]),
                    type = "item",
                    finished = o[2] >= o[3],
                    numFulfilled = o[2],
                    numRequired = o[3],
                }
            end
            return out
        end,
    }
    ns.Dispatch("QUEST_LOG_UPDATE")
end

local FEATHER, SHARD = 5165, 5075
local function QuestEnv(extra)
    local env = Env(extra)
    env.items[FEATHER] = { name = "Sunscale Feather", classId = 12 }
    env.items[SHARD] = { name = "Blood Shard", classId = 12 }
    return env
end

local corpse = 0
local function KillAndLoot(env, ns, drops)
    corpse = corpse + 1
    local guid = string.format("Creature-0-1-0-1-3255-0000DD%04d", corpse)
    Damage(env, ns, guid, "Screecher")
    Die(env, ns, guid, "Screecher")
    local slots = {}
    for i, id in ipairs(drops) do
        slots[i] = { id = id, name = env.items[id].name, q = 1, src = { { guid, 1 } } }
    end
    if #slots == 0 then slots[1] = { id = 100, name = "Linen Cloth", q = 1, src = { { guid, 1 } } } end
    Loot(env, ns, slots)
    return guid
end

test("quest items only count attempts made while their quest is active", function()
    local env = QuestEnv()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    QuestLog(env, ns, {})
    for _ = 1, 10 do
        KillAndLoot(env, ns, {}) -- no quest
    end
    -- objective names without an item id: attempts before the first drop count too
    QuestLog(env, ns, { [880] = { { "Sunscale Feather", 0, 3 } } })
    KillAndLoot(env, ns, {})
    KillAndLoot(env, ns, {})
    eq(ns.db.sources[3255].qp["Sunscale Feather"], 2)
    KillAndLoot(env, ns, { FEATHER })
    QuestLog(env, ns, { [880] = { { "Sunscale Feather", 1, 3 } } })
    KillAndLoot(env, ns, {})
    eq(ns.db.sources[3255].qp, nil, "known now")
    eq(ns.Store.QuestState(FEATHER), "gated")
    -- all collected, then turned in: no drops possible
    QuestLog(env, ns, { [880] = { { "Sunscale Feather", 3, 3 } } })
    for _ = 1, 5 do
        KillAndLoot(env, ns, {})
    end
    QuestLog(env, ns, {})
    for _ = 1, 5 do
        KillAndLoot(env, ns, {})
    end
    local rec = ns.db.sources[3255]
    eq(rec.lb, 24)
    local d, n = ns.Store.Combined(3255, FEATHER)
    eq(d, 1)
    eq(n, 4)
    local _, linen = ns.Store.Combined(3255, 100)
    eq(linen, 24, "ordinary items count every corpse")
    local cmp = ns.Store.Compare(3255, FEATHER)
    eq(cmp.mine.n, 4)
    eq(rec.streak[FEATHER], 1, "no dry streak without the quest")
    ok(ns.Lookup.Row(3255, FEATHER).gated)
    local snap = ns.Store.ValidateSnapshot(ns.Store.Snapshot({}))
    eq(snap.src[3255].n, 24)
    eq(snap.src[3255].qb[FEATHER], 4)
    eq(snap.src[3255].l[FEATHER][1], 1)
    eq(snap.src[3255].qb[100], nil)
    local e = ns.Export.Collect({ sources = true }).sources[3255].loot[FEATHER]
    eq(e.n, 4)
    _G.C_QuestLog = nil
end)

test("quest items: newer objective format, plural names, empty and unloaded objectives", function()
    local env = QuestEnv()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local Q = ns.Quests
    eq(Q.Needed(), nil, "nothing is known without a quest log")
    eq(Q.ObjectiveName("Sunscale Feather: 3/10"), "Sunscale Feather")
    eq(Q.ObjectiveName("3/10 Sunscale Feather"), "Sunscale Feather")
    eq(Q.ObjectiveName(" : 0/10"), nil)
    eq(Q.ObjectiveName("0/10"), nil)
    eq(Q.ObjectiveName("0/10 "), nil)
    eq(Q.Match({ ["Sunscale Feathers"] = true }, "Sunscale Feather"), "Sunscale Feathers")
    local m, ambiguous = Q.Match({ ["Feathers A"] = true, ["Feathers B"] = true }, "Feather")
    eq(m, nil)
    eq(ambiguous, true)
    env.questFormat = "%s collected: %d/%d"
    QuestLog(env, ns, { [880] = { { "Sunscale Feathers", 0, 3 } } })
    KillAndLoot(env, ns, {})
    KillAndLoot(env, ns, { FEATHER })
    local d, n = ns.Store.Combined(3255, FEATHER)
    eq(d, 1)
    eq(n, 2)
    _G.C_QuestLog = nil
end)

test("quest items: a drop from before the last objective item is no drop without a quest", function()
    local env = QuestEnv()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    QuestLog(env, ns, { [880] = { { "Sunscale Feather", 2, 3 } } })
    KillAndLoot(env, ns, { FEATHER })
    QuestLog(env, ns, { [880] = { { "Sunscale Feather", 3, 3 } } })
    KillAndLoot(env, ns, { FEATHER })
    KillAndLoot(env, ns, { FEATHER })
    eq(ns.Store.QuestState(FEATHER), "gated")
    local d, n = ns.Store.Combined(3255, FEATHER)
    eq(d, 1)
    eq(n, 1)
    _G.C_QuestLog = nil
end)

test("quest class items that drop without a quest keep the full sample", function()
    local env = QuestEnv()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    QuestLog(env, ns, { [5052] = { { "Blood Shard", 0, 1 } } })
    KillAndLoot(env, ns, { SHARD })
    eq(ns.Store.QuestState(SHARD), "gated", "not known yet")
    QuestLog(env, ns, {})
    Advance(ns, 1000)
    KillAndLoot(env, ns, { SHARD })
    KillAndLoot(env, ns, {})
    KillAndLoot(env, ns, { SHARD })
    eq(ns.Store.QuestState(SHARD), "free")
    local d, n = ns.Store.Combined(3255, SHARD)
    eq(d, 3)
    eq(n, 4)
    local s = ns.Store.Snapshot({}).src[3255]
    eq(s.qb[SHARD], 4, "explicit, so the merge knows it from old uploads")
    -- ordinary materials a quest asks for are never quest items
    QuestLog(env, ns, { [1] = { { "Linen Cloth", 0, 10 } } })
    KillAndLoot(env, ns, { 100 })
    KillAndLoot(env, ns, { 100 })
    eq(ns.Store.QuestState(100), nil)
    eq(ns.db.sources[3255].qp, nil)
    _G.C_QuestLog = nil
end)

test("quest items in shared layers: records without their own count are left out", function()
    local env = QuestEnv()
    env.community = {
        version = 1,
        generated = 5,
        contributors = { xyz = 1 },
        sources = {
            [3255] = {
                nm = "Screecher",
                k = "mob",
                n = 1000,
                m = 0,
                l = { [FEATHER] = { 30, 30 } },
                qb = { [FEATHER] = 60 },
                sp = {},
            },
        },
    }
    env.saved.version = 3
    env.saved.sources = { -- recorded before quest items were counted separately
        [3255] = {
            kind = "mob",
            name = "Screecher",
            kills = 50,
            lb = 50,
            attempts = 50,
            loot = { [FEATHER] = { d = 4, q = 4 } },
        },
    }
    env.saved.items = { [FEATHER] = { n = "Sunscale Feather", src = {} } }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local d, n = ns.Store.Combined(3255, FEATHER)
    eq(d, 30)
    eq(n, 60)
    eq(ns.Store.Compare(3255, FEATHER).mine.n, 0, "the old own numbers say nothing")
    ns.db.settings.useCommunity = false
    ns.Fire("SETTINGS_CHANGED", "useCommunity")
    d, n = ns.Store.Combined(3255, FEATHER)
    eq(d, 4)
    eq(n, 50, "nobody knows it as a quest item")
    local bad = ns.Store.ValidateSnapshot({
        v = 1,
        uid = "x",
        src = { [1] = { n = 10, l = { [7] = { 5, 5 } }, qb = { [7] = 3, [8] = 99, x = 1 } } },
    })
    eq(bad.src[1].l[7], nil, "more drops than attempts")
    eq(bad.src[1].qb[7], 3)
    eq(bad.src[1].qb[8], nil, "more than the source's attempts")
end)

local function QuestUI(env, q)
    _G.GetQuestID = function() return q.id end
    _G.GetTitleText = function() return q.title end
    _G.GetNumQuestRewards = function() return #q.rewards end
    _G.GetNumQuestChoices = function() return #q.choices end
    local function list(kind) return kind == "reward" and q.rewards or q.choices end
    _G.GetQuestItemLink = function(kind, i)
        local r = list(kind)[i]
        return "|cffffffff|Hitem:" .. r.id .. "::|h[" .. r.name .. "]|h|r"
    end
    _G.GetQuestItemInfo = function(kind, i)
        local r = list(kind)[i]
        return r.name, 0, r.q
    end
    _G.QuestIsDaily = function() return q.daily or false end
    _G.C_QuestLog = { IsQuestFlaggedCompleted = function(id) return env.completed and env.completed[id] or false end }
    env.units.npc = { name = q.giver }
end

local function ClearQuestUI()
    for _, k in ipairs({
        "GetQuestID",
        "GetTitleText",
        "GetNumQuestRewards",
        "GetNumQuestChoices",
        "GetQuestItemLink",
        "GetQuestItemInfo",
        "QuestIsDaily",
        "C_QuestLog",
    }) do
        _G[k] = nil
    end
end

test("quest rewards are recorded as a source with giver location", function()
    local env = Env({ completed = {} })
    env.items[300] = { name = "Defias Boots", sell = 200 }
    env.items[301] = { name = "Militia Gloves", sell = 150 }
    QuestUI(env, {
        id = 155,
        title = "The Defias Brotherhood",
        giver = "Gryan Stoutmantle",
        rewards = { { id = 100, name = "Linen Cloth", q = 3 } },
        choices = { { id = 300, name = "Defias Boots", q = 1 }, { id = 301, name = "Militia Gloves", q = 1 } },
    })
    local ns = Stub.Boot(ROOT, env)
    local got, money = {}, 0
    ns.On("RECEIVED", function(id, q) got[id] = q end)
    ns.On("MONEY", function(c) money = money + c end)
    env.pos = { 0.56, 0.47 }
    ns.Dispatch("QUEST_DETAIL")
    ns.Dispatch("QUEST_ACCEPTED", 155)
    env.pos = { 0.10, 0.10 }
    ns.Dispatch("QUEST_COMPLETE")
    ns.Dispatch("QUEST_TURNED_IN", 155, 1000, 2500)
    ns.Dispatch("CHAT_MSG_LOOT", "You receive item: |cffffffff|Hitem:300::|h[Defias Boots]|h|r.")
    ns.Dispatch("CHAT_MSG_LOOT", "You receive item: |cffffffff|Hitem:100::|h[Linen Cloth]|h|rx3.")
    local rec = ns.db.sources["quest:155"]
    ok(rec, "quest source")
    eq(rec.kind, "quest")
    eq(rec.name, "The Defias Brotherhood")
    eq(rec.giver, "Gryan Stoutmantle")
    eq(rec.attempts, 1)
    eq(rec.loot[100].q, 3)
    ok(rec.choice[300] and rec.choice[301], "choice rewards flagged")
    eq(rec.choice[100], nil, "fixed reward not a choice")
    eq(rec.money, 2500)
    eq(money, 2500, "quest gold counted as income")
    eq(got[300], 1)
    eq(got[100], 3)
    local spot = ns.Nav.Hotspots("quest:155")[1]
    ok(math.abs(spot.x - 0.565) < 0.01 and math.abs(spot.y - 0.475) < 0.01, "accept location used, not turn-in")
    local fastest = ns.Nav.Best(300)
    eq(fastest.key, "quest:155")
    ok(ns.Nav.Label(fastest):find("choice"), "labelled as choice")
    ok(ns.Tooltip, "tooltip module loaded")
    env.completed[155] = true
    local after, _, list = ns.Nav.Best(300)
    eq(after, nil, "finished one-time quest not suggested")
    eq(#list, 1, "but still listed")
    ok(ns.Nav.Label(list[1]):find("done"))
    ok(ns.Report.ItemDetail(300):find("Quest: The Defias Brotherhood"), "shown in item details")
    ClearQuestUI()
end)

test("quest level from the quest log is recorded and shared like a mob level", function()
    local env = Env({ completed = {} })
    QuestUI(env, { id = 155, title = "The Defias Brotherhood", giver = "Gryan", rewards = {}, choices = {} })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    _G.C_QuestLog.GetLogIndexForQuestID = function(id) return id == 155 and 3 or nil end
    _G.C_QuestLog.GetInfo = function(i) return i == 3 and { questID = 155, level = 18 } or nil end
    ns.Dispatch("QUEST_DETAIL")
    ns.Dispatch("QUEST_ACCEPTED", 155)
    _G.C_QuestLog.GetInfo = function() return nil end -- gone from the log at the turn-in
    ns.Dispatch("QUEST_COMPLETE")
    ns.Dispatch("QUEST_TURNED_IN", 155, 0, 0)
    local rec = ns.db.sources["quest:155"]
    eq(rec.lmin, 18)
    eq(rec.lmax, 18)
    eq(ns.Store.Snapshot().src["quest:155"].lv[1], 18, "shared as lv")
    ClearQuestUI()
end)

local function SearchData(env)
    env.items[300] = {
        name = "Defias Boots",
        quality = 2,
        ilvl = 22,
        req = 17,
        classId = 4,
        subclassId = 2,
        equipLoc = "INVTYPE_FEET",
    }
    env.items[301] =
        { name = "Militia Dagger", quality = 1, ilvl = 8, req = 3, classId = 2, equipLoc = "INVTYPE_WEAPON" }
    env.items[302] = { name = "Smite's Mighty Hammer", quality = 3, ilvl = 24, req = 18, classId = 2 }
    env.items[302].equipLoc = "INVTYPE_2HWEAPON"
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local kobold = SeedKobold(ns, 40, 8)
    kobold.lmin, kobold.lmax = 5, 7
    local defias = ns.Store.EnsureSource(116, "Defias Bandit", "mob")
    defias.kills, defias.attempts, defias.lb = 10, 10, 10
    defias.lmin, defias.lmax, defias.cls = 15, 16, "elite"
    defias.loot[300] = { d = 1, q = 1 }
    ns.Store.AddSpawn(defias, 1436, 0.4, 0.5)
    ns.db.maps[1436] = "Westfall"
    ns.db.vendors[777] = { nm = "Innkeeper Farley", i = { [301] = { p = 5 } } }
    ns.db.npcs[777] = { nm = "Innkeeper Farley", lv = { 30, 30 }, r = "friendly", f = { vendor = true, gossip = true } }
    ns.db.items[302] = { st = { ITEM_MOD_STRENGTH_SHORT = 11, ITEM_MOD_STAMINA_SHORT = 4 }, dv = 1 }
    ns.db.items[300] = { st = { ITEM_MOD_STAMINA_SHORT = 3 }, dv = 1 }
    local q = ns.Store.EnsureSource("quest:155", "The Defias Brotherhood", "quest")
    q.attempts, q.gid, q.lmin, q.lmax, q.rep = 1, 777, 18, 18, nil
    q.loot[302] = { d = 1, q = 1 }
    local d = ns.Store.EnsureSource("quest:200", "Kobold Candles", "quest")
    d.attempts, d.lmin, d.lmax, d.rep = 1, 6, 6, "daily"
    ns.Store.indexDirty, ns.Vendors.indexDirty = true, true
    ns.Fire("DATA_CHANGED", "test")
    return ns
end

local function Ids(rows)
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = tostring(r.id)
    end
    return table.concat(out, ",")
end

test("advanced search finds items by quality, level, slot, stat and origin", function()
    local ns = SearchData(Env())
    local S = ns.Search
    eq(Ids(S.Run("items", { quality = 2 })), "302,300", "uncommon or better, highest item level first")
    eq(Ids(S.Run("items", { ilvlMin = "20", ilvlMax = "23" })), "300")
    eq(Ids(S.Run("items", { reqMax = "5", class = 2 })), "301")
    eq(Ids(S.Run("items", { slot = "INVTYPE_FEET" })), "300")
    eq(Ids(S.Run("items", { stat = "ITEM_MOD_STAMINA_SHORT" })), "302,300")
    eq(Ids(S.Run("items", { stat = "ITEM_MOD_STAMINA_SHORT", statMin = "4" })), "302")
    eq(Ids(S.Run("items", { origin = "mob" })), "300,100", "dropped by mobs")
    eq(Ids(S.Run("items", { origin = "vendor" })), "301")
    eq(Ids(S.Run("items", { origin = "quest" })), "302")
    eq(Ids(S.Run("items", { name = "defias", origin = "mob" })), "300")
    eq(#S.Run("items", { slot = "INVTYPE_HEAD" }), 0)
    local rows = S.Run("items", { stat = "ITEM_MOD_STRENGTH_SHORT" })
    eq(rows[1].stat, 11, "stat value for the column")
    ok(#S.Stats() == 2, "stat options from the recorded items")
end)

test("advanced search finds NPCs and sources by kind, level, classification, role, zone and drops", function()
    local ns = SearchData(Env())
    local S = ns.Search
    eq(Ids(S.Run("npcs", { levelMin = "10", levelMax = "20" })), "116")
    eq(Ids(S.Run("npcs", { classification = "elite" })), "116")
    eq(Ids(S.Run("npcs", { classification = "normal", kind = "mob" })), "1234")
    eq(Ids(S.Run("npcs", { role = "vendor" })), "777", "NPCs that drop nothing are found too")
    eq(Ids(S.Run("npcs", { reaction = "friendly" })), "777")
    eq(Ids(S.Run("npcs", { kind = "npc" })), "777")
    eq(Ids(S.Run("npcs", { zone = "westf" })), "116")
    eq(Ids(S.Run("npcs", { drops = "boots" })), "116")
    eq(Ids(S.Run("npcs", { name = "kob" })), "1234")
    local all = S.Run("npcs", {})
    for _, r in ipairs(all) do
        ok(not tostring(r.id):find("^quest:"), "quests have their own tab")
    end
end)

test("advanced search finds quests by level, giver, reward, repeat and status", function()
    local env = Env({ completed = { [155] = true } })
    _G.C_QuestLog = { IsQuestFlaggedCompleted = function(id) return env.completed[id] or false end }
    local ns = SearchData(env)
    local S = ns.Search
    eq(Ids(S.Run("quests", {})), "quest:200,quest:155", "lowest level first")
    eq(Ids(S.Run("quests", { levelMin = "10" })), "quest:155")
    eq(Ids(S.Run("quests", { giver = "farley" })), "quest:155")
    eq(Ids(S.Run("quests", { reward = "hammer" })), "quest:155")
    eq(Ids(S.Run("quests", { ["repeat"] = "daily" })), "quest:200")
    eq(Ids(S.Run("quests", { ["repeat"] = "once" })), "quest:155")
    eq(Ids(S.Run("quests", { status = "open" })), "quest:200")
    eq(Ids(S.Run("quests", { status = "done" })), "quest:155")
    _G.C_QuestLog = nil
end)

test("advanced search page: form on the right, results on the left, one tab per kind", function()
    local env = Env()
    env.items[300] = { name = "Defias Boots", quality = 2, ilvl = 22, classId = 4, equipLoc = "INVTYPE_FEET" }
    local ns = Stub.Boot(ROOT, env)
    local defias = ns.Store.EnsureSource(116, "Defias Bandit", "mob")
    defias.kills, defias.attempts, defias.lb = 10, 10, 10
    defias.loot[300] = { d = 1, q = 1 }
    ns.Store.indexDirty = true
    ok(ns.Page.Show({ type = "search", id = "all" }), "shown")
    local st = ns.Page._State()
    eq(st.section, "search")
    eq(st.tabs[1], "items")
    eq(st.tabs[3], "quests")
    eq(st.panel, "search:items", "the form on the right page")
    eq(#st.rows, 0, "nothing until searched")
    ns.SearchPage.Show("items", { quality = 2 })
    Advance(ns, 1)
    st = ns.Page._State()
    eq(st.tab, "items")
    eq(Ids(st.rows), "300")
    ok(st.sub:find("1"), st.sub)
    ns.Page.types.search.Open(st.rows[1])
    eq(ns.Page._State().type, "item", "double-click opens the page")
    ns.Page.Back()
    eq(Ids(ns.Page._State().rows), "300", "results survive the way back")
    ns.SearchPage.Show("npcs", { drops = "boots" })
    Advance(ns, 1)
    st = ns.Page._State()
    eq(st.tab, "npcs")
    eq(st.panel, "search:npcs")
    eq(Ids(st.rows), "116")
end)

test("quest giver, turn-in npc and required items are recorded", function()
    local env = Env({ completed = {} })
    QuestUI(env, {
        id = 155,
        title = "The Defias Brotherhood",
        giver = "Gryan Stoutmantle",
        rewards = { { id = 100, name = "Linen Cloth", q = 3 } },
        choices = {},
    })
    _G.GetNumQuestItems = function() return 1 end
    local rewardLink = _G.GetQuestItemLink
    _G.GetQuestItemLink = function(kind, i)
        if kind == "required" then return ItemLinkOf(765, "Silverleaf") end
        return rewardLink(kind, i)
    end
    local rewardInfo = _G.GetQuestItemInfo
    _G.GetQuestItemInfo = function(kind, i)
        if kind == "required" then return "Silverleaf", 0, 10 end
        return rewardInfo(kind, i)
    end
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    env.units.npc.guid = "Creature-0-1-0-1-4000-0000EEEE01"
    ns.Dispatch("QUEST_DETAIL")
    ns.Dispatch("QUEST_ACCEPTED", 155)
    env.units.npc.guid = "GameObject-0-1-0-1-4001-0000EEEE02"
    ns.Dispatch("QUEST_PROGRESS")
    ns.Dispatch("QUEST_COMPLETE")
    ns.Dispatch("QUEST_TURNED_IN", 155, 0, 0)
    local rec = ns.db.sources["quest:155"]
    eq(rec.gid, 4000, "giver npc id")
    eq(rec.tid, "go:4001", "turned in at an object")
    eq(rec.req[765], 10)
    local idx = ns.Quests.Index()
    eq(idx.starts[4000][1], "quest:155")
    eq(idx.ends["go:4001"][1], "quest:155")
    eq(idx.requires[765][1].count, 10)
    _G.GetNumQuestItems = nil
    ClearQuestUI()
end)

test("item pushes outside a turn-in are not income", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local got = 0
    ns.On("RECEIVED", function() got = got + 1 end)
    ns.Dispatch("CHAT_MSG_LOOT", "You receive item: |cffffffff|Hitem:100::|h[Linen Cloth]|h|r.")
    eq(got, 0, "vendor purchase / crafting ignored")
end)

test("daily quest stays suggested and survives sharing", function()
    local env = Env({ completed = { [500] = true } })
    QuestUI(env, {
        id = 500,
        title = "Daily Delivery",
        giver = "Bob",
        daily = true,
        rewards = {},
        choices = { { id = 200, name = "Rare Ring", q = 1 } },
    })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    ns.Dispatch("QUEST_COMPLETE")
    ns.Dispatch("QUEST_TURNED_IN", 500, 0, 0)
    eq(ns.db.sources["quest:500"].rep, "daily")
    local fastest = ns.Nav.Best(200)
    eq(fastest.key, "quest:500", "repeatable quest still suggested")
    local snap = ns.Store.ValidateSnapshot(ns.Codec.Decode(ns.Report.ExportString()))
    eq(snap.src["quest:500"].rp, "daily")
    eq(snap.src["quest:500"].ch[200], true)
    ClearQuestUI()
end)

test("coin text is parsed in English and German", function()
    local ns = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    eq(ns.Collector.ParseCoin("1 Gold\n23 Silver\n4 Copper"), 12304)
    eq(ns.Collector.ParseCoin("17 Copper"), 17)
    eq(ns.Collector.ParseCoin("nothing"), nil)
    _G.GOLD_AMOUNT, _G.SILVER_AMOUNT, _G.COPPER_AMOUNT = "%d Gold", "%d Silber", "%d Kupfer"
    local de = Stub.Boot(ROOT, Env(), { filter = CORE_ONLY })
    eq(de.Collector.ParseCoin("2 Silber 5 Kupfer"), 205)
    _G.GOLD_AMOUNT, _G.SILVER_AMOUNT, _G.COPPER_AMOUNT = nil, nil, nil
end)

test("full corpse coin is recorded even when split in a group", function()
    local env = Env({ grouped = true })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local received = 0
    ns.On("MONEY", function(c) received = received + c end)
    env.loot = { { name = "1 Silver\n20 Copper", q = 0, src = { { MOB, 0 } } } }
    ns.Dispatch("LOOT_OPENED")
    env.money = 30 -- our share of the 120 copper
    ns.Dispatch("PLAYER_MONEY")
    ns.Dispatch("LOOT_CLOSED")
    env.money = 31
    ns.Dispatch("PLAYER_MONEY")
    local rec = ns.db.sources[1234]
    eq(rec.money, 120, "corpse total from the loot slot")
    eq(rec.mc, 1)
    eq(rec.mmin, 120)
    eq(rec.mmax, 120)
    eq(received, 31, "session counts what we actually got")
end)

test("area loot coin is split by source", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    Loot(env, ns, { { name = "50 Copper", q = 0, src = { { MOB, 20 }, { OTHER, 30 } } } })
    eq(ns.db.sources[1234].money, 20)
    eq(ns.db.sources[5678].money, 30)
end)

test("items and coin per kill summary", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    for i = 1, 4 do
        local g = string.format("Creature-0-1-0-1-1234-%010d", i)
        Damage(env, ns, g)
        Die(env, ns, g)
        local slots = { { id = 100, name = "Linen Cloth", q = i, src = { { g, i } } } }
        if i % 2 == 0 then slots[2] = { name = (i * 10) .. " Copper", q = 0, src = { { g, 0 } } } end
        if i == 4 then slots = { slots[2] } end
        Loot(env, ns, slots)
    end
    local sum = ns.Store.SourceSummary(1234)
    eq(sum.n, 4)
    near(sum.items, (1 + 2 + 3) / 4, 1e-9, "items per kill")
    near(sum.stacks, 3 / 4, 1e-9, "stacks per kill")
    near(sum.coin, (20 + 40) / 4, 1e-9, "coin per kill")
    near(sum.coinChance, 0.5, 1e-9)
    eq(sum.coinMin, 20)
    eq(sum.coinMax, 40)
    eq(sum.imax, 3)
    eq(ns.db.sources[1234].empty, 1, "coin-only loot has no items")
    local _, kind = ns.Store.SourceMeta(1234)
    eq(kind, "mob", "kind kept even without a name")
    local text = ns.Report.PerKillText(1234, "mob")
    ok(text:find("1.50 items", 1, true) and text:find("0.75 stacks", 1, true), "per kill text: " .. text)
    local csv = ns.Report.ExportCSV()
    local header, row = csv:match("^([^\n]+)\n([^\n]+)")
    local function cols(line)
        local n = 1
        for _ in line:gmatch(",") do
            n = n + 1
        end
        return n
    end
    eq(cols(row), cols(header), "CSV row matches header")
    local snap = ns.Store.ValidateSnapshot(ns.Codec.Decode(ns.Report.ExportString()))
    eq(snap.src[1234].cm[1], 2)
    eq(snap.src[1234].cm[2], 4)
    ns.db.meta.uid = "peer000000000000"
    ns.Store.ImportPeer("Bob", snap)
    eq(ns.Store.SourceSummary(1234).coinChance, 0.5, "guild data combined")
    eq(ns.Store.SourceSummary(1234).n, 8)
end)

test("stack sizes per drop: ore per node, cloth per kill", function()
    local env = Env()
    env.items[2770] = { name = "Copper Ore", sell = 5 }
    local ns = Stub.Boot(ROOT, env)
    -- 10 mining attempts on copper veins: 1,2,2,3,1,2,4,2,1,2 ore
    local amounts = { 1, 2, 2, 3, 1, 2, 4, 2, 1, 2 }
    for i, q in ipairs(amounts) do
        ns.Dispatch("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-" .. i, 2575)
        Loot(
            env,
            ns,
            { { id = 2770, name = "Copper Ore", q = q, src = { { "GameObject-0-1-0-1-1731-0000" .. i, q } } } }
        )
        Stub.T.now = Stub.T.now + 30
    end
    local rec = ns.db.sources["go:1731"]
    eq(rec.kind, "mine")
    eq(rec.loot[2770].h[2], 5)
    eq(rec.loot[2770].h[4], 1)
    local qty = ns.Report.Qty("go:1731", 2770)
    eq(qty.min, 1)
    eq(qty.max, 4)
    near(qty.avg, 2.0, 1e-9)
    eq(ns.Report.QtyRange(qty), "1-4 (Avg 2.0)")
    eq(ns.Report.QtyDist(qty), "1× 30% · 2× 50% · 3× 10% · 4× 10%")
    ok(ns.Report.SourceDetail("go:1731"):find("1-4 per drop (avg 2.0)", 1, true), "stack sizes in source details")
    ok(ns.Report.ItemDetail(2770):find("1-4 per drop (avg 2.0)", 1, true), "stack sizes in item details")
    local csv = ns.Report.ExportCSV()
    ok(csv:find(",1,4,1:3;2:5;3:1;4:1,", 1, true), "CSV min, max and distribution")
    local header, row = csv:match("^([^\n]+)\n([^\n]+)")
    local function cols(line)
        local n = 1
        for _ in line:gmatch(",") do
            n = n + 1
        end
        return n
    end
    eq(cols(row), cols(header), "CSV row matches header")
    -- guild data adds to the histogram
    local snap = ns.Store.ValidateSnapshot(ns.Codec.Decode(ns.Report.ExportString()))
    eq(snap.src["go:1731"].l[2770][3][2], 5, "histogram shared")
    ns.db.meta.uid = "peer000000000000"
    ns.Store.ImportPeer("Bob", snap)
    local h, total = ns.Store.QtyHist("go:1731", 2770)
    eq(total, 20)
    eq(h[2], 10)
end)

test("stack histogram respects the community baseline", function()
    local env = Env()
    env.saved = {
        version = 3,
        meta = { uid = "me00000000000000", rev = 1 },
        sources = {
            [1234] = {
                name = "Kobold",
                kind = "mob",
                kills = 10,
                attempts = 10,
                loot = { [100] = { d = 4, q = 6, h = { [1] = 2, [2] = 2 } } },
            },
        },
    }
    env.community = {
        version = 1,
        generated = 7,
        contributors = { me00000000000000 = true },
        sources = {
            [1234] = { nm = "Kobold", k = "mob", n = 100, l = { [100] = { 40, 60, { [1] = 20, [2] = 20 } } } },
        },
    }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local _, total = ns.Store.QtyHist(1234, 100)
    eq(total, 40, "own data already in the community file is not counted twice")
    ns.db.sources[1234].loot[100].h[3] = 1
    local h, total2 = ns.Store.QtyHist(1234, 100)
    eq(total2, 41)
    eq(h[3], 1)
end)

local function Kill(env, ns, guid)
    Damage(env, ns, guid)
    Die(env, ns, guid)
end

test("unlooted kills are left out of drop rates, empty corpses count", function()
    local env = Env()
    local lootable = {}
    _G.CanLootUnit = function(guid) return lootable[guid] end
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local A, B, C = MOB, MOB2, "Creature-0-1-0-1-1234-0000AAAA03"
    lootable[A], lootable[B], lootable[C] = true, false, true
    Kill(env, ns, A) -- has loot, looted below
    Kill(env, ns, B) -- empty corpse
    Kill(env, ns, C) -- has loot, never looted
    Loot(env, ns, { { id = 200, name = "Rare Ring", q = 1, src = { { A, 1 } } } })
    Advance(ns, 4)
    local rec = ns.db.sources[1234]
    eq(rec.kills, 3)
    eq(rec.lb, 2, "looted + empty")
    eq(rec.ek, 1)
    local d, n = ns.Store.Combined(1234, 200)
    eq(d, 1)
    eq(n, 2, "rate 1/2, not 1/3")
    eq(rec.streak[200], 1, "empty corpse is a real miss, the unlooted one is not")
    Advance(ns, 1000)
    eq(rec.ul, 1, "never-looted corpse counted as not looted")
    ok(ns.Report.SourceDetail(1234):find("Not looted: 1 (not counted)", 1, true), "shown in details")
    _G.CanLootUnit = nil
end)

test("without CanLootUnit every kill still counts", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    Kill(env, ns, MOB)
    Advance(ns, 2)
    eq(ns.db.sources[1234].lb, 1)
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 1, src = { { MOB, 1 } } } })
    eq(ns.db.sources[1234].lb, 1, "not counted twice")
end)

test("skinning a looted corpse is its own source, kill without skinning changes nothing", function()
    local env = Env()
    env.items[2318] = { name = "Light Leather" }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    Kill(env, ns, MOB)
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 1, src = { { MOB, 1 } } } })
    Kill(env, ns, MOB2) -- killed and looted, not skinned
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 1, src = { { MOB2, 1 } } } })
    env.units.target = nil -- skinning without targeting the corpse
    ns.Dispatch("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-skin1", 8613)
    Loot(env, ns, { { id = 2318, name = "Light Leather", q = 2, src = { { MOB, 2 } } } })
    local skin = ns.db.sources["skin:1234"]
    ok(skin, "skinning source")
    eq(skin.attempts, 1, "only the skinned corpse is a skinning attempt")
    eq(skin.loot[2318].q, 2)
    eq(ns.Collector.stats.dupes, 0, "not mistaken for re-looting the corpse")
    eq(ns.db.sources[1234].attempts, 2)
    eq(ns.db.sources[1234].loot[2318], nil, "leather not counted as a mob drop")
    Advance(ns, 10)
    Loot(env, ns, { { id = 2318, name = "Light Leather", q = 2, src = { { MOB, 2 } } } })
    eq(skin.attempts, 1, "reopened skinning loot not counted again")
end)

test("veins: every harvest is an attempt, failed casts are not", function()
    local env = Env()
    env.items[2770] = { name = "Copper Ore" }
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    local vein = "GameObject-0-1-0-1-1731-0000DDDD01"
    for i = 1, 2 do
        ns.Dispatch("UNIT_SPELLCAST_SENT", "player", "Copper Vein", "Cast-3-m" .. i, 2575)
        ns.Dispatch("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-m" .. i, 2575)
        Loot(env, ns, { { id = 2770, name = "Copper Ore", q = i, src = { { vein, i } } } })
        Advance(ns, 3)
    end
    local rec = ns.db.sources["go:1731"]
    eq(rec.attempts, 2, "second harvest of the same vein counted")
    eq(rec.loot[2770].q, 3)
    Advance(ns, 10)
    Loot(env, ns, { { id = 2770, name = "Copper Ore", q = 2, src = { { vein, 2 } } } })
    eq(rec.attempts, 2, "reopening without a new cast is not a new attempt")
    -- attacked while mining: the cast is interrupted, no loot
    ns.Dispatch("UNIT_SPELLCAST_SENT", "player", "Copper Vein", "Cast-3-m9", 2575)
    ns.Dispatch("UNIT_SPELLCAST_INTERRUPTED", "player", "Cast-3-m9", 2575)
    ns.Dispatch("UNIT_SPELLCAST_FAILED", "player", "Cast-3-m9", 2575)
    eq(rec.fails, 1, "counted once")
    eq(rec.attempts, 2, "failed cast is not an attempt")
    eq(ns.db.totals.fails.mine, 1)
    ok(ns.Report.SourceDetail("go:1731"):find("Failed or interrupted: 1 (not counted)", 1, true))
end)

test("fishing loot arrives long after the cast", function()
    local env = Env({ map = 1411 })
    local ns = Stub.Boot(ROOT, env, { filter = CORE_ONLY })
    ns.Dispatch("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-f1", 7620)
    Advance(ns, 15)
    Loot(env, ns, { { id = 100, name = "Linen Cloth", q = 1, src = { { "GameObject-0-1-0-1-35591-01", 1 } } } })
    ok(ns.db.sources["fish:1411"], "attributed to fishing, not to the bobber")
    eq(ns.db.sources["go:35591"], nil)
end)

-- ---------------------------------------------------------------- full load

test("welcome window opens once after the first login, not in combat, and on demand", function()
    local env = Env()
    local ns = Stub.Boot(ROOT, env)
    local combat = true
    local old = _G.InCombatLockdown
    _G.InCombatLockdown = function() return combat end
    ns.Dispatch("PLAYER_LOGIN")
    Advance(ns, 10)
    eq(ns.Welcome.IsShown(), false, "waits for the end of combat")
    combat = false
    Advance(ns, 6)
    eq(ns.Welcome.IsShown(), true)
    local greeted = 0
    for _, msg in ipairs(Stub.chat) do
        if msg:find("/wcx welcome", 1, true) then greeted = greeted + 1 end
    end
    eq(greeted, 1)
    local saved = ns.db
    ns.Welcome._Frame().buttons.close.__scripts.OnClick()
    eq(ns.Welcome.IsShown(), false)
    -- farming section and key binding follow the settings
    local with = #ns.Welcome.Sections()
    ns.db.settings.farming = false
    eq(#ns.Welcome.Sections(), with - 1)
    _G.GetBindingKey = function() return "F7" end
    ok(ns.Welcome.Sections()[4].text:find("F7", 1, true), "shows the bound key")
    _G.GetBindingKey = nil
    _G.SlashCmdList.WORLDCODEX("welcome")
    eq(ns.Welcome.IsShown(), true, "on demand")
    ns.Welcome._Frame().buttons.open.__scripts.OnClick()
    eq(ns.Welcome.IsShown(), false, "opening the book closes the guide")
    -- next login
    env.saved = saved
    ns = Stub.Boot(ROOT, env)
    _G.InCombatLockdown = function() return false end
    ns.Dispatch("PLAYER_LOGIN")
    Advance(ns, 10)
    eq(ns.Welcome.IsShown(), false, "only once")
    _G.InCombatLockdown = old
end)

test("all files load and UI entry points run", function()
    local env = Env()
    FakeAH({})
    local ns = Stub.Boot(ROOT, env)
    SeedKobold(ns, 40, 8)
    ns.Prices.Commit(100, { { p = 100, q = 1 } })
    ns.Dispatch("PLAYER_LOGIN")
    ns.Dispatch("PLAYER_ENTERING_WORLD")
    for _, cmd in ipairs({
        "help",
        "item linen",
        "mob kobold",
        "top 3",
        "kinds",
        "status",
        "ah",
        "sync",
        "goal linen 10",
        "goto linen",
        "goto stop",
        "diag",
        "options",
        "welcome",
        "report",
        "export csv",
        "export lua",
        "export",
        "import",
        "kpi",
        "session",
        "",
        "clear",
    }) do
        _G.SlashCmdList.WORLDCODEX(cmd)
    end
    ok(#ns.KPI.Rows() >= 10, "kpi rows")
    ok(ns.Report.ExportCSV():find("Linen Cloth"), "csv")
    ok(ns.Report.ExportLua():find("WorldCodex_Export"), "lua export")
    ok(ns.Farm.ReportText():find("Goals"), "farm text")
    ns.Browser.Toggle("items")
    ns.Browser.Toggle("sources")
    ns.Browser.Toggle("ah")
    ns.Browser.ShowItem(100)
    Advance(ns, 6)
    _G.SlashCmdList.WORLDCODEX("clear confirm")
    eq(next(ns.db.sources), nil, "wiped")
end)

-- ---------------------------------------------------------------- run

local savedG = {}
for k, v in pairs(_G) do
    savedG[k] = v
end

-- Optional filter: `luajit tests/run.lua <substring of test name>`
local filter = arg and arg[1]
local selected = {}
for _, t in ipairs(tests) do
    if not filter or t.name:find(filter, 1, true) then selected[#selected + 1] = t end
end
tests = selected

for _, t in ipairs(tests) do
    local okRun, err = xpcall(t.fn, debug.traceback)
    for k in pairs(_G) do
        if savedG[k] == nil then _G[k] = nil end
    end
    for k, v in pairs(savedG) do
        _G[k] = v
    end
    if okRun then
        print("ok    " .. t.name)
    else
        failures = failures + 1
        print("FAIL  " .. t.name .. "\n" .. tostring(err))
    end
end
print(string.format("\n%d tests, %d failures", #tests, failures))
os.exit(failures == 0 and 0 or 1)
