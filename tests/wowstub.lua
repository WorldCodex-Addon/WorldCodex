-- Minimal World of Warcraft API stub so the addon can be loaded and driven outside the game.
local Stub = {}

local StubMT
local function NewObject(kind)
    return setmetatable({ __kind = kind, __scripts = {}, __hooks = {}, __shown = false }, StubMT)
end

StubMT = {
    __index = function(_, key)
        if type(key) ~= "string" or key:sub(1, 2) == "__" then return nil end
        return function(self, ...)
            if key == "SetScript" then
                local ev, fn = ...
                self.__scripts[ev] = fn
            elseif key == "GetScript" then
                return self.__scripts[(...)]
            elseif key == "HookScript" then
                local ev, fn = ...
                self.__hooks[ev] = self.__hooks[ev] or {}
                table.insert(self.__hooks[ev], fn)
            elseif key == "Show" then
                self.__shown = true
            elseif key == "Hide" then
                self.__shown = false
            elseif key == "SetShown" then
                self.__shown = (...) and true or false
            elseif key == "IsShown" or key == "IsVisible" then
                return self.__shown
            elseif key == "SetText" then
                self.__text = ...
            elseif key == "GetText" then
                return self.__text
            elseif key == "GetStringHeight" or key == "GetWidth" or key == "GetHeight" then
                return 100
            elseif key == "GetFrameLevel" then
                return 1
            elseif key == "GetChecked" then
                return self.__checked
            elseif key == "SetChecked" then
                self.__checked = ...
            elseif key:match("^Create") then
                return NewObject(key)
            end
            return nil
        end
    end,
}

function Stub.Install(env)
    env = env or {}
    local T = { now = 1000, epoch = 1700000000 }
    Stub.T = T
    local G = _G

    G.bit = G.bit or require("bit")
    G.GetTime = function() return T.now end
    G.time = function() return math.floor(T.epoch + T.now) end
    G.date = os.date
    G.debugprofilestop = function() return os.clock() * 1000 end
    G.geterrorhandler = function()
        return function(err) error(err, 0) end
    end
    G.hooksecurefunc = function(a, b, c)
        if type(a) == "table" then
            local orig = a[b]
            a[b] = function(...)
                local r = { orig(...) }
                c(...)
                return unpack(r)
            end
        else
            local orig = G[a]
            G[a] = function(...)
                local r = { orig(...) }
                b(...)
                return unpack(r)
            end
        end
    end
    G.CreateFrame = function(kind, name)
        local f = NewObject(kind)
        if name then G[name] = f end
        return f
    end
    G.CreateFont = function(name)
        local fo = NewObject("Font")
        if name then G[name] = fo end
        return fo
    end
    G.UIParent = NewObject("Frame")
    G.Minimap = NewObject("Frame")
    G.GameTooltip = NewObject("GameTooltip")
    G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) table.insert(Stub.chat, msg) end }
    G.UISpecialFrames = {}
    G.SlashCmdList = {}
    G.GetLocale = function() return env.locale or "enUS" end
    G.UnitGUID = function(unit) return env.units and env.units[unit] and env.units[unit].guid or nil end
    G.UnitName = function(unit)
        if unit == "player" then return "Tester" end
        return env.units and env.units[unit] and env.units[unit].name or nil
    end
    G.UnitLevel = function(unit) return env.units and env.units[unit] and env.units[unit].level or 0 end
    G.UnitClassification = function(unit)
        return env.units and env.units[unit] and env.units[unit].classification or "normal"
    end
    local function U(unit) return env.units and env.units[unit] end
    G.UnitIsDead = function(unit) return U(unit) and U(unit).dead or false end
    G.UnitCanAttack = function(_, unit) return U(unit) ~= nil and not U(unit).friendly end
    G.UnitThreatSituation = function(_, unit) return U(unit) and U(unit).threat or nil end
    G.UnitIsUnit = function() return false end
    G.UnitIsPlayer = function(unit) return unit == "player" end
    G.UnitAffectingCombat = function(unit) return U(unit) and U(unit).threat ~= nil end
    G.UnitIsTapDenied = function(unit) return env.units and env.units[unit] and env.units[unit].denied or false end
    G.GetNormalizedRealmName = function() return "TestRealm" end
    G.IsInGroup = function() return env.grouped or false end
    G.IsInRaid = function() return false end
    G.IsInGuild = function() return true end
    G.IsShiftKeyDown = function() return false end
    G.GetMoney = function() return env.money or 0 end
    G.GetItemCount = function(id) return env.bags and env.bags[id] or 0 end
    G.GetItemInfo = function(id)
        local it = env.items and env.items[id]
        if not it then return nil end
        return it.name,
            "|cffffffff|Hitem:" .. id .. "|h[" .. it.name .. "]|h|r",
            it.quality or 1,
            it.ilvl or 1,
            it.req or 1,
            "",
            it.subclass or "",
            20,
            it.equipLoc or "",
            it.texture or 0,
            it.sell or 0,
            it.classId,
            it.subclassId
    end
    G.GetSpellInfo = function(id) return env.spells and env.spells[id] or nil end
    G.CombatLogGetCurrentEventInfo = function() return unpack(env.cleu or {}) end
    G.GetNumLootItems = function() return env.loot and #env.loot or 0 end
    G.GetLootSlotLink = function(i)
        local s = env.loot[i]
        return s.id and ("|cffffffff|Hitem:" .. s.id .. "|h[" .. s.name .. "]|h|r") or nil
    end
    G.GetLootSlotInfo = function(i)
        local s = env.loot[i]
        return 0, s.name, s.q or 1
    end
    G.GetLootSourceInfo = function(i)
        local s = env.loot[i]
        local out = {}
        for _, src in ipairs(s.src or {}) do
            out[#out + 1] = src[1]
            out[#out + 1] = src[2]
        end
        return unpack(out)
    end
    G.C_Map = {
        GetBestMapForUnit = function() return env.map or 1429 end,
        GetPlayerMapPosition = function()
            local p = env.pos or { 0.5, 0.5 }
            return { GetXY = function() return p[1], p[2] end }
        end,
        GetMapInfo = function(id) return { name = "Map" .. id } end,
    }
    G.LOOT_ITEM_SELF = "You receive loot: %s."
    G.LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
    -- Trainer window: env.trainer = { kind = "general"|"profession"|"pet", title = "<Warrior Trainer>",
    -- services = { { name, type = "available"|"unavailable"|"used", level, sub, spell, item, cost,
    -- skill = { name, rank }, line } } }, filtered like the client by env.trainerFilters.
    env.trainerFilters = env.trainerFilters or { available = true, unavailable = true, used = false }
    local function Visible()
        local out = {}
        for _, sv in ipairs(env.trainer and env.trainer.services or {}) do
            if env.trainerFilters[sv.type or "available"] then out[#out + 1] = sv end
        end
        return out
    end
    local TRAINER_TYPES = { general = 0, profession = 2, pet = 3 }
    G.C_Trainer =
        { GetTrainerType = function() return TRAINER_TYPES[env.trainer and env.trainer.kind or "general"] end }
    G.IsTradeskillTrainer = function() return env.trainer ~= nil and env.trainer.kind == "profession" end
    G.GetNumTrainerServices = function() return #Visible() end
    G.GetTrainerServiceInfo = function(i)
        local sv = Visible()[i]
        if not sv then return nil end
        return sv.name, sv.type or "available", 136243, sv.level or 1, sv.sub, sv.category
    end
    G.GetTrainerServiceCost = function(i)
        local sv = Visible()[i]
        return sv and sv.cost or 0, env.trainer and env.trainer.kind == "profession"
    end
    G.GetTrainerServiceSkillReq = function(i)
        local sv = Visible()[i]
        if sv and sv.skill then return sv.skill[1], sv.skill[2], true end
        return nil
    end
    G.GetTrainerServiceSkillLine = function(i)
        local sv = Visible()[i]
        return sv and sv.line or nil
    end
    G.GetTrainerServiceItemLink = function(i)
        local sv = Visible()[i]
        return sv and sv.item and ("|cffffffff|Hitem:" .. sv.item .. "::::|h[x]|h|r") or nil
    end
    G.GetTrainerServiceTypeFilter = function(f) return env.trainerFilters[f] and true or false end
    G.SetTrainerServiceTypeFilter = function(f, on) env.trainerFilters[f] = on and true or false end
    G.UnitClass = function(unit)
        if unit == "player" then return "Warrior", env.class or "WARRIOR", 1 end
        return nil
    end
    G.LOCALIZED_CLASS_NAMES_MALE = { WARRIOR = "Warrior", MAGE = "Mage" }
    G.LOCALIZED_CLASS_NAMES_FEMALE = { WARRIOR = "Warrior", MAGE = "Mage" }
    G.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() end,
        SendAddonMessage = function(prefix, msg, channel, target)
            table.insert(Stub.sent, { prefix = prefix, msg = msg, channel = channel, target = target })
        end,
    }
    G.MobLootDB = env.legacy
    G.WorldCodexDB = env.saved
    G.ItemsDB = env.oldSaved -- data under the addon's earlier name
    G.WorldCodex_CommunityData = nil
    Stub.chat, Stub.sent = {}, {}
    return T
end

function Stub.TocFiles(root, filter)
    local files = {}
    for line in io.lines(root .. "/WorldCodex.toc") do
        line = line:gsub("%s+$", "")
        if line ~= "" and not line:match("^##") then
            local path = line:gsub("\\", "/")
            if not filter or filter(path) then files[#files + 1] = path end
        end
    end
    return files
end

-- Loads the addon files into a fresh namespace and fires ADDON_LOADED.
function Stub.Boot(root, env, opts)
    opts = opts or {}
    Stub.Install(env)
    local ns = {}
    for _, path in ipairs(Stub.TocFiles(root, opts.filter)) do
        local chunk, err = loadfile(root .. "/" .. path)
        if not chunk then error(err) end
        chunk("WorldCodex", ns)
        -- Tests use their own community data (or none), never the shipped file, unless asked to.
        if path == "Data/Community.lua" then
            if env.community then
                _G.WorldCodex_CommunityData = env.community
            elseif not opts.realCommunity then
                _G.WorldCodex_CommunityData = { version = 1, generated = 0, contributors = {}, sources = {} }
            end
        end
    end
    ns.Dispatch("ADDON_LOADED", "WorldCodex")
    return ns
end

return Stub
