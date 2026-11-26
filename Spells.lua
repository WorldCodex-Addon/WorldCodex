local _, ns = ...

-- Spells WorldCodex has met: what trainers teach (Trainers.lua) and the recipes of profession windows
-- (Crafting.lua, `sid`). The client knows every spell, but only in its own language and only once the
-- spell's data is loaded; the record keeps what was read, for spell pages, search and the website.
-- db.spells[spellId] = { n = name, rk = rank / subtext, ic = icon file id, ds = description, t = last read }
local Sp = {}
ns.Spells = Sp

local L = ns.L
local Store = ns.Store

local pending = {} -- [spellId] = true while the client loads the spell's data

local function Db() return ns.db.spells end

local function Text(v, max)
    v = ns.Plain(v)
    if type(v) ~= "string" or v == "" then return nil end
    return v:sub(1, max)
end

-- What the client says about a spell now: { n, rk, ic, ds } (fields nil when unknown).
function Sp.Read(id)
    local C = C_Spell or {}
    local out = {}
    if type(id) ~= "number" then return out end
    local info = ns.Call(C.GetSpellInfo, id)
    if type(info) == "table" then
        out.n = Text(info.name, 120)
        local icon = ns.Plain(info.iconID) or ns.Plain(info.originalIconID)
        if type(icon) == "number" and icon > 0 then out.ic = icon end
    else
        out.n = ns.SpellName(id)
    end
    if not out.ic then
        local icon = ns.Call(C.GetSpellTexture, id)
        if type(icon) == "number" and icon > 0 then out.ic = icon end
    end
    out.rk = Text(ns.Call(C.GetSpellSubtext, id), 60)
    out.ds = Text(ns.Call(C.GetSpellDescription, id), 1000)
    return out
end

local function Cached(id)
    local f = C_Spell and C_Spell.IsSpellDataCached
    if not f then return true end
    return ns.Call(f, id) ~= false
end

-- Stores what the client knows about a spell. Asks the client to load spells it has not cached yet
-- (SPELL_DATA_LOAD_RESULT records them later). `rank`: the trainer window's rank text, used when the
-- client's spell data has none. Returns true when the record changed.
function Sp.Record(id, rank)
    if type(id) ~= "number" or id <= 0 or not Db() then return false end
    if not Cached(id) and C_Spell and C_Spell.RequestLoadSpellData then
        if not pending[id] then
            pending[id] = rank or true
            pcall(C_Spell.RequestLoadSpellData, id)
        end
        if not Db()[id] then return false end
    end
    local r = Sp.Read(id)
    if not r.n then return false end
    if not r.rk and type(rank) == "string" and rank ~= "" then r.rk = rank:sub(1, 60) end
    local rec = Db()[id]
    if not rec then
        rec = {}
        Db()[id] = rec
    end
    rec.t = ns.time()
    local changed = false
    for _, f in ipairs({ "n", "rk", "ic", "ds" }) do
        -- a description that is not loaded yet never replaces one that was
        if r[f] ~= nil and r[f] ~= rec[f] then
            rec[f] = r[f]
            changed = true
        end
    end
    if changed then Store.Mark(rec) end
    return changed
end

-- ---------------------------------------------------------------- readers

-- { name, rank, icon, desc } from the client, else from the record.
function Sp.Info(id)
    local live = Sp.Read(id)
    local rec = Db() and Db()[id] or {}
    return {
        name = live.n or rec.n,
        rank = live.rk or rec.rk,
        icon = live.ic or rec.ic,
        desc = live.ds or rec.ds,
    }
end

function Sp.Name(id)
    local info = Sp.Info(id)
    return info.name or (L["Spell"] .. " " .. tostring(id))
end

-- Name with rank: "Rend (Rank 2)".
function Sp.Title(id)
    local info = Sp.Info(id)
    local name = info.name or (L["Spell"] .. " " .. tostring(id))
    if info.rank then return name .. " (" .. info.rank .. ")" end
    return name
end

-- Name and rank for lists and search: the record first (no client calls), else the client.
function Sp.Brief(id)
    local rec = Db() and Db()[id]
    local name = rec and rec.n or ns.SpellName(id)
    local rank = rec and rec.rk
    if not rank and C_Spell then rank = Text(ns.Call(C_Spell.GetSpellSubtext, id), 60) end
    return name, rank
end

-- Required level of a spell (the lowest any trainer asks for), or nil.
function Sp.Level(id) return ns.Trainers and ns.Trainers.SpellLevel(id) or nil end

function Sp.Link(id)
    local link = C_Spell and ns.Call(C_Spell.GetSpellLink, id)
    if type(link) == "string" then return link end
    return "|cff71d5ff|Hspell:" .. id .. "|h[" .. Sp.Name(id) .. "]|h|r"
end

-- Every spell id WorldCodex can show a page for: recorded spells, what trainers teach and recipe
-- spells, in every layer that is switched on.
function Sp.AllIds()
    local ids = {}
    for id in pairs(Db() or {}) do
        ids[id] = true
    end
    if ns.Trainers then
        for _, l in ipairs(ns.Trainers.Layers()) do
            for _, rec in pairs(l.t) do
                for key in pairs(type(rec) == "table" and type(rec.s) == "table" and rec.s or {}) do
                    if type(key) == "number" then ids[key] = true end
                end
            end
        end
    end
    if ns.Crafting then
        for _, l in ipairs(ns.Crafting.Layers()) do
            for product, r in pairs(l.t) do
                local sid = type(r) == "table" and tonumber(r.sid)
                    or tonumber(tostring(product):match("^enchant:(%d+)$"))
                if sid then ids[sid] = true end
            end
        end
    end
    return ids
end

ns.On("DB_READY", function(db)
    db.spells = type(db.spells) == "table" and db.spells or {}
    ns.RegisterEvent("SPELL_DATA_LOAD_RESULT", function(id, success)
        local rank = pending[id]
        if not rank then return end
        pending[id] = nil
        if success then Sp.Record(id, type(rank) == "string" and rank or nil) end
    end)
end)

return Sp
