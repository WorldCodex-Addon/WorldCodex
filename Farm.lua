local _, ns = ...

-- Farming sessions, goals and bad-luck numbers.
local F = {}
ns.Farm = F

local L = ns.L
local IDLE = 900
local KEEP_SESSIONS = 30

local function DBF() return ns.db.farm end

local function NewSession(now)
    return {
        start = now,
        last = now,
        kills = 0,
        attempts = 0,
        drops = 0,
        value = 0,
        vendor = 0,
        money = 0,
        items = {},
        srcs = {},
        nav = nil,
    }
end

function F.End()
    local f = DBF()
    local s = f.cur
    f.cur = nil
    if s and s.last - s.start >= 60 then
        table.insert(f.hist, 1, s)
        while #f.hist > KEEP_SESSIONS do
            table.remove(f.hist)
        end
    end
end

function F.Current()
    local f = DBF()
    local s = f.cur
    if s and ns.time() - s.last > IDLE then
        F.End()
        s = nil
    end
    return s
end

local function Touch()
    local now = ns.time()
    local s = F.Current()
    if not s then
        s = NewSession(now)
        DBF().cur = s
        if ns.Nav and ns.Nav.active then s.nav = ns.Nav.active.itemId or true end
    end
    s.last = now
    return s
end

function F.Hours(s) return math.max(60, (s.last or 0) - (s.start or 0)) / 3600 end

function F.GoldPerHour(s) return (s.value + s.money) / F.Hours(s) end

ns.On("KILL", function(key)
    local s = Touch()
    s.kills = s.kills + 1
    s.srcs[key] = (s.srcs[key] or 0) + 1
end)

ns.On("ATTEMPT", function(key, rec)
    local s = Touch()
    s.attempts = s.attempts + 1
    if rec.kind ~= "mob" then s.srcs[key] = (s.srcs[key] or 0) + 1 end
end)

ns.On("LOOT", function(_, _, items)
    local s = Touch()
    for _ in pairs(items) do
        s.drops = s.drops + 1
    end
end)

ns.On("RECEIVED", function(itemId, qty)
    local s = Touch()
    s.items[itemId] = (s.items[itemId] or 0) + qty
    s.value = s.value + ns.Prices.UnitValue(itemId) * qty
    s.vendor = s.vendor + ns.Prices.Vendor(itemId) * qty
    F.CheckGoals()
end)

ns.On("MONEY", function(delta)
    local s = Touch()
    s.money = s.money + delta
end)

ns.On("GOTO", function(_, itemId)
    local s = F.Current()
    if s then s.nav = itemId or true end
end)

-- ---------------------------------------------------------------- goals

-- Items in bags and bank. The global GetItemCount does not exist on WoW Forever (in-game API dump).
local function Count(itemId)
    local get = (C_Item and C_Item.GetItemCount) or GetItemCount
    if not get then return 0 end
    local ok, n = pcall(get, itemId, true)
    return ok and tonumber(n) or 0
end

function F.SetGoal(itemId, target)
    DBF().goals[itemId] = { target = target, t = ns.time() }
    ns.Print(string.format(L["goal set: %d x %s (you have %d)"], target, ns.ItemName(itemId, true), Count(itemId)))
    ns.Fire("GOALS_CHANGED")
end

function F.ClearGoal(itemId)
    if itemId then
        DBF().goals[itemId] = nil
    else
        DBF().goals = {}
    end
    ns.Fire("GOALS_CHANGED")
end

-- Returns have, target, minutes-to-finish estimate (may be nil), best source entry.
function F.GoalProgress(itemId)
    local g = DBF().goals[itemId]
    if not g then return nil end
    local have = Count(itemId)
    local remaining = math.max(0, g.target - have)
    local best = ns.Nav.Best(itemId)
    local minutes
    if best and remaining > 0 then
        local perAttempt = best.rate * best.avgQty
        if perAttempt > 0 then minutes = remaining / perAttempt / best.pace * 60 end
    elseif remaining == 0 then
        minutes = 0
    end
    return have, g.target, minutes, best
end

function F.CheckGoals()
    for itemId, g in pairs(DBF().goals) do
        if not g.done and Count(itemId) >= g.target then
            g.done = ns.time()
            ns.Print(string.format(L["goal reached: %d x %s"], g.target, ns.ItemName(itemId, true)))
            if PlaySound then pcall(PlaySound, 8960) end
        end
    end
    ns.Fire("GOALS_CHANGED")
end

-- Current dry streak for an item at a source and the chance of a streak that long.
function F.BadLuck(key, itemId)
    local rec = ns.db.sources[key]
    if not rec then return nil end
    local streak = rec.streak[itemId] or 0
    local d, n = ns.Store.Combined(key, itemId)
    if n <= 0 or d <= 0 then return streak, nil end
    return streak, ns.Stats.PNoDrop(d / n, streak)
end

-- ---------------------------------------------------------------- text

local function SessionLine(s)
    local hours = F.Hours(s)
    return string.format(
        "%s  %s  kills %d (%.0f/h)  drops %d  value %s  coin %s  => %s/h%s",
        ns.date("%m-%d %H:%M", s.start),
        ns.Duration((s.last - s.start) / 60),
        s.kills,
        s.kills / hours,
        s.drops,
        ns.Coin(s.value),
        ns.Coin(s.money),
        ns.Coin(F.GoldPerHour(s)),
        s.nav and "  [goto]" or ""
    )
end

function F.ReportText()
    local lines = {}
    local s = F.Current()
    lines[#lines + 1] = "|cffffd100" .. L["Current session"] .. "|r"
    if s then
        lines[#lines + 1] = SessionLine(s)
        local top = {}
        for id, q in pairs(s.items) do
            top[#top + 1] = { id = id, q = q, v = ns.Prices.UnitValue(id) * q }
        end
        table.sort(top, function(a, b) return a.v > b.v end)
        for i = 1, math.min(8, #top) do
            lines[#lines + 1] =
                string.format("   %dx %s  %s", top[i].q, ns.ItemName(top[i].id, true), ns.Coin(top[i].v))
        end
    else
        lines[#lines + 1] = L["no active session - kill or gather something"]
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cffffd100" .. L["Goals"] .. "|r"
    local any = false
    for itemId in pairs(DBF().goals) do
        any = true
        local have, target, minutes, best = F.GoalProgress(itemId)
        lines[#lines + 1] = string.format(
            "   %s  %d/%d  ETA %s%s",
            ns.ItemName(itemId, true),
            have,
            target,
            minutes and ns.Duration(minutes) or "?",
            best and ("  @ " .. tostring(best.name)) or ""
        )
        if best then
            local streak, p = F.BadLuck(best.key, itemId)
            if streak and p and streak > 0 then
                lines[#lines + 1] = string.format("      dry streak %d - chance of that: %s", streak, ns.Pct(p))
            end
        end
    end
    if not any then
        lines[#lines + 1] = "   " .. L["no goals - /worldcodex goal <item> <count>"]
    else
        lines[#lines + 1] = "   |cff888888"
            .. L["remove: right-click the goal in the tracker, the Remove goal button, or /worldcodex goal clear <item>"]
            .. "|r"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cffffd100" .. L["Recent sessions"] .. "|r"
    for i, h in ipairs(DBF().hist) do
        if i > 15 then break end
        lines[#lines + 1] = SessionLine(h)
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------- farming page

local function ItemIcon(id)
    local icon = ns.ItemIcon(id)
    return icon and ("|T" .. icon .. ":16:16:0:0|t ") or ""
end

-- The current session and the goals as facts for the farming page (UI/Details.lua): label/value rows
-- for the session, its most valuable loot and the goals as item entries.
function F.Facts()
    local sections = {}
    local s = F.Current()
    local rows = {}
    if s then
        local hours = F.Hours(s)
        rows[#rows + 1] = { label = L["Started"], value = ns.date("%H:%M", s.start) }
        rows[#rows + 1] = { label = L["Duration"], value = ns.Duration((s.last - s.start) / 60) }
        rows[#rows + 1] = { label = L["Kills"], value = string.format("%d  (%.0f/h)", s.kills, s.kills / hours) }
        rows[#rows + 1] = { label = L["Drops"], value = tostring(s.drops) }
        rows[#rows + 1] = { label = L["Item value"], value = ns.Coin(s.value) }
        rows[#rows + 1] = { label = L["Coin"], value = ns.Coin(s.money) }
        rows[#rows + 1] = { label = L["Per hour"], value = ns.Coin(F.GoldPerHour(s)) }
    else
        rows[#rows + 1] = { note = L["no active session - kill or gather something"] }
    end
    sections[#sections + 1] = { title = L["Current session"], rows = rows }

    if s then
        local top = {}
        for id, q in pairs(s.items) do
            top[#top + 1] = { id = id, q = q, v = ns.Prices.UnitValue(id) * q }
        end
        table.sort(top, function(a, b)
            if a.v ~= b.v then return a.v > b.v end
            return a.id < b.id
        end)
        local loot = {}
        for i = 1, math.min(8, #top) do
            local e = top[i]
            loot[i] = {
                entry = true,
                itemId = e.id,
                name = ItemIcon(e.id) .. e.q .. "x " .. ns.ItemName(e.id, true),
                value = ns.Coin(e.v),
            }
        end
        if #loot > 0 then sections[#sections + 1] = { title = L["Most valuable loot"], rows = loot } end
    end

    local ids = {}
    for itemId in pairs(DBF().goals) do
        ids[#ids + 1] = itemId
    end
    table.sort(ids)
    local goals = {}
    for _, itemId in ipairs(ids) do
        local have, target, minutes, best = F.GoalProgress(itemId)
        local sub = { L["Time left"] .. ": " .. (minutes and ns.Duration(minutes) or "?") }
        if best then
            sub[#sub + 1] = string.format(L["at %s"], tostring(best.name))
            local streak, p = F.BadLuck(best.key, itemId)
            if streak and p and streak > 0 then
                sub[#sub + 1] = string.format(L["dry streak %d (chance: %s)"], streak, ns.Pct(p))
            end
        end
        goals[#goals + 1] = {
            entry = true,
            itemId = itemId,
            name = ItemIcon(itemId) .. ns.ItemName(itemId, true),
            value = string.format("%d/%d", have or 0, target or 0),
            sub = table.concat(sub, " · "),
        }
    end
    if #goals == 0 then
        goals[1] = { note = L["no goals - /worldcodex goal <item> <count>"] }
    else
        goals[#goals + 1] = {
            note = L["remove: right-click the goal in the tracker, the Remove goal button, or /worldcodex goal clear <item>"],
        }
    end
    sections[#sections + 1] = { title = L["Goals"], rows = goals }
    return { sections = sections }
end

-- Finished sessions, newest first.
function F.History() return DBF().hist end

ns.On("DB_READY", function()
    ns.RegisterEvent("BAG_UPDATE_DELAYED", F.CheckGoals)
    ns.RegisterEvent("PLAYER_LOGOUT", function()
        local s = F.Current()
        if s then s.last = ns.time() end
    end)
end)

return F
