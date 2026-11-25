local _, ns = ...

-- Where NPCs stand, and what they are.
--   Interactions (talking, merchant, quests, trainer, flight master, bank) record the location: the
--   player stands next to the NPC, and addons cannot read other units' positions, so the player's
--   position is used.
--   Sightings (mouseover, target, nameplates; out of combat and within ~28 yards, CheckInteractDistance)
--   only add name, level, classification and reaction, never a location: 28 yards is too far for the
--   player's position to stand for the NPC's. Records without an interaction role therefore have no
--   location, and such records from other players (made by older versions) are not shown on maps.
-- db.npcs[npcId | "go:<objectId>"] = { nm, t, sp = { [map] = { [cell] = n } }, lv = { min, max }, cl,
--                                      r = "hostile" | "neutral" | "friendly", f = { [role] = true } }
local Np = {}
ns.Npcs = Np

local Store = ns.Store

Np.MAX_CELLS = 24 -- per NPC over all maps; roaming NPCs keep their first cells
Np.INTERVAL = 120 -- seconds before the same NPC in the same cell counts again
Np.RANGE = 4 -- CheckInteractDistance index 4: follow distance, about 28 yards
Np.ROLES = { gossip = true, vendor = true, quest = true, trainer = true, taxi = true, banker = true }
Np.CLASSIFICATIONS = { elite = true, rare = true, rareelite = true, worldboss = true }

local recent = {} -- [key] = { map, cell, t }

local function Db() return ns.db.npcs end

-- Unit API call: nil when it fails or the value is secret (combat, instances).
local function Safe(fn, ...)
    if not fn then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return ns.Plain(a), ns.Plain(b) end
    return nil
end

-- npc id for creatures; "go:<id>" for objects, only when interacting (quest boards, books)
local function KeyFor(unit, exact)
    local guid = Safe(UnitGUID, unit)
    local gt = ns.GuidType(guid)
    if gt == "Creature" then return ns.GuidId(guid) end
    if exact and gt == "GameObject" then
        local id = ns.GuidId(guid)
        return id and ("go:" .. id) or nil
    end
    return nil
end

local function Reaction(unit)
    local r = Safe(UnitReaction, unit, "player")
    if not r then return nil end
    if r <= 3 then return "hostile" end
    if r == 4 then return "neutral" end
    return "friendly"
end

-- Sightings are kept to NPCs the player came close to (keeps the table small).
local function Near(unit)
    if not CheckInteractDistance then return false end
    return Safe(CheckInteractDistance, unit, Np.RANGE) and true or false
end

local function CellCount(sp)
    local n = 0
    for _, cells in pairs(sp) do
        for _ in pairs(cells) do
            n = n + 1
        end
    end
    return n
end

-- What the share string carries about an NPC (locations aside), to tell whether a record changed.
local function Facts(rec, role)
    local lv = rec.lv or {}
    return table.concat({
        tostring(rec.nm),
        tostring(lv[1]),
        tostring(lv[2]),
        tostring(rec.cl),
        tostring(rec.r),
        tostring(role and rec.f and rec.f[role]),
    }, "|")
end

-- Records the unit (an interaction when `role` is given; only interactions store a location).
-- Returns true when something was stored.
function Np.Record(unit, role)
    local exact = role ~= nil
    local key = KeyFor(unit, exact)
    if not key then return false end
    if not exact then
        if ns.InCombat() or Safe(UnitIsPlayer, unit) or Safe(UnitPlayerControlled, unit) then return false end
        if Safe(UnitIsDead, unit) or not Near(unit) then return false end
    end
    local map, x, y = ns.PlayerLocation()
    local rec = Db()[key]
    if not rec then
        rec = { sp = {} }
        Db()[key] = rec
    end
    local before = Facts(rec, role)
    rec.nm = Safe(UnitName, unit) or rec.nm
    rec.t = ns.time()
    if type(key) == "number" then
        local lvl = Safe(UnitLevel, unit)
        if lvl and lvl > 0 then
            rec.lv = rec.lv or { lvl, lvl }
            rec.lv[1], rec.lv[2] = math.min(rec.lv[1], lvl), math.max(rec.lv[2], lvl)
        end
        local cls = Safe(UnitClassification, unit)
        rec.cl = Np.CLASSIFICATIONS[cls] and cls or rec.cl
        rec.r = Reaction(unit) or rec.r
    end
    if role and Np.ROLES[role] then
        rec.f = rec.f or {}
        rec.f[role] = true
    end
    -- a sighting that changes nothing is no news for the next share string
    if Facts(rec, role) ~= before then Store.Mark(rec) end
    if exact and map and x then
        local cell = Store.CellKey(x, y)
        local last = recent[key]
        local now = GetTime()
        if not (last and last.map == map and last.cell == cell and now - last.t < Np.INTERVAL) then
            recent[key] = { map = map, cell = cell, t = now }
            local m = rec.sp[map] or {}
            if m[cell] or CellCount(rec.sp) < Np.MAX_CELLS then
                m[cell] = (m[cell] or 0) + 1
                rec.sp[map] = m
                Store.Mark(rec)
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------- layers and readers

function Np.Layers()
    local out = { { layer = "me", t = Db() } }
    if ns.db.settings.useGuild then
        for _, peer in pairs(ns.db.peers) do
            if type(peer.np) == "table" and not Store.IsContributor(peer.uid) then
                out[#out + 1] = { layer = "guild", t = peer.np, lc = peer.lc }
            end
        end
    end
    local c = Store.Community()
    if c and ns.db.settings.useCommunity and type(c.npcs) == "table" then
        out[#out + 1] = { layer = "community", t = c.npcs }
    end
    return out
end

-- All layers combined: { nm, lv, cl, r, f } (locations come through Store.Spawns).
function Np.Info(key)
    local info
    for _, l in ipairs(Np.Layers()) do
        local rec = l.t[key]
        if type(rec) == "table" then
            info = info or { f = {} }
            info.nm = info.nm or rec.nm
            if type(rec.lv) == "table" and rec.lv[1] then
                info.lv = info.lv and { math.min(info.lv[1], rec.lv[1]), math.max(info.lv[2], rec.lv[2]) }
                    or { rec.lv[1], rec.lv[2] }
            end
            info.cl = info.cl or rec.cl
            info.r = info.r or rec.r
            for role in pairs(type(rec.f) == "table" and rec.f or {}) do
                info.f[role] = true
            end
        end
    end
    return info
end

-- Name in the player's language: own record, community name for this locale, a guild peer with the
-- same locale, then any shared name.
function Np.Name(key)
    local own = Db()[key]
    if own and own.nm then return own.nm end
    local locale = GetLocale and GetLocale()
    local c = Store.Community()
    local names = c and type(c.names) == "table" and c.names[locale]
    if names and names[key] then return names[key] end
    local any
    for _, l in ipairs(Np.Layers()) do
        local rec = l.t[key]
        if type(rec) == "table" and rec.nm then
            if l.lc == locale then return rec.nm end
            any = any or rec.nm
        end
    end
    return any
end

function Np.AllIds()
    local ids = {}
    for _, l in ipairs(Np.Layers()) do
        for key in pairs(l.t) do
            ids[key] = true
        end
    end
    return ids
end

-- Locations come from interactions, so only records with a role count.
local function HasRole(rec) return type(rec.f) == "table" and next(rec.f) ~= nil end
Np.HasRole = HasRole

-- Locations for maps and pages: NPC interaction spots of every layer; vendors' merchant locations
-- only when there are none (they were recorded at the same moment).
Store.AddSpawnProvider(function(key, add)
    if not ns.db.npcs then return end
    local found = false
    for _, l in ipairs(Np.Layers()) do
        local rec = l.t[key]
        if type(rec) == "table" and type(rec.sp) == "table" and next(rec.sp) and HasRole(rec) then
            add(rec.sp)
            found = true
        end
    end
    if not found and ns.Vendors and type(key) == "number" then
        for _, l in ipairs(ns.Vendors.Layers()) do
            local v = l.t[key]
            if type(v) == "table" and type(v.sp) == "table" then add(v.sp) end
        end
    end
end)

ns.On("DB_READY", function(db)
    db.npcs = type(db.npcs) == "table" and db.npcs or {}
    -- Older versions stored sighting locations as well; records without an interaction had only
    -- those, so their locations are dropped once.
    if not db.meta.npcInteractOnly then
        for _, rec in pairs(db.npcs) do
            if type(rec) == "table" and not HasRole(rec) then rec.sp = {} end
        end
        db.meta.npcInteractOnly = true
    end
    local function Interaction(role)
        return function() Np.Record("npc", role) end
    end
    ns.RegisterEvent("GOSSIP_SHOW", Interaction("gossip"))
    ns.RegisterEvent("MERCHANT_SHOW", Interaction("vendor"))
    ns.RegisterEvent("QUEST_GREETING", Interaction("quest"))
    ns.RegisterEvent("QUEST_DETAIL", Interaction("quest"))
    ns.RegisterEvent("QUEST_PROGRESS", Interaction("quest"))
    ns.RegisterEvent("QUEST_COMPLETE", Interaction("quest"))
    ns.RegisterEvent("TRAINER_SHOW", Interaction("trainer"))
    ns.RegisterEvent("TAXIMAP_OPENED", Interaction("taxi"))
    ns.RegisterEvent("BANKFRAME_OPENED", Interaction("banker"))
    ns.RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() Np.Record("mouseover") end)
    ns.RegisterEvent("PLAYER_TARGET_CHANGED", function() Np.Record("target") end)
    ns.RegisterEvent("NAME_PLATE_UNIT_ADDED", function(unit)
        if unit then Np.Record(unit) end
    end)
end)

return Np
