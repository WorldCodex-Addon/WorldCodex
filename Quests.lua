local _, ns = ...

-- Quests as item sources. The reward window (QUEST_COMPLETE) lists fixed and choice rewards; the
-- turn-in (QUEST_TURNED_IN) counts as one attempt. The accept location is stored as the quest's
-- spawn so navigation leads to the quest giver. The quest's level (from the quest log, while the quest is
-- in it) is kept as the record's level range (lmin = lmax), shared like a mob's level (snapshot lv).
local Q = {}
ns.Quests = Q

local Store = ns.Store
local TURN_IN_WINDOW = 5

local offered -- rewards seen in the reward window, waiting for the turn-in
local detail -- quest shown in the accept dialog
local progress -- items required by the quest in the hand-in dialog (QUEST_PROGRESS)
local lastTurnIn -- { key, t } so the reward items that follow in chat count as income

function Q.Key(questId) return "quest:" .. questId end

local function Starts() return ns.db.questStarts end

local function QuestTitle(questId, fallback)
    if fallback and fallback ~= "" then return fallback end
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, title = pcall(C_QuestLog.GetTitleForQuestID, questId)
        if ok and title then return title end
    end
    return "Quest " .. questId
end

function Q.IsCompleted(questId)
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        local ok, done = pcall(C_QuestLog.IsQuestFlaggedCompleted, questId)
        if ok then return done and true or false end
    end
    if IsQuestFlaggedCompleted then return IsQuestFlaggedCompleted(questId) and true or false end
    return false
end

-- questId from a "quest:<id>" source key
function Q.IdFromKey(key) return type(key) == "string" and tonumber(key:match("^quest:(%d+)$")) or nil end

local function ReadRewards(kind, count)
    local out = {}
    for i = 1, count or 0 do
        local link = GetQuestItemLink and GetQuestItemLink(kind, i)
        local id = ns.ItemIdFromLink(link)
        local name, _, qty = GetQuestItemInfo(kind, i)
        if id then out[id] = { q = tonumber(qty) or 1, name = name } end
    end
    return out
end

-- Level of a quest in the log (nil when it is not in the log or the client does not say).
function Q.Level(questId)
    local level
    local log = C_QuestLog
    if log and log.GetLogIndexForQuestID and log.GetInfo then
        local index = ns.Call(log.GetLogIndexForQuestID, questId)
        local info = index and ns.Call(log.GetInfo, index)
        if type(info) == "table" then level = ns.Plain(info.level) end
    end
    if (type(level) ~= "number" or level <= 0) and log and log.GetQuestDifficultyLevel then
        level = ns.Call(log.GetQuestDifficultyLevel, questId)
    end
    level = tonumber(level)
    if not level or level <= 0 or level > 100 then return nil end
    return math.floor(level)
end

local function RepeatType()
    if QuestIsDaily and QuestIsDaily() then return "daily" end
    if QuestIsWeekly and QuestIsWeekly() then return "weekly" end
    return nil
end

-- Who the quest window belongs to: npc id for creatures, "go:<id>" for objects (wanted posters,
-- books). A quest that opens right after using a bag item was started by that item.
function Q.NpcKey()
    local guid = ns.Call(UnitGUID, "npc")
    local gt = ns.GuidType(guid)
    if gt == "Creature" or gt == "Vehicle" then return ns.GuidId(guid) end
    if gt == "GameObject" then
        local id = ns.GuidId(guid)
        return id and ("go:" .. id) or nil
    end
    return nil
end

local function StartItem()
    local use = ns.Collector and ns.Collector.LastItemUse and ns.Collector.LastItemUse(5)
    return use and use.id or nil
end

function Q.OnDetail()
    local questId = GetQuestID and GetQuestID()
    if not questId or questId == 0 then return end
    local gid = Q.NpcKey()
    detail = {
        id = questId,
        title = GetTitleText and GetTitleText(),
        giver = ns.Call(UnitName, "npc"),
        gid = gid,
        si = not gid and StartItem() or nil,
        lv = Q.Level(questId),
    }
end

-- Hand-in dialog with the items the quest asks for.
function Q.OnProgress()
    local questId = GetQuestID and GetQuestID()
    if not questId or questId == 0 or not GetNumQuestItems then return end
    local req = {}
    for i = 1, GetNumQuestItems() or 0 do
        local id = ns.ItemIdFromLink(GetQuestItemLink and GetQuestItemLink("required", i))
        local _, _, count = GetQuestItemInfo("required", i)
        if id then req[id] = tonumber(count) or 1 end
    end
    progress = { id = questId, req = req, tid = Q.NpcKey() }
end

function Q.OnAccepted(a1, a2)
    local questId = a2 or a1
    if type(questId) ~= "number" or questId == 0 then return end
    local map, x, y = ns.PlayerLocation()
    local start = { t = ns.time(), map = map, x = x, y = y }
    if detail and detail.id == questId then
        start.giver = detail.giver
        start.title = detail.title
        start.gid = detail.gid
        start.si = detail.si
        start.lv = detail.lv
    end
    start.lv = Q.Level(questId) or start.lv
    Starts()[questId] = start
end

function Q.OnRewardWindow()
    local questId = GetQuestID and GetQuestID()
    if not questId or questId == 0 then return end
    offered = {
        id = questId,
        title = GetTitleText and GetTitleText(),
        rewards = ReadRewards("reward", GetNumQuestRewards and GetNumQuestRewards()),
        choices = ReadRewards("choice", GetNumQuestChoices and GetNumQuestChoices()),
        rep = RepeatType(),
        npc = ns.Call(UnitName, "npc"),
        tid = Q.NpcKey(),
        lv = Q.Level(questId),
    }
end

function Q.OnTurnedIn(questId, _, money)
    if type(questId) ~= "number" then return end
    local o = offered and offered.id == questId and offered or nil
    offered = nil
    local start = Starts()[questId]
    local key = Q.Key(questId)
    local rec = Store.EnsureSource(key, QuestTitle(questId, (o and o.title) or (start and start.title)), "quest")
    rec.kind = "quest"
    if o and o.rep then rec.rep = o.rep end
    if start and start.giver then
        rec.giver = start.giver
    elseif o and o.npc then
        rec.giver = rec.giver or o.npc
    end
    if not next(rec.spawns) then
        if start and start.x then
            Store.AddSpawn(rec, start.map, start.x, start.y)
        else
            local map, x, y = ns.PlayerLocation()
            if x then Store.AddSpawn(rec, map, x, y) end
        end
    end
    -- quest giver / turn-in npc keys, start item and required items (latest wins)
    if start and start.gid then rec.gid = start.gid end
    if start and start.si then rec.si = start.si end
    if o and o.tid then rec.tid = o.tid end
    local p = progress and progress.id == questId and progress or nil
    progress = nil
    if p and next(p.req) then rec.req = p.req end
    if not rec.tid and p and p.tid then rec.tid = p.tid end
    local level = (o and o.lv) or (start and start.lv)
    if level and (rec.lmin ~= level or rec.lmax ~= level) then
        rec.lmin, rec.lmax = level, level
        Store.Mark(rec)
    end
    Starts()[questId] = nil
    Store.CountAttempt(key, rec, ns.InGroup())
    if o then
        for id, r in pairs(o.rewards) do
            Store.AddDrop(key, rec, id, r.q, r.name)
        end
        rec.choice = rec.choice or {}
        for id, r in pairs(o.choices) do
            Store.AddDrop(key, rec, id, r.q, r.name)
            rec.choice[id] = true
        end
    end
    money = tonumber(money) or 0
    if money > 0 then
        Store.AddMoney(rec, money)
        ns.Fire("MONEY", money)
    end
    lastTurnIn = { key = key, t = GetTime() }
    ns.Fire("DATA_CHANGED", "quest")
end

-- True right after a turn-in, when "You receive item" messages are the quest's rewards.
function Q.InTurnIn() return lastTurnIn ~= nil and GetTime() - lastTurnIn.t <= TURN_IN_WINDOW end

function Q.IsChoice(key, itemId)
    local rec = ns.db.sources[key]
    if rec and rec.choice and rec.choice[itemId] then return true end
    for _, peer in pairs(ns.db.peers) do
        local s = peer.src and peer.src[key]
        if s and s.ch and s.ch[itemId] then return true end
    end
    local c = Store.Community()
    local s = c and c.sources[key]
    return s and s.ch and s.ch[itemId] and true or false
end

-- Repeat type ("daily"/"weekly") from any layer, nil for one-time quests.
function Q.RepeatType(key)
    local rec = ns.db.sources[key]
    if rec and rec.rep then return rec.rep end
    for _, peer in pairs(ns.db.peers) do
        local s = peer.src and peer.src[key]
        if s and s.rp then return s.rp end
    end
    local c = Store.Community()
    local s = c and c.sources[key]
    return s and s.rp or nil
end

-- Giver key, turn-in key, required items and start item of a quest from the first layer that has
-- them (own record first; shared snapshots carry them as qg, qt, rq, si).
function Q.Fields(key)
    local rec = ns.db.sources[key]
    local gid, tid, req, si = rec and rec.gid, rec and rec.tid, rec and rec.req, rec and rec.si
    if gid == nil or tid == nil or req == nil or si == nil then
        Store.EachShared(key, function(_, s)
            if gid == nil then gid = s.qg end
            if tid == nil then tid = s.qt end
            if req == nil and type(s.rq) == "table" then req = s.rq end
            if si == nil then si = s.si end
        end)
    end
    return gid, tid, req, si
end

-- Lookups over all quests: which quests an npc/object starts or ends, which quests need an item,
-- and which quests an item starts. Rebuilt when data changes.
local qindex
function Q.Index()
    if qindex and qindex.rev == ns.db.meta.rev and not qindex.dirty then return qindex end
    local idx = { rev = ns.db.meta.rev, starts = {}, ends = {}, requires = {}, startedBy = {} }
    local function add(t, k, v)
        if k == nil then return end
        t[k] = t[k] or {}
        t[k][#t[k] + 1] = v
    end
    for key in pairs(Store.AllSourceKeys()) do
        if Q.IdFromKey(key) then
            local gid, tid, req, si = Q.Fields(key)
            add(idx.starts, gid, key)
            add(idx.ends, tid, key)
            add(idx.startedBy, si, key)
            for id, count in pairs(req or {}) do
                add(idx.requires, id, { key = key, count = count })
            end
        end
    end
    qindex = idx
    return idx
end
ns.On("DATA_CHANGED", function()
    if qindex then qindex.dirty = true end
end)
ns.On("SETTINGS_CHANGED", function()
    if qindex then qindex.dirty = true end
end)

-- ---------------------------------------------------------------- items the quest log still needs

-- Quest items only drop while a quest in the log still asks for them, so their drop rate may only
-- count attempts from that time (Store.CountNeeded). Objectives carry no item id, only a text
-- ("Sunscale Feather: 3/10", newer clients "3/10 Sunscale Feather"): items are matched by name.
local RECENT = 900
local needed -- { names = { [objective name] = true }, complete = bool }; a new table on every change
local dirty, ready = 0, false -- dirty: time the log changed since it was last read, else false
local lastNeeded = {} -- objective name -> time it was last still needed

function Q.ObjectiveName(text)
    if type(text) ~= "string" then return nil end
    local name = text:match("^%s*%d+%s*/%s*%d+%s+(.-)%s*$")
        or text:match("^%s*(.-)%s*:%s*%d+%s*/%s*%d+")
        or text:match("^%s*(.-)%s*：%s*%d+%s*/%s*%d+")
        or text:match("^%s*(.-)%s*$")
    -- only a count: the client has not loaded the item's name yet
    if not name or name:match("^[%d%s/:]*$") then return nil end
    return name
end

local function ReadLog()
    local api = C_QuestLog
    local out = { names = {}, complete = true }
    local seen, count = {}, 0
    local function add(questId)
        if type(questId) ~= "number" or questId <= 0 or seen[questId] then return end
        seen[questId] = true
        count = count + 1
        if ns.Call(api.IsFailed, questId) then return end
        local list = ns.Call(api.GetQuestObjectives, questId)
        if type(list) ~= "table" then
            if ns.Call(api.GetNumQuestObjectives, questId) ~= 0 then out.complete = false end
            return
        end
        for _, o in ipairs(list) do
            if ns.Plain(o.type) == "item" and not ns.Plain(o.finished) then
                local name = Q.ObjectiveName(ns.Plain(o.text))
                if name then
                    out.names[name] = true
                else
                    out.complete = false -- the item's name is not loaded yet
                end
            end
        end
    end
    local ok, shown, total = pcall(api.GetNumQuestLogEntries)
    if not ok then return nil end
    for i = 1, tonumber(ns.Plain(shown)) or 0 do
        add(ns.Call(api.GetQuestIDForLogIndex, i))
    end
    -- quests under collapsed headers are not listed on every client
    total = tonumber(ns.Plain(total)) or 0
    if count < total then
        for questId in pairs(Starts()) do
            if ns.Call(api.IsOnQuest, questId) then add(questId) end
        end
    end
    if count < total then out.complete = false end
    return out
end

-- Items the quest log still needs right now, or nil while the log is unknown (before the client has
-- sent it). The result is never changed afterwards, so it can be kept as the state at that moment.
function Q.Needed()
    local api = C_QuestLog
    if
        not ready or not (api and api.GetNumQuestLogEntries and api.GetQuestIDForLogIndex and api.GetQuestObjectives)
    then
        return nil
    end
    if dirty or not needed then
        for name in pairs(needed and needed.names or {}) do
            lastNeeded[name] = dirty or GetTime()
        end
        needed = ReadLog()
        dirty = false
    end
    return needed
end

-- What was needed at both moments (a mob's death and its loot window).
function Q.Both(a, b)
    if a == nil or a == b then return b end
    if b == nil then return nil end
    local out = { names = {}, complete = a.complete and b.complete }
    for name in pairs(a.names) do
        if b.names[name] then out.names[name] = true end
    end
    return out
end

-- Objective of a name table that stands for an item: the same name, else the only objective that
-- contains the item's name (plural objectives). Second result: more than one could be meant.
function Q.Match(names, itemName)
    if type(itemName) ~= "string" or itemName == "" then return nil end
    if names[itemName] then return itemName end
    local found
    for name in pairs(names) do
        if name:find(itemName, 1, true) then
            if found then return nil, true end
            found = name
        end
    end
    return found
end

-- Whether a quest needs the item or did a few minutes ago: corpses from before the last objective
-- item was looted may still hold one.
function Q.RecentlyNeeded(itemName)
    local now = Q.Needed()
    local names = {}
    for name in pairs(now and now.names or {}) do
        names[name] = true
    end
    for name, t in pairs(lastNeeded) do
        if GetTime() - t <= RECENT then names[name] = true end
    end
    local name, ambiguous = Q.Match(names, itemName)
    return name ~= nil or ambiguous == true
end

local function LogChanged() dirty = dirty or GetTime() end

ns.On("DB_READY", function(db)
    ns.RegisterEvent("QUEST_LOG_UPDATE", function()
        ready = true
        LogChanged()
    end)
    for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "QUEST_DATA_LOAD_RESULT" }) do
        ns.RegisterEvent(event, LogChanged)
    end
    db.questStarts = type(db.questStarts) == "table" and db.questStarts or {}
    local cutoff = ns.time() - 60 * 86400
    for id, s in pairs(db.questStarts) do
        if (s.t or 0) < cutoff then db.questStarts[id] = nil end
    end
    ns.RegisterEvent("QUEST_DETAIL", Q.OnDetail)
    ns.RegisterEvent("QUEST_PROGRESS", Q.OnProgress)
    ns.RegisterEvent("QUEST_ACCEPTED", Q.OnAccepted)
    ns.RegisterEvent("QUEST_COMPLETE", Q.OnRewardWindow)
    ns.RegisterEvent("QUEST_TURNED_IN", Q.OnTurnedIn)
end)

return Q
