local _, ns = ...

-- Browse lists of the WorldCodex window: Items, Sources, Auction house and (with the farming
-- features) Farming. They are pages of type "list" in the same window and history as the item and
-- source pages (UI/Page.lua): a click shows a preview in the side panel, a double-click opens the page.
local L = ns.L
local W, C = ns.Widgets, ns.Charts
local P = ns.Page
local B = {}
ns.Browser = B

-- tab = list shown last; data = its rows (default order); query[list] = search text per list;
-- reset[list] = scroll back to the top on the next build (new search or filter).
local state = { tab = "items", data = {}, selected = nil, query = {}, reset = {} }

local function Price(v) return v and v > 0 and ns.CoinShort(v) or "-" end

-- Icon of an item row, looked up only for rows on screen (C_Item.GetItemIconByID needs no item cache).
local function ItemIcon(r)
    if r.icon == nil then r.icon = ns.ItemIcon(r.id) or false end
    return r.icon or nil
end
local NAME_COL = { key = "name", title = L["Item"], w = 170, text = function(r) return r.label end, icon = ItemIcon }
local function BestCol(title)
    return { key = "best", title = title, w = 150, text = function(r) return r.best end }
end
-- Main zone of a source row (in instances the dungeon), worked out only for rows on screen.
local function ZoneOf(r)
    if r.zone == nil then
        local z = ns.Lookup.Zones(r.id, 1)[1]
        r.zone = z and z.name or ""
    end
    return r.zone
end

-- Picture of a source row: the NPC's portrait, else the icon of its kind.
local function SourceIcon(r) return P.SourceIcon(r.id, r.kindKey) end

local SOURCE_COLS = {
    { key = "name", title = L["Source"], w = 132, text = function(r) return r.label end, icon = SourceIcon },
    { key = "kind", title = L["Kind"], w = 68, text = function(r) return r.kind end },
    { key = "zone", title = L["Zone"], w = 92, text = ZoneOf, sort = ZoneOf },
    { key = "n", title = "n", w = 40, align = "RIGHT", text = function(r) return tostring(r.n) end },
    {
        key = "perKill",
        title = L["Items/kill"],
        w = 56,
        align = "RIGHT",
        text = function(r) return string.format("%.2f", r.perKill) end,
    },
    { key = "coin", title = L["Coin/kill"], w = 62, align = "RIGHT", text = function(r) return Price(r.coin) end },
}

local function ItemCols(best)
    return {
        NAME_COL,
        {
            key = "rate",
            title = L["Rate"],
            w = 60,
            align = "RIGHT",
            text = function(r) return r.rate > 0 and ns.Pct(r.rate) or "-" end,
        },
        {
            key = "n",
            title = "n",
            w = 50,
            align = "RIGHT",
            text = function(r) return r.n > 0 and tostring(r.n) or "-" end,
        },
        best,
        { key = "price", title = L["Price"], w = 80, align = "RIGHT", text = function(r) return Price(r.price) end },
    }
end

-- Column sets; the farming variants (fastest source, value per kill) are separate tables.
local COLUMNS = {
    ["list:items"] = ItemCols(BestCol(L["Top source"])),
    ["list:items:farm"] = ItemCols(BestCol(L["Best farm"])),
    ["list:sources"] = SOURCE_COLS,
    ["list:ah"] = {
        NAME_COL,
        { key = "min", title = L["min"], w = 70, align = "RIGHT", text = function(r) return Price(r.min) end },
        { key = "avg", title = L["avg"], w = 70, align = "RIGHT", text = function(r) return Price(r.avg) end },
        { key = "max", title = L["max"], w = 70, align = "RIGHT", text = function(r) return Price(r.max) end },
        { key = "price", title = L["market"], w = 76, align = "RIGHT", text = function(r) return Price(r.price) end },
        {
            key = "age",
            title = L["Age"],
            w = 50,
            align = "RIGHT",
            text = function(r) return ns.Age(ns.time() + r.age) end,
        },
    },
}
do
    local farm = {}
    for i, col in ipairs(SOURCE_COLS) do
        farm[i] = col
    end
    farm[#farm + 1] =
        { key = "value", title = L["Value"], w = 62, align = "RIGHT", text = function(r) return Price(r.value) end }
    COLUMNS["list:sources:farm"] = farm
end

local DEFAULT_SORT = {
    items = { key = "price", desc = true },
    sources = { key = "n", desc = true },
    ah = { key = "price", desc = true },
}

local SECTION = {
    items = { label = L["Items"], icon = "Interface\\Icons\\INV_Misc_Bag_08" },
    sources = { label = L["Sources"], icon = "Interface\\Icons\\INV_Misc_Map_01" },
    ah = { label = L["Auction house"], icon = "Interface\\Icons\\INV_Misc_Coin_01" },
    farming = { label = L["Farming"], icon = "Interface\\Icons\\INV_Misc_PocketWatch_01" },
}

-- ---------------------------------------------------------------- data

local function Matches(name, q) return q == "" or tostring(name):lower():find(q, 1, true) ~= nil end

-- Row caches: building a row (ranking + price summary) is the expensive part, so rows are kept
-- until their item's data changes. Names are cached separately so a search only builds matches.
local nameCache, itemRows, ahRows = {}, {}, {}

local function LowerName(id)
    local n = nameCache[id]
    if not n then
        n = ns.ItemName(id):lower()
        nameCache[id] = n
    end
    return n
end

function B.InvalidateItem(itemId)
    if itemId then
        nameCache[itemId], itemRows[itemId], ahRows[itemId] = nil, nil, nil
    else
        nameCache, itemRows, ahRows = {}, {}, {}
    end
end

-- The client knows the item's name (or we stored it); otherwise the row shows "item:<id>" until the
-- name arrives (GET_ITEM_INFO_RECEIVED).
local function Known(id)
    if ns.ItemInfo(id) then return true end
    local it = ns.db.items[id]
    return it ~= nil and it.n ~= nil
end

-- With "bags only" ticked and no search text, item lists show only what is in the bags.
local function BagFilter(q) return q == "" and ns.db.settings.browserBagsOnly end

local function ItemRow(id)
    local r = itemRows[id]
    if r then return r end
    local fastest, highest = ns.Nav.Best(id)
    local price = ns.Prices.Get(id)
    local best = fastest and ns.Nav.Label(fastest) or ""
    if not ns.FarmingOn() then
        local top = ns.Lookup.ItemModel(id).best
        best = top and string.format("%s (%s)", ns.Nav.Label(top), ns.Pct(top.rate)) or ""
    end
    r = {
        type = "item",
        id = id,
        name = LowerName(id),
        label = ns.ItemName(id, true),
        unnamed = not Known(id),
        rate = highest and highest.rate or 0,
        n = highest and highest.n or 0,
        best = best,
        price = price and price.market or 0,
    }
    itemRows[id] = r
    return r
end

local function AhRow(id)
    local r = ahRows[id]
    if r ~= nil then return r or nil end
    local p = ns.Prices.Get(id)
    if not p then
        ahRows[id] = false
        return nil
    end
    r = {
        type = "item",
        id = id,
        name = LowerName(id),
        label = ns.ItemName(id, true),
        unnamed = not Known(id),
        min = p.min or 0,
        avg = p.avg or 0,
        max = p.max or 0,
        price = p.market or 0,
        age = -(p.t or 0),
    }
    ahRows[id] = r
    return r
end

local Build = {}

function Build.items(q)
    local out = {}
    local ids = BagFilter(q) and ns.BagItems() or ns.Store.AllItemIds()
    for id in pairs(ids) do
        if q == "" or LowerName(id):find(q, 1, true) then out[#out + 1] = ItemRow(id) end
    end
    return out
end

function Build.sources(q)
    local out = {}
    for key in pairs(ns.Store.AllSourceKeys()) do
        local name, kind = ns.Store.SourceMeta(key)
        if Matches(name, q) then
            local value, _, n = ns.Report.SourceValue(key)
            local sum = ns.Store.SourceSummary(key)
            out[#out + 1] = {
                type = "source",
                id = key,
                name = tostring(name):lower(),
                label = tostring(name),
                kind = ns.KIND_LABEL[kind] or kind,
                kindKey = kind,
                n = n or 0,
                perKill = sum.items,
                coin = sum.coin,
                value = value,
            }
        end
    end
    return out
end

function Build.ah(q)
    local out = {}
    local bags = BagFilter(q)
    for id in pairs(bags and ns.BagItems() or ns.db.ah) do
        if ns.db.ah[id] and (q == "" or LowerName(id):find(q, 1, true)) then
            local r = AhRow(id)
            if r then out[#out + 1] = r end
        end
    end
    return out
end

local function SortData(tab)
    local s = DEFAULT_SORT[tab]
    if not s then return end
    local key, desc = s.key, s.desc
    table.sort(state.data, function(a, b)
        local va, vb = a[key], b[key]
        if va == vb then return a.name < b.name end
        if type(va) ~= type(vb) then
            va, vb = tostring(va), tostring(vb)
        end
        if desc then return va > vb end
        return va < vb
    end)
end

local function Query(tab) return ns.Trim(state.query[tab] or ""):lower() end

local function IsList(id) return Build[id] ~= nil end

-- ---------------------------------------------------------------- actions

local function SelectedItemId()
    local sel = state.selected
    return sel and sel.type == "item" and sel.id or nil
end

local function GotoSelected()
    local sel = state.selected
    if not sel then return end
    if sel.type == "item" then
        ns.Nav.Goto(tostring(sel.id))
    else
        ns.Nav.GotoSource(sel.id)
    end
end

local function NeedItem()
    local id = SelectedItemId()
    if not id then ns.Print(L["select an item first"]) end
    return id
end

local goalInput, bagsOnly

local function GoalSelected()
    local id = NeedItem()
    if not id then return end
    ns.Farm.SetGoal(id, tonumber(goalInput:GetText()) or 20)
end

local function RemoveGoalSelected()
    local id = NeedItem()
    if not id then return end
    if not ns.db.farm.goals[id] then
        ns.Print(L["no goal set for this item"])
        return
    end
    ns.Farm.ClearGoal(id)
    ns.Print(string.format(L["goal removed: %s"], ns.ItemName(id, true)))
end

local function LinkSelected()
    local id = SelectedItemId()
    if id and ChatEdit_InsertLink then ChatEdit_InsertLink(ns.ItemLink(id)) end
end

-- Opens the item or source page of a list row.
function B.OpenPage(sel)
    if not sel then return false end
    return P.Show({ type = sel.type == "item" and "item" or "source", id = sel.id })
end

local function ShowDetail()
    local sel = state.selected
    if not sel then
        P.Preview(L["Select an entry on the left."])
    elseif sel.type == "item" then
        ns.Details.Show(ns.Report.ItemFacts(sel.id))
    else
        ns.Details.Show(ns.Report.SourceFacts(sel.id))
    end
end

-- Controls of the lists, made the first time a list is shown.
local function EnsureWidgets()
    if bagsOnly then return end
    local layer = P.Frame().pageLayer
    bagsOnly = W.Check(layer, L["Bags only"], function() return ns.db.settings.browserBagsOnly end, function(v)
        ns.db.settings.browserBagsOnly = v
        state.reset[state.tab] = true
        P.Refresh()
    end, W.Font("body"))
    bagsOnly.flowWidth = 110 -- box and label, for the row of actions
    goalInput = W.Input(layer, 36)
    goalInput:SetNumeric(true)
    goalInput:SetText("20")
end

-- ---------------------------------------------------------------- list page renderer

local R = { live = false, sticky = true, noLayers = true, Columns = COLUMNS, Custom = {} }

function R.KeyOf(r) return r.type .. ":" .. tostring(r.id) end

function R.Prepare(id)
    EnsureWidgets()
    state.tab = id
    if not IsList(id) then return end
    local q = Query(id)
    state.data = ns.Profile("browser", Build[id], q)
    SortData(id)
    -- ask the client for missing names, a few at a time; rows update as they arrive
    for _, r in ipairs(state.data) do
        if r.unnamed then
            ns.Lookup.WarmNames()
            break
        end
    end
end

function R.Header(id)
    local s = SECTION[id] or SECTION.items
    local sub = ""
    if IsList(id) then
        sub = string.format(L["%d entries"], #state.data)
        if id ~= "sources" and BagFilter(Query(id)) then
            sub = string.format(L["%d entries - items in your bags (untick or search to see all)"], #state.data)
        end
    end
    local info = ""
    if id == "sources" then
        info = L["Click a row for details, double-click to open its page, right-click to go there."]
    elseif IsList(id) then
        info = L["Click a row for details, double-click to open its page, right-click to go there."]
            .. " "
            .. L["Shift-click links the item."]
    end
    return { icon = s.icon, title = s.label, sub = sub, info = info }
end

function R.Actions(id)
    local list = {}
    if IsList(id) then
        list[#list + 1] = {
            label = L["Open page"],
            width = 96,
            fn = function() B.OpenPage(state.selected) end,
        }
        list[#list + 1] = { label = L["Take me there"], width = 110, fn = GotoSelected }
    end
    if id == "items" or id == "ah" then
        if ns.AH and ns.AH.SearchNow then
            list[#list + 1] = {
                label = L["Scan AH"],
                width = 80,
                fn = function()
                    local item = NeedItem()
                    if item then ns.AH.SearchNow(item) end
                end,
            }
        end
        list[#list + 1] = { label = L["Link"], width = 60, fn = LinkSelected }
        if ns.FarmingOn() then
            list[#list + 1] = { widget = goalInput, gap = 12 }
            list[#list + 1] = { label = L["Set goal"], width = 84, fn = GoalSelected }
            list[#list + 1] = { label = L["Remove goal"], width = 100, fn = RemoveGoalSelected }
        end
    end
    list[#list + 1] = { label = L["Refresh"], width = 80, fn = function() P.Refresh() end }
    if (id == "items" or id == "ah") and bagsOnly then list[#list + 1] = { widget = bagsOnly, gap = 16 } end
    return list
end

function R.Tabs(id)
    if id == "farming" then return { { id = "farming", label = L["Farming"], custom = "farming", solo = true } } end
    local colset = "list:" .. id
    if ns.FarmingOn() and COLUMNS[colset .. ":farm"] then colset = colset .. ":farm" end
    local keep = not state.reset[id]
    state.reset[id] = nil
    return {
        { id = "list", label = SECTION[id].label, table = colset, rows = state.data, solo = true, keepOffset = keep },
    }
end

function R.Select(r)
    if not r then
        state.selected = nil
    else
        state.selected = { type = r.type, id = r.id }
    end
    if IsList(state.tab) then ShowDetail() end
end

function R.Click(r, button)
    R.Select(r)
    if IsShiftKeyDown and IsShiftKeyDown() and r.type == "item" then
        LinkSelected()
    elseif button == "RightButton" then
        GotoSelected()
    end
end

R.Open = B.OpenPage

function R.RowTooltip(tt, r)
    if r.type == "item" then return tt:SetHyperlink("item:" .. r.id) end
    tt:AddLine(r.label, 1, 1, 1)
    tt:AddLine(r.kind, 0.6, 0.6, 0.6)
    tt:AddLine(L["Double-click to open this source."], 0.5, 0.5, 0.5)
end

-- The search box filters the lists (not the farming report).
function R.Query(id)
    if not IsList(id) then return nil end
    return state.query[id] or ""
end

function R.Filter(id, text)
    if not IsList(id) then return false end
    state.query[id] = text or ""
    state.reset[id] = true
    return true
end

-- Recent sessions on the right page of the farming tab.
local HISTORY_COLS = {
    {
        key = "start",
        title = L["Started"],
        w = 96,
        text = function(h) return ns.date("%m-%d %H:%M", h.start) end,
    },
    {
        key = "duration",
        title = L["Duration"],
        w = 70,
        text = function(h) return ns.Duration((h.last - h.start) / 60) end,
        sort = function(h) return h.last - h.start end,
    },
    {
        key = "kills",
        title = L["Kills"],
        w = 84,
        align = "RIGHT",
        text = function(h) return string.format("%d  (%.0f/h)", h.kills, h.kills / ns.Farm.Hours(h)) end,
    },
    { key = "drops", title = L["Drops"], w = 50, align = "RIGHT", text = function(h) return tostring(h.drops) end },
    {
        key = "perHour",
        title = L["Per hour"],
        w = 96,
        align = "RIGHT",
        text = function(h) return Price(ns.Farm.GoldPerHour(h)) end,
        sort = function(h) return ns.Farm.GoldPerHour(h) end,
    },
}

local function SessionTooltip(tt, h)
    tt:AddLine(ns.date("%Y-%m-%d %H:%M", h.start) .. "  ·  " .. ns.Duration((h.last - h.start) / 60), 1, 1, 1)
    tt:AddDoubleLine(L["Item value"], ns.Coin(h.value), 0.8, 0.8, 0.8, 1, 1, 1)
    tt:AddDoubleLine(L["Coin"], ns.Coin(h.money), 0.8, 0.8, 0.8, 1, 1, 1)
    tt:AddDoubleLine(L["Per hour"], ns.Coin(ns.Farm.GoldPerHour(h)), 0.8, 0.8, 0.8, 1, 1, 1)
    if h.nav then tt:AddLine(L["Farmed with the waypoint arrow"], 0.6, 0.6, 0.6) end
end

local function BuildHistory(parent)
    local fr = CreateFrame("Frame", nil, parent)
    fr:SetAllPoints(parent)
    fr.title = W.Text(fr, "heading")
    fr.title:SetPoint("TOPLEFT", 0, 0)
    fr.title:SetText(L["Recent sessions"])
    fr.table = C.Table(fr, HISTORY_COLS, {
        rows = P.PANEL_ROWS,
        rowH = P.ROW_H,
        width = P.PANEL_W,
        keyOf = function(h) return h.start end,
        onEnter = function(row, h)
            if not GameTooltip then return end
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            SessionTooltip(GameTooltip, h)
            GameTooltip:Show()
        end,
        onLeave = function()
            if GameTooltip then GameTooltip:Hide() end
        end,
    })
    fr.table:SetPoint("TOPLEFT", 0, -30)
    return fr
end

-- The farming tab: the current session and the goals on the left page, the recent sessions on the right.
function R.Custom.farming(parent)
    local fr = CreateFrame("Frame", nil, parent)
    fr:SetAllPoints(parent)
    fr.facts = ns.Details.Frame(fr, P.CONTENT_W)
    function fr:Update()
        ns.Details.Render(self.facts, ns.Farm.Facts())
        local history = P.ShowPanel("farmHistory", BuildHistory)
        history.table:SetData(ns.Farm.History(), L["No finished sessions yet."])
    end
    return fr
end

P.Register("list", R)

-- ---------------------------------------------------------------- entry points

local function Showing(...)
    local cur = P.Current()
    if not cur or cur.type ~= "list" then return false end
    if select("#", ...) == 0 then return true end
    for i = 1, select("#", ...) do
        if cur.id == select(i, ...) then return true end
    end
    return false
end

function B.SetSearch(text)
    if not Showing() or not IsList(state.tab) then return end
    R.Filter(state.tab, text or "")
    P.Frame().search:SetText(text or "")
    P.Refresh()
end

function B._State() return state end

-- Opens a list (items, sources, ah, farming); without one, closes the window or opens it again on the
-- last page.
function B.Toggle(tab)
    ns.context = "browser open" .. (tab and (" " .. tab) or "")
    if tab == "farming" and not ns.FarmingOn() then tab = "items" end
    if not tab then return P.Toggle({ type = "list", id = state.tab }) end
    state.tab = tab
    return P.Show({ type = "list", id = tab })
end

function B.Refresh()
    if Showing() then P.Refresh() end
end

function B.ShowItem(itemId) return P.Show({ type = "item", id = itemId }) end

-- Keep cached rows in sync with the data they were built from.
ns.On("PRICES_UPDATED", function(itemId)
    if itemId then
        itemRows[itemId], ahRows[itemId] = nil, nil
    else
        itemRows, ahRows = {}, {}
    end
end)
ns.On("DATA_CHANGED", function() itemRows = {} end)
-- Names of dungeon mobs arrive a moment after they were recorded (Store.ResolveNames): lists are not
-- live, so the one on screen is rebuilt once.
local namesPending = false
ns.On("DATA_CHANGED", function(what)
    if what ~= "names" or namesPending or not Showing() then return end
    namesPending = true
    ns.After(1, function()
        namesPending = false
        if Showing() then P.Refresh() end
    end)
end)
ns.On("SETTINGS_CHANGED", function() itemRows = {} end)
-- Names of items the client had not cached arrive one by one: rows on screen are updated in place
-- (in batches) instead of rebuilding the list.
local arrived, redrawPending = {}, false
local function RedrawNames()
    redrawPending = false
    local ids = arrived
    arrived = {}
    if not Showing("items", "ah") then return end
    local changed = false
    for _, r in ipairs(state.data) do
        if r.unnamed and ids[r.id] then
            r.label, r.name, r.unnamed = ns.ItemName(r.id, true), LowerName(r.id), not Known(r.id)
            if r.icon == false then r.icon = nil end -- look again once the item is known
            changed = true
        end
    end
    if changed then P.RenderRows() end
end
ns.RegisterEvent("GET_ITEM_INFO_RECEIVED", function(itemId)
    if not itemId then return end
    B.InvalidateItem(itemId)
    if not Showing("items", "ah") then return end
    arrived[itemId] = true
    if not redrawPending then
        redrawPending = true
        ns.After(0.5, RedrawNames)
    end
end)

local bagRefreshPending = false
ns.On("BAGS_CHANGED", function()
    if bagRefreshPending or not Showing("items", "ah") or not ns.db.settings.browserBagsOnly then return end
    bagRefreshPending = true
    ns.After(1, function()
        bagRefreshPending = false
        if Showing("items", "ah") then P.Refresh() end
    end)
end)

ns.On("GOALS_CHANGED", function()
    if Showing("farming") then
        P.Refresh()
    elseif Showing("items", "ah") then
        ShowDetail()
    end
end)

local refreshPending = false
ns.On("PRICES_UPDATED", function(itemId)
    if not Showing("items", "ah") then return end
    local sel = state.selected
    if itemId and sel and sel.type == "item" and sel.id == itemId then ShowDetail() end
    if refreshPending or not Showing("ah") then return end
    refreshPending = true
    ns.After(2, function()
        refreshPending = false
        if Showing("ah") then P.Refresh() end
    end)
end)

return B
