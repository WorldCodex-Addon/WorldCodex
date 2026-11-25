local _, ns = ...

-- Small charts drawn with plain textures (no CreateLine, which this client may lack): rate bars
-- with confidence bands, column charts, stacked shares and a sortable virtual table. They live on the
-- book pages of the WorldCodex window, so they use the page fonts and colours of UI/Widgets.lua
-- (W.Font, W.PAPER: set for the page style the client can show).
local C = {}
ns.Charts = C

local W = ns.Widgets

local function Tex(parent, layer)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    return t
end

local function RGB(c) return c[1] / 255, c[2] / 255, c[3] / 255 end
local function Paint(tex, c) W.Color(tex, c[1], c[2], c[3], c[4]) end

-- Colours for the "you vs everyone else" marker: above, below, no significant difference.
C.DIFF_COLOR = { [1] = { 70, 220, 90 }, [-1] = { 235, 80, 70 }, [0] = { 120, 170, 255 } }
C.LAYER_COLOR = { me = { 80, 150, 255 }, guild = { 80, 200, 110 }, community = { 230, 190, 70 } }
-- Default column colour (brown ink on paper), so the personal overlay (blue) stands out.
local function Ink() return W.PAPER.ink end

-- ---------------------------------------------------------------- rate bar

-- Horizontal rate bar on a log scale (0.1 % .. 100 %) with ticks at 1 % and 10 %, the 95 %
-- interval as a band and the rate as a marker. bar:Set(lo, p, hi, conf, mine) where the optional
-- `mine` = { lo, p, hi, diff } draws the player's own rate in a second, thinner row.
function C.RateBar(parent, width, height)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width, height)
    f.w, f.h = width, height
    f.track = Tex(f, "BACKGROUND")
    f.track:SetAllPoints()
    Paint(f.track, W.PAPER.track)
    f.ticks = {}
    for i, p in ipairs({ 0.01, 0.1 }) do
        local t = Tex(f, "BORDER")
        t:SetSize(1, height)
        t:SetPoint("LEFT", f, "LEFT", math.floor(ns.Stats.LogPos(p) * width), 0)
        Paint(t, W.PAPER.tick)
        f.ticks[i] = t
    end
    local function Pair()
        local band, mark = Tex(f, "ARTWORK"), Tex(f, "OVERLAY")
        return { band = band, mark = mark }
    end
    f.main, f.mine = Pair(), Pair()

    local function Place(pair, lo, p, hi, top, h, color, bandAlpha)
        local pos = ns.Stats.LogPos
        local w = f.w
        local x = math.min(w - 2, math.max(0, math.floor(pos(p) * w + 0.5)))
        local a = math.min(x, math.max(0, math.floor(pos(lo) * w + 0.5)))
        local b = math.min(w, math.max(x + 2, math.floor(pos(hi) * w + 0.5)))
        local r, g, bb = RGB(color)
        pair.band:ClearAllPoints()
        pair.band:SetPoint("TOPLEFT", f, "TOPLEFT", a, -top)
        pair.band:SetSize(math.max(1, b - a), h)
        W.Color(pair.band, r, g, bb, bandAlpha)
        pair.mark:ClearAllPoints()
        pair.mark:SetPoint("TOPLEFT", f, "TOPLEFT", x, -top)
        pair.mark:SetSize(2, h)
        W.Color(pair.mark, r, g, bb, 1)
        pair.band:Show()
        pair.mark:Show()
    end

    function f:Set(lo, p, hi, conf, mine)
        if not p or p <= 0 then
            self.main.band:Hide()
            self.main.mark:Hide()
            self.mine.band:Hide()
            self.mine.mark:Hide()
            return
        end
        local color = ns.Report.CONF_COLOR[conf or "high"] or ns.Report.CONF_COLOR.high
        local h = self.h
        if mine and mine.p then
            local top = math.max(2, math.floor(h * 0.6))
            Place(self.main, lo, p, hi, 0, top, color, 0.4)
            Place(self.mine, mine.lo, mine.p, mine.hi, top + 1, h - top - 1, C.DIFF_COLOR[mine.diff or 0], 0.35)
        else
            Place(self.main, lo, p, hi, 0, h, color, 0.4)
            self.mine.band:Hide()
            self.mine.mark:Hide()
        end
    end
    return f
end

-- ---------------------------------------------------------------- columns

-- Bottom-aligned columns. chart:Set(values, opts): values = { {v=, v2=, lo=, hi=} }, v in 0..max;
-- v2 is an overlay (e.g. personal share) drawn as a narrow bar; lo/hi a whisker.
-- opts = { max =, color = {r,g,b}, color2 =, left = "text", right = "text", marks = { [i] = true } }
function C.Columns(parent, width, height)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width, height)
    f.w, f.h = width, height
    f.bg = Tex(f, "BACKGROUND")
    f.bg:SetAllPoints()
    Paint(f.bg, W.PAPER.well)
    f.pool = {}
    f.leftText = W.Text(f, "muted")
    f.leftText:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -2)
    f.rightText = W.Text(f, "muted")
    f.rightText:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -2)

    local function Bar(i)
        local b = f.pool[i]
        if not b then
            b = { main = Tex(f, "ARTWORK"), over = Tex(f, "OVERLAY"), whisker = Tex(f, "BORDER") }
            f.pool[i] = b
        end
        return b
    end

    function f:Set(values, opts)
        opts = opts or {}
        local n = #values
        local maxv = opts.max or 0
        if not opts.max then
            for _, e in ipairs(values) do
                maxv = math.max(maxv, e.v or 0, e.v2 or 0, e.hi or 0)
            end
        end
        local slot = n > 0 and self.w / n or self.w
        local bw = math.max(1, math.floor(slot * 0.8))
        local c1, c2 = opts.color or Ink(), opts.color2 or C.LAYER_COLOR.me
        local function H(v) return maxv > 0 and math.max(0, math.floor((v or 0) / maxv * (self.h - 2) + 0.5)) or 0 end
        for i, e in ipairs(values) do
            local b = Bar(i)
            local x = math.floor((i - 1) * slot)
            local h = H(e.v)
            local r, g, bb = RGB(e.color or c1)
            b.main:ClearAllPoints()
            b.main:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x, 0)
            b.main:SetSize(bw, math.max(1, h))
            W.Color(b.main, r, g, bb, (opts.marks and opts.marks[i]) and 1 or 0.7)
            b.main:Show()
            if e.v2 then
                local r2, g2, b2 = RGB(c2)
                b.over:ClearAllPoints()
                b.over:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x + math.floor(bw / 3), 0)
                b.over:SetSize(math.max(1, math.floor(bw / 3)), math.max(1, H(e.v2)))
                W.Color(b.over, r2, g2, b2, 0.95)
                b.over:Show()
            else
                b.over:Hide()
            end
            if e.lo and e.hi then
                b.whisker:ClearAllPoints()
                b.whisker:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x + math.floor(bw / 2), H(e.lo))
                b.whisker:SetSize(1, math.max(1, H(e.hi) - H(e.lo)))
                W.Color(b.whisker, 0.25, 0.16, 0.06, 0.8)
                b.whisker:Show()
            else
                b.whisker:Hide()
            end
        end
        for i = n + 1, #self.pool do
            local b = self.pool[i]
            b.main:Hide()
            b.over:Hide()
            b.whisker:Hide()
        end
        self.leftText:SetText(opts.left or "")
        self.rightText:SetText(opts.right or "")
        self.count = n
    end
    return f
end

-- ---------------------------------------------------------------- stacked shares

-- One horizontal bar split into coloured segments: chart:Set({ {v=, color={r,g,b}} }).
function C.Stack(parent, width, height)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width, height)
    f.w = width
    f.bg = Tex(f, "BACKGROUND")
    f.bg:SetAllPoints()
    Paint(f.bg, W.PAPER.track)
    f.segs = {}
    function f:Set(parts)
        local total = 0
        for _, p in ipairs(parts) do
            total = total + (p.v or 0)
        end
        local x = 0
        for i, p in ipairs(parts) do
            local t = self.segs[i] or Tex(self, "ARTWORK")
            self.segs[i] = t
            local w = total > 0 and math.floor((p.v or 0) / total * self.w + 0.5) or 0
            if i == #parts then w = self.w - x end
            if w >= 1 and total > 0 then
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", self, "TOPLEFT", x, 0)
                t:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x, 0)
                t:SetWidth(w)
                local r, g, b = RGB(p.color)
                W.Color(t, r, g, b, 0.9)
                t:Show()
                x = x + w
            else
                t:Hide()
            end
        end
        for i = #parts + 1, #self.segs do
            self.segs[i]:Hide()
        end
    end
    return f
end

-- ---------------------------------------------------------------- gauge

-- Bullet gauge: the value as a filled bar on a 0..max scale and the target as a tick.
-- g:Set(value, max, target, color) with color = {r, g, b} (0-255); nil value or max hides the bar.
function C.Gauge(parent, width, height)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width, height)
    f.w, f.h = width, height
    f.track = Tex(f, "BACKGROUND")
    f.track:SetAllPoints()
    Paint(f.track, W.PAPER.track)
    f.fill = Tex(f, "ARTWORK")
    f.tick = Tex(f, "OVERLAY")
    function f:Set(value, max, target, color)
        if value and max and max > 0 and value > 0 then
            local w = math.max(1, math.min(self.w, math.floor(value / max * self.w + 0.5)))
            local r, g, b = RGB(color or Ink())
            self.fill:ClearAllPoints()
            self.fill:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
            self.fill:SetSize(w, self.h)
            W.Color(self.fill, r, g, b, 0.85)
            self.fill:Show()
        else
            self.fill:Hide()
        end
        if target and max and max > 0 then
            local x = math.min(self.w - 2, math.floor(math.min(1, target / max) * self.w + 0.5))
            self.tick:ClearAllPoints()
            self.tick:SetPoint("TOPLEFT", self, "TOPLEFT", x, 2)
            self.tick:SetSize(2, self.h + 4)
            W.Color(self.tick, 0.18, 0.11, 0.04, 0.9)
            self.tick:Show()
        else
            self.tick:Hide()
        end
        self.value = value or false
    end
    return f
end

-- ---------------------------------------------------------------- table

-- Shows an icon (texture) or, with kind "display", the portrait of a creature display id (a still
-- image of its 3D model, as the client draws unit portraits).
function C.SetIcon(tex, value, kind)
    if kind == "display" and SetPortraitTextureFromCreatureDisplayID then
        tex:SetTexCoord(0, 1, 0, 1)
        if pcall(SetPortraitTextureFromCreatureDisplayID, tex, value) then return end
    end
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    tex:SetTexture(kind ~= "display" and value or "Interface\\Icons\\INV_Misc_QuestionMark")
end

-- Sortable virtual list. cols = { {key=, title=, w=, align=, text=fn(r) | create=fn(cell, w) + render=fn(widget, r),
-- sort=fn(r) -> value} }. opts = { rows =, rowH =, width =, onClick = fn(r, button), onDoubleClick = fn(r),
-- onEnter = fn(rowFrame, r), onLeave = fn() }. With opts.width the column widths are scaled to fill it
-- (scroll bar included). t:SetData(list) keeps the given order until a header is clicked; t.selected is
-- the selected record; t:SetVisibleRows(n) shows at most opts.rows rows. Cell text is passed through
-- W.Ink (readable on paper). A column with icon = fn(r) -> texture[, "display"] shows that icon before
-- its text ("display": a creature display id, drawn as the creature's portrait).
function C.Table(parent, cols, opts)
    opts = opts or {}
    local ROWS, ROW_H = opts.rows or 14, opts.rowH or 18
    local width = 0
    for _, col in ipairs(cols) do
        width = width + col.w
    end
    local scale = opts.width and (opts.width - 18) / width or 1
    width = 0
    for _, col in ipairs(cols) do
        col.cw = math.floor(col.w * scale)
        width = width + col.cw
    end
    local t = CreateFrame("Frame", nil, parent)
    t:SetSize(width + 16, (ROWS + 1) * ROW_H)
    -- Fields are always set (false instead of nil) so reads never fall through to frame methods.
    t.cols, t.data, t.offset, t.rowFrames, t.headers = cols, {}, 0, {}, {}
    t.selected, t.sortCol, t.sortDesc, t.keepOffset, t.emptyText, t.rendered = false, false, false, false, false, 0
    t.visible = ROWS
    -- Selection survives a refresh with new row objects when opts.keyOf identifies rows.
    local function Key(r)
        if not r then return nil end
        return opts.keyOf and opts.keyOf(r) or r
    end
    t:EnableMouseWheel(true)

    local x = 0
    for c, col in ipairs(cols) do
        local h = CreateFrame("Button", nil, t)
        h:SetSize(col.cw, ROW_H)
        h:SetPoint("TOPLEFT", x, 0)
        h.text = W.Text(h, "headingSmall")
        h.text:SetPoint("LEFT", 2, 0)
        h.text:SetText(col.title or "")
        h:SetScript("OnClick", function()
            if t.sortCol == c then
                t.sortDesc = not t.sortDesc
            else
                t.sortCol, t.sortDesc = c, col.key ~= "name"
            end
            t:Sort()
            t:Render()
        end)
        t.headers[c] = h
        col.x = x
        x = x + col.cw
    end
    local rule = t:CreateTexture(nil, "ARTWORK")
    Paint(rule, W.PAPER.tick)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", t, "TOPLEFT", 0, -ROW_H + 1)
    rule:SetPoint("TOPRIGHT", t, "TOPLEFT", width, -ROW_H + 1)

    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, t)
        row:SetSize(width, ROW_H)
        row:SetPoint("TOPLEFT", 0, -i * ROW_H)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        Paint(hl, W.PAPER.hover)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        Paint(row.sel, W.PAPER.select)
        row.sel:Hide()
        row.cells, row.icons = {}, {}
        for c, col in ipairs(cols) do
            local cell
            if col.create then
                cell = col.create(row, col.cw - 6, ROW_H)
                cell:SetPoint("LEFT", row, "LEFT", col.x + 2, 0)
            else
                local indent = 0
                if col.icon then
                    indent = ROW_H
                    local icon = row:CreateTexture(nil, "ARTWORK")
                    icon:SetSize(ROW_H - 3, ROW_H - 3)
                    icon:SetPoint("LEFT", row, "LEFT", col.x + 2, 0)
                    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                    row.icons[c] = icon
                end
                cell = W.Text(row, "body")
                cell:SetPoint("LEFT", row, "LEFT", col.x + 2 + indent, 0)
                -- right-aligned numbers keep clear of the next column (or the scroll bar)
                cell:SetWidth(col.cw - indent - (col.align == "RIGHT" and 8 or 4))
                cell:SetJustifyH(col.align or "LEFT")
                cell:SetWordWrap(false)
            end
            row.cells[c] = cell
        end
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(self, button)
            if not self.data then return end
            t.selected = self.data
            t:Render()
            if opts.onClick then opts.onClick(self.data, button) end
        end)
        row:SetScript("OnDoubleClick", function(self)
            if self.data and opts.onDoubleClick then opts.onDoubleClick(self.data) end
        end)
        row:SetScript("OnEnter", function(self)
            if self.data and opts.onEnter then opts.onEnter(self, self.data) end
        end)
        row:SetScript("OnLeave", function()
            if opts.onLeave then opts.onLeave() end
        end)
        t.rowFrames[i] = row
    end

    t.slider = W.Slider(t)
    t.slider:SetPoint("TOPLEFT", t, "TOPLEFT", width + 2, -ROW_H)
    t.slider:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", width + 2, 0)
    t.slider:SetScript("OnValueChanged", function(_, value)
        local v = math.floor(value + 0.5)
        if v ~= t.offset then
            t.offset = v
            t:Render()
        end
    end)
    t:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, #t.data - t.visible)
        t.offset = math.max(0, math.min(maxOffset, t.offset - delta * 3))
        t.slider:SetValue(t.offset)
        t:Render()
    end)

    t.empty = W.Text(t, "mutedLarge")
    t.empty:SetJustifyH("CENTER")
    t.empty:SetWidth(width - 20)
    t.empty:SetPoint("TOP", t, "TOP", -8, -3 * ROW_H)

    -- Fewer rows when the page has less room (rows beyond n stay hidden).
    function t:SetVisibleRows(n)
        n = math.max(1, math.min(ROWS, n))
        if n == self.visible then return end
        self.visible = n
        self:SetHeight((n + 1) * ROW_H)
        self:Render()
    end

    function t:Sort()
        local col = self.cols[self.sortCol or 0]
        if not col then return end
        local get = col.sort or function(r) return r[col.key] end
        local desc = self.sortDesc
        table.sort(self.data, function(a, b)
            local va, vb = get(a), get(b)
            if va == vb then return tostring(a.name) < tostring(b.name) end
            if type(va) ~= type(vb) then
                va, vb = tostring(va), tostring(vb)
            end
            if desc then return va > vb end
            return va < vb
        end)
    end

    function t:SetData(list, emptyText)
        self.data = {}
        for i, r in ipairs(list or {}) do
            self.data[i] = r
        end
        local keep = Key(self.selected)
        self.selected = false
        if keep ~= nil then
            for _, r in ipairs(self.data) do
                if Key(r) == keep then self.selected = r end
            end
        end
        if not self.keepOffset then
            self.offset = 0
            self.slider:SetValue(0)
        end
        self.emptyText = emptyText
        if self.sortCol then self:Sort() end
        self:Render()
    end

    function t:Render()
        local total = #self.data
        local maxOffset = math.max(0, total - self.visible)
        if self.offset > maxOffset then self.offset = maxOffset end
        self.slider:SetMinMaxValues(0, maxOffset)
        for i = 1, ROWS do
            local row = self.rowFrames[i]
            local r = i <= self.visible and self.data[self.offset + i] or nil
            row.data = r
            if r then
                for c, col in ipairs(self.cols) do
                    local cell = row.cells[c]
                    if col.render then
                        col.render(cell, r)
                    else
                        cell:SetText(W.Ink(col.text(r) or ""))
                        if col.icon then C.SetIcon(row.icons[c], col.icon(r)) end
                    end
                    cell:Show()
                end
                if self.selected and Key(self.selected) == Key(r) then
                    row.sel:Show()
                else
                    row.sel:Hide()
                end
                row:Show()
            else
                row:Hide()
            end
        end
        self.empty:SetText(total == 0 and (self.emptyText or "") or "")
        self.rendered = total
    end

    return t
end

return C
