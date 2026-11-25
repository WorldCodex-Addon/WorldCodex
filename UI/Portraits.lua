local _, ns = ...

-- Still portraits of NPCs for lists and page headings: the client's unit-portrait picture of the
-- creature's 3D model (SetPortraitTextureFromCreatureDisplayID). That needs the creature's display id,
-- which no API gives for an npc id, so a hidden model is set to the creature (PlayerModel:SetCreature,
-- one at a time) and asked for its display id; creatures under the mouse or targeted are read at once
-- (SetUnit). The ids are kept in db.displays[npcId] (personal cache, never shared). New ids fire
-- "PORTRAITS" (batched), which redraws what is on screen.
local Pt = {}
ns.Portraits = Pt

local RETRY_AFTER, MAX_TRIES, LOAD_WAIT = 60, 3, 0.5

local queue, queued = {}, {}
local tries, lastTry = {}, {}
local models = {}
local busy = false
local firePending = false

local function Db() return ns.db and ns.db.displays end

local function Save(npc, display)
    display = ns.Plain(display, "display id")
    local db = Db()
    if not db or type(display) ~= "number" or display <= 0 or db[npc] == display then return false end
    db[npc] = display
    if not firePending then
        firePending = true
        ns.After(0.3, function()
            firePending = false
            ns.Fire("PORTRAITS")
        end)
    end
    return true
end

-- An invisible model frame (off screen), made once per purpose; nil when the client has none.
local function Model(kind)
    if models[kind] ~= nil then return models[kind] or nil end
    local ok, m = pcall(CreateFrame, "PlayerModel", nil, UIParent)
    if not ok or not m or not m.GetDisplayInfo then
        models[kind] = false
        return nil
    end
    m:SetSize(8, 8)
    m:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", -100, -100)
    m.onLoaded = false
    if m.HasScript and m:HasScript("OnModelLoaded") then
        m:SetScript("OnModelLoaded", function(self)
            if self.onLoaded then self.onLoaded() end
        end)
    end
    m:Show()
    models[kind] = m
    return m
end

local Next
-- Loads the next queued creature into the hidden model and reads its display id (when the model has
-- loaded, or after LOAD_WAIT seconds). Waits outside instances: there the creature data is hidden.
function Next()
    if busy or #queue == 0 then return end
    if IsInInstance and ns.Call(IsInInstance) then
        ns.After(10, Next)
        return
    end
    local npc = table.remove(queue, 1)
    queued[npc] = nil
    local db = Db()
    if not db or db[npc] then return Next() end
    local m = Model("creature")
    if not (m and m.SetCreature) then return end
    busy = npc
    tries[npc], lastTry[npc] = (tries[npc] or 0) + 1, GetTime()
    local set = pcall(m.SetCreature, m, npc)
    local function Finish()
        if busy ~= npc then return end
        busy = false
        m.onLoaded = false
        if set then
            local ok, display = pcall(m.GetDisplayInfo, m)
            if ok then Save(npc, display) end
        end
        ns.After(0.05, Next)
    end
    m.onLoaded = Finish
    ns.After(LOAD_WAIT, Finish)
end

-- Display id of an npc, or nil (then it is looked up in the background and "PORTRAITS" fires).
function Pt.DisplayId(npc)
    if type(npc) ~= "number" then return nil end
    local db = Db()
    if not db then return nil end
    if db[npc] then return db[npc] end
    if queued[npc] or busy == npc or (tries[npc] or 0) >= MAX_TRIES then return nil end
    if lastTry[npc] and GetTime() - lastTry[npc] < RETRY_AFTER then return nil end
    queued[npc] = true
    queue[#queue + 1] = npc
    if not busy then ns.After(0, Next) end
    return nil
end

-- A creature under the mouse or targeted: its display id straight from the unit.
function Pt.FromUnit(unit)
    local db = Db()
    if not db or ns.UnitHidden(unit) then return end
    local guid = ns.Call(UnitGUID, unit)
    if ns.GuidType(guid) ~= "Creature" then return end
    local npc = ns.GuidId(guid)
    if not npc or db[npc] then return end
    local m = Model("unit")
    if not (m and m.SetUnit) or not pcall(m.SetUnit, m, unit) then return end
    local ok, display = pcall(m.GetDisplayInfo, m)
    if ok and Save(npc, display) then return end
    m.onLoaded = function()
        m.onLoaded = false
        local okLoaded, d = pcall(m.GetDisplayInfo, m)
        if okLoaded then Save(npc, d) end
    end
end

ns.On("DB_READY", function()
    ns.RegisterEvent("PLAYER_TARGET_CHANGED", function() Pt.FromUnit("target") end)
    ns.RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() Pt.FromUnit("mouseover") end)
end)

return Pt
