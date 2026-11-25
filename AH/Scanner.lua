local _, ns = ...

-- Scan queue on top of the auction house adapter. The adapter calls A.ItemDone(itemId, listings)
-- and A.FullDone(map) (itemId -> price levels { [unit price] = quantity }) when results are complete.
local A = { adapters = {}, queue = {}, queued = {}, open = false, scanned = 0 }
ns.AH = A

local L = ns.L
local MAX_QUEUE = 600
local ITEM_TIMEOUT = 10
local STALE_SECONDS = 3600
local AUTO_FULL_SCAN_AFTER = 3600
local COMMIT_PER_FRAME = 400 -- at most, and only while within the frame budget
local COMMIT_BUDGET_MS = 5
local MAX_FAILS = 5
local PASSIVE_COOLDOWN = 60

local commitQueue
local passiveAt = {}

A.stats = { searches = 0, done = 0, partial = 0, timeouts = 0, errors = 0, passive = 0, fails = 0, lastError = nil }

function A.Pick()
    local m = A.adapters.modern
    if m and m.Available() then return m end
    return nil
end

function A.Queue(itemId, front)
    if type(itemId) ~= "number" or A.queued[itemId] or #A.queue >= MAX_QUEUE then return false end
    A.queued[itemId] = true
    if front then
        table.insert(A.queue, 1, itemId)
    else
        A.queue[#A.queue + 1] = itemId
    end
    return true
end

function A.QueueStale(force)
    local db = ns.db
    local now = ns.time()
    local list = {}
    local wanted = {}
    for id, it in pairs(db.items) do
        if it.src and next(it.src) then wanted[id] = true end
    end
    for id in pairs(db.farm.goals) do
        wanted[id] = true
    end
    for id in pairs(wanted) do
        local r = db.ah[id]
        local t = r and r.last and r.last.t or 0
        if force or now - t > STALE_SECONDS then list[#list + 1] = { id = id, t = t } end
    end
    table.sort(list, function(a, b) return a.t < b.t end)
    local n = 0
    for _, e in ipairs(list) do
        if A.Queue(e.id) then n = n + 1 end
    end
    return n
end

function A.Stop()
    A.queue, A.queued = {}, {}
    A.busy = nil
    commitQueue = nil
    if A.adapter and A.adapter.Reset then A.adapter.Reset() end
end

function A.ItemDone(itemId, listings)
    ns.Prices.Commit(itemId, listings or {})
    A.scanned = A.scanned + 1
    A.stats.done = A.stats.done + 1
    A.stats.fails = 0
    if A.busy and A.busy.id == itemId then A.busy = nil end
    ns.Fire("PRICES_UPDATED", itemId)
end

-- Results of searches the player runs in the auction house window are recorded at most once a minute.
function A.PassiveWanted(itemId)
    local at = passiveAt[itemId]
    return not (at and GetTime() - at < PASSIVE_COOLDOWN)
end

function A.Passive(itemId, listings)
    if not A.PassiveWanted(itemId) then return end
    passiveAt[itemId] = GetTime()
    ns.Prices.Commit(itemId, listings or {})
    A.stats.passive = A.stats.passive + 1
    ns.Fire("PRICES_UPDATED", itemId)
end

-- map: itemId -> price levels. Committed a few milliseconds per frame to avoid hitches.
function A.FullDone(map)
    commitQueue = { ids = {}, map = map, i = 1 }
    for id in pairs(map) do
        commitQueue.ids[#commitQueue.ids + 1] = id
    end
    ns.db.meta.lastFullScan = ns.time()
    ns.Print(string.format(L["AH full scan: %d items received, saving..."], #commitQueue.ids))
end

function A.FullScan()
    if not A.open then
        ns.Print(L["open the auction house first"])
        return false
    end
    if not A.adapter or not A.adapter.FullScan then
        ns.Print(L["full scan is not supported on this client"])
        return false
    end
    if A.adapter.Busy() then
        ns.Print(L["a scan is already running"])
        return false
    end
    A.busy = nil
    return A.adapter.FullScan()
end

local function StartSearch(id, now)
    A.stats.searches = A.stats.searches + 1
    local ok, why = A.adapter.SearchItem(id)
    if ok then
        A.busy = { id = id, t = now }
        return true
    end
    A.stats.errors = A.stats.errors + 1
    A.stats.fails = A.stats.fails + 1
    A.stats.lastError = why
    ns.Debug("AH search failed for", id, why)
    return false
end

-- Searches right away when possible (e.g. from a button click), otherwise puts the item first in line.
function A.SearchNow(itemId)
    if not A.open or not A.adapter then
        A.Queue(itemId, true)
        ns.Print(L["queued - open the auction house to scan"])
        return false
    end
    if not A.adapter.Busy() and A.adapter.CanQuery() then
        A.queued[itemId] = nil
        if StartSearch(itemId, GetTime()) then
            ns.Print(string.format(L["searching the auction house for %s..."], ns.ItemName(itemId, true)))
            return true
        end
        ns.Print(string.format(L["AH search failed: %s"], tostring(A.stats.lastError)))
        return false
    end
    A.Queue(itemId, true)
    ns.Print(string.format(L["%s queued - the auction house is busy"], ns.ItemName(itemId, true)))
    return false
end

function A.Status()
    local count, lastT = 0, 0
    for _, r in pairs(ns.db.ah) do
        count = count + 1
        if r.last and r.last.t and r.last.t > lastT then lastT = r.last.t end
    end
    local s = A.stats
    local full = ns.db.meta.lastFullScan
    return string.format(
        L["AH prices for %d items | last price: %s | last full scan: %s | queue: %d | adapter: %s"],
        count,
        lastT > 0 and ns.date("%Y-%m-%d %H:%M", lastT) or "never",
        full and ns.date("%Y-%m-%d %H:%M", full) or "never",
        #A.queue,
        A.adapter and A.adapter.name or (A.Pick() and A.Pick().name or "none")
    ) .. "\n" .. string.format(
        L["searches %d, answered %d (partial %d), timeouts %d, errors %d, from your own searches %d%s"],
        s.searches,
        s.done,
        s.partial,
        s.timeouts,
        s.errors,
        s.passive,
        s.lastError and (" | last error: " .. tostring(s.lastError)) or ""
    )
end

local function AutoScan()
    if not A.open or not A.adapter then return end
    local last = ns.db.meta.lastFullScan or 0
    if A.adapter.FullScan and ns.time() - last >= AUTO_FULL_SCAN_AFTER and not A.adapter.Busy() then
        A.FullScan()
    else
        local n = A.QueueStale(false)
        if n > 0 then ns.Print(string.format(L["queued %d items with old prices for AH scan"], n)) end
    end
end

ns.RegisterEvent("AUCTION_HOUSE_SHOW", function()
    A.open = true
    A.adapter = A.Pick()
    A.stats.fails = 0
    if not A.adapter then
        ns.Print(L["no supported auction house API found on this client"])
        return
    end
    if A.adapter.Reset then A.adapter.Reset() end
    if ns.db and ns.db.settings.autoScanAH then
        -- give the Blizzard auction UI a moment to send its own first query
        ns.After(1.5, AutoScan)
    end
end)

ns.RegisterEvent("AUCTION_HOUSE_CLOSED", function()
    A.open = false
    A.busy = nil
    if A.adapter and A.adapter.Reset then A.adapter.Reset() end
end)

local function OnTimeout()
    local id, list
    if A.adapter.Partial then
        id, list = A.adapter.Partial()
    end
    if A.adapter.Reset then A.adapter.Reset() end
    A.busy = nil
    if id and list and #list > 0 then
        A.stats.partial = A.stats.partial + 1
        A.ItemDone(id, list)
        return
    end
    A.stats.timeouts = A.stats.timeouts + 1
    A.stats.fails = A.stats.fails + 1
    A.stats.lastError = "no answer for item " .. tostring(id)
    ns.Debug("AH search timed out for", id)
end

ns.OnUpdate(function(_, now)
    if commitQueue then
        local q = commitQueue
        local clock = debugprofilestop
        local deadline = clock and clock() + COMMIT_BUDGET_MS
        local done = 0
        while q.i <= #q.ids do
            local id = q.ids[q.i]
            q.i = q.i + 1
            ns.Prices.Commit(id, nil, nil, nil, q.map[id])
            q.map[id] = nil -- freed as we go
            A.scanned = A.scanned + 1
            done = done + 1
            if done >= COMMIT_PER_FRAME or (deadline and clock() >= deadline) then break end
        end
        if q.i > #q.ids then
            commitQueue = nil
            ns.Print(L["AH full scan saved"])
            ns.Fire("PRICES_UPDATED")
        end
        return
    end
    if not A.open or not A.adapter then return end
    if A.adapter.Tick then A.adapter.Tick(now) end
    if A.adapter.Busy() then
        if A.busy and now - A.busy.t > ITEM_TIMEOUT then OnTimeout() end
        return
    end
    A.busy = nil
    if #A.queue == 0 or not A.adapter.CanQuery() then return end
    if A.stats.fails >= MAX_FAILS and A.stats.done == 0 then
        ns.Print(
            string.format(
                L["AH item searches are not answered (%s) - stopped the queue. Use /worldcodex ah scan for a full scan."],
                tostring(A.stats.lastError)
            )
        )
        A.queue, A.queued = {}, {}
        return
    end
    local id = table.remove(A.queue, 1)
    A.queued[id] = nil
    StartSearch(id, now)
end)

return A
