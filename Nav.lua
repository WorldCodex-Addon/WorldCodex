local _, ns = ...

-- Ranking of sources per item, spawn hotspots and waypoints.
local N = {}
ns.Nav = N

local L = ns.L
local Store = ns.Store

-- Rough attempts per hour when the player has no own pace data for a source yet.
N.DEFAULT_PACE = {
    mob = 60,
    herb = 20,
    mine = 20,
    skin = 60,
    fish = 90,
    pickpocket = 60,
    lockpick = 15,
    object = 10,
    container = 300,
    disenchant = 300,
    mill = 300,
    prospect = 300,
    salvage = 120,
    quest = 4,
    other = 30,
}

function N.Pace(key, kind)
    local rec = ns.db.sources[key]
    if rec and (rec.pk or 0) >= 5 and (rec.ps or 0) > 0 then return rec.pk / rec.ps * 3600, true end
    return N.DEFAULT_PACE[kind or (rec and rec.kind) or "other"] or 30, false
end

-- Returns array of candidate sources for an item, sorted by expected minutes per drop.
function N.Rank(itemId)
    local out = {}
    for key in pairs(Store.SourcesForItem(itemId)) do
        local d, n, q, parts = Store.Combined(key, itemId)
        if n > 0 and d > 0 then
            local name, kind = Store.SourceMeta(key)
            local lo, hi = ns.Stats.Wilson(d, n)
            local pace, measured = N.Pace(key, kind)
            local e = {
                key = key,
                name = name,
                kind = kind,
                d = d,
                n = n,
                q = q,
                parts = parts,
                rate = d / n,
                lo = lo,
                hi = hi,
                avgQty = q / d,
                pace = pace,
                paceMeasured = measured,
                minutes = ns.Stats.MinutesPerDrop(lo, pace),
                attempts = math.ceil(1 / (d / n)),
            }
            if kind == "quest" then
                -- Quest rewards are fixed, so the observed rate is used as is. A one-time quest the
                -- player already finished stays listed but is never suggested.
                local questId = ns.Quests.IdFromKey(key)
                e.choice = ns.Quests.IsChoice(key, itemId)
                e.rep = ns.Quests.RepeatType(key)
                e.done = not e.rep and questId and ns.Quests.IsCompleted(questId) or false
                e.minutes = e.done and math.huge or ns.Stats.MinutesPerDrop(e.rate, pace)
            end
            out[#out + 1] = e
        end
    end
    table.sort(out, function(a, b)
        if a.minutes ~= b.minutes then return a.minutes < b.minutes end
        return a.rate > b.rate
    end)
    return out
end

-- Fastest and highest-rate source; finished one-time quests are never suggested.
function N.Best(itemId)
    local list = N.Rank(itemId)
    local fastest, highest
    for _, e in ipairs(list) do
        if not e.done then
            fastest = fastest or e
            if not highest or e.rate > highest.rate then highest = e end
        end
    end
    return fastest, highest, list
end

-- Display name of a ranked source, e.g. "Quest: The Defias (choice, done)".
function N.Label(e)
    local name = tostring(e.name)
    if e.kind ~= "quest" then return name end
    local tags = {}
    if e.choice then tags[#tags + 1] = L["choice"] end
    if e.rep then tags[#tags + 1] = L[e.rep] end
    if e.done then tags[#tags + 1] = L["done"] end
    name = L["Quest"] .. ": " .. name
    if #tags > 0 then name = name .. " (" .. table.concat(tags, ", ") .. ")" end
    return name
end

-- ---------------------------------------------------------------- hotspots

local function Neighbors(cell)
    local cx, cy = math.floor(cell / 100), cell % 100
    local out = {}
    for dx = -1, 1 do
        for dy = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
                local nx, ny = cx + dx, cy + dy
                if nx >= 0 and nx < 100 and ny >= 0 and ny < 100 then out[#out + 1] = nx * 100 + ny end
            end
        end
    end
    return out
end

-- Connected groups of spawn cells (8-neighbourhood); returns { map, x, y, weight, cells }.
function N.Hotspots(key)
    local spots = {}
    for map, cells in pairs(Store.Spawns(key)) do
        local seen = {}
        for cell in pairs(cells) do
            if not seen[cell] then
                local stack, w, sx, sy, count = { cell }, 0, 0, 0, 0
                seen[cell] = true
                while #stack > 0 do
                    local c = table.remove(stack)
                    local n = cells[c]
                    local x, y = Store.CellXY(c)
                    w = w + n
                    sx, sy = sx + x * n, sy + y * n
                    count = count + 1
                    for _, nb in ipairs(Neighbors(c)) do
                        if cells[nb] and not seen[nb] then
                            seen[nb] = true
                            stack[#stack + 1] = nb
                        end
                    end
                end
                if w > 0 then spots[#spots + 1] = { map = map, x = sx / w, y = sy / w, weight = w, cells = count } end
            end
        end
    end
    table.sort(spots, function(a, b) return a.weight > b.weight end)
    return spots
end

local function Vec(x, y)
    if CreateVector2D then return CreateVector2D(x, y) end
    return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
end

-- Converts a position on one map into coordinates on another map of the same continent.
function N.Convert(map, x, y, toMap)
    if map == toMap then return x, y end
    if not (C_Map and C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos) then return nil end
    local ok, cont, world = pcall(C_Map.GetWorldPosFromMapPos, map, Vec(x, y))
    if not ok or not cont or not world then return nil end
    local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, world, toMap)
    if not ok2 or not pos then return nil end
    local tx, ty = pos:GetXY()
    if not tx or tx < -0.5 or tx > 1.5 or ty < -0.5 or ty > 1.5 then return nil end
    return tx, ty
end

local sizeCache = {}
function N.MapSize(map)
    if sizeCache[map] ~= nil then return sizeCache[map] or nil end
    local w, h
    if C_Map and C_Map.GetWorldPosFromMapPos then
        local ok1, _, a = pcall(C_Map.GetWorldPosFromMapPos, map, Vec(0, 0))
        local ok2, _, b = pcall(C_Map.GetWorldPosFromMapPos, map, Vec(1, 1))
        if ok1 and ok2 and a and b then
            local ax, ay = a:GetXY()
            local bx, by = b:GetXY()
            -- world positions are (north, west) ordered; map width spans the second axis
            w, h = math.abs(ay - by), math.abs(ax - bx)
        end
    end
    sizeCache[map] = (w and w > 0) and { w, h } or false
    return sizeCache[map] or nil
end

-- Distance (yards, may be nil) and absolute bearing (radians, 0 = north, counter-clockwise).
function N.Relative(target)
    local pm, px, py = ns.PlayerLocation()
    if not pm or not px then return nil end
    local tx, ty = N.Convert(target.map, target.x, target.y, pm)
    if not tx then return nil, nil, "zone" end
    local size = N.MapSize(pm)
    local sw, sh = size and size[1] or 1, size and size[2] or 1
    local dx, dy = (tx - px) * sw, (ty - py) * sh
    local dist = size and math.sqrt(dx * dx + dy * dy) or nil
    local bearing = math.atan2(-dx, -dy)
    return dist, bearing
end

function N.PickHotspot(key)
    local spots = N.Hotspots(key)
    if #spots == 0 then return nil end
    local pm, px, py = ns.PlayerLocation()
    local best, bestScore
    for _, s in ipairs(spots) do
        local dist = 5000
        if pm and px then
            local tx, ty = N.Convert(s.map, s.x, s.y, pm)
            if tx then
                local size = N.MapSize(pm)
                local sw, sh = size and size[1] or 1000, size and size[2] or 1000
                dist = math.sqrt(((tx - px) * sw) ^ 2 + ((ty - py) * sh) ^ 2)
            end
        end
        local score = s.weight / (1 + dist / 500)
        if not bestScore or score > bestScore then
            best, bestScore = s, score
        end
    end
    return best, spots
end

-- ---------------------------------------------------------------- waypoints

N.active = nil

function N.ClearWaypoint(silent)
    if N.tomtomUid and TomTom and TomTom.RemoveWaypoint then pcall(TomTom.RemoveWaypoint, TomTom, N.tomtomUid) end
    N.tomtomUid = nil
    N.active = nil
    ns.Fire("WAYPOINT", nil)
    if not silent then ns.Print(L["navigation cleared"]) end
end

function N.SetWaypoint(map, x, y, title, key, itemId)
    N.ClearWaypoint(true)
    N.active = { map = map, x = x, y = y, title = title, key = key, itemId = itemId, t = ns.time() }
    local used
    if TomTom and TomTom.AddWaypoint then
        local ok, uid = pcall(
            TomTom.AddWaypoint,
            TomTom,
            map,
            x,
            y,
            { title = title, persistent = false, minimap = true, world = true }
        )
        if ok then
            N.tomtomUid = uid
            used = "TomTom"
        end
    end
    if
        not used
        and not ns.InCombat()
        and C_Map
        and C_Map.SetUserWaypoint
        and UiMapPoint
        and UiMapPoint.CreateFromCoordinates
    then
        local ok = pcall(function()
            if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(map) then error("not allowed") end
            C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(map, x, y))
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            end
        end)
        if ok then used = "map pin" end
    end
    ns.Fire("WAYPOINT", N.active)
    return used or "arrow"
end

local function FindItem(query)
    local id = tonumber(query) or ns.ItemIdFromLink(query)
    if id then return id end
    local q = query:lower()
    if q == "" then return nil end
    local candidates = {}
    for itemId in pairs(ns.db.items) do
        candidates[itemId] = true
    end
    for itemId in pairs(ns.db.farm.goals) do
        candidates[itemId] = true
    end
    for itemId in pairs(ns.db.ah) do
        candidates[itemId] = true
    end
    local partial
    for itemId in pairs(candidates) do
        local it = ns.db.items[itemId]
        local name = ((it and it.n) or ns.ItemName(itemId)):lower()
        if name == q then return itemId end
        if (not partial or itemId < partial) and name:find(q, 1, true) then partial = itemId end
    end
    return partial
end
N.FindItem = FindItem

function N.GotoSource(key, itemId)
    local name = Store.SourceMeta(key)
    local spot = N.PickHotspot(key)
    if not spot then
        ns.Print(string.format(L["no location recorded for %s yet"], tostring(name)))
        return false
    end
    local title = itemId and string.format("%s (%s)", name, ns.ItemName(itemId)) or name
    local how = N.SetWaypoint(spot.map, spot.x, spot.y, title, key, itemId)
    ns.Print(
        string.format(
            L["navigating to %s in %s (%.1f, %.1f) via %s"],
            tostring(name),
            ns.MapName(spot.map),
            spot.x * 100,
            spot.y * 100,
            how
        )
    )
    local kpi = ns.db.kpi
    kpi.gotoIssued = (kpi.gotoIssued or 0) + 1
    ns.Fire("GOTO", key, itemId)
    return true
end

function N.Goto(query)
    query = ns.Trim(query)
    if query == "" or query == "stop" or query == "clear" then
        N.ClearWaypoint()
        return
    end
    local itemId = FindItem(query)
    if itemId then
        local fastest = N.Best(itemId)
        if not fastest then
            ns.Print(string.format(L["no known source for %s"], ns.ItemName(itemId, true)))
            return
        end
        for _, e in ipairs(N.Rank(itemId)) do
            if not e.done and next(Store.Spawns(e.key)) then return N.GotoSource(e.key, itemId) end
        end
        ns.Print(string.format(L["no location recorded for any source of %s yet"], ns.ItemName(itemId, true)))
        return
    end
    local key = ns.Report and ns.Report.FindSource(query)
    if key then return N.GotoSource(key) end
    ns.Print(string.format(L["nothing found for '%s'"], query))
end

ns.On("KILL", function(key)
    local a = N.active
    if a and a.key == key and not a.hit and ns.time() - a.t <= 600 then
        a.hit = true
        ns.db.kpi.gotoHits = (ns.db.kpi.gotoHits or 0) + 1
    end
end)

return N
