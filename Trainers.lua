local _, ns = ...

-- What trainers teach: recorded from the trainer window (TRAINER_SHOW / TRAINER_UPDATE).
-- db.trainers[npcId] = { nm = name, t = last seen, tt = kind, pf = profession key, cls = class file,
--                        s = { [service] = { c = cost, lv = required level, sk = required skill rank,
--                                            it = item made (recipes), nm = name (only without spell id) } } }
--   tt: "class" (class trainer of class `cls`), "profession" (profession `pf`, a Crafting/skill line key),
--       "pet" (pet trainer: costs are training points) or "general" (riding, weapons, portals, ...).
--   service: the spell id (from the service tooltip), else "n:<name>" (name in the recorder's language).
-- The window shows only the services its filters let through, so it is read with every filter on and
-- the player's filters are put back at once. Services are added and updated, never removed.
local Tr = {}
ns.Trainers = Tr

local L = ns.L
local Store = ns.Store

Tr.KINDS = { class = true, profession = true, pet = true, general = true }
Tr.FILTERS = { "available", "unavailable", "used" }
Tr.MAX_SERVICES = 400

-- Skill lines of the professions, to turn the window's localized skill names into profession keys
-- (Crafting.lua keys; gathering professions and fishing have no recipes there).
Tr.SKILL_LINES = {
    alchemy = 171,
    blacksmithing = 164,
    enchanting = 333,
    engineering = 202,
    herbalism = 182,
    leatherworking = 165,
    mining = 186,
    skinning = 393,
    tailoring = 197,
    jewelcrafting = 755,
    inscription = 773,
    cooking = 185,
    firstaid = 129,
    fishing = 356,
}

local function Db() return ns.db.trainers end

local function SkillLineName(id)
    local T = C_TradeSkillUI
    local name = T and ns.Call(T.GetTradeSkillDisplayName, id)
    if type(name) == "string" and name ~= "" then return name end
    local info = T and ns.Call(T.GetProfessionInfoBySkillLineID, id)
    name = type(info) == "table" and ns.Plain(info.professionName)
    return type(name) == "string" and name ~= "" and name or nil
end

local skillByName
-- Profession key of a localized skill line name ("Alchimie" -> "alchemy").
function Tr.ProfessionKey(name)
    if type(name) ~= "string" or name == "" then return nil end
    if not skillByName then
        skillByName = {}
        for key, id in pairs(Tr.SKILL_LINES) do
            local n = SkillLineName(id)
            if n then skillByName[n:lower()] = key end
        end
    end
    local key = skillByName[name:lower()]
    if key then return key end
    return ns.Crafting and ns.Crafting.ProfessionKey(name) or nil
end

-- Localized profession name for a key (skill line name, else the crafting name).
function Tr.ProfessionName(key)
    local id = Tr.SKILL_LINES[key]
    local name = id and SkillLineName(id)
    if name then return name end
    return ns.Crafting and ns.Crafting.ProfessionName(key) or tostring(key)
end

-- Localized class name for a class file ("WARRIOR" -> "Krieger").
function Tr.ClassName(cls)
    local names = LOCALIZED_CLASS_NAMES_MALE
    if type(names) ~= "table" and LocalizedClassList then names = ns.Call(LocalizedClassList, false) end
    return type(names) == "table" and names[cls] or tostring(cls)
end

-- "Warrior trainer", "Alchemy trainer", "Pet trainer", "Trainer".
function Tr.Label(info)
    if type(info) ~= "table" then return L["Trainer"] end
    if info.tt == "class" and info.cls then return string.format(L["%s trainer"], Tr.ClassName(info.cls)) end
    if info.tt == "profession" and info.pf then return string.format(L["%s trainer"], Tr.ProfessionName(info.pf)) end
    if info.tt == "pet" then return L["Pet trainer"] end
    return L["Trainer"]
end

-- ---------------------------------------------------------------- reading the window

local function Plain(...)
    local n = select("#", ...)
    local out = {}
    for i = 1, n do
        out[i] = ns.Plain((select(i, ...)))
    end
    return out, n
end

-- All results of a call, secrets as nil; {} when the function is missing or fails.
local function Results(fn, ...)
    if not fn then return {}, 0 end
    local res = { pcall(fn, ...) }
    if not res[1] then return {}, 0 end
    return Plain(unpack(res, 2, table.maxn(res)))
end

local function TooltipKind(name)
    local t = Enum and Enum.TooltipDataType
    return t and t[name]
end

-- Spell id (or item id) the service's tooltip shows.
local function ServiceTooltip(i)
    local get = C_TooltipInfo and C_TooltipInfo.GetTrainerService
    local data = get and ns.Call(get, i)
    if type(data) ~= "table" then return nil end
    local id, kind = ns.Plain(data.id), ns.Plain(data.type)
    if type(id) ~= "number" or id <= 0 then return nil end
    if kind == TooltipKind("Item") then return nil, id end
    if kind == nil or kind == TooltipKind("Spell") then return id end
    return nil
end

local function TrainerType()
    local get = C_Trainer and C_Trainer.GetTrainerType
    local t = get and ns.Call(get)
    local e = Enum and Enum.TrainerType or {}
    if t ~= nil and t == e.Pet then return "pet" end
    if (t ~= nil and t == e.Tradeskills) or ns.Call(IsTradeskillTrainer) then return "profession" end
    return "general"
end

-- Does the trainer's title ("<Warrior Trainer>", "<Kriegerlehrer>") name the player's class? true,
-- false, or nil when the tooltip cannot be read. Class trainers only teach their own class, so the
-- window of another class's trainer has no services and is never read.
local function TitleNamesClass(cls)
    local get = C_TooltipInfo and C_TooltipInfo.GetUnit
    local data = get and ns.Call(get, "npc")
    local lines = type(data) == "table" and ns.Plain(data.lines)
    if type(lines) ~= "table" then return nil end
    local names = {}
    for _, female in ipairs({ false, true }) do
        local list = female and LOCALIZED_CLASS_NAMES_FEMALE or LOCALIZED_CLASS_NAMES_MALE
        if type(list) ~= "table" and LocalizedClassList then list = ns.Call(LocalizedClassList, female) end
        local n = type(list) == "table" and list[cls]
        if type(n) == "string" and n ~= "" then names[#names + 1] = n:lower() end
    end
    if #names == 0 then return nil end
    for i = 2, math.min(#lines, 3) do
        local line = ns.Plain(lines[i])
        local text = type(line) == "table" and ns.Plain(line.leftText)
        if type(text) == "string" then
            text = text:lower()
            for _, n in ipairs(names) do
                if text:find(n, 1, true) then return true end
            end
        end
    end
    return false
end

-- Turns every type filter on; returns the ones that were off (to be put back by Restore).
local function OpenFilters()
    local changed = {}
    if not (GetTrainerServiceTypeFilter and SetTrainerServiceTypeFilter) then return changed end
    for _, f in ipairs(Tr.FILTERS) do
        local on = ns.Call(GetTrainerServiceTypeFilter, f)
        if not on then
            if pcall(SetTrainerServiceTypeFilter, f, true) then changed[#changed + 1] = f end
        end
    end
    return changed
end

local function RestoreFilters(changed)
    for _, f in ipairs(changed) do
        pcall(SetTrainerServiceTypeFilter, f, false)
    end
end

-- One service of the open window: key, entry, skill line name; nil for headers and unreadable rows.
local function ReadService(i, kind)
    local info = Results(GetTrainerServiceInfo, i)
    local name, stype, reqLevel = info[1], info[2], info[4]
    if type(name) ~= "string" or name == "" or stype == "header" then return nil end
    local spell, item = ServiceTooltip(i)
    local link = ns.Call(GetTrainerServiceItemLink, i)
    item = ns.ItemIdFromLink(link) or item
    local cost = ns.Call(GetTrainerServiceCost, i)
    local e = {
        c = type(cost) == "number" and cost >= 0 and math.floor(cost) or nil,
        lv = type(reqLevel) == "number" and reqLevel > 1 and reqLevel or nil,
        it = item,
    }
    local skill = Results(GetTrainerServiceSkillReq, i)
    if kind == "profession" and type(skill[2]) == "number" and skill[2] > 0 then e.sk = skill[2] end
    local key = spell
    if not key then
        local sub = info[5]
        key = "n:" .. name .. ((type(sub) == "string" and sub ~= "") and (" (" .. sub .. ")") or "")
        key = key:sub(1, 80)
        e.nm = name
    end
    local line = ns.Call(GetTrainerServiceSkillLine, i)
    local sub = type(info[5]) == "string" and info[5] ~= "" and info[5] or nil
    return key, e, type(line) == "string" and line ~= "" and line or skill[1], sub
end

local function SameService(a, b)
    return type(a) == "table" and a.c == b.c and a.lv == b.lv and a.sk == b.sk and a.it == b.it and a.nm == b.nm
end

local reading = false
Tr.lastRead = nil -- { npc, services, filters } for /worldcodex diag trainer

-- Reads the open trainer window. Returns true when something was read.
function Tr.Scan()
    if reading or not (GetNumTrainerServices and GetTrainerServiceInfo) then return false end
    local guid = ns.Call(UnitGUID, "npc")
    if ns.GuidType(guid) ~= "Creature" then return false end
    local npc = ns.GuidId(guid)
    if not npc then return false end
    reading = true
    local changedFilters = OpenFilters()
    local kind = TrainerType()
    local ranks = {} -- [spellId] = the window's rank text ("Rank 2"), for spells the client gives none
    local ok, services, skills = pcall(function()
        local out, lines = {}, {}
        local n = math.min(ns.Call(GetNumTrainerServices) or 0, Tr.MAX_SERVICES)
        for i = 1, n do
            local key, e, line, sub = ReadService(i, kind)
            if key then
                out[key] = e
                if line then lines[line] = (lines[line] or 0) + 1 end
                if sub and type(key) == "number" then ranks[key] = sub end
            end
        end
        return out, lines
    end)
    RestoreFilters(changedFilters)
    reading = false
    if not ok or type(services) ~= "table" or not next(services) then return false end
    Tr.lastRead = { npc = npc, filters = #changedFilters }

    local rec = Db()[npc]
    if not rec then
        rec = { s = {} }
        Db()[npc] = rec
    end
    local before = string.format("%s|%s|%s|%s", tostring(rec.nm), tostring(rec.tt), tostring(rec.pf), tostring(rec.cls))
    rec.nm = ns.Call(UnitName, "npc") or rec.nm
    rec.t = ns.time()
    if kind == "profession" then
        local best, bestN
        for line, c in pairs(skills) do
            if not bestN or c > bestN then
                best, bestN = line, c
            end
        end
        rec.tt, rec.cls = "profession", nil
        rec.pf = Tr.ProfessionKey(best) or rec.pf
    elseif kind == "pet" then
        rec.tt, rec.pf, rec.cls = "pet", nil, nil
    else
        local cls = Results(UnitClass, "player")[2]
        local named = type(cls) == "string" and TitleNamesClass(cls)
        if named == true then
            rec.tt, rec.cls, rec.pf = "class", cls, nil
        elseif named == false or not rec.tt then
            rec.tt, rec.cls, rec.pf = "general", nil, nil
        end
    end
    local changed = before
        ~= string.format("%s|%s|%s|%s", tostring(rec.nm), tostring(rec.tt), tostring(rec.pf), tostring(rec.cls))
    rec.s = type(rec.s) == "table" and rec.s or {}
    local count = 0
    for key, e in pairs(services) do
        count = count + 1
        if type(key) == "number" and ns.Spells then ns.Spells.Record(key, ranks[key]) end
        if not SameService(rec.s[key], e) then
            rec.s[key] = e
            changed = true
        end
    end
    Tr.lastRead.services = count
    if changed then Store.Mark(rec) end
    Tr.indexDirty = true
    ns.Fire("DATA_CHANGED", "trainer", npc)
    return true
end

-- /worldcodex diag trainer: what the client returns for the open trainer window.
function Tr.Diagnose()
    local out = {}
    local last = Tr.lastRead
    out[#out + 1] = last
            and string.format(
                "last read: npc %s, %s services, %d filters opened",
                tostring(last.npc),
                tostring(last.services),
                last.filters
            )
        or "last read: none"
    if not GetNumTrainerServices then
        out[#out + 1] = "GetNumTrainerServices missing"
        return out
    end
    local n = ns.Call(GetNumTrainerServices) or 0
    local filters = {}
    for _, f in ipairs(Tr.FILTERS) do
        filters[#filters + 1] = f .. "=" .. tostring(ns.Call(GetTrainerServiceTypeFilter, f))
    end
    out[#out + 1] = string.format(
        "open window: %d services, type %s (C_Trainer %s, tradeskill %s), filters %s",
        n,
        TrainerType(),
        tostring(C_Trainer and ns.Call(C_Trainer.GetTrainerType)),
        tostring(ns.Call(IsTradeskillTrainer)),
        table.concat(filters, " ")
    )
    for i = 1, math.min(n, 15) do
        local info, count = Results(GetTrainerServiceInfo, i)
        local parts = {}
        for j = 1, count do
            parts[#parts + 1] = tostring(info[j])
        end
        local spell, item = ServiceTooltip(i)
        local skill = Results(GetTrainerServiceSkillReq, i)
        out[#out + 1] = string.format(
            "  %d: %s | spell %s item %s | cost %s | skill %s %s | line %s | link %s",
            i,
            table.concat(parts, ", "),
            tostring(spell),
            tostring(item),
            tostring(ns.Call(GetTrainerServiceCost, i)),
            tostring(skill[1]),
            tostring(skill[2]),
            tostring(ns.Call(GetTrainerServiceSkillLine, i)),
            tostring(ns.Call(GetTrainerServiceItemLink, i)):gsub("|", "||")
        )
    end
    return out
end

-- ---------------------------------------------------------------- layers and readers

function Tr.Layers()
    local out = { { layer = "me", t = Db() } }
    if ns.db.settings.useGuild then
        for _, peer in pairs(ns.db.peers) do
            if type(peer.tr) == "table" and not Store.IsContributor(peer.uid) then
                out[#out + 1] = { layer = "guild", t = peer.tr }
            end
        end
    end
    local c = Store.Community()
    if c and ns.db.settings.useCommunity and type(c.trainers) == "table" then
        out[#out + 1] = { layer = "community", t = c.trainers }
    end
    return out
end

-- Everything known about a trainer, all layers combined (the player's own values first):
-- { tt, pf, cls, s = { [service] = entry } } or nil.
function Tr.Get(npc)
    local info
    for _, l in ipairs(Tr.Layers()) do
        local rec = l.t[npc]
        if type(rec) == "table" then
            info = info or { s = {} }
            if not info.tt and Tr.KINDS[rec.tt] then
                info.tt, info.pf, info.cls = rec.tt, rec.pf, rec.cls
            end
            for key, e in pairs(type(rec.s) == "table" and rec.s or {}) do
                if info.s[key] == nil and type(e) == "table" then info.s[key] = e end
            end
        end
    end
    return info
end

-- Display name of a service: the spell's name in the client's language, else the recorded name.
function Tr.ServiceName(key, e)
    if type(key) == "number" then return ns.SpellName(key) or (e and e.nm) or ("spell " .. key) end
    return (e and e.nm) or tostring(key):gsub("^n:", "")
end

local index, bySpell -- itemId -> { [npc] = service key }; spellId -> { [npc] = true }
Tr.indexDirty = true

local function Rebuild()
    index, bySpell = {}, {}
    for _, l in ipairs(Tr.Layers()) do
        for npc, rec in pairs(l.t) do
            for key, e in pairs(type(rec) == "table" and type(rec.s) == "table" and rec.s or {}) do
                if type(e) == "table" and type(e.it) == "number" then
                    index[e.it] = index[e.it] or {}
                    index[e.it][npc] = index[e.it][npc] or key
                end
                if type(key) == "number" then
                    bySpell[key] = bySpell[key] or {}
                    bySpell[key][npc] = true
                end
            end
        end
    end
    Tr.indexDirty = false
end

-- Trainers that teach the recipe of an item: { [npc] = service key }.
function Tr.ForItem(itemId)
    if Tr.indexDirty or not index then Rebuild() end
    return index[itemId] or {}
end

-- Trainers that teach a spell: { [npc] = true }.
function Tr.ForSpell(spellId)
    if Tr.indexDirty or not bySpell then Rebuild() end
    return bySpell[spellId] or {}
end

-- Lowest level a trainer requires for a spell (nil when no trainer names one).
function Tr.SpellLevel(spellId)
    local best
    for npc in pairs(Tr.ForSpell(spellId)) do
        local info = Tr.Get(npc)
        local e = info and info.s[spellId]
        if e and type(e.lv) == "number" and (not best or e.lv < best) then best = e.lv end
    end
    return best
end

ns.On("DATA_CHANGED", function(what)
    if what ~= "trainer" then Tr.indexDirty = true end
end)
ns.On("SETTINGS_CHANGED", function() Tr.indexDirty = true end)

ns.On("DB_READY", function(db)
    db.trainers = type(db.trainers) == "table" and db.trainers or {}
    local open, token, quietUntil = false, 0, 0
    local function Read()
        if open and Tr.Scan() then quietUntil = GetTime() + 1 end
    end
    ns.RegisterEvent("TRAINER_SHOW", function()
        open = true
        ns.After(0.2, Read)
    end)
    -- learning something changes the list; the filter changes of our own read fire it too
    ns.RegisterEvent("TRAINER_UPDATE", function()
        if reading or not open or GetTime() < quietUntil then return end
        token = token + 1
        local mine = token
        ns.After(0.5, function()
            if mine == token then Read() end
        end)
    end)
    ns.RegisterEvent("TRAINER_CLOSED", function() open = false end)
end)

return Tr
