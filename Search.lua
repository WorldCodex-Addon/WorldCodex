local _, ns = ...

-- Advanced search (the "Advanced search" section of the WorldCodex window, UI/PageSearch.lua): items by
-- name, quality, item level, required level, class, slot, stat and where they come from; NPCs and
-- sources by name, kind, level, classification, reaction, role, zone and the items they drop; quests by
-- name, level, zone, giver, reward, repeat type and whether the player has done them.
--
-- A filter is a table of optional fields (nil or "" = any); S.Run(kind, filter) returns the matching rows,
-- sorted. Cheap tests run first so that expensive ones (levels and zones of community records, which are
-- decoded on access) only run for entries that passed the others. It calls ns.Yield in its loops, so it
-- can run as a background job (S.Start). Item facts come from the client's item cache and db.items: the
-- community file carries no item details, so items the client has not cached are only found by name and
-- source until their facts arrive.
local S = {}
ns.Search = S

local L = ns.L
local Store = ns.Store

S.KINDS = { "items", "npcs", "quests" }
S.MAX_ROWS = 2000
S.MAX_ITEM_MATCHES = 300 -- items considered for "drops" / "reward" filters

-- ---------------------------------------------------------------- option lists (for the form)

local function Global(name, fallback)
    local v = _G[name]
    if type(v) == "string" and v ~= "" then return v end
    return fallback
end

S.QUALITIES = {
    { 0, Global("ITEM_QUALITY0_DESC", L["Poor"]) },
    { 1, Global("ITEM_QUALITY1_DESC", L["Common"]) },
    { 2, Global("ITEM_QUALITY2_DESC", L["Uncommon"]) },
    { 3, Global("ITEM_QUALITY3_DESC", L["Rare"]) },
    { 4, Global("ITEM_QUALITY4_DESC", L["Epic"]) },
    { 5, Global("ITEM_QUALITY5_DESC", L["Legendary"]) },
}

-- Item classes (Enum.ItemClass) with the client's names.
local CLASS_IDS = { 0, 1, 2, 3, 4, 5, 7, 9, 12, 15 }
local CLASS_FALLBACK = {
    [0] = L["Consumable"],
    [1] = L["Container"],
    [2] = L["Weapon"],
    [3] = L["Gem"],
    [4] = L["Armor"],
    [5] = L["Reagent"],
    [7] = L["Trade goods"],
    [9] = L["Recipe"],
    [12] = L["Quest"],
    [15] = L["Miscellaneous"],
}
function S.Classes()
    local out = {}
    local info = C_Item and C_Item.GetItemClassInfo
    for _, id in ipairs(CLASS_IDS) do
        local name = info and ns.Call(info, id)
        out[#out + 1] = { id, type(name) == "string" and name ~= "" and name or CLASS_FALLBACK[id] }
    end
    return out
end

-- Equipment slots (inventory type names; the client's global strings are their labels).
S.SLOTS = {
    "INVTYPE_HEAD",
    "INVTYPE_NECK",
    "INVTYPE_SHOULDER",
    "INVTYPE_CLOAK",
    "INVTYPE_CHEST",
    "INVTYPE_ROBE",
    "INVTYPE_WRIST",
    "INVTYPE_HAND",
    "INVTYPE_WAIST",
    "INVTYPE_LEGS",
    "INVTYPE_FEET",
    "INVTYPE_FINGER",
    "INVTYPE_TRINKET",
    "INVTYPE_WEAPON",
    "INVTYPE_2HWEAPON",
    "INVTYPE_WEAPONMAINHAND",
    "INVTYPE_WEAPONOFFHAND",
    "INVTYPE_SHIELD",
    "INVTYPE_HOLDABLE",
    "INVTYPE_RANGED",
    "INVTYPE_RANGEDRIGHT",
    "INVTYPE_THROWN",
    "INVTYPE_RELIC",
    "INVTYPE_BAG",
}
-- chest and robe are the same slot
local SLOT_ALIAS = { INVTYPE_ROBE = "INVTYPE_CHEST" }
function S.SlotLabel(loc) return Global(loc, (loc:gsub("^INVTYPE_", ""):lower())) end

-- Where an item comes from: groups of source kinds, plus vendors and crafting.
S.ORIGINS = {
    { "mob", L["Mobs"], { mob = true, pickpocket = true } },
    { "gather", L["Gathering"], { herb = true, mine = true, skin = true, fish = true } },
    { "object", L["Chests & objects"], { object = true, container = true, lockpick = true } },
    { "quest", L["Quests"], { quest = true } },
    { "vendor", L["Vendors"] },
    { "craft", L["Crafting"] },
}

-- Stat keys found in the recorded item details, with labels.
function S.Stats()
    local seen = {}
    for _, it in pairs(ns.db.items) do
        if type(it.st) == "table" then
            for key, v in pairs(it.st) do
                if type(v) == "number" then seen[key] = true end
            end
        end
    end
    local out = {}
    for key in pairs(seen) do
        out[#out + 1] = { key, ns.Report.StatLabel(key) }
    end
    table.sort(out, function(a, b) return tostring(a[2]) < tostring(b[2]) end)
    return out
end

S.CLASSIFICATIONS = {
    { "normal", L["normal"] },
    { "elite", L["elite"] },
    { "rare", L["rare"] },
    { "rareelite", L["rare elite"] },
    { "worldboss", L["world boss"] },
}
S.REACTIONS = { { "hostile", L["hostile"] }, { "neutral", L["neutral"] }, { "friendly", L["friendly"] } }
S.ROLES = {
    { "vendor", L["Vendor"] },
    { "trainer", L["Trainer"] },
    { "quest", L["Quest giver"] },
    { "taxi", L["Flight master"] },
    { "banker", L["Banker"] },
    { "gossip", L["Gossip"] },
}
S.REPEATS = { { "once", L["once"] }, { "daily", L["daily"] }, { "weekly", L["weekly"] } }
S.STATUS = { { "done", L["done"] }, { "open", L["not done"] } }

-- Source kinds for the NPC search: the loot source kinds (without quests) and NPCs that drop nothing.
function S.SourceKinds()
    local out = {}
    for kind, label in pairs(ns.KIND_LABEL) do
        if kind ~= "quest" then out[#out + 1] = { kind, label } end
    end
    table.sort(out, function(a, b) return a[2] < b[2] end)
    out[#out + 1] = { "npc", L["Other NPCs"] }
    return out
end

-- ---------------------------------------------------------------- helpers

local function Text(v)
    if type(v) ~= "string" then return nil end
    v = ns.Trim(v):lower()
    return v ~= "" and v or nil
end

local function Has(v) return v ~= nil and v ~= "" end

-- true when [lo, hi] overlaps the filter range [min, max] (either end may be nil)
local function InRange(lo, hi, min, max)
    if not min and not max then return true end
    if not lo then return false end
    hi = hi or lo
    if min and hi < min then return false end
    if max and lo > max then return false end
    return true
end

-- Lower-case name contains the text.
local function NameHas(name, q) return tostring(name or ""):lower():find(q, 1, true) ~= nil end

-- Zones of a source whose name contains the text.
local function ZoneHas(key, q)
    for _, z in ipairs(ns.Lookup.Zones(key)) do
        if NameHas(z.name, q) then return true end
    end
    return false
end

-- Source keys that have an item whose name contains the text (at most MAX_ITEM_MATCHES items).
local function SourcesDropping(q)
    local keys, n = {}, 0
    for id in pairs(S.AllItems()) do
        if ns.Lookup.LowerName(id):find(q, 1, true) then
            for key in pairs(Store.SourcesForItem(id)) do
                keys[key] = true
            end
            n = n + 1
            if n >= S.MAX_ITEM_MATCHES then break end
        end
        ns.Yield()
    end
    return keys
end

-- Every item WorldCodex knows: loot, recorded items and prices (Store.AllItemIds), plus what vendors sell
-- and what recipes make or use.
function S.AllItems()
    local ids = Store.AllItemIds()
    for _, l in ipairs(ns.Vendors and ns.Vendors.Layers() or {}) do
        for _, rec in pairs(l.t) do
            if type(rec) == "table" and type(rec.i) == "table" then
                for id in pairs(rec.i) do
                    if type(id) == "number" then ids[id] = true end
                end
            end
        end
    end
    for _, l in ipairs(ns.Crafting and ns.Crafting.Layers() or {}) do
        for product, rec in pairs(l.t) do
            if type(product) == "number" then ids[product] = true end
            if type(rec) == "table" and type(rec.r) == "table" then
                for id in pairs(rec.r) do
                    if type(id) == "number" then ids[id] = true end
                end
            end
        end
    end
    return ids
end

-- What is known about an item without asking the server: the client's cache, else the facts recorded
-- in db.items, else GetItemInfoInstant (class, subclass, slot).
function S.ItemFacts(id)
    local it = ns.db.items[id]
    local d = ns.ItemDetails(id)
    local f = {
        quality = d.quality or (it and it.ql),
        ilvl = d.ilvl or (it and it.il),
        req = d.minLevel or (it and it.rq) or nil,
        classId = d.classId or (it and it.cl),
        subclassId = d.subclassId or (it and it.sc),
        equipLoc = d.equipLoc or (it and it.eq),
        subclass = d.subclass,
        stats = it and type(it.st) == "table" and it.st or nil,
    }
    if f.classId == nil and C_Item and C_Item.GetItemInfoInstant then
        local ok, _, _, sub, loc, _, cl, sc = pcall(C_Item.GetItemInfoInstant, id)
        if ok then
            f.classId, f.subclassId = cl, sc
            f.subclass = f.subclass or sub
            if type(loc) == "string" and loc ~= "" then f.equipLoc = f.equipLoc or loc end
        end
    end
    if f.req == 0 then f.req = nil end
    return f
end

local function Origin(id, origin)
    if origin == "vendor" then return ns.Vendors ~= nil and next(ns.Vendors.ForItem(id)) ~= nil end
    if origin == "craft" then return ns.Crafting ~= nil and ns.Crafting.Get(id) ~= nil end
    local kinds
    for _, o in ipairs(S.ORIGINS) do
        if o[1] == origin then kinds = o[3] end
    end
    if not kinds then return true end
    for key in pairs(Store.SourcesForItem(id)) do
        local _, kind = Store.SourceMeta(key)
        if kinds[kind] then return true end
    end
    return false
end

-- ---------------------------------------------------------------- searches

local Run = {}

function Run.items(f)
    local q = Text(f.name)
    local min, max = tonumber(f.ilvlMin), tonumber(f.ilvlMax)
    local rmin, rmax = tonumber(f.reqMin), tonumber(f.reqMax)
    local quality, class = tonumber(f.quality), tonumber(f.class)
    local slot = Has(f.slot) and f.slot or nil
    local stat = Has(f.stat) and f.stat or nil
    local statMin = tonumber(f.statMin)
    local origin = Has(f.origin) and f.origin or nil
    local out = {}
    for id in pairs(S.AllItems()) do
        ns.Yield()
        if not q or ns.Lookup.LowerName(id):find(q, 1, true) then
            local x = S.ItemFacts(id)
            local ok = true
            if quality and not (x.quality and x.quality >= quality) then ok = false end
            if ok and class and x.classId ~= class then ok = false end
            if ok and slot and (SLOT_ALIAS[x.equipLoc] or x.equipLoc) ~= (SLOT_ALIAS[slot] or slot) then ok = false end
            if ok and (min or max) and not InRange(x.ilvl, x.ilvl, min, max) then ok = false end
            if ok and (rmin or rmax) and not InRange(x.req or 1, x.req or 1, rmin, rmax) then ok = false end
            local sv
            if ok and stat then
                sv = x.stats and x.stats[stat]
                if type(sv) ~= "number" or sv == 0 or (statMin and sv < statMin) then ok = false end
            end
            if ok and origin and not Origin(id, origin) then ok = false end
            if ok then
                local p = ns.Prices.Get(id)
                out[#out + 1] = {
                    type = "item",
                    id = id,
                    name = ns.Lookup.LowerName(id),
                    label = ns.ItemName(id, true),
                    ilvl = x.ilvl or 0,
                    req = x.req or 0,
                    kindText = ((x.classId == 2 or x.classId == 4) and x.equipLoc and Global(x.equipLoc))
                        or x.subclass
                        or "",
                    stat = sv or 0,
                    price = p and p.market or 0,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
        return a.name < b.name
    end)
    return out
end

-- Keys of every NPC and source (quests apart): loot sources, NPCs met, vendors.
local function SourceKeys(quests)
    local sources = Store.AllSourceKeys()
    local keys = {}
    for key in pairs(sources) do
        if (ns.Quests.IdFromKey(key) ~= nil) == quests then keys[key] = true end
    end
    if not quests then
        for _, extra in ipairs({ ns.Npcs and ns.Npcs.AllIds() or {}, ns.Vendors and ns.Vendors.AllIds() or {} }) do
            for key in pairs(extra) do
                keys[key] = true
            end
        end
    end
    return keys, sources
end

function Run.npcs(f)
    local q = Text(f.name)
    local kindF = Has(f.kind) and f.kind or nil
    local min, max = tonumber(f.levelMin), tonumber(f.levelMax)
    local clsF = Has(f.classification) and f.classification or nil
    local reactF = Has(f.reaction) and f.reaction or nil
    local roleF = Has(f.role) and f.role or nil
    local zone = Text(f.zone)
    local drops = Text(f.drops) and SourcesDropping(Text(f.drops)) or nil
    local keys, sources = SourceKeys(false)
    local out = {}
    for key in pairs(keys) do
        ns.Yield()
        local ok = not drops or drops[key]
        local name, kind
        if ok then
            name = ns.Lookup.Name(key)
            if q and not NameHas(name, q) then ok = false end
        end
        if ok then
            if sources[key] then
                kind = select(2, Store.SourceMeta(key))
            else
                kind = "npc"
            end
            if kindF and kind ~= kindF then ok = false end
        end
        local info, lmin, lmax, cls
        if ok and (min or max or clsF or reactF or roleF) then
            info = ns.Npcs and ns.Npcs.Info(key) or nil
            if sources[key] then
                lmin, lmax, cls = Store.SourceLevel(key)
            end
            if not lmin and info and info.lv then
                lmin, lmax = info.lv[1], info.lv[2]
            end
            cls = cls or (info and info.cl)
            if not InRange(lmin, lmax, min, max) then ok = false end
            if ok and clsF and (cls or "normal") ~= clsF then ok = false end
            if ok and reactF and not (info and info.r == reactF) then ok = false end
            if ok and roleF then
                local has = info and info.f and info.f[roleF]
                if roleF == "vendor" and ns.Vendors and ns.Vendors.Get(key) then has = true end
                if not has then ok = false end
            end
        end
        if ok and zone and not ZoneHas(key, zone) then ok = false end
        if ok then
            out[#out + 1] = {
                type = "source",
                id = key,
                name = tostring(name):lower(),
                label = tostring(name),
                kindKey = kind,
                kind = kind == "npc" and L["NPC"] or (ns.KIND_LABEL[kind] or tostring(kind)),
                lmin = lmin,
                lmax = lmax,
                cls = cls,
                levelDone = info ~= nil or lmin ~= nil,
                n = sources[key] and (Store.SourceBaseCombined(key)) or 0,
            }
        end
    end
    table.sort(out, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.name < b.name
    end)
    return out
end

function Run.quests(f)
    local q = Text(f.name)
    local min, max = tonumber(f.levelMin), tonumber(f.levelMax)
    local zone = Text(f.zone)
    local giver = Text(f.giver)
    local rewards = Text(f.reward) and SourcesDropping(Text(f.reward)) or nil
    local rep = Has(f["repeat"]) and f["repeat"] or nil
    local status = Has(f.status) and f.status or nil
    local keys = SourceKeys(true)
    local out = {}
    for key in pairs(keys) do
        ns.Yield()
        local ok = not rewards or rewards[key]
        local name
        if ok then
            name = ns.Lookup.Name(key)
            if q and not NameHas(name, q) then ok = false end
        end
        local questId = ns.Quests.IdFromKey(key)
        if ok and status then
            local done = ns.Quests.IsCompleted(questId)
            if (status == "done") ~= done then ok = false end
        end
        if ok and rep and (ns.Quests.RepeatType(key) or "once") ~= rep then ok = false end
        local lmin, lmax
        if ok then
            lmin, lmax = Store.SourceLevel(key)
            if not InRange(lmin, lmax, min, max) then ok = false end
        end
        local gid, giverName
        if ok then
            gid = ns.Quests.Fields(key)
            giverName = gid ~= nil and ns.Lookup.Name(gid) or ""
            if giver and not NameHas(giverName, giver) then ok = false end
        end
        if ok and zone and not ZoneHas(key, zone) then ok = false end
        if ok then
            local r = ns.Quests.RepeatType(key)
            out[#out + 1] = {
                type = "source",
                id = key,
                name = tostring(name):lower(),
                label = tostring(name),
                kindKey = "quest",
                lmin = lmin,
                lmax = lmax,
                level = lmin or 0,
                giver = tostring(giverName or ""),
                rep = r and L[r] or "",
                done = ns.Quests.IsCompleted(questId),
            }
        end
    end
    table.sort(out, function(a, b)
        if a.level ~= b.level then return a.level < b.level end
        return a.name < b.name
    end)
    return out
end

-- True when the filter sets anything.
function S.Active(filter)
    for _, v in pairs(filter or {}) do
        if Has(v) then return true end
    end
    return false
end

-- Rows of `kind` ("items" | "npcs" | "quests") that match the filter; total before the cap.
function S.Run(kind, filter)
    local fn = Run[kind]
    if not fn then return {}, 0 end
    local out = fn(filter or {})
    local total = #out
    for i = total, S.MAX_ROWS + 1, -1 do
        out[i] = nil
    end
    return out, total
end

-- Runs the search as a background job; done(rows, total) afterwards (also when it failed: no rows).
function S.Start(kind, filter, done)
    ns.RunJob("search", function() return { S.Run(kind, filter) } end, function(ok, res)
        if ok and type(res) == "table" then
            done(res[1] or {}, res[2] or 0)
        else
            done({}, 0)
        end
    end)
end

return S
