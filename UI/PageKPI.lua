local _, ns = ...

-- KPI page of the WorldCodex window: every KPI (KPI.lua) as a table row with its value, target, a
-- gauge (bar = value, tick = target) and status; the side panel shows the selected KPI with its
-- chart. Measuring walks all items, so the page refreshes only on open and with the Refresh button.
local L = ns.L
local W, C, P = ns.Widgets, ns.Charts, ns.Page

local R = { live = false, noLayers = true, sticky = true, Custom = {} }
local rows = {}

local function StatusColor(ok)
    if ok == nil then return ns.KPI.INK end
    return ok and ns.KPI.GOOD or ns.KPI.BAD
end

local function StatusText(ok)
    if ok == nil then return "|cff8c7d64-|r" end
    return ok and ("|cff2a7a2e" .. L["met"] .. "|r") or ("|cffa8321e" .. L["missed"] .. "|r")
end

R.Columns = {
    kpi = {
        { key = "id", title = "#", w = 22, align = "RIGHT", text = function(r) return tostring(r.id) end },
        {
            key = "name",
            title = L["KPI"],
            w = 150,
            text = function(r) return r.name end,
            sort = function(r) return r.name:lower() end,
        },
        { key = "valueText", title = L["Value"], w = 80, align = "RIGHT", text = function(r) return r.valueText end },
        { key = "targetText", title = L["Target"], w = 90, text = function(r) return r.targetText end },
        {
            key = "gauge",
            title = "",
            w = 110,
            create = function(row, width, height) return C.Gauge(row, width, math.max(6, height - 8)) end,
            render = function(g, r)
                g:Set(r.gauge and r.gauge[1], r.gauge and r.gauge[2], r.gauge and r.gauge[3], StatusColor(r.ok))
            end,
            sort = function(r) return r.gauge and r.gauge[1] and r.gauge[2] and r.gauge[1] / r.gauge[2] or -1 end,
        },
        {
            key = "ok",
            title = L["Status"],
            w = 56,
            text = function(r) return StatusText(r.ok) end,
            sort = function(r)
                if r.ok == nil then return 1 end
                return r.ok and 2 or 0
            end,
        },
    },
}

function R.KeyOf(r) return r.id end

function R.Prepare() rows = ns.KPI.Rows() end

function R.Header()
    local met, total = 0, 0
    for _, r in ipairs(rows) do
        if r.ok ~= nil then
            total = total + 1
            if r.ok then met = met + 1 end
        end
    end
    return {
        icon = "Interface\\Icons\\INV_Misc_Note_01",
        title = L["KPIs"],
        sub = string.format(L["%d of %d targets met"], met, total),
        info = L["Measured on your own data in this game. Click a row to see its chart; Refresh measures again."],
    }
end

function R.Actions()
    return { { label = L["Refresh"], width = 90, fn = function() P.Refresh() end } }
end

function R.Tabs()
    return { { id = "kpi", label = L["KPIs"], table = "kpi", rows = rows, solo = true, keepOffset = true } }
end

-- ---------------------------------------------------------------- side panel

local function BuildPanel(parent)
    local a = CreateFrame("Frame", nil, parent)
    a:SetAllPoints(parent)
    local x, w = 0, P.PANEL_W - 8
    local Y = P.Y
    local function Text(role, y, h)
        local fs = W.Text(a, role)
        fs:SetPoint("TOPLEFT", x, Y(y))
        fs:SetWidth(w)
        if h then fs:SetHeight(Y(h)) end
        fs:SetJustifyV("TOP")
        return fs
    end
    a.title = Text("heading", -8, 16)
    a.group = Text("muted", -24, 12)
    a.value = Text("title", -42, 20)
    a.status = Text("bodyLarge", -46, 14)
    a.status:SetJustifyH("RIGHT")
    a.target = Text("body", -66, 12)
    a.gauge = C.Gauge(a, w, Y(12))
    a.gauge:SetPoint("TOPLEFT", x, Y(-84))
    a.desc = Text("body", -104, 58)
    a.chartLabel = Text("headingSmall", -168, 12)
    a.columns = C.Columns(a, w, Y(84))
    a.columns:SetPoint("TOPLEFT", x, Y(-184))
    a.stack = C.Stack(a, w, Y(12))
    a.stack:SetPoint("TOPLEFT", x, Y(-184))
    a.note = Text("body", -290, 96)
    return a
end

local function ShowKpi(r)
    local a = P.ShowPanel("kpi", BuildPanel)
    a.row = r
    a.title:SetText(string.format("%d · %s", r.id, r.name))
    a.group:SetText(r.group)
    a.value:SetText(r.valueText)
    a.status:SetText(W.Ink(StatusText(r.ok)))
    a.target:SetText(r.targetText ~= "-" and (L["Target"] .. ": " .. r.targetText) or "")
    if r.gauge and r.gauge[2] then
        a.gauge:Set(r.gauge[1], r.gauge[2], r.gauge[3], StatusColor(r.ok))
        a.gauge:Show()
    else
        a.gauge:Hide()
    end
    a.desc:SetText(r.desc or "")
    local chart = r.chart
    a.columns:Hide()
    a.stack:Hide()
    local noteY = -184
    if chart then
        a.chartLabel:SetText(chart.label or "")
        if chart.kind == "stack" then
            a.stack:Set(chart.parts)
            a.stack:Show()
            noteY = -204
        else
            a.columns:Set(chart.values, chart.opts)
            a.columns:Show()
            noteY = -290
        end
    else
        a.chartLabel:SetText("")
    end
    a.note:ClearAllPoints()
    a.note:SetPoint("TOPLEFT", 0, P.Y(noteY))
    a.note:SetText(W.Ink(r.note or ""))
end

function R.Select(r)
    if not r then return P.Analysis(nil, { empty = L["Select a row to see the details."] }) end
    ShowKpi(r)
end

function R.RowTooltip(tt, r)
    tt:AddLine(r.name, 1, 1, 1)
    if r.desc then tt:AddLine(r.desc, 0.8, 0.8, 0.8, true) end
end

P.Register("kpi", R)
ns.PageKPI = R

return R
