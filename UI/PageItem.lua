local _, ns = ...

-- Item page: every source of an item grouped into tabs (Dropped by, Gathered from, Contained in,
-- Quests, Processing), rate bars with confidence, the player's own rate against everyone else's,
-- and the price history.
local L = ns.L
local W, P, C = ns.Widgets, ns.Page, ns.Charts
local Lk = ns.Lookup

local R = {}

R.Columns = {
    sources = {
        {
            key = "name",
            title = L["Source"],
            w = 150,
            text = function(r) return ns.Nav.Label(r) end,
            sort = function(r) return tostring(r.name):lower() end,
            icon = function(r) return P.SourceIcon(r.key, r.kind) end,
        },
        { key = "lmin", title = L["Level"], w = 36, text = P.LevelText, sort = function(r) return r.lmin or 0 end },
        { key = "zone", title = L["Zone"], w = 104, text = P.ZoneText, sort = P.ZoneText },
        P.BarColumn(90),
        { key = "rate", title = "%", w = 46, align = "RIGHT", text = P.RateText },
        { key = "n", title = "n", w = 40, align = "RIGHT", text = function(r) return tostring(r.n) end },
        { key = "avgQty", title = L["Qty"], w = 34, align = "RIGHT", text = P.QtyText },
    },
}

local function FarmingOn() return not ns.FarmingOn or ns.FarmingOn() end

function R.Header(id, layer)
    local d = ns.ItemDetails(id)
    local sub = { "#" .. id }
    if d.ilvl and d.ilvl > 0 then sub[#sub + 1] = string.format(L["item level %d"], d.ilvl) end
    if d.minLevel and d.minLevel > 1 then sub[#sub + 1] = string.format(L["requires level %d"], d.minLevel) end
    if d.class then
        sub[#sub + 1] = d.subclass and d.subclass ~= d.class and (d.class .. " / " .. d.subclass) or d.class
    end
    if d.slot then sub[#sub + 1] = d.slot end
    if d.stack and d.stack > 1 then sub[#sub + 1] = string.format(L["stacks to %d"], d.stack) end
    local info = {}
    local vendor = ns.Prices.Vendor(id)
    local line = {}
    if vendor and vendor > 0 then line[#line + 1] = L["Vendor"] .. " " .. ns.Coin(vendor) end
    local price = ns.Report.PriceLine(id)
    line[#line + 1] = price and (L["AH"] .. ": " .. price) or L["no auction data"]
    info[1] = table.concat(line, "  ·  ")
    local m = Lk.ItemModel(id, layer)
    if m.total > 0 then
        local best = m.best
        if best then
            info[2] = string.format(
                L["%d sources · surest: %s %s (at least %s)"],
                m.total,
                ns.Nav.Label(best),
                P.RateText(best),
                ns.Pct(best.lo)
            )
        else
            info[2] = string.format(L["%d sources, all with few observations"], m.total)
        end
    end
    return {
        icon = d.texture,
        link = d.link or ("item:" .. id),
        title = ns.ItemName(id, true),
        sub = table.concat(sub, " · "),
        info = table.concat(info, "\n"),
    }
end

function R.Actions(id)
    local list = {
        {
            label = L["Link"],
            width = 60,
            fn = function()
                if ChatEdit_InsertLink then ChatEdit_InsertLink(ns.ItemLink(id)) end
            end,
        },
        {
            label = L["Show on map"],
            width = 104,
            fn = function()
                if ns.MapPins and ns.MapPins.ShowItem then ns.MapPins.ShowItem(id, true) end
            end,
        },
    }
    if ns.AH and ns.AH.SearchNow then
        list[#list + 1] = { label = L["Scan AH"], width = 80, fn = function() ns.AH.SearchNow(id) end }
    end
    if FarmingOn() and ns.Farm then
        if ns.db.farm.goals[id] then
            list[#list + 1] = { label = L["Remove goal"], width = 100, fn = function() ns.Farm.ClearGoal(id) end }
        else
            list[#list + 1] = { label = L["Set goal"], width = 80, fn = function() ns.Farm.SetGoal(id, 20) end }
        end
    end
    if ns.WEB_BASE and ns.WebLink then
        list[#list + 1] = { label = L["Web link"], width = 80, fn = function() ns.WebLink("item", id) end }
    end
    return list
end

function R.Tabs(id, layer)
    local m = Lk.ItemModel(id, layer)
    local tabs = {}
    for _, s in ipairs(m.order) do
        tabs[#tabs + 1] = {
            id = s,
            label = Lk.SECTION_LABEL[s],
            count = m.counts[s],
            table = "sources",
            rows = m.sections[s],
        }
    end
    if #tabs == 0 then
        tabs[1] = {
            id = "drop",
            label = Lk.SECTION_LABEL.drop,
            count = 0,
            table = "sources",
            rows = {},
            empty = layer == "mine" and L["You have not looted this item yet."]
                or L["Nobody has looted this item yet."],
        }
    end
    -- the item itself (stats, weapon damage, effects; Items.lua): its own tab, because with drops
    -- the right page shows the selected source
    if #ns.Report.ItemDetailRows(id) > 0 then
        tabs[#tabs + 1] = { id = "details", label = L["Item"], custom = "details" }
    end
    if ns.ItemTabs then
        for _, t in ipairs(ns.ItemTabs(id, layer)) do
            tabs[#tabs + 1] = t
        end
    end
    if ns.Prices.Get(id) or #ns.Prices.History(id) > 0 then
        tabs[#tabs + 1] = { id = "prices", label = L["Prices"], custom = "prices" }
    end
    return tabs
end

-- Nothing selected: the item's own facts (stats, weapon damage, effects; Items.lua) on the right page.
local function ShowItemFacts()
    local cur = P.Current()
    local id = cur and cur.type == "item" and cur.id
    local rows = id and ns.Report.ItemDetailRows(id) or {}
    if #rows == 0 or not ns.Details then return false end
    local d = ns.ItemDetails(id)
    local sub = {}
    if d.slot then sub[#sub + 1] = d.slot end
    if d.subclass and d.subclass ~= "" then sub[#sub + 1] = d.subclass end
    ns.Details.Show({
        title = ns.ItemName(id, true),
        icon = d.texture,
        subtitle = table.concat(sub, " · "),
        sections = { { title = L["Item"], rows = rows } },
    })
    return true
end

function R.Select(r, tab)
    if not r then
        if not (tab and tab.custom) and ShowItemFacts() then return end
        P.Analysis(nil, { empty = tab and tab.custom and " " or nil })
        return
    end
    if r.extra then
        if ns.PageExtra and ns.PageExtra.Select then return ns.PageExtra.Select(r) end
    end
    if r.asItem then
        return P.Analysis(r, {
            title = ns.ItemName(r.itemId, true),
            kind = tostring(r.name),
            openType = "item",
            openId = r.itemId,
            openLabel = L["Open item"],
        })
    end
    P.Analysis(r, {
        title = ns.Nav.Label(r),
        kind = (ns.KIND_LABEL[r.kind] or r.kind) .. (P.ZoneText(r) ~= "" and (" · " .. P.ZoneText(r)) or ""),
        openType = "source",
        openId = r.key,
        openLabel = L["Open source"],
    })
end

function R.Open(r)
    if r.openType then return P.Show({ type = r.openType, id = r.openId }) end
    -- extra rows (vendors, trainers, quests, ...) open only what they name; their itemId is no item
    if r.extra then return false end
    P.Show({ type = "source", id = r.key })
end

function R.RowTooltip(tt, r)
    if r.extra then return ns.PageExtra.Tooltip(tt, r) end
    if r.asItem then return tt:SetHyperlink("item:" .. r.itemId) end
    tt:AddLine(ns.Nav.Label(r), 1, 1, 1)
    tt:AddLine(ns.KIND_LABEL[r.kind] or r.kind, 0.6, 0.6, 0.6)
    if r.kind ~= "quest" then
        tt:AddDoubleLine(
            L["Chance"],
            string.format("%s (95%%: %s - %s)", ns.Pct(r.rate), ns.Pct(r.lo), ns.Pct(r.hi)),
            0.8,
            0.8,
            0.8,
            1,
            1,
            1
        )
    end
    tt:AddDoubleLine(L["Observations"], tostring(r.n), 0.8, 0.8, 0.8, 1, 1, 1)
    if r.mine and r.mine.n > 0 then
        tt:AddDoubleLine(
            L["You"],
            string.format("%d/%d = %s", r.mine.d, r.mine.n, ns.Pct(r.mine.d / r.mine.n)),
            0.31,
            0.59,
            1,
            1,
            1,
            1
        )
    end
    tt:AddLine(L["Double-click to open this source."], 0.5, 0.5, 0.5)
end

function R.EmptyText() return L["Select a source to see the details."] end

R.Custom = {}

-- Item details on the left page (the right page keeps the selected source's analysis or the facts).
function R.Custom.details(parent)
    local fr = CreateFrame("Frame", nil, parent)
    fr:SetAllPoints(parent)
    fr.facts = ns.Details.Frame(fr, P.CONTENT_W)
    function fr:Update(id)
        ns.Details.Render(self.facts, { sections = { { title = L["Item"], rows = ns.Report.ItemDetailRows(id) } } })
    end
    return fr
end

-- Price history: daily medians with min-max whiskers over the last 60 days.
function R.Custom.prices(parent)
    local fr = CreateFrame("Frame", nil, parent)
    fr:SetAllPoints(parent)
    fr.text = W.Text(fr, "bodyLarge")
    fr.text:SetPoint("TOPLEFT", 4, -4)
    fr.text:SetWidth(P.CONTENT_W)
    fr.text:SetHeight(70)
    fr.text:SetJustifyV("TOP")
    fr.label = W.Text(fr, "headingSmall")
    fr.label:SetPoint("TOPLEFT", 4, -84)
    fr.label:SetText(L["Daily median with lowest and highest price"])
    fr.chart = C.Columns(fr, P.CONTENT_W, 160)
    fr.chart:SetPoint("TOPLEFT", 4, -100)
    function fr:Update(id)
        local p = ns.Prices.Get(id)
        local lines = {}
        if p then
            lines[#lines + 1] = ns.Report.PriceLine(id)
            if p.min14 then lines[#lines + 1] = L["lowest in 14 days"] .. ": " .. ns.Coin(p.min14) end
            if p.qty then lines[#lines + 1] = string.format(L["%d listed"], p.qty) end
            lines[#lines + 1] = string.format(L["%d days of history"], p.days or 0)
        else
            lines[#lines + 1] = L["no auction data"]
        end
        self.text:SetText(W.Ink(table.concat(lines, "\n")))
        local hist = ns.Prices.History(id)
        local values = {}
        local first = math.max(1, #hist - 59)
        for i = first, #hist do
            local d = hist[i].d
            values[#values + 1] = { v = d.md or d.mn or 0, lo = d.mi, hi = d.mx }
        end
        local left = hist[first] and ns.date("%m-%d", hist[first].day * 86400) or ""
        local right = hist[#hist] and ns.date("%m-%d", hist[#hist].day * 86400) or ""
        local maxv = 0
        for _, v in ipairs(values) do
            maxv = math.max(maxv, v.v or 0, v.hi or 0)
        end
        self.chart:Set(values, {
            color = { 185, 125, 25 },
            left = left .. (maxv > 0 and ("   " .. L["max"] .. " " .. ns.ShortCoin(maxv)) or ""),
            right = right,
        })
    end
    return fr
end

P.Register("item", R)
ns.PageItem = R

return R
