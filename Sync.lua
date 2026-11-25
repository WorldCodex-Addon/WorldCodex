local _, ns = ...

-- Guild / group data sharing. Every player only ever sends their own personal counts, and peers
-- are stored per sender (replaced on update), so data is never counted twice.
--   V:<uid>:<rev>        advertise (GUILD / PARTY / RAID)
--   Q:<uid>              request a snapshot from the player who advertised <uid>
--   D:<xfer>:<i>:<n>:..  snapshot chunk
local S = {}
ns.Sync = S

local L = ns.L
local PREFIX = "WorldCodex"
local CHUNK = 200
local SEND_INTERVAL = 1.0
local ADVERTISE_EVERY = 600
local ANSWER_COOLDOWN = 600
local REQUEST_COOLDOWN = 900

local outbox = {}
local incoming = {}
local requests = {}
local answered = {}
local asked = {}
local lastSend = 0
local xferSeq = 0
S.stats = { sent = 0, received = 0, imported = 0 }

local function Enabled() return ns.db and ns.db.settings.sync end

local function Me()
    local name = UnitName and UnitName("player") or "?"
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

local function SameName(a, b)
    if not a or not b then return false end
    if a == b then return true end
    if a:find("-", 1, true) and b:find("-", 1, true) then return false end
    return a:match("^[^%-]+") == b:match("^[^%-]+")
end

-- Addon messages are blocked inside instances on Midnight-era clients (and whenever the client's
-- "Chat" restriction is on: Enum.AddOnRestrictionType.Chat, "addon chat communications are
-- restricted"): nothing is sent then, queued messages wait in the outbox.
local function CanSend()
    if ns.Call(IsInInstance) then return false end
    return ns.Restricted("Chat") ~= true and ns.Restricted("Map") ~= true
end
S.CanSend = CanSend

local function RawSend(msg, channel, target)
    if ChatThrottleLib and ChatThrottleLib.SendAddonMessage then
        ChatThrottleLib:SendAddonMessage("BULK", PREFIX, msg, channel, target)
    elseif C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, msg, channel, target)
    elseif SendAddonMessage then
        SendAddonMessage(PREFIX, msg, channel, target)
    end
    S.stats.sent = S.stats.sent + 1
end

local function Queue(msg, channel, target, urgent)
    if ChatThrottleLib and CanSend() then return RawSend(msg, channel, target) end
    if urgent then
        table.insert(outbox, 1, { msg, channel, target })
    else
        outbox[#outbox + 1] = { msg, channel, target }
    end
end

local function Channels()
    local list = {}
    if IsInGuild and IsInGuild() then list[#list + 1] = "GUILD" end
    if ns.InRaid() then
        list[#list + 1] = "RAID"
    elseif ns.InGroup() then
        list[#list + 1] = "PARTY"
    end
    return list
end

function S.Advertise()
    if not Enabled() or not CanSend() then return end
    local msg = "V:" .. ns.db.meta.uid .. ":" .. ns.db.meta.rev
    -- date of the shipped community data, so guild members learn when a newer release exists
    -- (older versions ignore this message type)
    local gen = ns.CommunityInfo()
    for _, ch in ipairs(Channels()) do
        Queue(msg, ch, nil, true)
        if gen then Queue("G:" .. gen, ch, nil, true) end
    end
end

-- A guild member has community data at least a day newer than ours: say so once per session.
local newerNoted = false
function S.OnCommunityDate(gen)
    local own = ns.CommunityInfo() or 0
    if newerNoted or not gen or gen < own + 86400 then return end
    newerNoted = true
    ns.Print(
        string.format(
            L["A guild member has newer community data (%s). Update WorldCodex to get it."],
            ns.date("%Y-%m-%d", gen)
        )
    )
end

function S.SendSnapshot(channel, target)
    -- prices only for items WorldCodex tracks: after a full auction house scan, thousands of prices
    -- made every answer a large string that froze sender and receiver
    local payload = ns.Codec.Encode(ns.Store.Snapshot({ minN = 3, ah = true, ahRelevant = true, cells = 8 }))
    payload = payload:sub(6) -- drop "WCX1:" prefix, the receiver re-adds it
    xferSeq = xferSeq + 1
    local id = string.format("%x%x", math.floor(GetTime()) % 4096, xferSeq % 256)
    local n = math.ceil(#payload / CHUNK)
    for i = 1, n do
        Queue("D:" .. id .. ":" .. i .. ":" .. n .. ":" .. payload:sub((i - 1) * CHUNK + 1, i * CHUNK), channel, target)
    end
    ns.Debug("sync: sending", n, "chunks via", channel, target or "")
end

local function HandleData(sender, id, i, n, data)
    local key = sender .. "|" .. id
    local x = incoming[key]
    if not x then
        if n > 2000 then return end
        x = { parts = {}, got = 0, n = n, t = GetTime() }
        incoming[key] = x
    end
    if x.n ~= n or x.parts[i] then return end
    x.parts[i] = data
    x.got = x.got + 1
    x.t = GetTime()
    if x.got < x.n then return end
    incoming[key] = nil
    local snap, err = ns.Codec.Decode("WCX1:" .. table.concat(x.parts))
    if not snap then
        ns.Debug("sync: bad data from", sender, err)
        return
    end
    local ok, why = ns.Store.ImportPeer(sender, snap, sender)
    if ok then
        S.stats.imported = S.stats.imported + 1
        ns.Debug("sync: imported data from", sender)
    else
        ns.Debug("sync: rejected data from", sender, why)
    end
end

function S.OnMessage(prefix, msg, channel, sender)
    prefix, msg, channel, sender = ns.Plain(prefix), ns.Plain(msg), ns.Plain(channel), ns.Plain(sender)
    if prefix ~= PREFIX or not Enabled() or type(msg) ~= "string" then return end
    if SameName(sender, Me()) then return end
    S.stats.received = S.stats.received + 1
    local kind = msg:sub(1, 1)
    if kind == "V" then
        local uid, rev = msg:match("^V:([%w]+):(%d+)$")
        rev = tonumber(rev)
        if not uid or not rev then return end
        local peer = ns.db.peers[sender]
        local now = GetTime()
        if (not peer or (peer.rev or -1) < rev) and (not asked[sender] or now - asked[sender] > REQUEST_COOLDOWN) then
            asked[sender] = now
            Queue("Q:" .. uid, "WHISPER", sender, true)
        end
    elseif kind == "Q" then
        local uid = msg:match("^Q:([%w]+)$")
        if uid ~= ns.db.meta.uid then return end
        local now = GetTime()
        if answered[sender] and now - answered[sender] < ANSWER_COOLDOWN then return end
        answered[sender] = now
        requests[#requests + 1] = { sender = sender, channel = channel, t = now }
    elseif kind == "G" then
        S.OnCommunityDate(tonumber(msg:match("^G:(%d+)$")))
    elseif kind == "D" then
        local id, i, n, data = msg:match("^D:(%w+):(%d+):(%d+):(.*)$")
        if id then HandleData(sender, id, tonumber(i), tonumber(n), data) end
    end
end

-- Several requests within a few seconds are answered with one broadcast instead of many whispers.
local function FlushRequests()
    if #requests == 0 or not CanSend() then return end
    if GetTime() - requests[1].t < 5 then return end
    local list = requests
    requests = {}
    if #list >= 2 and IsInGuild and IsInGuild() then
        S.SendSnapshot("GUILD")
    else
        for _, r in ipairs(list) do
            S.SendSnapshot("WHISPER", r.sender)
        end
    end
end

ns.OnUpdate(function(_, now)
    if #outbox > 0 and now - lastSend >= SEND_INTERVAL and CanSend() then
        lastSend = now
        local m = table.remove(outbox, 1)
        RawSend(m[1], m[2], m[3])
    end
end)

function S.Status()
    local peers = 0
    for _ in pairs(ns.db.peers) do
        peers = peers + 1
    end
    return string.format(
        L["sync %s | peers: %d | sent %d, received %d messages, imported %d snapshots | outbox %d"],
        Enabled() and "on" or "off",
        peers,
        S.stats.sent,
        S.stats.received,
        S.stats.imported,
        #outbox
    )
end

function S.Now()
    asked = {}
    S.Advertise()
end

ns.On("DB_READY", function()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    elseif RegisterAddonMessagePrefix then
        RegisterAddonMessagePrefix(PREFIX)
    end
    ns.RegisterEvent("CHAT_MSG_ADDON", S.OnMessage)
    ns.RegisterEvent("PLAYER_ENTERING_WORLD", function() ns.After(20, S.Advertise) end)
    local pending = false
    ns.RegisterEvent("GROUP_ROSTER_UPDATE", function()
        if pending then return end
        pending = true
        ns.After(5, function()
            pending = false
            S.Advertise()
        end)
    end)
    ns.Every(ADVERTISE_EVERY, S.Advertise)
    ns.Every(1, FlushRequests)
    ns.Every(60, function()
        local now = GetTime()
        for k, x in pairs(incoming) do
            if now - x.t > 300 then incoming[k] = nil end
        end
    end)
end)

return S
