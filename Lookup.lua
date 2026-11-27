local _, ns = ...

-- Read models for the item and source pages ("Wowhead in game"): every source of an item grouped
-- into sections and ranked by how sure the rate is, the full drop table of a source, personal
-- numbers against everyone else's, zones and search. Pure data, no UI; nothing here writes to the
-- saved variables (never Store.Item / EnsureSource), so browsing community data costs no memory on disk.
local Lk = {}
ns.Lookup = Lk

local L = ns.L
local Store, Stats = ns.Store, ns.Stats

Lk.SECTION = {
    mob = "drop",
    pickpocket = "gather",
    skin = "gather",
    herb = "gather",
    mine = "gather",
    fish = "gather",
    salvage = "gather",
    object = "contained",
    lockpick = "contained",
    container = "contained",
    quest = "quest",
    disenchant = "process",
    mill = "process",
    prospect = "process",
    other = "other",
}
Lk.SECTION_ORDER = { "drop", "gather", "contained", "quest", "process", "other" }
Lk.SECTION_LABEL = {
    drop = L["Dropped by"],
    gather = L["Gathered from"],
    contained = L["Contained in"],
    quest = L["Quests"],
    process = L["Processing"],
    other = L["Other"],
}

-- Corpse gathering keys hang off a mob: "skin:1234", "pickpocket:name:Kobold", ...
Lk.RELATED = { "skin", "herb", "mine", "pickpocket", "salvage" }
local RELATED_SET = {}
for _, p in ipairs(Lk.RELATED) do
    RELATED_SET[p] = true
end

-- Rows with fewer observations are listed after all others, whatever their rate.
Lk.FEW = 5

-- Layers a page can show: everything combined, only the player's own data, or everyone else's.
Lk.LAYERS = { "all", "mine", "others" }

-- ---------------------------------------------------------------- cache

local gen = 0
local cache = {}

local function Bump()
    gen = gen + 1
    cache = {}
end
Lk.Invalidate = Bump
ns.On("DATA_CHANGED", Bump)
ns.On("SETTINGS_CHANGED", Bump)

local function Cached(id, build)
    local rev = ns.db and ns.db.meta.rev or 0
    local e = cache[id]
    if e and e.rev == rev and e.gen == gen then return e.v end
    local v = build()
    cache[id] = { rev = rev, gen = gen, v = v }
    return v
end

-- ---------------------------------------------------------------- rows

local function Counts(cmp, layer)
    if layer == "mine" then return cmp.mine.d, cmp.mine.n, cmp.mine.q end
    if layer == "others" then return cmp.others.d, cmp.others.n, cmp.others.q end
    return nil
end

-- One (source, item) pair with everything a page or tooltip shows about it.
function Lk.Row(key, itemId, layer)
    local cmp = Store.Compare(key, itemId)
    local d, n, q = Counts(cmp, layer)
    local parts
    if not d then
        d, n, q, parts = Store.Combined(key, itemId)
    end
    local name, kind = Store.SourceMeta(key)
    local lo, hi = Stats.Wilson(d, n)
    local r = {
        key = key,
        itemId = itemId,
        layer = layer or "all",
        name = name,
        kind = kind,
        section = Lk.SECTION[kind] or "other",
        d = d,
        n = n,
        q = q,
        rate = n > 0 and d / n or 0,
        lo = lo,
        hi = hi,
        avgQty = d > 0 and q / d or 0,
        perAttempt = n > 0 and q / n or 0,
        parts = parts,
        conf = Stats.Confidence(d, n),
        mine = cmp.mine,
        others = cmp.others,
        diff = 0,
    }
    local m, o = cmp.mine, cmp.others
    local differs, z, pv = Stats.Differs(m.d, m.n, o.d, o.n)
    if differs then r.diff = z > 0 and 1 or -1 end
    r.pv = pv
    if m.n > 0 and o.n > 0 and o.d > 0 then r.luck = Stats.LuckPercentile(m.d, m.n, o.d / o.n) end
    local rec = ns.db.sources[key]
    if rec then r.streak = rec.streak[itemId] end
    r.gated = kind ~= "quest" and Store.IsGated(itemId) -- counted only while its quest was active
    r.lmin, r.lmax, r.cls = Store.SourceLevel(key)
    if kind == "quest" and ns.Quests then
        local questId = ns.Quests.IdFromKey(key)
        r.choice = ns.Quests.IsChoice(key, itemId)
        r.rep = ns.Quests.RepeatType(key)
        r.done = not r.rep and questId and ns.Quests.IsCompleted(questId) or false
    end
    return r
end

-- Sure rates first: Wilson lower bound, then sample size; rows with few observations last.
function Lk.RowOrder(a, b)
    local fa, fb = a.n < Lk.FEW, b.n < Lk.FEW
    if fa ~= fb then return fb end
    if a.lo ~= b.lo then return a.lo > b.lo end
    if a.n ~= b.n then return a.n > b.n end
    return tostring(a.name) < tostring(b.name)
end

-- ---------------------------------------------------------------- item model

-- { id, layer, sections = { drop = {rows}, ... }, order = {present sections}, counts, best, total }
function Lk.ItemModel(itemId, layer)
    layer = layer or "all"
    return Cached("i" .. layer .. ":" .. tostring(itemId), function()
        local m = { id = itemId, layer = layer, sections = {}, order = {}, counts = {}, total = 0 }
        for key in pairs(Store.SourcesForItem(itemId)) do
            local r = Lk.Row(key, itemId, layer)
            if r.n > 0 and r.d > 0 then
                local list = m.sections[r.section]
                if not list then
                    list = {}
                    m.sections[r.section] = list
                end
                list[#list + 1] = r
                m.total = m.total + 1
            end
        end
        for _, s in ipairs(Lk.SECTION_ORDER) do
            local list = m.sections[s]
            if list then
                table.sort(list, Lk.RowOrder)
                m.order[#m.order + 1] = s
                m.counts[s] = #list
                for _, r in ipairs(list) do
                    if not r.done and r.n >= Lk.FEW and (not m.best or r.lo > m.best.lo) then m.best = r end
                end
            end
        end
        return m
    end)
end

-- ---------------------------------------------------------------- source model

-- Display name of any key: a loot source, else an NPC seen or a vendor visited.
function Lk.Name(key)
    local name = Store.SourceMeta(key)
    if name ~= tostring(key) then return name end
    return (ns.Npcs and ns.Npcs.Name(key)) or (ns.Vendors and ns.Vendors.Get(key) and ns.Vendors.Name(key)) or name
end

-- npc id behind a key, for portraits and models: 1234, "skin:1234" -> 1234; nil for objects etc.
function Lk.NpcId(key)
    if type(key) == "number" then return key end
    local prefix, base = Lk.SplitKey(key)
    if prefix and type(base) == "number" then return base end
    return nil
end

-- "skin:1234" -> "skin", 1234; "pickpocket:name:Kobold" -> "pickpocket", "name:Kobold"
function Lk.SplitKey(key)
    if type(key) ~= "string" then return nil, key end
    local prefix, rest = key:match("^(%a+):(.+)$")
    if prefix and RELATED_SET[prefix] then return prefix, tonumber(rest) or rest end
    return nil, key
end

-- The mob a source belongs to, and its corpse-gathering sources that have data.
function Lk.Related(key)
    local prefix, base = Lk.SplitKey(key)
    if not prefix and not (type(key) == "number" or (type(key) == "string" and key:match("^name:"))) then
        return nil, {}
    end
    local out = {}
    if prefix and Store.HasSource(base) then
        local name, kind = Store.SourceMeta(base)
        out[#out + 1] = { key = base, name = name, kind = kind, n = (Store.SourceBaseCombined(base)) }
    end
    for _, p in ipairs(Lk.RELATED) do
        local k = p .. ":" .. tostring(base)
        if k ~= key and Store.HasSource(k) then
            local name, kind = Store.SourceMeta(k)
            out[#out + 1] = { key = k, name = name, kind = kind, n = (Store.SourceBaseCombined(k)) }
        end
    end
    return base, out
end

-- Map shares of a source's spawn cells: { {map, name, weight, share} } sorted by weight.
function Lk.Zones(key, limit)
    local out, total = {}, 0
    for map, w in pairs(Store.ZoneCounts(key)) do
        if w > 0 then
            out[#out + 1] = { map = map, weight = w }
            total = total + w
        end
    end
    table.sort(out, function(a, b) return a.weight > b.weight end)
    if limit then
        for i = #out, limit + 1, -1 do
            out[i] = nil
        end
    end
    for _, z in ipairs(out) do
        z.share = total > 0 and z.weight / total or 0
        z.name = ns.MapName(z.map)
    end
    return out
end

-- { key, name, kind, layer, summary, coin = {mine, others}, items = {rows}, related, parent,
--   personal = {kills, lb, ek, ul, attempts, fails}, lmin, lmax, cls, zones, diffs = {rows} }
function Lk.SourceModel(key, layer)
    layer = layer or "all"
    return Cached("s" .. layer .. ":" .. tostring(key), function()
        local name, kind = Store.SourceMeta(key)
        if not Store.HasSource(key) then
            -- an NPC that was only seen, talked to or bought from
            name = Lk.Name(key)
            kind = (ns.Vendors and ns.Vendors.Get(key)) and "vendor" or "npc"
        end
        local m = {
            key = key,
            name = name,
            kind = kind,
            layer = layer,
            summary = Store.SourceSummary(key),
            coin = Store.CompareSource(key),
            items = {},
            diffs = {},
        }
        for id in pairs(Store.SourceItems(key)) do
            local r = Lk.Row(key, id, layer)
            if r.n > 0 and r.d > 0 then m.items[#m.items + 1] = r end
            if r.diff ~= 0 then m.diffs[#m.diffs + 1] = r end
        end
        table.sort(m.items, function(a, b)
            if a.rate ~= b.rate then return a.rate > b.rate end
            return a.n > b.n
        end)
        table.sort(m.diffs, function(a, b) return a.pv < b.pv end)
        local parent, related = Lk.Related(key)
        m.related = related
        if Lk.SplitKey(key) then m.parent = parent end
        local rec = ns.db.sources[key]
        if rec then
            m.personal = {
                kills = rec.kills,
                lb = rec.lb,
                ek = rec.ek,
                ul = rec.ul,
                attempts = rec.attempts,
                fails = rec.fails,
            }
        end
        m.lmin, m.lmax, m.cls = Store.SourceLevel(key)
        local info = ns.Npcs and ns.Npcs.Info(key)
        if info then
            if not m.lmin and info.lv then
                m.lmin, m.lmax = info.lv[1], info.lv[2]
            end
            m.cls = m.cls or info.cl
            m.reaction = info.r
            m.roles = info.f
        end
        m.npcId = Lk.NpcId(key)
        m.zones = Lk.Zones(key, 5)
        return m
    end)
end

-- Every (source, item) pair where the player's rate differs significantly from everyone else's.
function Lk.Differences(limit)
    return Cached("diffs", function()
        local out = {}
        for key, rec in pairs(ns.db.sources) do
            for id in pairs(rec.loot) do
                local r = Lk.Row(key, id, "all")
                if r.diff ~= 0 then out[#out + 1] = r end
            end
        end
        table.sort(out, function(a, b) return a.pv < b.pv end)
        if limit then
            for i = #out, limit + 1, -1 do
                out[i] = nil
            end
        end
        return out
    end)
end

-- Loot sources that are objects (chests, herbs, veins, ...) with this name, most data first. Several
-- object types can share a name ("Battered Chest").
function Lk.ObjectsByName(name)
    if type(name) ~= "string" or name == "" then return {} end
    local idx = Cached("objects", function()
        local byName = {}
        for key in pairs(Store.AllSourceKeys()) do
            if type(key) == "string" and key:match("^go:") then
                local n = tostring((Store.SourceMeta(key))):lower()
                byName[n] = byName[n] or {}
                table.insert(byName[n], key)
            end
        end
        for _, list in pairs(byName) do
            table.sort(list, function(a, b) return Store.SourceBaseCombined(a) > Store.SourceBaseCombined(b) end)
        end
        return byName
    end)
    return idx[name:lower()] or {}
end

-- The mob (npc id key) with this name that has the most data, or nil. In instances the client hides
-- the GUID of the unit under the mouse; the tooltip's name is all there is to go on.
function Lk.MobByName(name)
    if type(name) ~= "string" or name == "" then return nil end
    local idx = Cached("mobs", function()
        local byName = {}
        for key in pairs(Store.AllSourceKeys()) do
            if type(key) == "number" then
                local n, kind = Store.SourceMeta(key)
                if kind == "mob" then
                    n = tostring(n):lower()
                    local best = byName[n]
                    if not best or Store.SourceBaseCombined(key) > Store.SourceBaseCombined(best) then
                        byName[n] = key
                    end
                end
            end
        end
        return byName
    end)
    return idx[name:lower()]
end

-- ---------------------------------------------------------------- names and search

local names = {}

-- Lower-case item name; placeholder names of uncached items are not kept, so they resolve later.
function Lk.LowerName(id)
    local n = names[id]
    if n then return n end
    local name = ns.ItemName(id)
    n = name:lower()
    if name:sub(1, 5) ~= "item:" then names[id] = n end
    return n
end

function Lk.ForgetName(id)
    if id then
        names[id] = nil
    else
        names = {}
    end
end

ns.RegisterEvent("GET_ITEM_INFO_RECEIVED", function(itemId) names[itemId] = nil end)

-- Asks the client for names of items it has not cached yet (community data), a few at a time and
-- never in combat, so search can find them. The scan over every item runs at most once a minute (it is
-- called on every list filter while unnamed rows show, and some ids never get a name).
local warming, warmedAt
function Lk.WarmNames()
    if warming or not ns.db then return end
    local now = GetTime and GetTime() or 0
    if warmedAt and now - warmedAt < 60 then return end
    warmedAt = now
    local request = (C_Item and C_Item.RequestLoadItemDataByID) or nil
    local queue = {}
    for id in pairs(Store.AllItemIds()) do
        if not names[id] then
            local name = ns.ItemInfo(id)
            if name then
                names[id] = name:lower() -- known: the next scan skips the client call
            else
                queue[#queue + 1] = id
            end
        end
    end
    if #queue == 0 then return end
    warming = { queue = queue, i = 1 }
    local function step()
        if not warming then return end
        if ns.InCombat() then return ns.After(2, step) end
        for _ = 1, 20 do
            local id = warming.queue[warming.i]
            if not id then
                warming = nil
                return
            end
            warming.i = warming.i + 1
            if request then
                pcall(request, id)
            else
                ns.ItemInfo(id)
            end
        end
        ns.After(0.1, step)
    end
    step()
end

function Lk.WarmProgress()
    if not warming then return nil end
    return warming.i - 1, #warming.queue
end

local function Score(name, q)
    if name == q then return 3 end
    if name:sub(1, #q) == q then return 2 end
    if name:find(q, 1, true) then return 1 end
    return 0
end

-- Items and sources whose name matches q (exact > prefix > substring, then more data first).
-- Item ids ("#2589", "2589") and item links match the item directly.
function Lk.Search(q, limit)
    limit = limit or 30
    q = ns.Trim(q):lower()
    local out = {}
    if q == "" then return out end
    local linked = ns.ItemIdFromLink(q)
    local id = linked or tonumber(q:match("^#?(%d+)$"))
    if id then out[#out + 1] = { type = "item", id = id, name = ns.ItemName(id), score = 4, n = 0 } end
    if linked then return out end
    for itemId in pairs(Store.AllItemIds()) do
        if itemId ~= id then
            local s = Score(Lk.LowerName(itemId), q)
            if s > 0 then
                out[#out + 1] = { type = "item", id = itemId, name = ns.ItemName(itemId), score = s, n = 0 }
            end
        end
    end
    local keys = Store.AllSourceKeys()
    -- NPCs that are no loot source (vendors, trainers, quest givers) are found too
    for _, extra in ipairs({ ns.Npcs and ns.Npcs.AllIds() or {}, ns.Vendors and ns.Vendors.AllIds() or {} }) do
        for key in pairs(extra) do
            keys[key] = true
        end
    end
    for key in pairs(keys) do
        local name = Lk.Name(key)
        local s = Score(tostring(name):lower(), q)
        if s > 0 then
            local isSource = Store.HasSource(key)
            out[#out + 1] = {
                type = "source",
                key = key,
                name = name,
                kind = isSource and select(2, Store.SourceMeta(key)) or "npc",
                score = s,
                n = isSource and (Store.SourceBaseCombined(key)) or 0,
            }
        end
    end
    -- spells trainers teach and recipe spells (Spells.lua). Every word of the query must appear in
    -- the name, the rank or the required level, so "rend rank 2", "verwunden 2" or "rend level 10" find one
    -- rank among many.
    if ns.Spells then
        local words = {}
        for w in q:gmatch("[^%s%(%)]+") do
            words[#words + 1] = w
        end
        local levelWord = tostring(L["Level"]):lower()
        for spellId in pairs(ns.Spells.AllIds()) do
            local name, rank = ns.Spells.Brief(spellId)
            if name then
                local lower = name:lower()
                local s = Score(lower, q)
                local level
                if s == 0 then
                    level = ns.Spells.Level(spellId)
                    local hay = table.concat(
                        { lower, rank and rank:lower() or "", level and (levelWord .. " " .. level) or "" },
                        " "
                    )
                    -- numbers match whole numbers only ("rank 1" must not find "level 10")
                    local numbers = {}
                    for d in hay:gmatch("%d+") do
                        numbers[d] = true
                    end
                    local all = #words > 0
                    for _, w in ipairs(words) do
                        local found
                        if w:match("^%d+$") then
                            found = numbers[w]
                        else
                            found = hay:find(w, 1, true)
                        end
                        if not found then
                            all = false
                            break
                        end
                    end
                    if all then s = 1 end
                end
                if s > 0 then
                    out[#out + 1] = {
                        type = "spell",
                        id = spellId,
                        name = name,
                        rank = rank,
                        level = level or ns.Spells.Level(spellId),
                        recipe = ns.Crafting and ns.Crafting.ForSpell(spellId) ~= nil,
                        score = s,
                        n = 0,
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.n ~= b.n then return a.n > b.n end
        if a.name ~= b.name then return tostring(a.name) < tostring(b.name) end
        -- ranks of one spell: lowest level first
        return (a.level or 0) < (b.level or 0)
    end)
    for i = #out, limit + 1, -1 do
        out[i] = nil
    end
    return out
end
