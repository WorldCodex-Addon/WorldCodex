local _, ns = ...

-- Captures kills (combat log), loot windows, gathering casts and money, and feeds the Store.
local C = {}
ns.Collector = C

local L = ns.L
local Store = ns.Store
local band = bit and bit.band

local AFFILIATION_GROUP = 0x7 -- MINE | PARTY | RAID
local TAG_TTL = 180
local MEMORY_TTL = 900
local CAST_TTL = 6

local tagged = {} -- creature guid -> { t, denied }
local names = {} -- guid -> name
local counted = {} -- creature guid -> time its kill was counted
local looted = {} -- dedupe key -> time
local lootBase = {} -- creature guid -> time the corpse entered the drop-rate base (looted or confirmed empty)
local unlooted = {} -- creature guid -> { t, key } killed with loot on it but not looted (yet)
local gathered = {} -- guid -> { kind, stamp, name, t } last gathering cast on a corpse / node
local failedSeen = {} -- cast id -> time (one count per failed cast)
local need = {} -- creature guid -> items the quest log needed when it died (Quests.Needed)
local died = {} -- creature guid -> time an engaged, not tapped-away mob died (corpse to loot)
local lootLog = {} -- last loot windows and how they were resolved (/worldcodex diag loot)
local lastCast, lastSent, lastItemUse
local loot
local lastSource
local lastMoney

C.stats = { dupes = 0, corpses = 0, unknown = 0, lootEvents = 0 }

local SPELL_KIND = {}
local function AddSpells(kind, ids)
    for _, id in ipairs(ids) do
        SPELL_KIND[id] = kind
    end
end
AddSpells("herb", { 2366, 2368, 3570, 11993, 28695, 50300, 74519, 110413, 158745, 195114, 265819, 309780, 366252 })
AddSpells("mine", { 2575, 2576, 3564, 10248, 29354, 50310, 74517, 102161, 158754, 195122, 265837, 309835, 366260 })
AddSpells("skin", { 8613, 8617, 8618, 10768, 32678, 50305, 74522, 102216, 158756, 194174, 265855, 308569, 366263 })
AddSpells("fish", { 7620, 7731, 7732, 18248, 33095, 51294, 88868, 110410, 131474 })
AddSpells("pickpocket", { 921 })
AddSpells("lockpick", { 1804 })
AddSpells("disenchant", { 13262 })
AddSpells("prospect", { 31252 })
AddSpells("mill", { 51005 })
C.SPELL_KIND = SPELL_KIND

local FALLBACK_NAMES = {
    ["herb gathering"] = "herb",
    herbalism = "herb",
    ["kräutersammeln"] = "herb",
    ["kräuterkunde"] = "herb",
    mining = "mine",
    bergbau = "mine",
    skinning = "skin",
    ["kürschnerei"] = "skin",
    ["kürschnern"] = "skin",
    fishing = "fish",
    angeln = "fish",
    ["pick pocket"] = "pickpocket",
    pickpocket = "pickpocket",
    taschendiebstahl = "pickpocket",
    ["pick lock"] = "lockpick",
    lockpicking = "lockpick",
    ["schloss knacken"] = "lockpick",
    disenchant = "disenchant",
    entzaubern = "disenchant",
    milling = "mill",
    mahlen = "mill",
    prospecting = "prospect",
    sondieren = "prospect",
    salvage = "salvage",
}

local STANDALONE = { fish = true, disenchant = true, mill = true, prospect = true, salvage = true }
-- Disenchanting, milling and prospecting are recorded per input item ("de:<itemId>") when the item
-- that was clicked is known: it gets locked when the cast starts, a few seconds before the loot.
local PROCESS_PREFIX = { disenchant = "de", mill = "mill", prospect = "prospect" }
local PROCESS_TTL = 8
local FISH_TTL = 30 -- the bobber is clicked when a fish bites, often long after the cast
local GATHER_FAIL = { herb = true, mine = true, skin = true, pickpocket = true, lockpick = true, salvage = true }
local UNIT_GATHER = { pickpocket = true, skin = true, herb = true, mine = true, salvage = true }
local OBJECT_GATHER = { herb = true, mine = true, lockpick = true }

local kindByName

local function BuildNameMap()
    kindByName = {}
    for id, kind in pairs(SPELL_KIND) do
        local name = ns.SpellName(id)
        if name then kindByName[name:lower()] = kind end
    end
end

function C.KindForSpell(spellId, spellName)
    local k = spellId and SPELL_KIND[spellId]
    if k then return k end
    spellName = spellName or (spellId and ns.SpellName(spellId))
    if type(spellName) ~= "string" then return nil end
    local ln = spellName:lower()
    if not kindByName then BuildNameMap() end
    if kindByName[ln] then return kindByName[ln] end
    for pat, kind in pairs(FALLBACK_NAMES) do
        if ln:find(pat, 1, true) then return kind end
    end
    return nil
end

local function Recent(entry, ttl)
    if entry and GetTime() - entry.t <= (ttl or CAST_TTL) then return entry end
    return nil
end

-- Item used from the bags in the last `ttl` seconds: { t, id } or nil (quests started by an item).
function C.LastItemUse(ttl) return Recent(lastItemUse, ttl or 3) end

local function RecentCast()
    if lastCast and lastCast.kind == "fish" then return Recent(lastCast, FISH_TTL) end
    return Recent(lastCast)
end

local function Settings() return ns.db.settings end

-- ---------------------------------------------------------------- kills

-- Level range and classification (elite, rare, ...) of a mob record.
local function ApplyUnitInfo(rec, lvl, cls)
    if type(lvl) == "number" and lvl > 0 then
        rec.lmin = math.min(rec.lmin or lvl, lvl)
        rec.lmax = math.max(rec.lmax or lvl, lvl)
    end
    if cls and cls ~= "normal" and cls ~= "minus" then rec.cls = cls end
end

local function RecordUnitInfo(rec, guid)
    local unit = ns.UnitForGuid(guid)
    if not unit then return end
    ApplyUnitInfo(rec, ns.Call(UnitLevel, unit), ns.Call(UnitClassification, unit))
    if not names[guid] then names[guid] = ns.Call(UnitName, unit) end
end

-- The corpse being looted when the client hides which unit it is (instances): a dead unit under the
-- mouse (right-click looting) or the interaction target (loot key). Its identity is hidden, its level
-- and classification may not be. nil outside instances, where RecordUnitInfo knows the unit exactly.
local function HiddenCorpse()
    for _, unit in ipairs({ "mouseover", "softinteract" }) do
        local ok, guid = pcall(UnitGUID, unit)
        if ok and ns.IsSecret(guid) and ns.Call(UnitIsDead, unit) then
            local lvl = ns.CallAs("corpse level", UnitLevel, unit)
            local cls = ns.CallAs("corpse classification", UnitClassification, unit)
            if lvl or cls then return { unit = unit, level = lvl, cls = cls } end
        end
    end
    return nil
end

-- A corpse enters the drop-rate base once: when looted, or when confirmed to have no loot.
local function AddToLootBase(guid, key, rec, empty, needed)
    if lootBase[guid] then return end
    lootBase[guid] = GetTime()
    unlooted[guid] = nil
    Store.CountLootBase(key, rec, empty, needed or ns.Quests.Both(need[guid], ns.Quests.Needed()))
end
C.AddToLootBase = AddToLootBase

-- Shortly after a solo kill: is there loot on the corpse? Empty corpses count as "dropped nothing";
-- corpses with loot wait to be looted, and are excluded from rates if they never are.
function C.CheckLootable(guid, key, try)
    if lootBase[guid] then return end
    local rec = ns.db.sources[key]
    if not rec then return end
    if not CanLootUnit then
        AddToLootBase(guid, key, rec, false) -- no way to tell: count the kill (previous behaviour)
        return
    end
    local ok, hasLoot = pcall(CanLootUnit, guid)
    if ok then
        hasLoot = ns.Plain(hasLoot) -- false: empty corpse
    else
        hasLoot = nil
    end
    if hasLoot == nil then
        AddToLootBase(guid, key, rec, false)
    elseif hasLoot then
        unlooted[guid] = { t = GetTime(), key = key }
    elseif (try or 1) < 2 then
        ns.After(1.5, function() C.CheckLootable(guid, key, 2) end)
    else
        AddToLootBase(guid, key, rec, true)
    end
end

local function CountCorpse(guid, grouped, fromLoot)
    if counted[guid] then return false end
    counted[guid] = GetTime()
    need[guid] = need[guid] or ns.Quests.Needed()
    local npc = ns.GuidId(guid)
    local name = names[guid]
    local key = npc or (name and ("name:" .. name))
    if not key then return false end
    local rec = Store.EnsureSource(key, name, "mob")
    RecordUnitInfo(rec, guid)
    Store.AddLocation(rec)
    Store.CountKill(key, rec, grouped)
    C.stats.corpses = C.stats.corpses + 1
    if not fromLoot and not grouped then ns.After(1.5, function() C.CheckLootable(guid, key, 1) end) end
    return true
end
C.CountCorpse = CountCorpse

local function IsCreature(guid)
    local gt = ns.GuidType(guid)
    return gt == "Creature" or gt == "Vehicle"
end

local function OnDeath(guid, name)
    local tg = tagged[guid]
    if not tg or GetTime() - tg.t > TAG_TTL then return end
    tagged[guid] = nil
    if name then names[guid] = name end
    if tg.denied then return end
    died[guid] = GetTime()
    need[guid] = ns.Quests.Needed()
    if ns.InGroup() then
        -- In a group the corpse is counted when we loot it, so kills looted by others don't dilute the rate.
        return
    end
    CountCorpse(guid, false)
end

function C.OnCombatLog(...)
    local sub, srcFlags, dstGUID, dstName, _
    if CombatLogGetCurrentEventInfo then
        _, sub, _, _, _, srcFlags, _, dstGUID, dstName = CombatLogGetCurrentEventInfo()
    else
        _, sub, _, _, _, srcFlags, _, dstGUID, dstName = ...
    end
    sub, srcFlags, dstGUID, dstName = ns.Plain(sub), ns.Plain(srcFlags), ns.Plain(dstGUID), ns.Plain(dstName)
    if not sub or not dstGUID then return end
    if sub == "UNIT_DIED" or sub == "PARTY_KILL" or sub == "UNIT_DESTROYED" then
        if sub == "PARTY_KILL" and IsCreature(dstGUID) and not tagged[dstGUID] and not counted[dstGUID] then
            tagged[dstGUID] = { t = GetTime() }
        end
        OnDeath(dstGUID, dstName)
        return
    end
    if not srcFlags or band(srcFlags, AFFILIATION_GROUP) == 0 then return end
    if sub:sub(-7) ~= "_DAMAGE" and sub:sub(-7) ~= "_MISSED" then return end
    if not IsCreature(dstGUID) then return end
    local tg = tagged[dstGUID]
    if not tg then
        tg = {}
        tagged[dstGUID] = tg
        if dstName then names[dstGUID] = dstName end
    end
    tg.t = GetTime()
    if not tg.checked then
        local unit = ns.UnitForGuid(dstGUID)
        if unit then
            tg.checked = true
            tg.denied = ns.IsTapDenied(unit)
        end
    end
end

-- ---------------------------------------------------------------- unit-based kill tracking
-- Works without the combat log (which some clients forbid for addons): watches the units the
-- player can see. A mob counts when it dies after the player was on its threat list and it was
-- not tapped by someone else. Kills this misses are still counted when the corpse is looted.

local plates = {}
local FIXED_UNITS = { "target", "focus", "mouseover", "softenemy" }

-- Unit API call: nil when it fails or the value is secret (combat, instances).
local Safe = ns.Call

function C.ObserveUnit(unit)
    -- in instances the client hides who the unit is: one check instead of several hidden lookups
    if ns.UnitHidden(unit) then return ns.Count("units hidden") end
    local guid = ns.CallAs("unit guid", UnitGUID, unit)
    if type(guid) ~= "string" or not IsCreature(guid) then return end
    if Safe(UnitIsPlayer, unit) then return end
    local dead = Safe(UnitIsDead, unit) and true or false
    local st = tagged[guid]
    if not st then
        if dead or counted[guid] then return end
        if UnitCanAttack and not Safe(UnitCanAttack, "player", unit) then return end
        st = {}
        tagged[guid] = st
    end
    st.t = GetTime()
    if not names[guid] then names[guid] = ns.CallAs("unit name", UnitName, unit) end
    if not dead then
        if not st.engaged then
            local threat = Safe(UnitThreatSituation, "player", unit)
            if
                threat ~= nil
                or Safe(UnitIsUnit, unit .. "target", "player")
                or Safe(UnitIsUnit, unit .. "target", "pet")
            then
                st.engaged = true
            end
        end
        if not st.checked then
            st.checked = true
            st.denied = ns.IsTapDenied(unit)
        elseif ns.IsTapDenied(unit) then
            st.denied = true
        end
        return
    end
    if not st.engaged then
        tagged[guid] = nil
        return
    end
    st.engaged = false
    OnDeath(guid, names[guid])
end

function C.ObserveAll()
    for _, unit in ipairs(FIXED_UNITS) do
        C.ObserveUnit(unit)
    end
    for unit in pairs(plates) do
        C.ObserveUnit(unit)
    end
end

local function OnUnitEvent(unit)
    if unit then C.ObserveUnit(unit) end
end

-- ---------------------------------------------------------------- casts

function C.OnSpellcastSucceeded(unit, a2, a3, a4, a5)
    if ns.Plain(unit) ~= "player" then return end
    a2, a3, a5 = ns.Plain(a2), ns.Plain(a3), ns.Plain(a5)
    local spellId, spellName
    if type(a3) == "number" then
        spellId = a3
    elseif type(a2) == "string" and type(a5) == "number" then
        spellName, spellId = a2, a5
    end
    local kind = C.KindForSpell(spellId, spellName)
    if not kind then return end
    local stamp = (type(a2) == "string" and a2:find("Cast", 1, true)) and a2 or tostring(GetTime())
    lastCast = { kind = kind, t = GetTime(), guid = ns.Call(UnitGUID, "target"), stamp = stamp }
end

-- Gathering that did not finish (attacked while mining, moved, skill too low...). Not an attempt -
-- nothing could drop - but counted per source so it is visible.
function C.FindGatherSource(kind, name)
    if not name then return nil end
    for key, rec in pairs(ns.db.sources) do
        if rec.kind == kind and rec.name == name then return key, rec end
    end
    return nil
end

function C.OnSpellcastFailed(unit, a2, a3, a4, a5)
    if ns.Plain(unit) ~= "player" then return end
    a2, a3, a5 = ns.Plain(a2), ns.Plain(a3), ns.Plain(a5)
    local spellId, spellName
    if type(a3) == "number" then
        spellId = a3
    elseif type(a2) == "string" and type(a5) == "number" then
        spellName, spellId = a2, a5
    end
    local kind = C.KindForSpell(spellId, spellName)
    if not kind or not GATHER_FAIL[kind] then return end
    if type(a2) == "string" and a2:find("Cast", 1, true) then
        if failedSeen[a2] then return end
        failedSeen[a2] = GetTime()
    end
    local totals = ns.db.totals
    totals.fails = totals.fails or {}
    totals.fails[kind] = (totals.fails[kind] or 0) + 1
    local sent = Recent(lastSent, 10)
    local _, rec = C.FindGatherSource(kind, sent and sent.target)
    if rec then rec.fails = (rec.fails or 0) + 1 end
    if lastCast and lastCast.kind == kind and GetTime() - lastCast.t < 1 then lastCast = nil end
end

function C.OnSpellcastSent(unit, a2, a3, a4, a5)
    if ns.Plain(unit) ~= "player" then return end
    a2, a4 = ns.Plain(a2), ns.Plain(a4)
    local target
    if type(a4) == "number" then
        target = a2
    else
        target = a4
    end
    if type(target) == "string" and target ~= "" then lastSent = { t = GetTime(), target = target } end
end

function C.OnItemUsed(bag, slot)
    local id
    if C_Container and C_Container.GetContainerItemID then
        id = C_Container.GetContainerItemID(bag, slot)
    elseif GetContainerItemID then
        id = GetContainerItemID(bag, slot)
    elseif GetContainerItemLink then
        id = ns.ItemIdFromLink(GetContainerItemLink(bag, slot))
    end
    if id then lastItemUse = { t = GetTime(), id = id } end
end

-- ---------------------------------------------------------------- loot

local function SlotSources(slot)
    if not GetLootSourceInfo then return nil end
    local r = { GetLootSourceInfo(slot) }
    if #r == 0 then return nil end
    local out = {}
    for i = 1, #r, 2 do
        local guid = ns.Plain(r[i], "loot source")
        if type(guid) == "string" then out[#out + 1] = { guid = guid, q = tonumber(ns.Plain(r[i + 1])) } end
    end
    return #out > 0 and out or nil
end

-- Coin text of a money slot, e.g. "1 Gold\n23 Silver\n4 Copper" (localized), in copper.
local coinPatterns
function C.ParseCoin(text)
    if type(text) ~= "string" then return nil end
    if not coinPatterns then
        local function pat(fmt, default)
            local p = (fmt or default):gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
            return (p:gsub("%%%d%$d", "(%%d+)"):gsub("%%d", "(%%d+)"))
        end
        coinPatterns = {
            { pat(GOLD_AMOUNT, "%d Gold"), 10000 },
            { pat(SILVER_AMOUNT, "%d Silver"), 100 },
            { pat(COPPER_AMOUNT, "%d Copper"), 1 },
        }
    end
    local total, found = 0, false
    for _, cp in ipairs(coinPatterns) do
        local n = tonumber(text:match(cp[1]))
        if n then
            total, found = total + n * cp[2], true
        end
    end
    return found and total or nil
end

local function IsMoneySlot(slot, link, name, qty)
    if GetLootSlotType then
        local t = ns.Call(GetLootSlotType, slot)
        local money = (Enum and Enum.LootSlotType and Enum.LootSlotType.Money) or LOOT_SLOT_MONEY or 2
        if t then return t == money end
    end
    return not link and (name ~= nil or (tonumber(qty) or 0) == 0)
end

local function ReadSlot(slot)
    local link = ns.CallAs("loot link", GetLootSlotLink, slot)
    local _, name, qty = GetLootSlotInfo(slot)
    name, qty = ns.Plain(name, "loot name"), ns.Plain(qty, "loot qty")
    if IsMoneySlot(slot, link, name, qty) then
        return { money = true, copper = C.ParseCoin(name), src = SlotSources(slot) }
    end
    if link then
        local id = ns.ItemIdFromLink(link)
        if not id then return nil end
        return { id = id, q = tonumber(qty) or 1, name = name or link:match("%[(.-)%]"), src = SlotSources(slot) }
    end
    return nil
end

local function ScanSlot(slot)
    if not loot or loot.slots[slot] then return end
    local s = ReadSlot(slot)
    if s then loot.slots[slot] = s end
end

local function TooltipObjectName() return ns.HoveredObjectName() end

-- Creature unit that is a corpse right now (the one being looted when the cursor is on it).
local function DeadCreature(unit)
    local guid = ns.Call(UnitGUID, unit)
    if type(guid) ~= "string" or not IsCreature(guid) then return nil end
    return ns.Call(UnitIsDead, unit) and guid or nil
end

-- Corpse the loot window most likely belongs to when the client does not name the loot source:
-- the corpse under the cursor or targeted, else the latest engaged mob that died and was not looted.
-- In dungeons the target has usually moved on to the next (living) mob, so it is not used blindly.
local CORPSE_TTL = 120
local function GuessCorpse(l)
    local guid = l.deadMouseover or l.deadTarget
    if guid then return guid end
    -- containers, chests and fishing are not corpses
    if l.itemUse or l.hoverName or (l.cast and STANDALONE[l.cast.kind]) then return nil end
    local best, bt
    for g, t in pairs(died) do
        if not lootBase[g] and not looted["mob" .. g] and GetTime() - t < CORPSE_TTL and (not bt or t > bt) then
            best, bt = g, t
        end
    end
    return best
end
C.GuessCorpse = GuessCorpse

-- kept in the saved file (lootLog), so a dungeon run can be checked after logging out
local function LogLoot(entry)
    table.insert(lootLog, 1, entry)
    while #lootLog > 30 do
        table.remove(lootLog)
    end
end

function C.LootLog() return lootLog end

function C.BeginLoot()
    if loot then
        -- LOOT_READY and LOOT_OPENED both arrive for one window; slots that were not readable
        -- at the first event (item data still loading) are read now.
        local n = GetNumLootItems and GetNumLootItems() or 0
        for i = 1, n do
            ScanSlot(i)
        end
        return
    end
    C.stats.lootEvents = C.stats.lootEvents + 1
    loot = {
        corpse = HiddenCorpse(),
        deadMouseover = DeadCreature("mouseover"),
        deadTarget = DeadCreature("target"),
        slots = {},
        t = GetTime(),
        stamp = tostring(GetTime()),
        needed = ns.Quests.Needed(), -- before the items are in the bags
        target = ns.CallAs("target guid", UnitGUID, "target"),
        targetName = ns.Call(UnitName, "target"),
        cast = RecentCast(),
        sent = Recent(lastSent),
        itemUse = Recent(lastItemUse, 3),
        processItem = Recent(lastItemUse, PROCESS_TTL),
        hoverName = TooltipObjectName(),
        grouped = ns.InGroup(),
        money = 0,
    }
    local n = GetNumLootItems and GetNumLootItems() or 0
    for i = 1, n do
        ScanSlot(i)
    end
end

function C.ResolveSource(guid, l)
    local cast = l.cast
    if cast and STANDALONE[cast.kind] then
        if cast.kind == "fish" then
            local map = ns.PlayerLocation()
            return "fish:" .. tostring(map or 0), L["Fishing"] .. ": " .. ns.MapName(map), "fish", "fish" .. l.stamp
        end
        local prefix, input = PROCESS_PREFIX[cast.kind], l.processItem
        -- the item must have been locked before the cast finished, not after it
        if prefix and input and input.t <= cast.t + 0.5 and cast.t - input.t <= PROCESS_TTL then
            return prefix .. ":" .. input.id, ns.ItemName(input.id), cast.kind, cast.kind .. l.stamp
        end
        return "kind:" .. cast.kind, ns.KIND_LABEL[cast.kind], cast.kind, cast.kind .. l.stamp
    end
    local gt = ns.GuidType(guid)
    if gt == "Creature" or gt == "Vehicle" then
        local id = ns.GuidId(guid)
        local name = names[guid] or (guid == l.target and l.targetName) or nil
        if not name then
            local unit = ns.UnitForGuid(guid)
            name = unit and ns.Call(UnitName, unit)
            names[guid] = name
        end
        local base = id or (name and ("name:" .. name))
        if not base then return nil end
        -- A gathering cast right before the loot window is what opened it (skinning a looted corpse
        -- often happens without targeting it). Each cast is its own attempt.
        if cast and UNIT_GATHER[cast.kind] then
            if cast.kind ~= "pickpocket" then
                gathered[guid] = { kind = cast.kind, stamp = cast.stamp, t = GetTime() }
            end
            return cast.kind .. ":" .. base, name, cast.kind, cast.kind .. guid .. tostring(cast.stamp)
        end
        local g = gathered[guid]
        if g then -- reopened a gathering loot window without a new cast
            return g.kind .. ":" .. base, name, g.kind, g.kind .. guid .. tostring(g.stamp)
        end
        return base, name, "mob", "mob" .. guid
    elseif gt == "GameObject" then
        local id = ns.GuidId(guid) or 0
        local name = (l.sent and l.sent.target) or l.hoverName or ("Object " .. id)
        if cast and OBJECT_GATHER[cast.kind] then
            -- Veins and herbs can be harvested more than once: every cast is its own attempt.
            gathered[guid] = { kind = cast.kind, stamp = cast.stamp, name = name, t = GetTime() }
            return "go:" .. id, name, cast.kind, "go" .. guid .. tostring(cast.stamp)
        end
        local g = gathered[guid]
        if g then return "go:" .. id, g.name or name, g.kind, "go" .. guid .. tostring(g.stamp) end
        return "go:" .. id, name, "object", "go" .. guid
    elseif gt == "Item" then
        local use = l.itemUse
        if use then return "item:" .. use.id, ns.ItemName(use.id), "container", "item" .. guid .. l.stamp end
        return "kind:container", L["Containers"], "container", "item" .. guid .. l.stamp
    end
    -- No usable loot source GUID (very old clients): fall back to the corpse, then the target.
    local corpse = GuessCorpse(l)
    if corpse and corpse ~= guid then return C.ResolveSource(corpse, l) end
    if l.target and l.target ~= guid then
        local tgt = ns.GuidType(l.target)
        if tgt == "Creature" or tgt == "Vehicle" or tgt == "GameObject" then return C.ResolveSource(l.target, l) end
    end
    C.stats.unknown = C.stats.unknown + 1
    return "kind:other", L["Other"], "other", "other" .. l.stamp
end

local function AddEntry(bySrc, guid, id, q, name)
    local e = bySrc[guid]
    if not e then
        e = { items = {} }
        bySrc[guid] = e
    end
    if id then
        local it = e.items[id]
        if not it then
            it = { q = 0, name = name }
            e.items[id] = it
        end
        it.q = it.q + (q or 1)
    end
    return e
end

function C.CommitLoot()
    local l = loot
    loot = nil
    if not l then return end
    local bySrc = {}
    local fallback = GuessCorpse(l) or l.target or "none"
    for _, s in pairs(l.slots) do
        if s.money then
            -- Coin from the loot window is the corpse's full amount, even when it is split in a group.
            -- With area loot, the per-source quantity of a money slot is that corpse's copper.
            local srcs = s.src or { { guid = fallback } }
            local perSource = 0
            for _, ss in ipairs(srcs) do
                perSource = perSource + (ss.q or 0)
            end
            for _, ss in ipairs(srcs) do
                local e = AddEntry(bySrc, ss.guid)
                local copper
                if perSource > 0 and #srcs > 1 then
                    copper = ss.q or 0
                elseif s.copper then
                    copper = s.copper / #srcs
                elseif perSource > 0 then
                    copper = ss.q or 0
                end
                if copper and copper > 0 then e.copper = (e.copper or 0) + copper end
            end
        elseif s.src then
            for _, ss in ipairs(s.src) do
                AddEntry(bySrc, ss.guid, s.id, ss.q or s.q, s.name)
            end
        else
            AddEntry(bySrc, fallback, s.id, s.q, s.name)
        end
    end
    if not next(bySrc) then
        -- an empty window: counts as an empty corpse only when it is known whose
        if fallback == "none" then
            LogLoot({ t = ns.time(), slots = 0, keys = {}, dupes = C.stats.dupes, empty = true })
            return
        end
        AddEntry(bySrc, fallback)
    end

    local committed = {}
    for guid, entry in pairs(bySrc) do
        local key, name, kind, dedupe = C.ResolveSource(guid, l)
        if key then
            if looted[dedupe] then
                C.stats.dupes = C.stats.dupes + 1
            else
                looted[dedupe] = GetTime()
                local rec = Store.EnsureSource(key, name, kind)
                if ns.KPI then ns.KPI.RecordPrediction(rec, entry.items) end
                local needed = l.needed
                if kind == "mob" then
                    -- needed when it died and still needed now
                    needed = ns.Quests.Both(need[guid], needed)
                    if not counted[guid] and (not l.grouped or Settings().countGroupKills) then
                        CountCorpse(guid, l.grouped, true)
                    end
                    if counted[guid] then AddToLootBase(guid, key, rec, false, needed) end
                    if not lootBase[guid] then needed = nil end -- not in the base: no quest counts either
                end
                if kind ~= "mob" and kind ~= "other" then Store.AddLocation(rec) end
                Store.CountAttempt(key, rec, l.grouped, needed)
                local total = 0
                for id, it in pairs(entry.items) do
                    Store.AddDrop(key, rec, id, it.q, it.name, l.grouped, needed)
                    total = total + it.q
                end
                if total > (rec.imax or 0) then rec.imax = total end
                if total == 0 then rec.empty = (rec.empty or 0) + 1 end
                rec.ca = (rec.ca or 0) + 1 -- looted attempts since coin counting started
                if entry.copper then Store.AddCoin(rec, entry.copper) end
                committed[#committed + 1] = { key = key, rec = rec, items = entry.items, coin = entry.copper }
            end
        end
    end
    local logged = { t = ns.time(), grouped = l.grouped, combat = ns.InCombat(), slots = 0, keys = {} }
    for _ in pairs(l.slots) do
        logged.slots = logged.slots + 1
    end
    local inInstance, instanceType = false, nil
    if IsInInstance then
        local ok, a, b = pcall(IsInInstance)
        if ok then
            inInstance, instanceType = a, b
        end
    end
    logged.instance = inInstance and (instanceType or "yes") or nil
    -- where: the map, and whether the client gave a position (it does not in instances)
    local map, x = ns.PlayerLocation()
    logged.map, logged.pos = map, x ~= nil
    if not map then logged.zone = ns.InstanceZone() end
    logged.noSource = true
    for _, sl in pairs(l.slots) do
        if sl.src then logged.noSource = nil end
    end
    for _, c in ipairs(committed) do
        local n = 0
        for _ in pairs(c.items) do
            n = n + 1
        end
        logged.keys[#logged.keys + 1] = tostring(c.key) .. "(" .. n .. ")"
    end
    logged.dupes = C.stats.dupes
    -- quest objectives waiting for items, and which looted items were taken for one
    if l.needed and next(l.needed.names) then
        logged.needed = {}
        for objective in pairs(l.needed.names) do
            logged.needed[#logged.needed + 1] = objective
        end
        table.sort(logged.needed)
        for _, c in ipairs(committed) do
            for id, item in pairs(c.items) do
                if ns.Quests.Match(l.needed.names, item.name) then
                    logged.quest = (logged.quest and logged.quest .. ", " or "") .. id
                end
            end
        end
    end
    LogLoot(logged)
    -- one mob looted whose unit the client hides: level and classification from the corpse unit
    if l.corpse and #committed == 1 and committed[1].rec.kind == "mob" then
        local rec = committed[1].rec
        ApplyUnitInfo(rec, l.corpse.level, l.corpse.cls)
        Store.Mark(rec)
        logged.corpse = l.corpse.unit .. " " .. tostring(l.corpse.level)
    end
    if #committed > 0 then
        local slotCoin = false
        for _, c in ipairs(committed) do
            if c.coin then slotCoin = true end
        end
        if not slotCoin and l.money > 0 then
            -- Coin amount not readable from the slot: fall back to the change in the player's gold.
            local share = l.money / #committed
            for _, c in ipairs(committed) do
                Store.AddCoin(c.rec, share)
            end
        end
        lastSource = { rec = committed[1].rec, key = committed[1].key, t = GetTime(), slotCoin = slotCoin }
        for _, c in ipairs(committed) do
            ns.Fire("LOOT", c.key, c.rec, c.items)
        end
        ns.Fire("DATA_CHANGED", "loot")
    end
end

function C.OnMoney()
    if not GetMoney then return end
    local now = GetMoney()
    local delta = lastMoney and (now - lastMoney) or 0
    lastMoney = now
    if delta <= 0 then return end
    if loot then
        loot.money = loot.money + delta
        ns.Fire("MONEY", delta)
    elseif lastSource and GetTime() - lastSource.t < 2 then
        if not lastSource.slotCoin then Store.AddMoney(lastSource.rec, delta) end
        ns.Fire("MONEY", delta)
    end
end

-- ---------------------------------------------------------------- chat (items actually received)

local function FormatToPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%%d%$s", "(.+)"):gsub("%%%d%$d", "(%%d+)")
    p = p:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
    return "^" .. p .. "$"
end
C.FormatToPattern = FormatToPattern

local selfMulti, selfSingle, pushedMulti, pushedSingle

function C.OnChatLoot(msg)
    msg = ns.Plain(msg)
    if type(msg) ~= "string" then return end
    selfMulti = selfMulti or FormatToPattern(LOOT_ITEM_SELF_MULTIPLE or "You receive loot: %sx%d.")
    selfSingle = selfSingle or FormatToPattern(LOOT_ITEM_SELF or "You receive loot: %s.")
    local link, qty = msg:match(selfMulti)
    if not link then
        link = msg:match(selfSingle)
        qty = 1
    end
    -- "You receive item" is also used for purchases and crafting; only count it as income right
    -- after a quest turn-in, when it carries the quest's rewards.
    if not link and ns.Quests and ns.Quests.InTurnIn() then
        pushedMulti = pushedMulti or FormatToPattern(LOOT_ITEM_PUSHED_SELF_MULTIPLE or "You receive item: %sx%d.")
        pushedSingle = pushedSingle or FormatToPattern(LOOT_ITEM_PUSHED_SELF or "You receive item: %s.")
        link, qty = msg:match(pushedMulti)
        if not link then
            link = msg:match(pushedSingle)
            qty = 1
        end
    end
    if not link then return end
    local id = ns.ItemIdFromLink(link)
    if id then ns.Fire("RECEIVED", id, tonumber(qty) or 1) end
end

-- ---------------------------------------------------------------- housekeeping

function C.Purge()
    local now = GetTime()
    for g, tg in pairs(tagged) do
        if now - tg.t > TAG_TTL then tagged[g] = nil end
    end
    for g, t in pairs(counted) do
        if now - t > MEMORY_TTL then counted[g] = nil end
    end
    for k, t in pairs(looted) do
        if now - t > MEMORY_TTL then looted[k] = nil end
    end
    for g, t in pairs(lootBase) do
        if now - t > MEMORY_TTL then lootBase[g] = nil end
    end
    for g, e in pairs(gathered) do
        if now - e.t > MEMORY_TTL then gathered[g] = nil end
    end
    for g, t in pairs(died) do
        if now - t > MEMORY_TTL then died[g] = nil end
    end
    for g in pairs(need) do
        if not died[g] and not counted[g] then need[g] = nil end
    end
    for id, t in pairs(failedSeen) do
        if now - t > MEMORY_TTL then failedSeen[id] = nil end
    end
    for g, u in pairs(unlooted) do
        if now - u.t > MEMORY_TTL then
            unlooted[g] = nil
            local rec = ns.db.sources[u.key]
            if rec then rec.ul = (rec.ul or 0) + 1 end
        end
    end
    local n = 0
    for _ in pairs(names) do
        n = n + 1
    end
    if n > 3000 then names = {} end
end

function C._State()
    return {
        tagged = tagged,
        counted = counted,
        looted = looted,
        names = names,
        lootBase = lootBase,
        unlooted = unlooted,
        gathered = gathered,
        died = died,
    }
end

ns.On("DB_READY", function(db)
    db.lootLog = type(db.lootLog) == "table" and db.lootLog or {}
    lootLog = db.lootLog
    lastMoney = GetMoney and GetMoney() or 0
    -- The combat log is forbidden for addons on some clients (registering it shows a "blocked" popup
    -- that pcall cannot catch), so it is strictly opt-in.
    if Settings().useCombatLog then
        ns.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function(...) ns.Profile("combatlog", C.OnCombatLog, ...) end)
    end
    ns.RegisterEvent("UNIT_HEALTH", OnUnitEvent)
    ns.RegisterEvent("UNIT_THREAT_LIST_UPDATE", OnUnitEvent)
    ns.RegisterEvent("UNIT_FLAGS", OnUnitEvent)
    ns.RegisterEvent("PLAYER_TARGET_CHANGED", function() C.ObserveUnit("target") end)
    ns.RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() C.ObserveUnit("mouseover") end)
    ns.RegisterEvent("NAME_PLATE_UNIT_ADDED", function(unit)
        if unit then
            plates[unit] = true
            C.ObserveUnit(unit)
        end
    end)
    ns.RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(unit)
        if unit then
            C.ObserveUnit(unit)
            plates[unit] = nil
        end
    end)
    ns.Every(0.5, function() ns.Profile("units", C.ObserveAll) end)
    ns.RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", C.OnSpellcastSucceeded)
    ns.RegisterEvent("UNIT_SPELLCAST_SENT", C.OnSpellcastSent)
    ns.RegisterEvent("UNIT_SPELLCAST_INTERRUPTED", C.OnSpellcastFailed)
    ns.RegisterEvent("UNIT_SPELLCAST_FAILED", C.OnSpellcastFailed)
    ns.RegisterEvent("LOOT_READY", function() ns.Profile("loot", C.BeginLoot) end)
    ns.RegisterEvent("LOOT_OPENED", function() ns.Profile("loot", C.BeginLoot) end)
    ns.RegisterEvent("LOOT_SLOT_CHANGED", ScanSlot)
    ns.RegisterEvent("LOOT_CLOSED", function() ns.Profile("loot", C.CommitLoot) end)
    ns.RegisterEvent("PLAYER_MONEY", C.OnMoney)
    ns.RegisterEvent("CHAT_MSG_LOOT", C.OnChatLoot)
    -- Using a container item (lockbox, clam, bag of loot) locks its bag slot; this avoids hooking
    -- Blizzard's protected UseContainerItem.
    ns.RegisterEvent("ITEM_LOCK_CHANGED", function(bag, slot)
        if bag and slot then C.OnItemUsed(bag, slot) end
    end)
    ns.Every(60, C.Purge)
end)

return C
