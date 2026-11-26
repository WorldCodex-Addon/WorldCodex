local _, ns = ...

-- The WorldCodex window ("Wowhead in game"), in the look of Blizzard's spellbook: one window
-- (W.JournalWindow) with an open book (W.Book) for the browse lists (UI/Browser.lua) and the item,
-- source and compare pages. The top bar holds the back/forward history, the data status, the layer
-- switch (All / Mine / Community), the search box (finds items and sources everywhere and jumps to their
-- page; the lists have their own filter box, UI/Browser.lua), the page tabs and the tools; the left page the page heading, its actions and the content (a table or a custom frame);
-- the right page the side panel (analysis of the selected row, facts, or a preview text). Section tabs
-- sit under the window.
--
-- Page types register a renderer with P.Register(type, R). Fields (Header and Tabs are required):
--   Prepare(id, layer)  runs first on every refresh
--   Header(id, layer)   -> { icon, npc, link, title, sub, info }
--   Actions(id)         -> { {label, width, fn} | {widget = frame, gap} } (buttons under the header)
--   Tabs(id, layer)     -> { {id, label, count, table = colset, rows, empty, keepOffset} | {id, label, custom}
--                          ; solo = true hides the tab buttons }
--   Columns[colset]; Custom[name](parent) -> frame with :Update(id, layer, tab)
--   Select(row, tab), Click(row, button), Open(row), RowTooltip(tooltip, row), KeyOf(row), EmptyText(id)
--   Query(id) -> the page's own filter text (lists), for P._State
--   live = false: no refresh on data changes; sticky = true: the selected row survives navigation;
--   noLayers = true: no layer switch
local P = {}
ns.Page = P

local L = ns.L
local W, C = ns.Widgets, ns.Charts

-- Window and book (about the size of the client's spellbook). The book starts under the top bar; SPLIT
-- is the spine. Text on the pages keeps clear of the book's edges and of the spine.
local WIDTH, HEIGHT = 1180, 720
local BOOK_TOP, BOOK_BOTTOM = 80, 4
local SPLIT = 648
local PAGE_TOP, PAGE_BOTTOM = 112, 40 -- text area of both pages, from the window's top / bottom edge
local LEFT_X, LEFT_R = 56, SPLIT - 36
P.PAGE_TOP, P.LEFT_X, P.LEFT_R = PAGE_TOP, LEFT_X, LEFT_R
local RIGHT_X, RIGHT_R = SPLIT + 36, WIDTH - 52
-- left page: heading (picture, title, subtitle), rule, info lines, rows of action buttons, content
local DIVIDER_Y, INFO_Y = PAGE_TOP + 52, PAGE_TOP + 66
local ACTIONS_Y = PAGE_TOP + 104
local ACTION_ROW, CONTENT_GAP = 28, 10
local PANEL_W = RIGHT_R - RIGHT_X
P.PANEL_W = PANEL_W
local MAX_HISTORY = 50
-- Room for the content on the left page (a table includes its scroll bar), table rows and row height.
P.CONTENT_W = LEFT_R - LEFT_X
P.ROW_H = 22
P.ROWS = math.floor((HEIGHT - ACTIONS_Y - ACTION_ROW - CONTENT_GAP - PAGE_BOTTOM) / P.ROW_H) - 1
-- table rows on the right page under a heading (e.g. the farming sessions)
P.PANEL_ROWS = math.floor((HEIGHT - PAGE_TOP - 30 - PAGE_BOTTOM) / P.ROW_H) - 1
-- The panels were laid out for 10-12 px fonts; positions are scaled for the larger page fonts.
P.SCALE = 1.3
local function Y(v) return math.floor(v * P.SCALE + 0.5) end
P.Y = Y

P.types = {}
P.layer = "all"
P.LAYER_LABEL = { all = L["All"], mine = L["Mine"], others = L["Community"] }

-- Section tabs under the window: a list (UI/Browser.lua) or a page. Item pages belong to Items (or
-- Auction house when opened from there), source pages to Sources.
P.SECTIONS = {
    { id = "items", label = L["Items"] },
    { id = "sources", label = L["Sources"] },
    { id = "ah", label = L["Auction house"] },
    { id = "farming", label = L["Farming"], farming = true },
    { id = "compare", label = L["Differences"], page = { type = "compare", id = "all" } },
    { id = "kpi", label = L["KPIs"], page = { type = "kpi", id = "all" } },
    { id = "search", label = L["Advanced search"], page = { type = "search", id = "all" } },
}

local f
local hist = { list = {}, pos = 0 }
local current
local section = "items"
local tables, customs = {}, {}
local actionButtons, actionWidgets = {}, {}
local pageWidgets = {}
local tabRows = {}
local selectedTab
local panelFrames = {}

function P.Register(kind, renderer) P.types[kind] = renderer end

local function Cur() return current and P.types[current.type] end

-- ---------------------------------------------------------------- shared formatting

local KIND_ICON = {
    mob = "Interface\\Icons\\INV_Misc_Head_Orc_01",
    herb = "Interface\\Icons\\INV_Misc_Flower_02",
    mine = "Interface\\Icons\\INV_Ore_Copper_01",
    skin = "Interface\\Icons\\INV_Misc_LeatherScrap_03",
    fish = "Interface\\Icons\\INV_Misc_Fish_02",
    pickpocket = "Interface\\Icons\\INV_Misc_Bag_11",
    lockpick = "Interface\\Icons\\INV_Box_01",
    object = "Interface\\Icons\\INV_Box_01",
    container = "Interface\\Icons\\INV_Misc_Bag_10",
    quest = "Interface\\GossipFrame\\AvailableQuestIcon",
    disenchant = "Interface\\Icons\\INV_Enchant_DustStrange",
    salvage = "Interface\\Icons\\INV_Misc_Gear_01",
}
P.KIND_ICON = KIND_ICON

-- Picture of a source for table rows: the NPC's still portrait (display id, kind "display") when known,
-- else the icon of its kind (raw kind key: "mob", "herb", ...).
function P.SourceIcon(key, kind)
    local npc = ns.Lookup.NpcId(key)
    local display = npc and ns.Portraits and ns.Portraits.DisplayId(npc)
    if display then return display, "display" end
    return KIND_ICON[kind] or KIND_ICON.mob
end

-- "5", "5-7", "5-7 elite"
function P.LevelText(r)
    if not r.lmin then return "" end
    local s = r.lmin == r.lmax and tostring(r.lmin) or (r.lmin .. "-" .. r.lmax)
    if r.cls then s = s .. " " .. (L[r.cls] or r.cls) end
    return s
end

-- Rate column text: quests show the quantity instead of a chance.
function P.RateText(r)
    if r.kind == "quest" then return r.choice and L["choice"] or L["always"] end
    return ns.Pct(r.rate)
end

function P.QtyText(r)
    if r.avgQty <= 0 then return "" end
    if math.abs(r.avgQty - math.floor(r.avgQty + 0.5)) < 0.05 then return "x" .. math.floor(r.avgQty + 0.5) end
    return string.format("x%.1f", r.avgQty)
end

-- Top zone of a source, computed once per row object.
function P.ZoneText(r)
    if r._zone == nil then
        local z = ns.Lookup.Zones(r.key, 1)[1]
        r._zone = z and z.name or ""
    end
    return r._zone
end

local CONF_LABEL = { none = L["no data"], low = L["unsure"], medium = L["fairly sure"], high = L["sure"] }
P.CONF_LABEL = CONF_LABEL

-- Bar cell for tables: the rate bar plus the personal rate when there is one.
function P.BarColumn(w)
    return {
        key = "lo",
        title = L["Chance"],
        w = w,
        create = function(row, width, height) return C.RateBar(row, width, math.max(6, height - 8)) end,
        render = function(bar, r)
            if r.kind == "quest" then
                bar:Set(nil)
                return
            end
            local m = r.mine
            local mine
            if m and m.n > 0 and r.layer ~= "mine" and m.n < r.n then
                local lo, hi = ns.Stats.Wilson(m.d, m.n)
                mine = { lo = lo, p = m.d / m.n, hi = hi, diff = r.diff }
            end
            bar:Set(r.lo, r.rate, r.hi, r.conf, mine)
        end,
    }
end

-- ---------------------------------------------------------------- analysis panel

local function Set(fs, text) fs:SetText(W.Ink(text or "")) end -- page text

-- Detailed view of one (source, item) row: big rate bar, you vs everyone else, chance after N
-- attempts, stack sizes, layer shares and the dry streak. Shared by item and source pages.
local function BuildAnalysis(parent)
    local a = CreateFrame("Frame", nil, parent)
    a:SetAllPoints(parent)
    a.row, a.openType, a.openId = false, false, false
    local x, w = 0, PANEL_W - 8
    local function Text(role, y, h)
        local fs = W.Text(a, role)
        fs:SetPoint("TOPLEFT", x, Y(y))
        fs:SetWidth(w)
        if h then fs:SetHeight(Y(h)) end
        fs:SetJustifyV("TOP")
        return fs
    end
    a.title = Text("heading", -8, 16)
    a.kind = Text("muted", -24, 12)
    a.bar = C.RateBar(a, w, Y(16))
    a.bar:SetPoint("TOPLEFT", x, Y(-42))
    -- scale under the rate bar: 0.1 %, 1 %, 10 %, 100 % at their places on the log scale
    a.scale = {}
    for i, label in ipairs({ "0.1%", "1%", "10%", "100%" }) do
        local fs = W.Text(a, "muted")
        fs:SetText(label)
        local px = x + w * (i - 1) / 3
        if i == 1 then
            fs:SetPoint("TOPLEFT", a, "TOPLEFT", px, Y(-60))
        elseif i == 4 then
            fs:SetPoint("TOPRIGHT", a, "TOPLEFT", px, Y(-60))
        else
            fs:SetPoint("TOP", a, "TOPLEFT", px, Y(-60))
        end
        a.scale[i] = fs
    end
    -- from here on each part sits under the one before (texts take the lines they need)
    local function Below(role, anchor, gap)
        local fs = W.Text(a, role)
        fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -gap)
        fs:SetWidth(w)
        fs:SetJustifyV("TOP")
        fs:SetSpacing(2)
        return fs
    end
    local LABELS_BELOW = 20 -- the charts' axis labels hang below them
    a.rate = Text("body", -74)
    a.rate:SetSpacing(2)
    a.curveLabel = Below("headingSmall", a.rate, Y(12))
    a.curve = C.Columns(a, w, Y(44))
    a.curve:SetPoint("TOPLEFT", a.curveLabel, "BOTTOMLEFT", 0, -4)
    a.curveText = Below("body", a.curve, LABELS_BELOW)
    a.stackLabel = Below("headingSmall", a.curveText, Y(10))
    a.stack = C.Columns(a, w, Y(36))
    a.stack:SetPoint("TOPLEFT", a.stackLabel, "BOTTOMLEFT", 0, -4)
    a.streak = Below("body", a.stack, LABELS_BELOW)
    -- at the bottom, where the numbers come from: share bar, one line per layer with its rate, the verdict
    a.layersLabel = Below("headingSmall", a.streak, Y(12))
    a.layers = C.Stack(a, w, Y(8))
    a.layers:SetPoint("TOPLEFT", a.layersLabel, "BOTTOMLEFT", 0, -5)
    a.layersText = Below("body", a.layers, 6)
    a.open = W.Button(a, L["Open source"], 124, function()
        if a.row then P.Show({ type = a.openType or "source", id = a.openId }) end
    end)
    a.open:SetPoint("BOTTOMLEFT", x, 0)
    a.map = W.Button(a, L["Show on map"], 124, function()
        if a.row and ns.MapPins and ns.MapPins.ShowSource then ns.MapPins.ShowSource(a.row.key, true) end
    end)
    a.map:SetPoint("LEFT", a.open, "RIGHT", 6, 0)
    a.empty = Text("body", -42, 120)
    return a
end

local function AttemptsWord(kind) return kind == "mob" and L["kills"] or L["attempts"] end

-- Colour code of a data layer, as in the share bar.
local function LayerHex(layer)
    local c = C.LAYER_COLOR[layer] or C.LAYER_COLOR.community
    return string.format("|cff%02x%02x%02x", c[1], c[2], c[3])
end

-- r: row from Lookup.Row; opts = { title =, kind =, openType =, openId = }
local function HidePanelFrames(except)
    for key, fr in pairs(panelFrames) do
        if key ~= except then fr:Hide() end
    end
    f.panelKey = except or false
end

function P.Analysis(r, opts)
    local a = f.analysis
    HidePanelFrames()
    f.preview:Hide()
    f.previewText = false
    a:Show()
    opts = opts or {}
    a.row = r or false
    for _, k in ipairs({ "title", "kind", "rate", "curveLabel", "curveText", "stackLabel" }) do
        a[k]:SetText("")
    end
    for _, fs in ipairs(a.scale) do
        fs:Hide()
    end
    if not r then
        for _, k in ipairs({ "bar", "curve", "stack", "layers", "open", "map" }) do
            a[k]:Hide()
        end
        a.layersLabel:SetText("")
        a.layersText:SetText("")
        a.streak:SetText("")
        Set(a.empty, opts.empty or L["Select a row to see the details."])
        return
    end
    a.empty:SetText("")
    a.openType, a.openId = opts.openType or false, opts.openId or false
    Set(a.title, opts.title or tostring(r.name))
    Set(a.kind, opts.kind or (ns.KIND_LABEL[r.kind] or r.kind))
    a.open:SetText(opts.openLabel or L["Open source"])
    a.open:Show()
    a.map:Show()
    local word = AttemptsWord(r.kind)
    local m, o = r.mine, r.others
    local item = ns.ItemName(r.itemId)
    if r.kind == "quest" then
        a.bar:Hide()
        Set(
            a.rate,
            string.format(
                "%s · %s %s (%d %s)",
                r.choice and L["Choice reward"] or L["Always rewarded"],
                L["Avg"],
                P.QtyText(r),
                r.n,
                L["turn-ins"]
            )
        )
    else
        a.bar:Show()
        local mine
        if m.n > 0 and r.layer ~= "mine" and m.n < r.n then
            local lo, hi = ns.Stats.Wilson(m.d, m.n)
            mine = { lo = lo, p = m.d / m.n, hi = hi, diff = r.diff }
        end
        a.bar:Set(r.lo, r.rate, r.hi, r.conf, mine)
        for _, fs in ipairs(a.scale) do
            fs:Show()
        end
        -- the rate, what it is made of, and how sure it is
        Set(
            a.rate,
            string.format("%s · %s", ns.Pct(r.rate), CONF_LABEL[r.conf] or r.conf)
                .. "\n"
                .. string.format(L["%s, %d of them with %s"], ns.Report.CountWord(r.n, r.kind), r.d, item)
                .. "\n"
                .. string.format(L["probably between %s and %s (95%% sure)"], ns.Pct(r.lo), ns.Pct(r.hi))
        )
    end

    -- where the numbers come from: who saw how many kills (share bar), how often the item came with
    -- them, and how the player's own rate compares with everyone else's
    local parts = r.parts
    if not parts then -- one side shown (Mine / Community): the player against everyone else
        parts = {}
        if m.n > 0 then parts[#parts + 1] = { layer = "me", n = m.n, d = m.d } end
        if o.n > 0 then parts[#parts + 1] = { layer = "others", n = o.n, d = o.d } end
    end
    if #parts > 0 then
        local segs = {}
        for _, part in ipairs(parts) do
            segs[#segs + 1] = { v = part.n, color = C.LAYER_COLOR[part.layer] or C.LAYER_COLOR.community }
        end
        a.layersLabel:SetText(L["Where the numbers come from"])
        a.layers:Set(segs)
        a.layers:Show()
        local lines = {}
        for _, e in ipairs(ns.Report.PartsLines(parts, r.kind, item)) do
            lines[#lines + 1] = LayerHex(e.layer) .. e.label .. ":|r " .. e.text
        end
        if m.n == 0 and r.kind ~= "quest" and r.layer ~= "others" then
            table.insert(lines, 1, LayerHex("me") .. L["Your data"] .. ":|r " .. L["no own data yet"])
        end
        if m.n > 0 and o.n > 0 and r.kind ~= "quest" then
            if r.diff > 0 then
                lines[#lines + 1] = "|cff46dc5a" .. L["Your rate is clearly higher than everyone else's."] .. "|r"
            elseif r.diff < 0 then
                lines[#lines + 1] = "|cffeb5046" .. L["Your rate is clearly lower than everyone else's."] .. "|r"
            end
            if r.luck then
                lines[#lines + 1] =
                    string.format(L["Luckier than %s of players with as many %s."], ns.Pct(r.luck), word)
            end
        end
        if r.gated then lines[#lines + 1] = L["Quest item: only counted while its quest was active."] end
        Set(a.layersText, table.concat(lines, "\n"))
    else
        a.layersLabel:SetText("")
        a.layers:Hide()
        a.layersText:SetText("")
    end

    -- chance after N attempts
    local p = r.rate
    if r.kind ~= "quest" and p > 0 and p < 1 then
        local k50, k90, k99 = ns.Stats.AttemptsFor(p, 0.5), ns.Stats.AttemptsFor(p, 0.9), ns.Stats.AttemptsFor(p, 0.99)
        local bars, step = {}, math.max(1, math.ceil(k99 / 24))
        local marks = {}
        for i = 1, 24 do
            local k = i * step
            bars[i] = { v = ns.Stats.CumChance(p, k) }
            if k >= k50 and k - step < k50 then marks[i] = true end
            if k >= k90 and k - step < k90 then marks[i] = true end
        end
        a.curveLabel:SetText(string.format(L["Chance after N %s"], word))
        a.curve:Set(bars, { max = 1, left = "1", right = tostring(24 * step), marks = marks })
        a.curve:Show()
        a.curveText:SetText(string.format("50%%: %d · 90%%: %d · 99%%: %d %s", k50, k90, k99, word))
    else
        a.curve:Hide()
    end

    -- stack sizes, personal share overlaid
    local qty = ns.Report.Qty(r.key, r.itemId)
    if qty.max and qty.max > 1 then
        local mineTotal = 0
        for _, cnt in pairs(m.h or {}) do
            mineTotal = mineTotal + cnt
        end
        local bars = {}
        for i, e in ipairs(qty.dist) do
            if i > 20 then break end
            bars[i] = { v = e.share, v2 = mineTotal > 0 and (m.h[e.size] or 0) / mineTotal or nil }
        end
        a.stackLabel:SetText(L["Stack sizes"] .. "  " .. ns.Report.QtyRange(qty))
        a.stack:Set(bars, {
            left = tostring(qty.dist[1].size),
            right = tostring(qty.dist[math.min(20, #qty.dist)].size),
        })
        a.stack:Show()
    else
        a.stack:Hide()
    end

    if r.streak and r.streak > 0 and p > 0 and r.kind ~= "quest" then
        a.streak:SetText(
            string.format(
                L["Dry streak: %d %s (chance of a streak this long: %s)"],
                r.streak,
                word,
                ns.Pct(ns.Stats.PNoDrop(p, r.streak))
            )
        )
    else
        a.streak:SetText("")
    end
end

-- The panel as a scrolling text (list previews).
function P.Preview(text)
    if not f then return end
    HidePanelFrames()
    f.analysis:Hide()
    f.analysis.row = false
    f.preview:Show()
    f.preview:SetText(W.Ink(text or ""))
    f.previewText = text or ""
end

-- Side panel content owned by a page type (e.g. the KPI charts): built once by build(panel), shown
-- instead of the analysis and the preview. Returns the frame.
function P.ShowPanel(key, build)
    local fr = panelFrames[key]
    if not fr then
        fr = build(f.panel)
        panelFrames[key] = fr
    end
    f.analysis:Hide()
    f.analysis.row = false
    f.preview:Hide()
    f.previewText = false
    HidePanelFrames(key)
    fr:Show()
    return fr
end

-- ---------------------------------------------------------------- tables and tabs

local function KeyOf(r)
    local renderer = Cur()
    if renderer and renderer.KeyOf then return renderer.KeyOf(r) end
    return tostring(r.key) .. "|" .. tostring(r.itemId)
end

-- One table per column set, shared by every page that uses it; callbacks go to the page shown.
local function TableFor(colset)
    local t = tables[colset]
    if t then return t end
    local owner = Cur()
    t = C.Table(f.content, owner.Columns[colset], {
        rows = P.ROWS,
        rowH = P.ROW_H,
        width = P.CONTENT_W,
        keyOf = KeyOf,
        onClick = function(r, button)
            local renderer = Cur()
            if renderer.Click then return renderer.Click(r, button) end
            if button == "RightButton" then
                if renderer.Open then renderer.Open(r) end
            elseif renderer.Select then
                renderer.Select(r)
            end
        end,
        onDoubleClick = function(r)
            local renderer = Cur()
            if renderer.Open then renderer.Open(r) end
        end,
        onEnter = function(row, r)
            local renderer = Cur()
            if renderer.RowTooltip and GameTooltip then
                GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                renderer.RowTooltip(GameTooltip, r)
                GameTooltip:Show()
            end
        end,
        onLeave = function()
            if GameTooltip then GameTooltip:Hide() end
        end,
    })
    t:SetPoint("TOPLEFT", 0, 0)
    t.sticky = owner.sticky or false
    tables[colset] = t
    return t
end

local function HideContent()
    for _, t in pairs(tables) do
        t:Hide()
    end
    for _, c in pairs(customs) do
        c:Hide()
    end
end

-- The content starts under the rows of action buttons; tables show as many rows as fit.
local function ContentTop(actionRows)
    return ACTIONS_Y + actionRows * ACTION_ROW + (actionRows > 0 and CONTENT_GAP - (ACTION_ROW - 22) or 0)
end

local function Layout(actionRows)
    local top = ContentTop(actionRows)
    f.contentTop = top
    f.content:ClearAllPoints()
    f.content:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT_X, -top)
    f.content:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", LEFT_R, PAGE_BOTTOM)
end

local function VisibleRows() return math.floor((HEIGHT - f.contentTop - PAGE_BOTTOM) / P.ROW_H) - 1 end

local function SelectTab(id)
    selectedTab = id
    local renderer = P.types[current.type]
    local tab
    for _, t in ipairs(tabRows) do
        if t.id == id then tab = t end
    end
    HideContent()
    if not tab then
        P.Analysis(nil, { empty = renderer.EmptyText and renderer.EmptyText(current.id) })
        return
    end
    if tab.custom then
        local c = customs[tab.custom]
        if not c then
            c = renderer.Custom[tab.custom](f.content)
            customs[tab.custom] = c
        end
        c:Show()
        c:Update(current.id, P.layer, tab)
        if renderer.Select then renderer.Select(nil, tab) end
        return
    end
    local t = TableFor(tab.table)
    t:SetVisibleRows(VisibleRows())
    t:Show()
    t.keepOffset = tab.keepOffset or false
    t:SetData(tab.rows, tab.empty)
    t.keepOffset = false
    if not t.selected and t.data[1] then
        t.selected = t.data[1]
        t:Render()
    end
    if renderer.Select then renderer.Select(t.selected, tab) end
end

function P.SelectedRow()
    for _, t in pairs(tables) do
        if t:IsShown() then return t.selected end
    end
    return nil
end

-- ---------------------------------------------------------------- refresh

local function SetLayerButtons(show)
    for _, b in ipairs(f.layerButtons) do
        if not show then
            b:Hide()
        else
            b:Show()
            if b.layer == P.layer then
                b:LockHighlight()
            else
                b:UnlockHighlight()
            end
        end
    end
end

local function Footer()
    local c = ns.Store.Community()
    local parts = {}
    if c and (c.generated or 0) > 0 then
        local n = 0
        for _ in pairs(c.contributors or {}) do
            n = n + 1
        end
        parts[#parts + 1] =
            string.format(L["Community data from %s, %d contributors"], ns.date("%Y-%m-%d", c.generated), n)
    else
        parts[#parts + 1] = L["No community data in this version."]
    end
    if not ns.db.settings.useCommunity then parts[#parts + 1] = L["community data switched off"] end
    local done, total = ns.Lookup.WarmProgress()
    if done then parts[#parts + 1] = string.format(L["loading item names %d/%d"], done, total) end
    f.footer:SetText(table.concat(parts, " · "))
end

-- A visible unit token for this npc id (for a real portrait), or nil.
local function UnitFor(npc)
    for _, unit in ipairs({ "npc", "target", "mouseover", "focus" }) do
        local guid = ns.Call(UnitGUID, unit)
        if guid and ns.GuidType(guid) == "Creature" and ns.GuidId(guid) == npc then return unit end
    end
    return nil
end

-- Header picture of an NPC: a still portrait of its 3D model (UI/Portraits.lua resolves the creature's
-- display id), else its portrait when it is around, else its model frozen on the first frame; for
-- everything else the item / kind icon.
local function SetPicture(h)
    f.model:Hide()
    f.icon:Show()
    f.icon.tex:SetAlpha(1)
    f.picture = "icon"
    if h.npc then
        local display = ns.Portraits and ns.Portraits.DisplayId(h.npc)
        if display then
            C.SetIcon(f.icon.tex, display, "display")
            f.picture = "portrait"
            return
        end
        local unit = UnitFor(h.npc)
        if unit and SetPortraitTexture then
            SetPortraitTexture(f.icon.tex, unit)
            f.icon.tex:SetTexCoord(0, 1, 0, 1)
            f.picture = "portrait"
            return
        end
        if f.model.SetCreature and pcall(f.model.SetCreature, f.model, h.npc) then
            pcall(f.model.SetPortraitZoom, f.model, 1)
            if f.model.FreezeAnimation then pcall(f.model.FreezeAnimation, f.model, 0, 0, 0) end
            f.model:Show()
            C.SetIcon(f.icon.tex, h.icon)
            -- keep the icon until the model has loaded (when the client tells us), else hide it now
            if not (f.model.HasScript and f.model:HasScript("OnModelLoaded")) then f.icon.tex:SetAlpha(0) end
            f.picture = "model"
            return
        end
    end
    C.SetIcon(f.icon.tex, h.icon)
end

-- Action buttons (and widgets) under the page heading, in rows across the left page. Returns the
-- number of rows used.
local function SetActions(renderer)
    local actions = renderer.Actions and renderer.Actions(current.id) or {}
    local nButtons, rows, x = 0, 0, LEFT_X
    local used = {}
    for _, act in ipairs(actions) do
        local b
        if act.widget then
            b = act.widget
            actionWidgets[b] = true
            used[b] = true
        else
            nButtons = nButtons + 1
            b = actionButtons[nButtons]
            if not b then
                b = W.Button(f.pageLayer, "", 100)
                b:SetHeight(22)
                actionButtons[nButtons] = b
            end
            b:SetText(act.label)
            -- translations are often longer than the English label
            local fs = b:GetFontString()
            local textW = fs and fs:GetStringWidth() or 0
            b:SetWidth(math.max(act.width or 100, math.ceil(textW) + 24))
            b:SetScript("OnClick", act.fn)
        end
        local w = type(b.flowWidth) == "number" and b.flowWidth or b:GetWidth() or 100
        local gap = act.gap or 4
        if rows == 0 then
            rows, x = 1, LEFT_X + (act.gap or 0)
        elseif x + gap + w > LEFT_R then
            rows, x = rows + 1, LEFT_X
        else
            x = x + gap
        end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(ACTIONS_Y + (rows - 1) * ACTION_ROW))
        b:Show()
        x = x + w
    end
    for i = nButtons + 1, #actionButtons do
        actionButtons[i]:Hide()
    end
    for w in pairs(actionWidgets) do
        if not used[w] then w:Hide() end
    end
    return rows
end

-- Extra controls owned by a page type (e.g. the "Bags only" box of the lists): shown while
-- visible(entry) is true for the page on screen.
function P.AddWidget(frame, visible) pageWidgets[#pageWidgets + 1] = { frame = frame, visible = visible } end

local sectionsFarming
local function SetSections()
    local farming = ns.FarmingOn()
    if sectionsFarming ~= farming then
        sectionsFarming = farming
        local list = {}
        for _, s in ipairs(P.SECTIONS) do
            if farming or not s.farming then list[#list + 1] = s end
        end
        f.sections:Set(list)
    end
    f.sections:Select(section)
end

function P.Refresh()
    if not f or not current then return end
    local renderer = P.types[current.type]
    local prev = ns.context
    ns.context = "page " .. current.type .. " " .. tostring(current.id)
    if renderer.Prepare then renderer.Prepare(current.id, P.layer) end
    local h = renderer.Header(current.id, P.layer)
    f.header = h
    SetPicture(h)
    f.icon.link = h.link
    Set(f.titleText, h.title or "?")
    Set(f.sub, h.sub)
    Set(f.info, h.info)
    Layout(SetActions(renderer))
    for _, pw in ipairs(pageWidgets) do
        if pw.visible(current) then
            pw.frame:Show()
        else
            pw.frame:Hide()
        end
    end
    -- tabs
    tabRows = renderer.Tabs(current.id, P.layer)
    local list = {}
    local solo = #tabRows == 1 and tabRows[1].solo
    if not solo then
        for i, t in ipairs(tabRows) do
            list[i] = { id = t.id, label = t.count and string.format("%s (%d)", t.label, t.count) or t.label }
        end
    end
    f.tabs:Set(list)
    local keep = selectedTab
    local found = false
    for _, t in ipairs(tabRows) do
        if t.id == keep then found = true end
    end
    if not keep or not found then keep = tabRows[1] and tabRows[1].id end
    f.tabs:Select(keep, true)
    SelectTab(keep)
    SetLayerButtons(not renderer.noLayers)
    SetSections()
    f.back:SetEnabled(hist.pos > 1)
    f.forward:SetEnabled(hist.pos < #hist.list)
    Footer()
    f.shownRev = ns.db.meta.rev
    ns.context = prev
end

local pending
local function Schedule()
    if not f or not f:IsShown() or pending then return end
    local renderer = Cur()
    if renderer and renderer.live == false then return end
    pending = true
    ns.After(2, function()
        pending = false
        local r = Cur()
        if f and f:IsShown() and not (r and r.live == false) then P.Refresh() end
    end)
end
for _, ev in ipairs({ "DATA_CHANGED", "PRICES_UPDATED", "SETTINGS_CHANGED", "GOALS_CHANGED" }) do
    ns.On(ev, Schedule)
end
ns.RegisterEvent("GET_ITEM_INFO_RECEIVED", function() Schedule() end)
-- Empty corpses and kills change counts without a DATA_CHANGED event.
ns.Every(5, function()
    local renderer = Cur()
    if f and f:IsShown() and f.shownRev ~= ns.db.meta.rev and not (renderer and renderer.live == false) then
        P.Refresh()
    end
end)

-- ---------------------------------------------------------------- navigation

local function Same(a, b) return a and b and a.type == b.type and a.id == b.id end

local function SectionOf(entry)
    if entry.type == "list" then return entry.id end
    if entry.type == "item" then return section == "ah" and "ah" or "items" end
    if entry.type == "source" or entry.type == "spell" then return "sources" end
    return entry.type
end

-- entry = { type = "item" | "source" | "spell" | "list" | "compare", id = itemId | sourceKey | spellId | list id,
--           tab = }
function P.Show(entry, noHistory)
    if not entry or entry.id == nil or not P.types[entry.type] then return false end
    if not ns.db then return false end
    P.Create()
    if not noHistory then
        for i = #hist.list, hist.pos + 1, -1 do
            hist.list[i] = nil
        end
        if not Same(hist.list[hist.pos], entry) then
            hist.list[#hist.list + 1] = { type = entry.type, id = entry.id }
            if #hist.list > MAX_HISTORY then table.remove(hist.list, 1) end
        end
        hist.pos = #hist.list
    end
    if not Same(current, entry) then selectedTab = entry.tab end
    if entry.tab then selectedTab = entry.tab end
    section = SectionOf(entry)
    current = { type = entry.type, id = entry.id }
    for _, t in pairs(tables) do
        if not t.sticky then t.selected = false end
    end
    f.resultsFrame:Hide()
    f:Show()
    P.Refresh()
    return true
end

function P.Back()
    if hist.pos <= 1 then return end
    hist.pos = hist.pos - 1
    P.Show(hist.list[hist.pos], true)
end

function P.Forward()
    if hist.pos >= #hist.list then return end
    hist.pos = hist.pos + 1
    P.Show(hist.list[hist.pos], true)
end

function P.SetLayer(layer)
    P.layer = layer
    if f and f:IsShown() then P.Refresh() end
end

function P.Hide()
    if f then f:Hide() end
end

function P.IsShown() return f and f:IsShown() or false end

-- The page on screen ({ type =, id = }) or nil.
function P.Current() return P.IsShown() and current or nil end

-- Closes the window, or opens it again on the last page (else on `home`).
function P.Toggle(home)
    if f and f:IsShown() then
        f:Hide()
        return false
    end
    if current then
        f:Show()
        P.Refresh()
        return true
    end
    return P.Show(home)
end

-- Item under the mouse (any tooltip showing an item), else a chest / herb / vein under the mouse
-- (by the name in its tooltip), else the NPC under the mouse or targeted.
function P.OpenHovered()
    local id
    if GameTooltip and GameTooltip:IsShown() then
        if TooltipUtil and TooltipUtil.GetDisplayedItem then
            local ok, _, link = pcall(TooltipUtil.GetDisplayedItem, GameTooltip)
            if ok then id = ns.ItemIdFromLink(link) end
        end
        if not id and GameTooltip.GetItem then
            local _, link = GameTooltip:GetItem()
            id = ns.ItemIdFromLink(link)
        end
    end
    if id then return P.Show({ type = "item", id = id }) end
    local object = ns.HoveredObjectName()
    local objects = object and ns.Lookup.ObjectsByName(object) or {}
    if objects[1] then return P.Show({ type = "source", id = objects[1] }) end
    for _, unit in ipairs({ "mouseover", "target" }) do
        local guid = ns.Call(UnitGUID, unit)
        local gt = ns.GuidType(guid)
        if gt == "Creature" or gt == "Vehicle" then
            local key = ns.GuidId(guid)
            if key then return P.Show({ type = "source", id = key }) end
        end
    end
    ns.Print(L["Hover over an item or NPC first."])
    return false
end

-- ---------------------------------------------------------------- search

local function RunSearch()
    local q = f.search:GetText() or ""
    local res = ns.Lookup.Search(q, #f.results)
    for i, b in ipairs(f.results) do
        local e = res[i]
        b.entry = e
        if e then
            local label
            if e.type == "item" then
                label = ns.ItemName(e.id, true)
            elseif e.type == "spell" then
                label = tostring(e.name)
                if e.rank then label = label .. " (" .. e.rank .. ")" end
                if e.level then label = label .. " · " .. L["Level"] .. " " .. e.level end
                label = label .. " |cff888888(" .. (e.recipe and L["Recipe"] or L["Spell"]) .. ")|r"
            else
                label = tostring(e.name) .. " |cff888888(" .. (ns.KIND_LABEL[e.kind] or tostring(e.kind)) .. ")|r"
            end
            b.text:SetText(label)
            b:Show()
        else
            b:Hide()
        end
    end
    if res[1] then
        f.resultsFrame:Show()
    else
        f.resultsFrame:Hide()
    end
    return res
end

local function Pick(e)
    if not e then return end
    f.resultsFrame:Hide()
    f.search:SetText("")
    f.search:ClearFocus()
    if e.type == "item" or e.type == "spell" then
        P.Show({ type = e.type, id = e.id })
    else
        P.Show({ type = "source", id = e.key })
    end
end

function P.Search(text)
    P.Create()
    f.search:SetText(text or "")
    return RunSearch()
end

-- ---------------------------------------------------------------- construction

local function ToolButton(label, fn)
    local b = W.Button(f, label, 84, fn)
    b:SetHeight(20)
    return b
end

function P.Create()
    if f then return f end
    f = W.JournalWindow("WorldCodexFrame", "WorldCodex", WIDTH, HEIGHT, "Interface\\Icons\\INV_Misc_Book_09")
    f.shownRev = -1
    f.previewText = false
    f.panelKey = false

    -- top bar, first row: history and data status (right of the portrait), layer switch and search
    f.back = W.Button(f, "<", 26, P.Back)
    f.back:SetPoint("TOPLEFT", 64, -28)
    f.forward = W.Button(f, ">", 26, P.Forward)
    f.forward:SetPoint("LEFT", f.back, "RIGHT", 2, 0)
    f.footer = W.Text(f, "frameMuted")
    f.footer:SetPoint("LEFT", f.forward, "RIGHT", 12, 0)
    f.footer:SetWidth(500)
    f.footer:SetWordWrap(false)

    -- the open book under the top bar; everything on its pages lives on f.pageLayer (above the book)
    f.book = W.Book(f)
    f.book:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -BOOK_TOP)
    f.book:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -3, BOOK_BOTTOM)
    f.book:SetSplit(SPLIT - 3)
    f.pageLayer = CreateFrame("Frame", nil, f.book)
    f.pageLayer:SetAllPoints(f)

    -- left page: the page heading (picture, title, subtitle), a rule and the info line
    local pl = f.pageLayer
    f.icon = W.Icon(pl, 40)
    f.icon:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT_X + 8, -PAGE_TOP)
    W.IconFrame(f.icon)
    f.icon:SetScript("OnEnter", function(self)
        if self.link and GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.link)
            GameTooltip:Show()
        end
    end)
    f.icon:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
    f.icon.link = false
    f.model = CreateFrame("PlayerModel", nil, pl)
    f.model:SetSize(40, 40)
    f.model:SetPoint("TOPLEFT", f.icon, "TOPLEFT", 0, 0)
    f.model:Hide()
    if f.model.HasScript and f.model:HasScript("OnModelLoaded") then
        f.model:SetScript("OnModelLoaded", function(self)
            -- a still picture: the first frame of the standing animation
            if self.FreezeAnimation then pcall(self.FreezeAnimation, self, 0, 0, 0) end
            f.icon.tex:SetAlpha(0)
        end)
    end
    f.picture = "icon"
    f.header = false
    f.titleText = W.Text(pl, "pageTitle")
    f.titleText:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 16, -1)
    f.titleText:SetWidth(P.CONTENT_W - 64)
    f.titleText:SetWordWrap(false)
    f.sub = W.Text(pl, "muted")
    f.sub:SetPoint("TOPLEFT", f.titleText, "BOTTOMLEFT", 0, -5)
    f.sub:SetWidth(P.CONTENT_W - 64)
    f.sub:SetWordWrap(false)
    f.divider = W.Divider(pl, LEFT_X - 24, LEFT_R + 4, -DIVIDER_Y)
    f.info = W.Text(pl, "body")
    f.info:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT_X, -INFO_Y)
    f.info:SetWidth(P.CONTENT_W)
    f.info:SetHeight(ACTIONS_Y - INFO_Y - 6)
    f.info:SetSpacing(2)
    f.info:SetJustifyV("TOP")

    -- search: the same on every page and list; finds items and sources and jumps to their page through
    -- a result dropdown
    f.search = W.SearchBox(f, 210, RunSearch, L["Search items and sources"])
    f.search:SetPoint("TOPRIGHT", -34, -29)
    if not f.search.blizzard then
        f.searchHint = W.Text(f, "frameMuted")
        f.searchHint:SetPoint("RIGHT", f.search, "LEFT", -8, 0)
        f.searchHint:SetText(L["Search"])
    end
    f.resultsFrame = CreateFrame("Frame", nil, f, W.BACKDROP_TEMPLATE)
    W.ApplyBackdrop(f.resultsFrame, 0.97)
    f.resultsFrame:SetPoint("TOPRIGHT", f.search, "BOTTOMRIGHT", 4, -2)
    f.resultsFrame:SetSize(300, 10 * 18 + 12)
    f.resultsFrame:SetFrameLevel((f:GetFrameLevel() or 1) + 30)
    f.resultsFrame:Hide()
    f.results = {}
    for i = 1, 10 do
        local b = CreateFrame("Button", nil, f.resultsFrame)
        b:SetSize(288, 18)
        b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 18)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        W.Color(hl, 1, 1, 1, 0.1)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", 2, 0)
        b.text:SetWidth(284)
        b.text:SetJustifyH("LEFT")
        b:SetScript("OnClick", function(self) Pick(self.entry) end)
        f.results[i] = b
    end
    local token = 0
    W.OnEdit(f.search, "OnTextChanged", function(_, user)
        if not user then return end
        token = token + 1
        local mine = token
        ns.After(0.25, function()
            if mine == token then RunSearch() end
        end)
    end)
    f.search:SetScript("OnEnterPressed", function(self)
        token = token + 1
        self:ClearFocus()
        Pick(RunSearch()[1])
    end)
    W.OnEdit(f.search, "OnEditFocusGained", function() ns.Lookup.WarmNames() end)

    -- layer switch left of the search box
    f.layerButtons = {}
    local prevLayer
    for i = #ns.Lookup.LAYERS, 1, -1 do
        local layer = ns.Lookup.LAYERS[i]
        local b = W.Button(f, P.LAYER_LABEL[layer], 84, function() P.SetLayer(layer) end)
        b:SetHeight(20)
        b.layer = layer
        if prevLayer then
            b:SetPoint("RIGHT", prevLayer, "LEFT", -2, 0)
        else
            b:SetPoint("RIGHT", f.search, "LEFT", -16, 0)
        end
        prevLayer = b
        f.layerButtons[#f.layerButtons + 1] = b
    end

    -- top bar, second row: page tabs standing on the book, tools on the right
    f.tabAnchor = CreateFrame("Frame", nil, f)
    f.tabAnchor:SetSize(10, 22)
    f.tabAnchor:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT_X + 4, -(BOOK_TOP - 22))
    f.tabs = W.Tabs(f, function(id) SelectTab(id) end)
    f.tabs.anchor = f.tabAnchor
    local opt = ToolButton(L["Options"], function()
        if ns.Options then ns.Options.Open() end
    end)
    opt:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -(BOOK_TOP - 26))
    local imp = ToolButton(L["Import"], function() ns.UI.ShowImport() end)
    imp:SetPoint("RIGHT", opt, "LEFT", -4, 0)
    local exp = ToolButton(L["Export"], function() ns.UI.ShowExport("string") end)
    exp:SetPoint("RIGHT", imp, "LEFT", -4, 0)

    -- content on the left page, the side panel is the right page
    f.content = CreateFrame("Frame", nil, pl)
    f.panel = CreateFrame("Frame", nil, pl)
    f.panel:SetPoint("TOPLEFT", f, "TOPLEFT", RIGHT_X, -PAGE_TOP)
    f.panel:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", RIGHT_R, PAGE_BOTTOM)
    f.analysis = BuildAnalysis(f.panel)
    f.preview = W.ScrollText(f.panel, true, W.Font("bodyLarge"))
    f.preview:SetPoint("TOPLEFT", 0, 0)
    f.preview:SetPoint("BOTTOMRIGHT", -26, 0)
    f.preview:Hide()
    Layout(0)

    -- section tabs under the window
    f.sections = W.BottomTabs(f, function(id)
        for _, s in ipairs(P.SECTIONS) do
            if s.id == id then return P.Show(s.page or { type = "list", id = id }) end
        end
    end)

    f:SetScript("OnHide", function()
        if f.resultsFrame then f.resultsFrame:Hide() end
    end)
    return f
end

function P.Frame() return P.Create() end

-- Redraws the table rows on screen (e.g. after item names arrived) without rebuilding the page.
function P.RenderRows()
    if not f or not f:IsShown() then return end
    for _, t in pairs(tables) do
        if t:IsShown() then t:Render() end
    end
    Footer()
end

-- New NPC portraits (UI/Portraits.lua): redraw the rows and the heading picture.
ns.On("PORTRAITS", function()
    if not f or not f:IsShown() then return end
    P.RenderRows()
    if f.header and f.header.npc and f.picture ~= "portrait" then SetPicture(f.header) end
end)

-- For tests and debugging: what the page currently shows.
function P._State()
    if not f or not current then return {} end
    local tabIds = {}
    for i, t in ipairs(tabRows) do
        tabIds[i] = t.id
    end
    local shownRows
    for _, t in pairs(tables) do
        if t:IsShown() then shownRows = t.data end
    end
    return {
        type = current.type,
        id = current.id,
        layer = P.layer,
        tab = selectedTab,
        tabs = tabIds,
        rows = shownRows or {},
        pos = hist.pos,
        history = #hist.list,
        title = f.titleText:GetText(),
        sub = f.sub:GetText(),
        info = f.info:GetText(),
        shown = f:IsShown(),
        analysis = f.analysis.row,
        preview = f.previewText,
        picture = f.picture,
        section = section,
        search = f.search:GetText(),
        filter = Cur() and Cur().Query and Cur().Query(current.id) or nil,
        chrome = f.chrome,
        panel = f.panelKey,
        details = f.panelKey == "details" and P.details or nil,
    }
end

-- Key binding labels (Bindings.xml).
BINDING_HEADER_WORLDCODEX = "WorldCodex"
BINDING_NAME_WORLDCODEX_HOVER = L["Open the WorldCodex page of the item or NPC under the mouse"]

return P
