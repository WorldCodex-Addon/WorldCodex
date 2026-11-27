local _, ns = ...

-- Facts laid out on a book page: an item's or a source's facts (Report.ItemFacts / SourceFacts) on the
-- right page next to the lists, the farming session on the left page. An optional heading with icon and
-- a muted subtitle, then sections: a small heading over a rule, label/value rows (value right-aligned),
-- entries (name and value on one line, a muted line below) and notes. Clicking an entry opens its page;
-- item entries show the item tooltip.
local D = {}
ns.Details = D

local W = ns.Widgets
local P = ns.Page

local SCROLLBAR = 26
local LABEL_W = 150
local RATE_W = 72
local SECTION_GAP = 16
local ROW_GAP = 4
local ENTRY_GAP = 8

-- A scrolling facts frame over all of `parent`, `width` wide (scroll bar included); filled by D.Render.
function D.Frame(parent, width)
    local fr = CreateFrame("Frame", nil, parent)
    fr:SetAllPoints(parent)
    local scroll = CreateFrame("ScrollFrame", nil, fr, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR, 0)
    local child = CreateFrame("Frame", nil, scroll)
    fr.width = width - SCROLLBAR - 6
    child:SetSize(fr.width, 10)
    scroll:SetScrollChild(child)
    fr.scroll, fr.child = scroll, child
    fr.pools = { fs = {}, line = {}, button = {} }
    fr.used = { fs = 0, line = 0, button = 0 }
    return fr
end

local function Text(fr, role, wrap, justify)
    fr.used.fs = fr.used.fs + 1
    local fs = fr.pools.fs[fr.used.fs]
    if not fs then
        fs = fr.child:CreateFontString(nil, "OVERLAY")
        fr.pools.fs[fr.used.fs] = fs
    end
    fs:SetFontObject(W.Font(role))
    fs:ClearAllPoints()
    fs:SetJustifyH(justify or "LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(wrap and true or false)
    fs:Show()
    return fs
end

local function Rule(fr, y, width)
    fr.used.line = fr.used.line + 1
    local t = fr.pools.line[fr.used.line]
    if not t then
        t = fr.child:CreateTexture(nil, "ARTWORK")
        local c = W.PAPER.tick
        W.Color(t, c[1], c[2], c[3], 0.35)
        fr.pools.line[fr.used.line] = t
    end
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", fr.child, "TOPLEFT", 0, -y)
    t:SetSize(width, 1)
    t:Show()
end

local function OpenEntry(row)
    if row.key ~= nil then return P.Show({ type = "source", id = row.key }) end
    if row.itemId then return P.Show({ type = "item", id = row.itemId }) end
end

-- Invisible button over an entry: highlight on hover, opens the page on click.
local function EntryButton(fr, y, height, width, row)
    fr.used.button = fr.used.button + 1
    local b = fr.pools.button[fr.used.button]
    if not b then
        b = CreateFrame("Button", nil, fr.child)
        local hl = b:CreateTexture(nil, "BACKGROUND")
        hl:SetAllPoints(b)
        local c = W.PAPER.hover
        W.Color(hl, c[1], c[2], c[3], c[4])
        hl:Hide()
        b.hl = hl
        b:SetScript("OnEnter", function(self)
            self.hl:Show()
            if self.row and self.row.itemId and GameTooltip and GameTooltip.SetItemByID then
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                GameTooltip:SetItemByID(self.row.itemId)
                GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave", function(self)
            self.hl:Hide()
            if GameTooltip then GameTooltip:Hide() end
        end)
        b:SetScript("OnClick", function(self)
            if not self.row then return end
            if self.row.itemId and IsShiftKeyDown and IsShiftKeyDown() and ChatEdit_InsertLink then
                ChatEdit_InsertLink(ns.ItemLink(self.row.itemId))
                return
            end
            OpenEntry(self.row)
        end)
        fr.pools.button[fr.used.button] = b
    end
    b.row = row
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", fr.child, "TOPLEFT", -2, -(y - 1))
    b:SetSize(width + 4, height + 2)
    b:Show()
end

-- Sets the text, places it at (x, -y) and returns its height.
local function Place(fr, fs, x, y, width, text)
    fs:SetWidth(width)
    fs:SetText(W.Ink(text or ""))
    fs:SetPoint("TOPLEFT", fr.child, "TOPLEFT", x, -y)
    return fs:GetStringHeight() or 12
end

-- Lays out facts = { title =, icon =, subtitle =, sections = { {title =, rows = {...}} } } in fr (from
-- D.Frame); title and subtitle are optional. Rows: { label =, value = } | { entry = true, name =, value =,
-- sub =, tag =, weak =, icon =, key = | itemId = } | { note = }. Shift-click on an item entry links it.
function D.Render(fr, facts)
    for _, pool in pairs(fr.pools) do
        for _, x in ipairs(pool) do
            x:Hide()
            x.row = nil
        end
    end
    fr.used.fs, fr.used.line, fr.used.button = 0, 0, 0
    local width = fr.width
    local y = 0
    if facts.title then
        local icon = facts.icon and ("|T" .. facts.icon .. ":20:20:0:0|t ") or ""
        y = y + Place(fr, Text(fr, "heading", true), 0, y, width, icon .. tostring(facts.title)) + 2
    end
    if facts.subtitle and facts.subtitle ~= "" then
        y = y + Place(fr, Text(fr, "muted", true), 0, y, width, facts.subtitle)
    end
    for _, section in ipairs(facts.sections) do
        if y > 0 then y = y + SECTION_GAP end
        y = y + Place(fr, Text(fr, "headingSmall", false), 0, y, width, section.title) + 2
        Rule(fr, y, width)
        y = y + 5
        for _, row in ipairs(section.rows) do
            if row.entry then
                local top = y
                local role = row.weak and "muted" or "body"
                local icon = row.icon and ("|T" .. row.icon .. ":16:16:0:0|t ") or ""
                local name = icon .. row.name .. (row.tag and ("  |cff888888" .. row.tag .. "|r") or "")
                local nh = Place(fr, Text(fr, role, false), 0, y, width - RATE_W - 4, name)
                local vh = Place(fr, Text(fr, role, false, "RIGHT"), width - RATE_W, y, RATE_W, row.value)
                y = y + math.max(nh, vh)
                if row.sub and row.sub ~= "" then
                    y = y + 1 + Place(fr, Text(fr, "muted", true), 8, y + 1, width - 8, row.sub)
                end
                if row.key ~= nil or row.itemId then EntryButton(fr, top, y - top, width, row) end
                y = y + ENTRY_GAP
            elseif row.note then
                y = y + Place(fr, Text(fr, "muted", true), 0, y, width, row.note) + ROW_GAP
            else
                local lh = Place(fr, Text(fr, "muted", false), 0, y, LABEL_W, row.label)
                local vh = Place(fr, Text(fr, "body", true, "RIGHT"), LABEL_W + 4, y, width - LABEL_W - 4, row.value)
                y = y + math.max(lh, vh) + ROW_GAP
            end
        end
    end
    fr.child:SetHeight(math.max(10, y + 4))
    fr.scroll:SetVerticalScroll(0)
    return fr
end

-- Facts of the selected list entry on the right page.
function D.Show(facts)
    local fr = P.ShowPanel("details", function(parent) return D.Frame(parent, P.PANEL_W) end)
    D.Render(fr, facts)
    P.details = facts
    return fr
end

return D
