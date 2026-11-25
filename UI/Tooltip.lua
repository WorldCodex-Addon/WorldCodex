local _, ns = ...

local L = ns.L
local T = {}
ns.Tooltip = T

local HEADER = "|cff33ff99WorldCodex|r"
local done = setmetatable({}, { __mode = "k" })

local function Settings() return ns.db and ns.db.settings end
local function FarmingOn() return not ns.FarmingOn or ns.FarmingOn() end

-- Key bound to "open page of hovered item / NPC", if any.
local function PageKey()
    if not GetBindingKey then return nil end
    local ok, key = pcall(GetBindingKey, "WORLDCODEX_HOVER")
    return ok and key or nil
end

local function AddItemLines(tt, itemId)
    local s = Settings()
    local shift = IsShiftKeyDown and IsShiftKeyDown()
    local price = ns.Prices.Get(itemId)
    local fastest, _, list = ns.Nav.Best(itemId)
    local vendor = ns.Prices.Vendor(itemId)
    local goal = ns.db.farm.goals[itemId]
    if not price and #list == 0 and not goal then return end
    tt:AddLine(HEADER)
    if price then
        if price.min then
            tt:AddDoubleLine(
                "  " .. L["AH min / avg / max"],
                string.format("%s / %s / %s", ns.Coin(price.min), ns.Coin(price.avg), ns.Coin(price.max)),
                0.8,
                0.8,
                0.8,
                1,
                1,
                1
            )
            tt:AddDoubleLine(
                "  "
                    .. L["market"]
                    .. string.format(" (%s%s)", ns.Age(price.age), price.origin == "guild" and ", guild" or ""),
                ns.Coin(price.market),
                0.8,
                0.8,
                0.8,
                1,
                1,
                1
            )
        else
            tt:AddDoubleLine(
                "  " .. L["Auction house"],
                L["none listed"] .. " (" .. ns.Age(price.age) .. ")",
                0.8,
                0.8,
                0.8,
                1,
                1,
                1
            )
        end
    end
    if vendor and vendor > 0 and shift then
        tt:AddDoubleLine("  " .. L["Vendor"], ns.Coin(vendor), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if #list > 0 then
        local max = shift and 8 or (s.tooltipSources or 3)
        table.sort(list, function(a, b) return a.rate > b.rate end) -- Rank returns a fresh table
        for i = 1, math.min(max, #list) do
            local e = list[i]
            local qty = ns.Report.Qty(e.key, itemId)
            local stack = (qty.max and qty.max > 1 or qty.avg >= 1.05) and (" · " .. ns.Report.QtyRange(qty)) or ""
            local right = e.kind == "quest" and string.format("x%.0f (n=%d)", e.avgQty, e.n)
                or string.format("%s ±%.1f%s (n=%d)", ns.Pct(e.rate), (e.hi - e.lo) / 2 * 100, stack, e.n)
            if s.tooltipBars and e.kind ~= "quest" then
                right = ns.Report.RateBarText(e.lo, e.rate, e.hi, 48, 8, ns.Stats.Confidence(e.d, e.n)) .. " " .. right
            end
            -- where to find it: the zone (in instances the only location there is)
            local zone = ns.Lookup.Zones(e.key, 1)[1]
            local label = ns.Nav.Label(e) .. (zone and (" |cff888888· " .. zone.name .. "|r") or "")
            tt:AddDoubleLine("  " .. label, right, 0.8, 0.8, 0.8, 1, 1, 1)
            if shift and qty.max and qty.max > qty.min then
                tt:AddLine("      " .. ns.Report.QtyDist(qty, 5), 0.7, 0.7, 0.7)
            end
            if shift then
                local parts = ns.Report.PartsText(e.parts, e.kind)
                if parts ~= "" then tt:AddLine("      " .. parts, 0.55, 0.55, 0.55) end
                local c = ns.Store.Compare(e.key, itemId)
                if c.mine.n > 0 and c.others.n > 0 and e.kind ~= "quest" then
                    local differs, z = ns.Stats.Differs(c.mine.d, c.mine.n, c.others.d, c.others.n)
                    local r, g, b = 0.55, 0.55, 0.55
                    if differs then
                        r, g, b = z > 0 and 0.3 or 0.95, z > 0 and 0.9 or 0.35, z > 0 and 0.35 or 0.3
                    end
                    tt:AddLine(
                        string.format(
                            "      %s %s (%d) · %s %s (%d)",
                            L["You"],
                            ns.Pct(c.mine.d / c.mine.n),
                            c.mine.n,
                            L["Community"],
                            ns.Pct(c.others.d / c.others.n),
                            c.others.n
                        ),
                        r,
                        g,
                        b
                    )
                end
            end
        end
        if #list > max then tt:AddLine(string.format("  ... +%d", #list - max), 0.6, 0.6, 0.6) end
        if not FarmingOn() then fastest = nil end
        if fastest and fastest.kind == "quest" then
            tt:AddLine(string.format("  %s: %s", L["Best farm"], ns.Nav.Label(fastest)), 0.2, 1, 0.2)
        elseif fastest then
            tt:AddLine(
                string.format(
                    "  %s: %s - ~%d %s (%s)",
                    L["Best farm"],
                    ns.Nav.Label(fastest),
                    fastest.attempts,
                    fastest.kind == "mob" and L["kills/drop"] or L["tries/drop"],
                    ns.Duration(fastest.minutes)
                ),
                0.2,
                1,
                0.2
            )
        end
    end
    if goal and FarmingOn() then
        local have, target, minutes = ns.Farm.GoalProgress(itemId)
        tt:AddLine(
            string.format("  %s: %d/%d, ETA %s", L["Goal"], have, target, minutes and ns.Duration(minutes) or "?"),
            1,
            0.82,
            0
        )
    end
    if not shift then
        local key = s.tooltipPageHint and PageKey()
        if key then
            tt:AddLine(string.format("  %s · %s: %s", L["Hold Shift for details"], key, L["open page"]), 0.5, 0.5, 0.5)
        else
            tt:AddLine("  " .. L["Hold Shift for details"], 0.5, 0.5, 0.5)
        end
    end
end

-- Quality, item level and quest flag of a drop: live from the client, else the cached item facts.
local QUEST_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12
local function SortFacts(id)
    local d = ns.ItemDetails(id)
    local it = ns.db and ns.db.items and ns.db.items[id]
    local quality = d.quality or (it and it.ql) or -1
    local ilvl = d.ilvl or (it and it.il) or 0
    local cls = d.classId or (it and it.cl)
    return cls == QUEST_CLASS, quality, ilvl
end

-- Drops of the mob (npc id key) under the mouse.
local function AddMobLines(tt, key)
    local ev, _, n = ns.Report.SourceValue(key)
    if not n or n <= 0 then return ns.Count("unit tooltip: no data for the mob") end
    ns.Count("unit tooltip: lines added")
    local items = {}
    for id in pairs(ns.Store.SourceItems(key)) do
        local d, nn = ns.Store.Combined(key, id)
        if d > 0 then
            local quest, quality, ilvl = SortFacts(id)
            items[#items + 1] = {
                id = id,
                rate = d / nn,
                value = d / nn * ns.Prices.UnitValue(id),
                qty = ns.Report.Qty(key, id),
                quest = quest,
                quality = quality,
                ilvl = ilvl,
            }
        end
    end
    -- Quest items first, then by rarity and item level (highest first); ties go to the most
    -- valuable drop with farming on, otherwise to the most likely one.
    local farming = FarmingOn()
    table.sort(items, function(a, b)
        if a.quest ~= b.quest then return a.quest end
        if a.quality ~= b.quality then return a.quality > b.quality end
        if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
        if farming and a.value ~= b.value then return a.value > b.value end
        if a.rate ~= b.rate then return a.rate > b.rate end
        if a.value ~= b.value then return a.value > b.value end
        return a.id < b.id
    end)
    tt:AddDoubleLine(HEADER .. " n=" .. n, farming and (ns.Coin(ev) .. " " .. L["per kill"]) or "", 1, 1, 1, 1, 1, 1)
    local sum = ns.Store.SourceSummary(key)
    local coin = sum.coin > 0 and (" · " .. ns.Coin(sum.coin)) or ""
    if sum.coinChance and sum.coinMin then
        coin = coin .. string.format(" (%s-%s)", ns.Coin(sum.coinMin), ns.Coin(sum.coinMax))
    end
    tt:AddLine(string.format("  %s %.1f %s%s", L["Avg"], sum.items, L["items"], coin), 0.8, 0.8, 0.8)
    for i = 1, math.min(3, #items) do
        local q = items[i].qty
        local stack = (q.max and q.max > 1) and (" · " .. ns.Report.QtyRange(q)) or ""
        tt:AddDoubleLine("  " .. ns.ItemName(items[i].id, true), ns.Pct(items[i].rate) .. stack, 1, 1, 1, 0.8, 0.8, 0.8)
    end
    if #items > 3 then tt:AddLine(string.format("  ... +%d", #items - 3), 0.6, 0.6, 0.6) end
end

-- Chests, herbs, veins and other objects: matched by the name in the tooltip.
local function AddObjectLines(tt, name)
    local keys = ns.Lookup.ObjectsByName(name)
    local key = keys[1]
    if not key then return end
    local m = ns.Lookup.SourceModel(key)
    local s = m.summary
    if s.n <= 0 then return end
    tt:AddDoubleLine(
        HEADER .. " n=" .. s.n,
        s.coin > 0 and (ns.Coin(s.coin) .. " " .. L["per attempt"]) or "",
        1,
        1,
        1,
        0.8,
        0.8,
        0.8
    )
    local shown = 0
    for _, r in ipairs(m.items) do
        if shown >= 4 then break end
        shown = shown + 1
        local right = ns.Pct(r.rate)
        if Settings().tooltipBars then
            right = ns.Report.RateBarText(r.lo, r.rate, r.hi, 48, 8, r.conf) .. " " .. right
        end
        tt:AddDoubleLine("  " .. ns.ItemName(r.itemId, true), right, 1, 1, 1, 0.8, 0.8, 0.8)
    end
    if #m.items > shown then tt:AddLine(string.format("  ... +%d", #m.items - shown), 0.6, 0.6, 0.6) end
    if #keys > 1 then
        tt:AddLine("  " .. string.format(L["%d more object types with this name"], #keys - 1), 0.5, 0.5, 0.5)
    end
    local pageKey = Settings().tooltipPageHint and PageKey()
    if pageKey then tt:AddLine(string.format("  %s: %s", pageKey, L["open page"]), 0.5, 0.5, 0.5) end
end
T.AddObjectLines = AddObjectLines

-- On modern clients the tooltip re-layouts itself after post-calls; calling Show() on Blizzard
-- tooltips from addon code there can taint them, so it is only done for the classic hooks.
local needShow = false

-- Small "WorldCodex" button under the item link popup (ItemRefTooltip) that opens the item page.
-- It is our own frame; the Blizzard tooltip itself is never shown or changed.
local refButton
local function ShowRefButton(itemId)
    if not ItemRefTooltip or not ns.Page or not CreateFrame then return end
    if not refButton then
        refButton = CreateFrame("Button", "WorldCodexItemRefButton", ItemRefTooltip, "UIPanelButtonTemplate")
        refButton:SetSize(90, 20)
        refButton:SetPoint("TOPRIGHT", ItemRefTooltip, "BOTTOMRIGHT", 0, 2)
        refButton:SetText("WorldCodex")
        refButton:SetScript("OnClick", function(self)
            if self.itemId then ns.Page.Show({ type = "item", id = self.itemId }) end
        end)
    end
    refButton.itemId = itemId
    refButton:Show()
end
T.ShowRefButton = ShowRefButton
function T.RefButton() return refButton end

local function OnItem(tt, itemId)
    if tt == ItemRefTooltip and itemId then ShowRefButton(itemId) end
    if not itemId or not Settings() or not Settings().tooltip then return end
    if done[tt] == itemId then return end
    done[tt] = itemId
    ns.Profile("tooltip", AddItemLines, tt, itemId)
    if needShow then tt:Show() end
end

local function OnObject(tt, name)
    if not name or not Settings() or not Settings().tooltipObject then return end
    if done[tt] == "obj:" .. name then return end
    done[tt] = "obj:" .. name
    ns.Profile("tooltip", AddObjectLines, tt, name)
end
T.OnObject = OnObject

local function AddUnitLines(tt, guid)
    local gt = ns.GuidType(guid)
    if gt ~= "Creature" and gt ~= "Vehicle" then return end
    local key = ns.GuidId(guid)
    if key then AddMobLines(tt, key) end
end
T.AddUnitLines = AddUnitLines

local function OnUnit(tt, guid)
    if not guid or not Settings() or not Settings().tooltipUnit then return end
    if done[tt] == guid then return end
    done[tt] = guid
    ns.Profile("tooltip", AddUnitLines, tt, guid)
    if needShow then tt:Show() end
end

-- Instances hide the unit's GUID: the mob is found by the name in the tooltip instead.
local function OnUnitName(tt, name)
    if not name or not Settings() or not Settings().tooltipUnit then return end
    local key = ns.Lookup.MobByName(name)
    if not key then
        ns.Count("unit tooltip: name not recorded")
        ns.Count("unit tooltip: last unknown name", name)
        return
    end
    ns.Count("unit tooltip: found by name")
    if done[tt] == "mob:" .. key then return end
    done[tt] = "mob:" .. key
    ns.Profile("tooltip", AddMobLines, tt, key)
end

function T.Install()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        -- tooltip data can hold secret values in combat and instances (ns.Plain)
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
            local id = data and ns.Plain(data.id)
            if id then OnItem(tt, id) end
        end)
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tt, data)
            if not data then return end
            ns.Count("unit tooltip")
            local guid = ns.Plain(data.guid, "tooltip guid")
            if guid then return OnUnit(tt, guid) end
            local line = type(data.lines) == "table" and data.lines[1]
            local name = type(line) == "table" and ns.Plain(line.leftText, "tooltip name") or nil
            if name then return OnUnitName(tt, name) end
            -- GUID, name and model are hidden in instances (confirmed on WoW Forever): the mob cannot
            -- be told apart. Counted: which of its other values are still readable there.
            ns.Count("unit tooltip: no readable name")
            if tt == GameTooltip then
                local probes = { level = UnitLevel, type = UnitCreatureType, class = UnitClassification }
                for what, fn in pairs(probes) do
                    if ns.CallAs("hovered " .. what, fn, "mouseover") ~= nil then
                        ns.Count("unit tooltip: " .. what .. " readable")
                    end
                end
            end
        end)
        if Enum.TooltipDataType.Object then
            -- the supported way for world objects; the tooltip lays itself out afterwards
            T.objectRoute = "data"
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Object, function(tt, data)
                local line = data and type(data.lines) == "table" and data.lines[1]
                local name = line and ns.Plain(line.leftText)
                if not name and tt == GameTooltip and GameTooltipTextLeft1 then
                    name = ns.Plain(GameTooltipTextLeft1:GetText())
                end
                OnObject(tt, name)
            end)
        elseif ns.db.settings.tooltipObjectHook then
            -- opt-in: this client has no object tooltip data, so lines are added when the tooltip
            -- shows and it is shown again to resize - may taint Blizzard's tooltip on modern clients
            T.objectRoute = "hook"
            GameTooltip:HookScript("OnShow", function(self)
                local name = ns.HoveredObjectName()
                if name and ns.Lookup.ObjectsByName(name)[1] then
                    OnObject(self, name)
                    self:Show()
                end
            end)
        end
    else
        needShow = true
        local function hookItem(tt)
            if not tt or not tt.HookScript then return end
            tt:HookScript("OnTooltipSetItem", function(self)
                local _, link = self:GetItem()
                OnItem(self, ns.ItemIdFromLink(link))
            end)
        end
        hookItem(GameTooltip)
        hookItem(ItemRefTooltip)
        hookItem(ShoppingTooltip1)
        hookItem(ShoppingTooltip2)
        GameTooltip:HookScript("OnTooltipSetUnit", function(self)
            local _, unit = self:GetUnit()
            if unit then OnUnit(self, ns.Call(UnitGUID, unit)) end
        end)
        -- old clients: objects have no tooltip callback, so add the lines when the tooltip shows
        T.objectRoute = "show"
        GameTooltip:HookScript("OnShow", function(self)
            local name = ns.HoveredObjectName()
            if name and ns.Lookup.ObjectsByName(name)[1] then
                OnObject(self, name)
                self:Show()
            end
        end)
    end
    for _, tt in ipairs({ GameTooltip, ItemRefTooltip, ShoppingTooltip1, ShoppingTooltip2 }) do
        if tt and tt.HookScript then
            tt:HookScript("OnTooltipCleared", function(self)
                done[self] = nil
                if self == ItemRefTooltip and refButton then refButton:Hide() end
            end)
            tt:HookScript("OnHide", function(self) done[self] = nil end)
        end
    end
end

-- Opt-in: Alt-click on any item link opens its page. Off by default because it hooks a Blizzard
-- function (post-hook only, the original always runs first and unchanged).
local altHooked = false
function T.InstallAltClick()
    if altHooked or not ns.db.settings.altClickPage then return end
    if not (hooksecurefunc and HandleModifiedItemClick) then return end
    altHooked = true
    hooksecurefunc("HandleModifiedItemClick", function(link)
        if not ns.db.settings.altClickPage or not (IsAltKeyDown and IsAltKeyDown()) or not ns.Page then return end
        local id = ns.ItemIdFromLink(link)
        if id then ns.Page.Show({ type = "item", id = id }) end
    end)
end

ns.On("DB_READY", function()
    T.Install()
    T.InstallAltClick()
end)
ns.On("SETTINGS_CHANGED", function(key)
    if key == "altClickPage" then T.InstallAltClick() end
end)

return T
