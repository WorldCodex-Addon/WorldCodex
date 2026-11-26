local _, ns = ...

local L = ns.L

local HELP = {
    "/worldcodex - open the WorldCodex window (items, sources, AH, farming, KPIs)",
    "/worldcodex welcome - how to use WorldCodex",
    "/worldcodex item <name|id|link> - open the item page (sources, rates, prices) | print <item> - same in chat",
    "/worldcodex mob <name|id> - open the page of a mob or other source | target - page of your target",
    "/worldcodex compare - where your drop rates differ from everyone else's",
    "/worldcodex goto <item|source> - navigate to the best farming spot | /worldcodex goto stop",
    "/worldcodex goal <item> <count> - set a farming goal | /worldcodex goal clear [item]",
    "/worldcodex session [end] - current farming session",
    "/worldcodex ah [all|scan|stop|auto on|off|<item>] - auction house scanning",
    "/worldcodex sync [on|off|now] - guild/group sharing status",
    "/worldcodex export [string|lua|json|csv [drops|quests|items|prices|history|vendors|recipes|npcs]] | import",
    "/worldcodex report | top [n] | kinds | status | kpi",
    "/worldcodex options | prune | diag [clear|loot|perf|item <id>] | clear confirm",
}

local function ItemAndCount(rest)
    local count = tonumber(rest:match("(%d+)%s*$"))
    local query = count and rest:gsub("%s*%d+%s*$", "") or rest
    return ns.Nav.FindItem(ns.Trim(query)), count
end

local function AH(rest)
    local db = ns.db
    local low = rest:lower()
    if low == "all" then
        local n = ns.AH.QueueStale(true)
        ns.Print(
            string.format(L["queued %d items for AH scan"], n)
                .. (ns.AH.open and "" or (" - " .. L["open the auction house"]))
        )
    elseif low == "scan" or low == "full" then
        ns.AH.FullScan()
    elseif low == "stop" then
        ns.AH.Stop()
        ns.Print(L["AH scan stopped"])
    elseif low == "auto on" or low == "auto off" then
        db.settings.autoScanAH = low == "auto on"
        ns.Print(L["auto scan on AH open"] .. ": " .. (db.settings.autoScanAH and "on" or "off"))
    elseif rest ~= "" then
        local id = ns.Nav.FindItem(rest)
        if id then
            ns.AH.Queue(id, true)
            ns.Print(string.format(L["queued %s for AH scan"], ns.ItemName(id, true)))
        else
            ns.Print(string.format(L["nothing found for '%s'"], rest))
        end
    else
        ns.Print(ns.AH.Status())
    end
end

-- Last loot windows: where they were, how many slots, which sources got the items.
local function DiagLoot()
    local log = ns.Collector.LootLog()
    if #log == 0 then
        ns.Print("no loot windows recorded since login")
        return
    end
    for _, e in ipairs(log) do
        local where = " map=" .. tostring(e.map) .. (e.pos and "" or " (no position)")
        if e.zone then where = where .. " zone=" .. e.zone end
        ns.Print(
            string.format(
                "%s slots=%d%s%s%s%s%s -> %s%s",
                ns.date("%H:%M:%S", e.t),
                e.slots,
                e.instance and (" instance=" .. tostring(e.instance)) or "",
                where,
                e.grouped and " group" or "",
                e.combat and " combat" or "",
                e.noSource and " no-source-guid" or "",
                #e.keys > 0 and table.concat(e.keys, ", ") or ("nothing recorded (dupes=" .. e.dupes .. ")"),
                e.needed
                        and string.format(
                            " | quest needs: %s; quest items: %s",
                            table.concat(e.needed, ", "),
                            e.quest or "-"
                        )
                    or ""
            )
        )
    end
end

-- Slow WorldCodex calls and long frames with WorldCodex's share of them (Core.lua watchdog).
local function DiagPerf()
    local slow = ns.slow
    if #slow.calls == 0 and #slow.frames == 0 and not next(ns.errors) then
        ns.Print("no slow calls, long frames or errors recorded since login")
    end
    if #slow.frames > 0 then
        ns.Print("long frames (game frozen for >= 250 ms) and how much of it was WorldCodex:")
        for _, e in ipairs(slow.frames) do
            ns.Print(
                string.format(
                    "  %s  frame %d ms, WorldCodex %d ms%s",
                    ns.date("%H:%M:%S", e.t),
                    e.ms,
                    e.mine,
                    e.top and string.format(" (largest: %s, %d ms)", e.top, e.topMs) or ""
                )
            )
        end
    end
    if #slow.calls > 0 then
        ns.Print("WorldCodex calls of 50 ms or more:")
        for _, e in ipairs(slow.calls) do
            ns.Print(string.format("  %s  %d ms  %s", ns.date("%H:%M:%S", e.t), e.ms, e.what))
        end
    end
    local states = {}
    for _, kind in ipairs({ "Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map", "Chat" }) do
        local r = ns.Restricted(kind)
        if r ~= nil then states[#states + 1] = kind .. "=" .. (r and "on" or "off") end
    end
    if #states > 0 then ns.Print("client restrictions: " .. table.concat(states, ", ")) end
    local counts = {}
    for what, n in pairs(ns.counts) do
        counts[#counts + 1] = string.format("%s: %s", what, tostring(n))
    end
    if #counts > 0 then
        table.sort(counts)
        ns.Print("counters: " .. table.concat(counts, " | "))
    end
    local hidden = {}
    for what, n in pairs(ns.secrets) do
        hidden[#hidden + 1] = string.format("%s %dx", what, n)
    end
    if #hidden > 0 then
        table.sort(hidden)
        ns.Print("values the client hid (secret): " .. table.concat(hidden, ", "))
    end
    local errs = {}
    for msg, e in pairs(ns.errors) do
        errs[#errs + 1] = { msg = msg, n = e.n, where = e.where }
    end
    if #errs > 0 then
        table.sort(errs, function(a, b) return a.n > b.n end)
        ns.Print("WorldCodex Lua errors (passed to the error handler at most once a minute each):")
        for i = 1, math.min(10, #errs) do
            local e = errs[i]
            ns.Print(string.format("  %dx  %s  (while: %s)", e.n, e.msg:sub(1, 160), tostring(e.where)))
        end
    end
    local update = (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage) or UpdateAddOnMemoryUsage
    local get = (C_AddOns and C_AddOns.GetAddOnMemoryUsage) or GetAddOnMemoryUsage
    if update and get then
        pcall(update)
        local ok, kb = pcall(get, "WorldCodex")
        if ok and kb then ns.Print(string.format("WorldCodex memory: %.1f MB", kb / 1024)) end
    end
    -- which Blizzard art the window could use (journal / quest / inset), once the window was opened
    local W = ns.Widgets
    if W then
        local chrome = ns.Page and ns.Page._State().chrome
        ns.Print(string.format("UI: window %s, pages %s", tostring(chrome or "-"), tostring(W.pageStyle or "-")))
    end
end

local function Diag(arg)
    if arg == "loot" then return DiagLoot() end
    if arg == "perf" then return DiagPerf() end
    local itemArg = arg and arg:match("^item%s*(.*)$")
    if itemArg then
        for _, line in ipairs(ns.Items.Diagnose(ns.ItemIdFromLink(itemArg) or tonumber(itemArg))) do
            ns.Print(line)
        end
        return
    end
    if arg == "clear" then
        ns.db.diag = nil
        for i = #ns.blocked, 1, -1 do
            ns.blocked[i] = nil
        end
        ns.Print("blocked-action log cleared")
        return
    end
    local list = ns.db.diag or ns.blocked
    if not list or #list == 0 then
        ns.Print("no blocked actions recorded")
        return
    end
    for _, e in ipairs(list) do
        ns.Print(
            string.format(
                "%s %s %s() while: %s%s",
                ns.date("%Y-%m-%d %H:%M:%S", e.t),
                e.event,
                e.func,
                e.context or "?",
                e.combat and " (in combat)" or ""
            )
        )
        if e.stack and e.stack ~= "" then ns.Print(e.stack) end
    end
end

-- Item / source pages need the UI files; without them the commands print to chat instead.
local function OpenItem(query)
    if not ns.Page or query == "" then return false end
    local id = ns.Nav.FindItem(query)
    if not id then
        local hit = ns.Lookup.Search(query, 1)[1]
        id = hit and hit.type == "item" and hit.id or nil
    end
    if not id then return false end
    return ns.Page.Show({ type = "item", id = id })
end

local function OpenSource(query)
    if not ns.Page or query == "" then return false end
    local key = ns.Report.FindSource(query)
    if key == nil then return false end
    return ns.Page.Show({ type = "source", id = key })
end

local function Slash(msg)
    if not ns.db then return end
    ns.context = "slash /worldcodex " .. tostring(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    rest = ns.Trim(rest)
    if cmd == "" or cmd == "show" then
        ns.Browser.Toggle()
    elseif cmd == "item" or cmd == "i" then
        if not OpenItem(rest) then ns.Report.PrintItem(rest) end
    elseif cmd == "print" then
        ns.Report.PrintItem(rest)
    elseif cmd == "mob" or cmd == "source" then
        if not OpenSource(rest) then ns.Report.PrintSource(rest) end
    elseif cmd == "target" then
        if ns.Page then ns.Page.OpenHovered() end
    elseif cmd == "compare" or cmd == "diff" then
        if ns.Page then
            ns.Page.Show({ type = "compare", id = "all" })
        else
            ns.Report.PrintDifferences()
        end
    elseif cmd == "goto" or cmd == "nav" then
        ns.Nav.Goto(rest)
    elseif cmd == "goal" then
        if rest:lower():match("^clear") then
            local q = ns.Trim(rest:sub(6))
            if q == "" then
                ns.Farm.ClearGoal(nil)
                ns.Print(L["all goals removed"])
            else
                local id = ns.Nav.FindItem(q)
                if not id or not ns.db.farm.goals[id] then
                    ns.Print(string.format(L["no goal found for '%s'"], q))
                else
                    ns.Farm.ClearGoal(id)
                    ns.Print(string.format(L["goal removed: %s"], ns.ItemName(id, true)))
                end
            end
        else
            local id, count = ItemAndCount(rest)
            if not id then
                ns.Print("usage: /worldcodex goal <item> <count>")
                return
            end
            ns.Farm.SetGoal(id, count or 20)
        end
    elseif cmd == "session" or cmd == "farm" then
        if rest == "end" then ns.Farm.End() end
        ns.Browser.Toggle("farming")
    elseif cmd == "ah" then
        AH(rest)
    elseif cmd == "sync" then
        local low = rest:lower()
        if low == "on" or low == "off" then ns.db.settings.sync = low == "on" end
        if low == "now" then ns.Sync.Now() end
        ns.Print(ns.Sync.Status())
    elseif cmd == "export" then
        local fmt, dataset = rest:lower():match("^(%S*)%s*(%S*)$")
        ns.UI.ShowExport(fmt ~= "" and fmt or "string", dataset ~= "" and dataset or nil)
    elseif cmd == "import" then
        ns.UI.ShowImport()
    elseif cmd == "report" then
        ns.UI.ShowReport()
    elseif cmd == "top" then
        ns.Report.PrintTop(tonumber(rest) or 20)
    elseif cmd == "kinds" then
        ns.Report.PrintKinds()
    elseif cmd == "status" then
        ns.Report.PrintStatus()
    elseif cmd == "kpi" then
        ns.UI.ShowKPI()
    elseif cmd == "welcome" or cmd == "guide" then
        ns.Welcome.Show()
    elseif cmd == "options" or cmd == "config" then
        ns.Options.Open()
    elseif cmd == "prune" then
        ns.Print(string.format(L["removed %d small, old sources"], ns.Store.Prune()))
    elseif cmd == "clear" then
        if rest == "confirm" then
            ns.Store.Wipe()
            ns.Print(L["all recorded data wiped"])
        else
            ns.Print(L["this deletes all recorded data - type /worldcodex clear confirm"])
        end
    elseif cmd == "diag" then
        Diag(rest:lower())
    elseif cmd == "help" then
        for _, line in ipairs(HELP) do
            ns.Print(line)
        end
    else
        ns.Print(string.format(L["unknown command '%s' - try /worldcodex help"], cmd))
    end
end
ns.Slash = Slash

SLASH_WORLDCODEX1 = "/worldcodex"
SLASH_WORLDCODEX2 = "/wcx"
SlashCmdList["WORLDCODEX"] = Slash

-- Public API for other addons and macros.
local API = ns.API
API.GetPrice = function(itemId) return ns.Prices.Get(itemId) end
API.RankSources = function(itemId) return ns.Nav.Rank(itemId) end
API.GetDropRate = function(sourceKey, itemId)
    local d, n = ns.Store.Combined(sourceKey, itemId)
    return n > 0 and d / n or nil, d, n
end
API.Goto = function(query) return ns.Nav.Goto(query) end

-- Copies, so callers can keep or change the result without touching the addon's data.
local function Copy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local c = {}
    seen[v] = c
    for k, x in pairs(v) do
        c[k] = Copy(x, seen)
    end
    return c
end

-- All sources of an item grouped into sections ("drop", "gather", "contained", "quest", "process").
-- layer: "all" (default), "mine" or "others".
API.GetItemSources = function(itemId, layer) return Copy(ns.Lookup.ItemModel(itemId, layer)) end
-- Drop table, coin and related sources of a mob / node / container / quest key.
API.GetSourceDrops = function(sourceKey, layer) return Copy(ns.Lookup.SourceModel(sourceKey, layer)) end
-- Personal numbers against everyone else's for (source, item).
API.Compare = function(sourceKey, itemId) return Copy(ns.Store.Compare(sourceKey, itemId)) end
-- Open pages (needs the UI; returns false without it).
API.OpenItem = function(itemId) return ns.Page and ns.Page.Show({ type = "item", id = itemId }) or false end
API.OpenSource = function(sourceKey) return ns.Page and ns.Page.Show({ type = "source", id = sourceKey }) or false end
API.OpenHovered = function() return ns.Page and ns.Page.OpenHovered() or false end
API.Print = ns.Print
