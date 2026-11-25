local _, ns = ...

-- Draws spawn cells on the world map: the source or item shown with "Show on map" (blue), and the
-- source currently navigated to (yellow, with the target point). Both work without each other.
local P = {}
ns.MapPins = P

local L = ns.L
local W = ns.Widgets
local pool = {}
local shownMap, shownKey, shownFocus
local overlay

-- At most this many cells for an item (union of its sources) so huge datasets stay cheap.
P.MAX_PINS = 600
P.ITEM_SOURCES = 20

-- { key = sourceKey } or { itemId = id }; nil when nothing is focused.
P.focus = nil

local function Canvas()
    if WorldMapFrame and WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child then
        return WorldMapFrame.ScrollContainer.Child
    end
    return WorldMapButton or WorldMapDetailFrame
end

local function CurrentMap()
    if WorldMapFrame and WorldMapFrame.GetMapID then return WorldMapFrame:GetMapID() end
    if GetCurrentMapAreaID then return GetCurrentMapAreaID() end
    return nil
end

local function Pin(i)
    local t = pool[i]
    if not t then
        t = overlay:CreateTexture(nil, "OVERLAY")
        pool[i] = t
    end
    return t
end

-- Spawn cells of the focus: { [map] = { [cell] = weight } }, capped at MAX_PINS cells overall.
function P.FocusCells(focus)
    focus = focus or P.focus
    if not focus then return {} end
    if focus.key ~= nil then return ns.Store.Spawns(focus.key) end
    local merged = {}
    local m = ns.Lookup.ItemModel(focus.itemId)
    local rows = {}
    for _, list in pairs(m.sections) do
        for _, r in ipairs(list) do
            rows[#rows + 1] = r
        end
    end
    table.sort(rows, ns.Lookup.RowOrder)
    for i = 1, math.min(P.ITEM_SOURCES, #rows) do
        for map, cells in pairs(ns.Store.Spawns(rows[i].key)) do
            local mm = merged[map] or {}
            merged[map] = mm
            for cell, cnt in pairs(cells) do
                mm[cell] = (mm[cell] or 0) + cnt * math.max(rows[i].lo, 0.001)
            end
        end
    end
    -- keep the heaviest cells only
    local all = {}
    for map, cells in pairs(merged) do
        for cell, w in pairs(cells) do
            all[#all + 1] = { map, cell, w }
        end
    end
    if #all <= P.MAX_PINS then return merged end
    table.sort(all, function(a, b) return a[3] > b[3] end)
    local out = {}
    for i = 1, P.MAX_PINS do
        local e = all[i]
        out[e[1]] = out[e[1]] or {}
        out[e[1]][e[2]] = e[3]
    end
    return out
end

-- Map with the most weight in a set of cells.
local function BestMap(cells)
    local best, bestW
    for map, list in pairs(cells) do
        local w = 0
        for _, cnt in pairs(list) do
            w = w + cnt
        end
        if not bestW or w > bestW then
            best, bestW = map, w
        end
    end
    return best
end

local function Draw(cells, map, w, h, size, used, r, g, b)
    local maxc = 0
    for _, list in pairs(cells) do
        for _, cnt in pairs(list) do
            if cnt > maxc then maxc = cnt end
        end
    end
    for m, list in pairs(cells) do
        for cell, cnt in pairs(list) do
            local x, y = ns.Store.CellXY(cell)
            if m ~= map then
                x, y = ns.Nav.Convert(m, x, y, map)
            end
            if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                used = used + 1
                local t = Pin(used)
                t:ClearAllPoints()
                t:SetSize(size, size)
                t:SetPoint("CENTER", overlay, "TOPLEFT", x * w, -y * h)
                W.Color(t, r, g, b, 1)
                t:SetAlpha(math.min(0.9, 0.3 + 0.6 * (maxc > 0 and cnt / maxc or 0)))
                t:Show()
            end
        end
    end
    return used
end

function P.Refresh()
    local canvas = Canvas()
    if not canvas or not WorldMapFrame or not WorldMapFrame:IsShown() then return end
    if not overlay then
        overlay = CreateFrame("Frame", nil, canvas)
        overlay:SetAllPoints(canvas)
        overlay:SetFrameLevel((canvas:GetFrameLevel() or 1) + 20)
    end
    local active = ns.Nav.active
    local map = CurrentMap()
    local key = active and active.key
    shownMap, shownKey, shownFocus = map, key, P.focus
    local used = 0
    if map then
        local w, h = canvas:GetWidth(), canvas:GetHeight()
        local size = math.max(4, w / 100)
        if P.focus then used = Draw(P.FocusCells(), map, w, h, size, used, 0.3, 0.8, 1) end
        if key then
            used = Draw(ns.Store.Spawns(key), map, w, h, size, used, 1, 0.82, 0)
            if active.map == map or ns.Nav.Convert(active.map, active.x, active.y, map) then
                local tx, ty = ns.Nav.Convert(active.map, active.x, active.y, map)
                used = used + 1
                local t = Pin(used)
                t:ClearAllPoints()
                t:SetSize(size * 2.5, size * 2.5)
                t:SetPoint("CENTER", overlay, "TOPLEFT", tx * w, -ty * h)
                W.Color(t, 1, 0.82, 0, 1)
                t:SetAlpha(1)
                t:Show()
            end
        end
    end
    P.used = used
    for i = used + 1, #pool do
        pool[i]:Hide()
    end
end

-- Opens the world map on `map` (never in combat: the map frame is protected there).
local function OpenMap(map)
    if not WorldMapFrame or ns.InCombat() then return false end
    if not WorldMapFrame:IsShown() then
        if OpenWorldMap then
            pcall(OpenWorldMap, map)
        elseif ToggleWorldMap then
            pcall(ToggleWorldMap)
        end
    end
    if map and WorldMapFrame.SetMapID then pcall(WorldMapFrame.SetMapID, WorldMapFrame, map) end
    return true
end

local function Focus(focus, open)
    P.focus = focus
    local cells = P.FocusCells(focus)
    local map = BestMap(cells)
    if not map then
        ns.Print(L["no location recorded yet"])
        return false
    end
    if open then OpenMap(map) end
    P.Refresh()
    return true
end

function P.ShowSource(key, open) return Focus({ key = key }, open) end
function P.ShowItem(itemId, open) return Focus({ itemId = itemId }, open) end
function P.ClearFocus()
    P.focus = nil
    P.Refresh()
end

ns.On("DB_READY", function()
    if not WorldMapFrame then return end
    WorldMapFrame:HookScript("OnShow", P.Refresh)
    local ticker = CreateFrame("Frame", nil, WorldMapFrame)
    ticker.t = 0
    ticker:SetScript("OnUpdate", function(self, elapsed)
        self.t = self.t + elapsed
        if self.t < 0.5 then return end
        self.t = 0
        local key = ns.Nav.active and ns.Nav.active.key
        if CurrentMap() ~= shownMap or key ~= shownKey or P.focus ~= shownFocus then P.Refresh() end
    end)
end)

ns.On("WAYPOINT", function() P.Refresh() end)

return P
