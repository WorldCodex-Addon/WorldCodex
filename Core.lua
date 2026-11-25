local ADDON, ns = ...

ns.ADDON = ADDON
ns.VERSION = "0.1.0"

-- Public WorldCodex website (uploads and the online database). nil until it is online: then the pages
-- get "Web link" buttons and the export window shows where to upload.
ns.WEB_BASE = nil

-- Copyable web address of an item or source page ("item", 2589 / "source", 1234).
function ns.WebUrl(kind, id)
    if not ns.WEB_BASE then return nil end
    local path = kind == "item" and "item/" or "source/"
    return ns.WEB_BASE .. "/" .. path .. tostring(id):gsub("[^%w:_-]", "")
end
ns.API = type(WorldCodexAPI) == "table" and WorldCodexAPI or {}
WorldCodexAPI = ns.API

ns.time = time or os.time
ns.date = date or os.date
ns.perf = {}

local L = ns.L

local frame = CreateFrame("Frame")
ns.frame = frame

local handlers, callbacks, timers, updaters = {}, {}, {}, {}

-- Errors by message: { n = count, first = time, last = reported, where = context }. The client's error
-- handler collects a stack (and locals) for every error even when error display is off; a handler
-- that fails on every UNIT_HEALTH in combat would cost frames, so a repeated error is passed on at
-- most once a minute. /worldcodex diag shows the counts.
ns.errors = {}
local ERROR_REPORT_EVERY = 60

local function ReportError(err)
    local msg = tostring(err)
    local e = ns.errors[msg]
    local now = GetTime and GetTime() or 0
    if e then
        e.n = e.n + 1
        if now - e.last < ERROR_REPORT_EVERY then return end
        e.last = now
    else
        local count = 0
        for _ in pairs(ns.errors) do
            count = count + 1
        end
        if count >= 50 then return end -- a flood of different messages: keep the first ones
        ns.errors[msg] = { n = 1, first = now, last = now, where = ns.context }
    end
    local h = geterrorhandler and geterrorhandler()
    if h then
        h(err)
    else
        print(err)
    end
end
ns.ReportError = ReportError

local function SafeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then ReportError(err) end
    return ok
end
ns.SafeCall = SafeCall

-- ---------------------------------------------------------------- freeze watchdog

-- How long WorldCodex's own Lua runs per event handler, timer and frame update. Calls of SLOW_MS
-- or more and frames of LONG_FRAME_MS or more are kept (newest first; /worldcodex diag perf, and in
-- the saved file as perfLog) together with WorldCodex's share of that frame, so a freeze can be told
-- apart from the client, the server or another addon.
local SLOW_MS, LONG_FRAME_MS, KEEP = 50, 250, 15
ns.slow = { calls = {}, frames = {} }
local where = setmetatable({}, { __mode = "k" }) -- handler -> "File.lua:line" that registered it
local frameWork, frameTopMs, frameTop = 0, 0, nil
local loadingUntil = 0

-- "UI/Page.lua:698" of the first caller outside Core.lua.
local function Where()
    if not debugstack then return nil end
    local ok, stack = pcall(debugstack, 2, 4, 0)
    if not ok or type(stack) ~= "string" then return nil end
    for file in stack:gmatch("WorldCodex[/\\](.-%.lua:%d+)") do
        if not file:match("^Core%.lua:") then return file end
    end
    return nil
end

local function Keep(list, entry)
    table.insert(list, 1, entry)
    if #list > KEEP then table.remove(list) end
end

-- SafeCall that measures: kind and name describe the call ("event", "LOOT_CLOSED").
local function Timed(kind, name, fn, ...)
    local clock = debugprofilestop
    if not clock then return SafeCall(fn, ...) end
    local t0 = clock()
    local ok = SafeCall(fn, ...)
    local ms = clock() - t0
    frameWork = frameWork + ms
    if ms > frameTopMs or ms >= SLOW_MS then
        local label = kind .. " " .. tostring(name) .. (where[fn] and (" (" .. where[fn] .. ")") or "")
        if ms > frameTopMs then
            frameTopMs, frameTop = ms, label
        end
        if ms >= SLOW_MS then Keep(ns.slow.calls, { t = ns.time(), what = label, ms = math.floor(ms) }) end
    end
    return ok
end

function ns.RegisterEvent(event, fn)
    where[fn] = where[fn] or Where()
    local list = handlers[event]
    if not list then
        if not pcall(frame.RegisterEvent, frame, event) then return false end
        list = {}
        handlers[event] = list
    end
    list[#list + 1] = fn
    return true
end

-- Breadcrumb of what WorldCodex is doing right now, reported if the game blocks one of our calls.
ns.context = "load"

function ns.Dispatch(event, ...)
    local list = handlers[event]
    if not list then return end
    if event == "ADDON_ACTION_FORBIDDEN" or event == "ADDON_ACTION_BLOCKED" then
        for i = 1, #list do
            SafeCall(list[i], ...)
        end
        return
    end
    local prev = ns.context
    ns.context = "event " .. event
    for i = 1, #list do
        Timed("event", event, list[i], ...)
    end
    ns.context = prev
end

frame:SetScript("OnEvent", function(_, event, ...) ns.Dispatch(event, ...) end)

function ns.On(name, fn)
    local list = callbacks[name]
    if not list then
        list = {}
        callbacks[name] = list
    end
    list[#list + 1] = fn
end

function ns.Fire(name, ...)
    local list = callbacks[name]
    if not list then return end
    local prev = ns.context
    ns.context = (prev or "?") .. " > " .. name
    for i = 1, #list do
        SafeCall(list[i], ...)
    end
    ns.context = prev
end

-- One-shot timers remember what scheduled them (ns.context), for the watchdog.
function ns.After(delay, fn) timers[#timers + 1] = { at = GetTime() + delay, fn = fn, from = ns.context } end

function ns.Every(interval, fn)
    where[fn] = where[fn] or Where()
    timers[#timers + 1] = { at = GetTime() + interval, fn = fn, every = interval }
end

function ns.OnUpdate(fn)
    where[fn] = where[fn] or Where()
    updaters[#updaters + 1] = fn
end

-- ---------------------------------------------------------------- background jobs

-- Long work (a share string built from years of data) runs in a coroutine that is resumed every frame
-- for JOB_BUDGET milliseconds, so the game keeps drawing. Code that can run inside a job calls
-- ns.Yield() in its loops; outside a job (guild sync, tests) ns.Yield does nothing. Lua 5.1 cannot
-- yield across pcall, table.sort comparators or other C calls: never call ns.Yield from inside them.
local JOB_BUDGET = 12
local jobs = {} -- name -> { co, done }
local jobCo, jobDeadline, jobTicks = nil, nil, 0

function ns.Yield()
    if not jobDeadline then return end
    jobTicks = jobTicks + 1
    if jobTicks < 64 then return end
    jobTicks = 0
    if debugprofilestop() >= jobDeadline and coroutine.running() == jobCo then coroutine.yield() end
end

local function StepJob(name, job)
    jobCo, jobDeadline, jobTicks = job.co, debugprofilestop() + JOB_BUDGET, 0
    local ok, res = coroutine.resume(job.co)
    jobCo, jobDeadline = nil, nil
    if jobs[name] ~= job then return end
    if not ok then
        jobs[name] = nil
        ReportError(res)
        SafeCall(job.done, false, res)
    elseif coroutine.status(job.co) == "dead" then
        jobs[name] = nil
        SafeCall(job.done, true, res)
    end
end

-- Runs fn() as job `name`; a new job with the same name replaces a running one. done(ok, result)
-- is called when it has finished. Without a frame clock the job runs at once.
function ns.RunJob(name, fn, done)
    if not debugprofilestop then
        local ok, res = pcall(fn)
        if not ok then ReportError(res) end
        SafeCall(done, ok, res)
        return
    end
    local job = { co = coroutine.create(fn), done = done }
    jobs[name] = job
    StepJob(name, job)
end

function ns.JobRunning(name) return jobs[name] ~= nil end

updaters[#updaters + 1] = function()
    if not next(jobs) then return end
    local names = {}
    for name in pairs(jobs) do
        names[#names + 1] = name
    end
    for _, name in ipairs(names) do
        local job = jobs[name]
        if job then StepJob(name, job) end
    end
end

function ns.Tick(elapsed)
    local now = GetTime()
    -- elapsed covers the previous frame, including the events handled during it
    local frameMs = (elapsed or 0) * 1000
    if frameMs >= LONG_FRAME_MS and now > loadingUntil then
        Keep(ns.slow.frames, {
            t = ns.time(),
            ms = math.floor(frameMs),
            mine = math.floor(frameWork),
            top = frameTop,
            topMs = math.floor(frameTopMs),
        })
    end
    frameWork, frameTopMs, frameTop = 0, 0, nil
    for i = #timers, 1, -1 do
        local t = timers[i]
        if t and now >= t.at then
            if t.every then
                t.at = now + t.every
            else
                table.remove(timers, i)
            end
            ns.context = "timer"
            Timed("timer", t.every and ("every " .. t.every .. "s") or ("from " .. tostring(t.from)), t.fn)
        end
    end
    ns.context = "update"
    for i = 1, #updaters do
        Timed("update", i, updaters[i], elapsed, now)
    end
    ns.context = "idle"
end

-- Loading screens are long frames of the client's own; they are not counted.
ns.RegisterEvent("LOADING_SCREEN_ENABLED", function() loadingUntil = math.huge end)
ns.RegisterEvent("LOADING_SCREEN_DISABLED", function() loadingUntil = GetTime() + 5 end)
ns.RegisterEvent("PLAYER_ENTERING_WORLD", function() loadingUntil = math.max(loadingUntil, GetTime() + 5) end)
-- kept in the saved file, so the last session's slow spots can be read after logging out
ns.On("DB_READY", function(db)
    db.perfLog = ns.slow
    db.errorLog = ns.errors
    db.secretLog = ns.secrets
    db.diagCounts = ns.counts
end)

frame:SetScript("OnUpdate", function(_, elapsed) ns.Tick(elapsed) end)

-- ---------------------------------------------------------------- blocked-action diagnostics

ns.blocked = {}

local function OnBlocked(event, addon, func)
    if addon ~= ADDON then return end
    local stack = debugstack and debugstack(2, 30, 0) or ""
    local ours = {}
    for line in stack:gmatch("[^\n]+") do
        if line:find(ADDON, 1, true) and not line:find("Core.lua", 1, true) then ours[#ours + 1] = line end
    end
    local entry = {
        event = event,
        func = tostring(func),
        context = ns.context,
        combat = InCombatLockdown and InCombatLockdown() or false,
        stack = table.concat(ours, "\n"),
        t = ns.time(),
    }
    table.insert(ns.blocked, 1, entry)
    while #ns.blocked > 10 do
        table.remove(ns.blocked)
    end
    if ns.db then ns.db.diag = ns.blocked end
    ns.Print(
        string.format(
            "|cffff4040%s|r %s() while: %s%s",
            event,
            entry.func,
            entry.context or "?",
            entry.combat and " (in combat)" or ""
        )
    )
    if entry.stack ~= "" then ns.Print(entry.stack) end
    ns.Print("please report this line - /worldcodex diag shows it again")
end

frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
handlers.ADDON_ACTION_FORBIDDEN = { function(...) OnBlocked("ADDON_ACTION_FORBIDDEN", ...) end }
handlers.ADDON_ACTION_BLOCKED = { function(...) OnBlocked("ADDON_ACTION_BLOCKED", ...) end }

function ns.InCombat() return InCombatLockdown and InCombatLockdown() or false end

local profileClock = debugprofilestop
function ns.Profile(name, fn, ...)
    if not profileClock then return fn(...) end
    local t0 = profileClock()
    local a, b, c = fn(...)
    local dt = profileClock() - t0
    local p = ns.perf[name]
    if not p then
        p = { n = 0, total = 0, max = 0 }
        ns.perf[name] = p
    end
    p.n = p.n + 1
    p.total = p.total + dt
    if dt > p.max then p.max = dt end
    return a, b, c
end

function ns.Print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    local msg = "|cff33ff99[WorldCodex]|r " .. table.concat(parts, " ")
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    else
        print(msg)
    end
end

function ns.Debug(...)
    if ns.db and ns.db.settings and ns.db.settings.debug then ns.Print("|cff888888debug|r", ...) end
end

function ns.Trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

function ns.Coin(copper)
    copper = math.floor((tonumber(copper) or 0) + 0.5)
    -- coin icons; the global GetCoinTextureString does not exist on WoW Forever (in-game API dump)
    local icons = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
    if icons then
        local ok, text = pcall(icons, copper)
        if ok and type(text) == "string" then return text end
    end
    local g = math.floor(copper / 10000)
    local s = math.floor(copper / 100) % 100
    local c = copper % 100
    if g > 0 then return string.format("%dg %ds %dc", g, s, c) end
    if s > 0 then return string.format("%ds %dc", s, c) end
    return string.format("%dc", c)
end

function ns.ShortCoin(copper)
    copper = math.floor((tonumber(copper) or 0) + 0.5)
    local g = math.floor(copper / 10000)
    local s = math.floor(copper / 100) % 100
    local c = copper % 100
    if g >= 100 then return string.format("%dg", g) end
    if g > 0 then return string.format("%dg%02ds", g, s) end
    if s > 0 then return string.format("%ds%02dc", s, c) end
    return string.format("%dc", c)
end

-- Short amount with the client's coin icons (rounded like ns.ShortCoin: whole gold from 100 gold,
-- whole silver from 1 gold); for tables and lists. Falls back to ns.ShortCoin.
function ns.CoinShort(copper)
    copper = math.floor((tonumber(copper) or 0) + 0.5)
    local g = math.floor(copper / 10000)
    if g >= 100 then
        copper = g * 10000
    elseif g > 0 then
        copper = math.floor(copper / 100) * 100
    end
    local icons = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
    if icons then
        local ok, text = pcall(icons, copper)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    return ns.ShortCoin(copper)
end

function ns.Pct(p) return string.format("%.1f%%", (p or 0) * 100) end

function ns.Age(seconds)
    seconds = math.max(0, seconds or 0)
    if seconds < 60 then return L["<1 min"] end
    if seconds < 3600 then return string.format(L["%d min"], math.floor(seconds / 60)) end
    if seconds < 86400 then return string.format(L["%d h"], math.floor(seconds / 3600)) end
    return string.format(L["%d d"], math.floor(seconds / 86400))
end

function ns.Duration(minutes)
    if not minutes or minutes ~= minutes or minutes == math.huge then return "?" end
    if minutes < 1 then return L["<1 min"] end
    if minutes < 90 then return string.format(L["%d min"], math.floor(minutes + 0.5)) end
    return string.format(L["%.1f h"], minutes / 60)
end

function ns.Split(s, sep)
    local out = {}
    for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do
        out[#out + 1] = part
    end
    return out
end

-- ---------------------------------------------------------------- secret values

-- Midnight-era clients (WoW Forever included) return "secret" values from unit, loot, chat and
-- tooltip APIs in combat and instances. Addon code may hold them, but comparing, indexing,
-- concatenating, testing or using one as a table key raises an error - in handlers that run on
-- every UNIT_HEALTH or tooltip that means a stream of errors. Values from those APIs go through
-- ns.Plain, which turns a secret into nil (unknown).
-- Counters for diagnosis (saved as diagCounts, /worldcodex diag perf): which code paths ran how often.
ns.counts = {}
function ns.Count(what, value)
    if value ~= nil then
        ns.counts[what] = value
    else
        ns.counts[what] = (tonumber(ns.counts[what]) or 0) + 1
    end
end

-- what = a short label: secret values seen are counted per label (ns.secrets, saved as secretLog,
-- /worldcodex diag perf), so a test session shows which values the client hides where.
ns.secrets = {}

function ns.Plain(v, what)
    local f = issecretvalue
    if f and f(v) then
        if what then ns.secrets[what] = (ns.secrets[what] or 0) + 1 end
        return nil
    end
    return v
end

-- Whether the client hides a unit's identity (GUID, name) right now: instances and restricted combat.
-- C_Secrets.ShouldUnitIdentityBeSecret exists on Midnight-era clients (DBM and Details use it).
function ns.UnitHidden(unit)
    local f = C_Secrets and C_Secrets.ShouldUnitIdentityBeSecret
    if not f then return false end
    local ok, hidden = pcall(f, unit)
    return ok and ns.Plain(hidden) == true
end

-- Restriction state of one kind ("Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map"): true,
-- false, or nil when the client has no such API.
function ns.Restricted(kind)
    local get = C_RestrictedActions and C_RestrictedActions.GetAddOnRestrictionState
    local types = Enum and Enum.AddOnRestrictionType
    if not (get and types and types[kind] ~= nil) then return nil end
    local ok, state = pcall(get, types[kind])
    state = ok and ns.Plain(state) or nil
    if type(state) ~= "number" then return nil end
    return state > 0
end

function ns.IsSecret(v)
    local f = issecretvalue
    return f ~= nil and f(v) and true or false
end

-- pcall(fn, ...) -> first result, or nil when the call fails, is missing or returns a secret.
function ns.Call(fn, ...)
    if not fn then return nil end
    local ok, v = pcall(fn, ...)
    if not ok then return nil end
    return ns.Plain(v)
end

-- ns.Call that counts a secret result under `what` (ns.secrets).
function ns.CallAs(what, fn, ...)
    if not fn then return nil end
    local ok, v = pcall(fn, ...)
    if not ok then return nil end
    return ns.Plain(v, what)
end

-- Creature name from an npc id without the unit being around: the client's creature cache through a
-- unit hyperlink (as map pin addons do). Needed where unit names are secret (instances). nil while
-- the client has not cached the creature; the lookup asks the server, so a later call succeeds.
-- Found names are kept for the session; a miss is not asked again for a few seconds, so readers
-- that run often (lists, Store.SourceMeta) cost one table lookup.
local creatureNames, creatureMiss = {}, {}
local CREATURE_RETRY = 3

function ns.CreatureName(npcId)
    local get = C_TooltipInfo and C_TooltipInfo.GetHyperlink
    if type(npcId) ~= "number" or npcId <= 0 or not get then return nil end
    local known = creatureNames[npcId]
    if known then return known end
    local now = GetTime()
    local miss = creatureMiss[npcId] -- { t, hidden }
    if miss and now - miss[1] < CREATURE_RETRY then return nil, miss[2] and "secret" or nil end
    local ok, data = pcall(get, "unit:Creature-0-0-0-0-" .. npcId)
    if not ok then data = nil end
    -- inside instances the client hides this too (confirmed): "secret" tells callers to wait
    local hidden = ns.IsSecret(data)
    data = ns.Plain(data, "creature cache")
    local lines = type(data) == "table" and data.lines
    hidden = hidden or ns.IsSecret(lines)
    lines = ns.Plain(lines, "creature cache")
    local line = type(lines) == "table" and lines[1]
    local text = type(line) == "table" and line.leftText
    hidden = hidden or ns.IsSecret(text)
    local name = ns.Plain(text, "creature cache")
    if type(name) ~= "string" or name == "" or name == UNKNOWNOBJECT or name == UNKNOWN then
        creatureMiss[npcId] = { now, hidden }
        return nil, hidden and "secret" or nil
    end
    creatureNames[npcId], creatureMiss[npcId] = name, nil
    return name
end

function ns.GuidType(guid)
    guid = ns.Plain(guid)
    if type(guid) ~= "string" or guid == "" then return nil end
    if guid:sub(1, 2) == "0x" then
        local h = guid:sub(3, 6):upper()
        if h == "F130" or h == "F140" then return "Creature" end
        if h == "F150" then return "Vehicle" end
        if h == "F110" then return "GameObject" end
        return nil
    end
    return guid:match("^([^%-]+)")
end

function ns.GuidId(guid)
    guid = ns.Plain(guid)
    if type(guid) ~= "string" or guid == "" then return nil end
    if guid:sub(1, 2) == "0x" then return tonumber(guid:sub(7, 12), 16) end
    local p = ns.Split(guid, "-")
    return tonumber(p[6])
end

function ns.ItemIdFromLink(link)
    link = ns.Plain(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end

local GetItemInfoFn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
function ns.ItemInfo(itemId)
    if not GetItemInfoFn or not itemId then return nil end
    local ok, name, link, quality, _, _, _, _, _, _, texture, sellPrice = pcall(GetItemInfoFn, itemId)
    if not ok or type(name) ~= "string" then return nil end
    return name, quality, sellPrice, texture, link
end

-- Everything GetItemInfo knows about an item (nil fields when the client has not cached it yet).
function ns.ItemDetails(itemId)
    local d = { id = itemId }
    if GetItemInfoFn and itemId then
        local ok, name, link, quality, ilvl, minLevel, class, subclass, stack, equipLoc, texture, sellPrice, classId, subclassId, bind =
            pcall(GetItemInfoFn, itemId)
        if ok and type(name) == "string" then
            d.name, d.link, d.quality, d.ilvl, d.minLevel = name, link, quality, ilvl, minLevel
            d.class, d.subclass, d.stack, d.texture, d.sellPrice = class, subclass, stack, texture, sellPrice
            d.classId, d.subclassId, d.bind = classId, subclassId, bind
            if type(equipLoc) == "string" and equipLoc ~= "" then
                d.equipLoc = equipLoc
                -- reagents have a slot type whose label is empty (INVTYPE_NON_EQUIP_IGNORE)
                local label = _G[equipLoc]
                if type(label) == "string" and label ~= "" then d.slot = label end
            end
        end
    end
    d.texture = d.texture or ns.ItemIcon(itemId)
    return d
end

-- Icon of an item (file id or path); also for items the client has not cached (from its item data).
function ns.ItemIcon(itemId)
    if not itemId then return nil end
    local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
    if getIcon then
        local ok, tex = pcall(getIcon, itemId)
        if ok and tex ~= nil and tex ~= 0 and tex ~= "" then return tex end
    end
    local _, _, _, texture = ns.ItemInfo(itemId)
    if texture ~= 0 and texture ~= "" then return texture end
    return nil
end

function ns.QualityColor(quality)
    if ITEM_QUALITY_COLORS and quality and ITEM_QUALITY_COLORS[quality] then
        local c = ITEM_QUALITY_COLORS[quality]
        if c.hex then return c.hex end
        return string.format("|cff%02x%02x%02x", (c.r or 1) * 255, (c.g or 1) * 255, (c.b or 1) * 255)
    end
    return "|cffffffff"
end

function ns.ItemName(itemId, colored)
    local name, quality = ns.ItemInfo(itemId)
    local it = ns.db and ns.db.items[itemId]
    if not name and it then
        name, quality = it.n, it.ql
    end
    name = name or ("item:" .. tostring(itemId))
    if colored then return ns.QualityColor(quality) .. name .. "|r" end
    return name
end

function ns.ItemLink(itemId)
    local _, _, _, _, link = ns.ItemInfo(itemId)
    return link or ("|cffffffff|Hitem:" .. itemId .. "::::::::::::|h[" .. ns.ItemName(itemId) .. "]|h|r")
end

function ns.SpellName(spellId)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
        if ok and type(info) == "table" and info.name then return info.name end
    end
    if GetSpellInfo then
        local ok, name = pcall(GetSpellInfo, spellId)
        if ok and type(name) == "string" then return name end
    end
    return nil
end

-- Set of item ids currently in the player's bags (backpack, bags and reagent bag). Cached until bags change.
local bagCache
function ns.BagItems()
    if bagCache then return bagCache end
    local numSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local itemId = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
    local set = {}
    if numSlots and itemId then
        for bag = 0, 5 do
            local ok, n = pcall(numSlots, bag)
            for slot = 1, (ok and n or 0) do
                local id = itemId(bag, slot)
                if id then set[id] = true end
            end
        end
    end
    bagCache = set
    return set
end

ns.RegisterEvent("BAG_UPDATE_DELAYED", function()
    bagCache = nil
    ns.Fire("BAGS_CHANGED")
end)

function ns.InGroup()
    if IsInGroup then return IsInGroup() and true or false end
    if GetNumPartyMembers then
        return (GetNumPartyMembers() or 0) > 0 or (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0
    end
    return false
end

function ns.InRaid()
    if IsInRaid then return IsInRaid() and true or false end
    return GetNumRaidMembers and (GetNumRaidMembers() or 0) > 0 or false
end

function ns.PlayerLocation()
    if C_Map and C_Map.GetBestMapForUnit then
        local map = C_Map.GetBestMapForUnit("player")
        if map then
            local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(map, "player")
            if pos then
                local x, y = pos:GetXY()
                x, y = ns.Plain(x), ns.Plain(y)
                if x and y and (x > 0 or y > 0) then return map, x, y end
            end
            return map
        end
    end
    if GetPlayerMapPosition then
        local map = GetCurrentMapAreaID and GetCurrentMapAreaID()
        local x, y = GetPlayerMapPosition("player")
        if map and x and (x > 0 or y > 0) then return map, x, y end
        return map
    end
    return nil
end

-- Name shown in the mouseover tooltip when it is not a unit or an item: a chest, herb, vein or other
-- object. nil otherwise.
function ns.HoveredObjectName()
    if not (GameTooltip and GameTooltip.IsShown and GameTooltip:IsShown() and GameTooltipTextLeft1) then return nil end
    local unit = GameTooltip.GetUnit and select(2, GameTooltip:GetUnit())
    if unit then return nil end
    local link = GameTooltip.GetItem and select(2, GameTooltip:GetItem())
    if link then return nil end
    local name = ns.Plain(GameTooltipTextLeft1:GetText())
    return type(name) == "string" and name ~= "" and name or nil
end

-- In instances the client gives addons neither a position nor a map id (confirmed on WoW Forever):
-- the zone is the instance itself, keyed by its negative instance id so it never collides with a map
-- id. Its name (client language) is kept in db.maps. Returns key, name or nil outside instances.
function ns.InstanceZone()
    if not (IsInInstance and GetInstanceInfo) then return nil end
    if not ns.Call(IsInInstance) then return nil end
    local ok, name, _, _, _, _, _, _, id = pcall(GetInstanceInfo)
    if not ok then return nil end
    id, name = ns.Plain(id), ns.Plain(name)
    if type(id) ~= "number" or id <= 0 then return nil end
    if type(name) == "string" and name ~= "" and ns.db then ns.db.maps[-id] = name end
    return -id, name
end

function ns.MapName(map)
    if not map then return "?" end
    local db = ns.db
    if db and db.maps[map] then return db.maps[map] end
    if map < 0 then
        -- an instance this client has not been in: its name by instance id where the client knows it
        local name = GetRealZoneText and ns.Call(GetRealZoneText, -map)
        if type(name) == "string" and name ~= "" and name ~= ns.Call(GetRealZoneText) then return name end
        return string.format(L["Instance %d"], -map)
    end
    local name
    if C_Map and C_Map.GetMapInfo then
        local info = C_Map.GetMapInfo(map)
        name = info and info.name
    end
    if not name and GetMapNameByID then name = GetMapNameByID(map) end
    if name and db then db.maps[map] = name end
    return name or ("map " .. map)
end

function ns.UnitForGuid(guid)
    if not guid then return nil end
    for _, unit in ipairs({ "target", "mouseover", "focus", "softenemy", "softinteract" }) do
        local g = ns.Call(UnitGUID, unit)
        if g and g == guid then return unit end
    end
    return nil
end

function ns.IsTapDenied(unit)
    if not unit then return false end
    if UnitIsTapDenied then return ns.Call(UnitIsTapDenied, unit) and true or false end
    if UnitIsTapped and UnitIsTappedByPlayer then
        return (ns.Call(UnitIsTapped, unit) and not ns.Call(UnitIsTappedByPlayer, unit)) and true or false
    end
    return false
end

-- ---------------------------------------------------------------- farming switch

-- WorldCodex is an item encyclopedia first. Its farming features (goals, tracker, arrow, sessions,
-- "best farm" suggestions) are optional; when a dedicated farming addon is loaded they start
-- switched off. Data collection is the same either way.
ns.FARMING_ADDONS = { "blackthornesfarmer" }

-- Title of a loaded farming addon, or nil.
function ns.OtherFarmingAddon()
    local num = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
    local info = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if not num or not info or not isLoaded then return nil end
    local ok, n = pcall(num)
    if not ok or type(n) ~= "number" then return nil end
    for i = 1, n do
        local ok2, name, title = pcall(info, i)
        if ok2 and type(name) == "string" then
            local flat = name:lower():gsub("[^%w]", "")
            for _, pattern in ipairs(ns.FARMING_ADDONS) do
                if flat:find(pattern, 1, true) then
                    local ok3, loaded = pcall(isLoaded, name)
                    if ok3 and loaded then return (type(title) == "string" and title ~= "") and title or name end
                end
            end
        end
    end
    return nil
end

-- Date and contributor count of the community data shipped with this version (nil without data).
function ns.CommunityInfo()
    local c = WorldCodex_CommunityData
    if type(c) ~= "table" or (tonumber(c.generated) or 0) <= 0 then return nil end
    local n = 0
    for _ in pairs(type(c.contributors) == "table" and c.contributors or {}) do
        n = n + 1
    end
    return c.generated, n
end

function ns.FarmingOn() return not ns.db or ns.db.settings.farming ~= false end

-- Decided at login (all addons are loaded then) unless the player chose in the options.
function ns.DecideFarming()
    local s = ns.db and ns.db.settings
    if not s or (s.farming ~= nil and not s.farmingAuto) then return end
    local other = ns.OtherFarmingAddon()
    local on = not other
    local changed = s.farming ~= on
    s.farming, s.farmingAuto = on, true
    if other and not ns.db.meta.farmNote then
        ns.db.meta.farmNote = true
        ns.Print(
            string.format(
                L["%s is loaded, so WorldCodex's own farming features (goals, tracker, arrow, sessions) are off. You can switch them on in the options."],
                other
            )
        )
    end
    if changed then ns.Fire("SETTINGS_CHANGED", "farming", on) end
end
ns.RegisterEvent("PLAYER_LOGIN", function() ns.DecideFarming() end)

ns.KIND_ORDER = {
    "mob",
    "herb",
    "mine",
    "skin",
    "fish",
    "pickpocket",
    "lockpick",
    "object",
    "container",
    "quest",
    "disenchant",
    "mill",
    "prospect",
    "salvage",
    "other",
}
ns.KIND_LABEL = {
    mob = L["Mobs"],
    herb = L["Herbalism"],
    mine = L["Mining"],
    skin = L["Skinning"],
    fish = L["Fishing"],
    pickpocket = L["Pickpocketing"],
    lockpick = L["Lockpicking"],
    object = L["Chests & objects"],
    container = L["Containers"],
    quest = L["Quests"],
    disenchant = L["Disenchanting"],
    mill = L["Milling"],
    prospect = L["Prospecting"],
    salvage = L["Salvage"],
    other = L["Other"],
    vendor = L["Vendor"],
    npc = L["NPC"],
}
