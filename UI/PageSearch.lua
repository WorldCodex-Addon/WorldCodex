local _, ns = ...

-- Advanced search page of the WorldCodex window (section "Advanced search", page type "search"). The
-- page tabs choose what is searched (items, NPCs and sources, quests); the right page holds the filter
-- form of that tab, the left page the results (Search.lua). A search runs as a background job when the
-- player presses Search or Enter in a field; the results stay until the next search.
local L = ns.L
local W, P = ns.Widgets, ns.Page
local S = ns.Search

local R = { live = false, noLayers = true, sticky = true, Custom = {} }

-- kind = tab shown; filters/results/total per kind; searched[kind] = a search has run; running = kind
-- being searched; selected = row picked in the results.
local state = { kind = "items", filters = { items = {}, npcs = {}, quests = {} }, results = {}, total = {} }
state.searched, state.running, state.selected = {}, false, nil
local forms = {}

local TABS = {
    { id = "items", label = L["Items"] },
    { id = "npcs", label = L["NPCs & sources"] },
    { id = "quests", label = L["Quests"] },
}

-- ---------------------------------------------------------------- columns

local function Price(v) return v and v > 0 and ns.CoinShort(v) or "" end
local function Num(v) return v and v > 0 and tostring(v) or "" end
local function ItemIcon(r)
    if r.icon == nil then r.icon = ns.ItemIcon(r.id) or false end
    return r.icon or nil
end
local function ZoneOf(r)
    if r.zone == nil then
        local z = ns.Lookup.Zones(r.id, 1)[1]
        r.zone = z and z.name or ""
    end
    return r.zone
end
local function LevelOf(r) return P.LevelText({ lmin = r.lmin, lmax = r.lmax, cls = r.cls }) end

R.Columns = {
    ["search:items"] = {
        { key = "name", title = L["Item"], w = 196, text = function(r) return r.label end, icon = ItemIcon },
        { key = "ilvl", title = L["iLvl"], w = 44, align = "RIGHT", text = function(r) return Num(r.ilvl) end },
        { key = "req", title = L["Req."], w = 44, align = "RIGHT", text = function(r) return Num(r.req) end },
        { key = "kindText", title = L["Type"], w = 120, text = function(r) return r.kindText end },
        {
            key = "stat",
            title = L["Stat"],
            w = 52,
            align = "RIGHT",
            text = function(r) return r.stat ~= 0 and tostring(r.stat) or "" end,
        },
        { key = "price", title = L["Price"], w = 80, align = "RIGHT", text = function(r) return Price(r.price) end },
    },
    ["search:npcs"] = {
        {
            key = "name",
            title = L["Name"],
            w = 160,
            text = function(r) return r.label end,
            icon = function(r) return P.SourceIcon(r.id, r.kindKey) end,
        },
        { key = "kind", title = L["Kind"], w = 84, text = function(r) return r.kind end },
        { key = "level", title = L["Level"], w = 84, text = LevelOf, sort = function(r) return r.lmin or 0 end },
        { key = "zone", title = L["Zone"], w = 140, text = ZoneOf, sort = ZoneOf },
        { key = "n", title = "n", w = 50, align = "RIGHT", text = function(r) return Num(r.n) end },
    },
    ["search:quests"] = {
        {
            key = "name",
            title = L["Quest"],
            w = 190,
            text = function(r) return (r.done and "|cff808080" or "") .. r.label .. (r.done and "|r" or "") end,
            icon = function() return P.KIND_ICON.quest end,
        },
        { key = "level", title = L["Level"], w = 44, align = "RIGHT", text = function(r) return Num(r.level) end },
        { key = "zone", title = L["Zone"], w = 120, text = ZoneOf, sort = ZoneOf },
        { key = "giver", title = L["Quest giver"], w = 120, text = function(r) return r.giver end },
        { key = "rep", title = L["Repeat"], w = 56, text = function(r) return r.rep end },
    },
}

-- ---------------------------------------------------------------- the form

-- Fields per tab. text: free text; range: from/to numbers (key .. "Min"/"Max"); choice: dropdown;
-- stat: dropdown of stats plus a minimum value (statMin).
local FIELDS = {
    items = {
        { key = "name", label = L["Name"], kind = "text" },
        { key = "quality", label = L["Quality at least"], kind = "choice", options = S.QUALITIES },
        { key = "class", label = L["Type"], kind = "choice", options = S.Classes },
        {
            key = "slot",
            label = L["Slot"],
            kind = "choice",
            options = function()
                local out = {}
                for _, loc in ipairs(S.SLOTS) do
                    out[#out + 1] = { loc, S.SlotLabel(loc) }
                end
                return out
            end,
        },
        { key = "ilvl", label = L["Item level"], kind = "range" },
        { key = "req", label = L["Required level"], kind = "range" },
        { key = "stat", label = L["Stat"], kind = "stat", options = S.Stats },
        { key = "origin", label = L["Obtained from"], kind = "choice", options = S.ORIGINS },
    },
    npcs = {
        { key = "name", label = L["Name"], kind = "text" },
        { key = "kind", label = L["Kind"], kind = "choice", options = S.SourceKinds },
        { key = "level", label = L["Level"], kind = "range" },
        { key = "classification", label = L["Classification"], kind = "choice", options = S.CLASSIFICATIONS },
        { key = "reaction", label = L["Reaction"], kind = "choice", options = S.REACTIONS },
        { key = "role", label = L["Role"], kind = "choice", options = S.ROLES },
        { key = "zone", label = L["Zone"], kind = "text" },
        { key = "drops", label = L["Drops item"], kind = "text" },
    },
    quests = {
        { key = "name", label = L["Name"], kind = "text" },
        { key = "level", label = L["Level"], kind = "range" },
        { key = "zone", label = L["Zone"], kind = "text" },
        { key = "giver", label = L["Quest giver"], kind = "text" },
        { key = "reward", label = L["Reward item"], kind = "text" },
        { key = "repeat", label = L["Repeat"], kind = "choice", options = S.REPEATS },
        { key = "status", label = L["Status"], kind = "choice", options = S.STATUS },
    },
}

local NOTES = {
    items = L["Stats are known for gear you have seen (bags, equipped, links, auction house). Items the client has not loaded yet only match by name and source."],
    npcs = L["Levels, roles and reactions come from NPCs you or others have met. Zone and item names match parts of words."],
    quests = L["Quest levels are recorded when a quest is accepted or handed in."],
}

local LABEL_W, ROW = 150, 32

local function Search(kind)
    kind = kind or state.kind
    local filter = {}
    for k, v in pairs(state.filters[kind]) do
        filter[k] = v
    end
    state.running = kind
    state.searched[kind] = true
    P.Refresh()
    S.Start(kind, filter, function(rows, total)
        state.results[kind], state.total[kind] = rows, total
        if state.running == kind then state.running = false end
        state.reset = true
        local cur = P.Current()
        if cur and cur.type == "search" then P.Refresh() end
    end)
end

local function NumberInput(parent, width, filter, key)
    local eb = W.Input(parent, width)
    eb:SetNumeric(true)
    eb:SetScript("OnTextChanged", function(self) filter[key] = self:GetText() or "" end)
    eb:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        Search()
    end)
    return eb
end

local function BuildForm(kind)
    return function(panel)
        local fr = CreateFrame("Frame", nil, panel)
        fr:SetAllPoints(panel)
        local filter = state.filters[kind]
        local controls = {} -- key -> widget with :SetText or :SetValue
        local controlX = LABEL_W
        local controlW = P.PANEL_W - LABEL_W - 24
        fr.title = W.Text(fr, "heading")
        fr.title:SetPoint("TOPLEFT", 0, 0)
        fr.title:SetText(L["Filters"])
        local y = -36
        for _, field in ipairs(FIELDS[kind]) do
            local label = W.Text(fr, "body")
            label:SetPoint("TOPLEFT", 0, y - 4)
            label:SetWidth(LABEL_W - 8)
            label:SetWordWrap(false)
            label:SetText(W.Ink(field.label))
            if field.kind == "text" then
                local eb = W.Input(fr, controlW)
                eb:SetPoint("TOPLEFT", controlX + 6, y)
                eb:SetScript("OnTextChanged", function(self) filter[field.key] = self:GetText() or "" end)
                eb:SetScript("OnEnterPressed", function(self)
                    self:ClearFocus()
                    Search()
                end)
                controls[field.key] = eb
            elseif field.kind == "range" then
                local from = NumberInput(fr, 50, filter, field.key .. "Min")
                from:SetPoint("TOPLEFT", controlX + 6, y)
                local dash = W.Text(fr, "body")
                dash:SetPoint("LEFT", from, "RIGHT", 8, 0)
                dash:SetText(W.Ink(L["to"]))
                local to = NumberInput(fr, 50, filter, field.key .. "Max")
                to:SetPoint("LEFT", dash, "RIGHT", 12, 0)
                controls[field.key .. "Min"], controls[field.key .. "Max"] = from, to
            else
                local width = field.kind == "stat" and controlW - 90 or controlW
                local dd = W.Dropdown(fr, width, field.options, L["Any"], function(v) filter[field.key] = v end)
                dd:SetPoint("TOPLEFT", controlX, y)
                controls[field.key] = dd
                if field.kind == "stat" then
                    local atLeast = W.Text(fr, "body")
                    atLeast:SetPoint("LEFT", dd, "RIGHT", 8, 0)
                    atLeast:SetText(W.Ink(">="))
                    local min = NumberInput(fr, 40, filter, "statMin")
                    min:SetPoint("LEFT", atLeast, "RIGHT", 10, 0)
                    controls.statMin = min
                end
            end
            y = y - ROW
        end
        local search = W.Button(fr, L["Search"], 110, function() Search() end)
        search:SetPoint("TOPLEFT", controlX, y - 6)
        local reset = W.Button(fr, L["Reset"], 90, function()
            for k in pairs(filter) do
                filter[k] = nil
            end
            fr:Load()
        end)
        reset:SetPoint("LEFT", search, "RIGHT", 6, 0)
        fr.note = W.Text(fr, "muted")
        fr.note:SetPoint("TOPLEFT", 0, y - 46)
        fr.note:SetWidth(P.PANEL_W - 24)
        fr.note:SetJustifyH("LEFT")
        fr.note:SetText(W.Ink(NOTES[kind]))
        -- puts the filter values into the controls (after a reset or when the form is built)
        function fr:Load()
            for key, c in pairs(controls) do
                if c.SetValue then
                    c:SetValue(filter[key])
                else
                    c:SetText(filter[key] or "")
                end
            end
        end
        fr:Load()
        fr.controls = controls
        forms[kind] = fr
        return fr
    end
end

-- ---------------------------------------------------------------- renderer

local function GotoSelected()
    local sel = state.selected
    if not sel then return end
    if sel.type == "item" then
        ns.Nav.Goto(tostring(sel.id))
    else
        ns.Nav.GotoSource(sel.id)
    end
end

local function OpenPage(r)
    if not r then return false end
    return P.Show({ type = r.type == "item" and "item" or "source", id = r.id })
end

local function LinkSelected()
    local sel = state.selected
    if sel and sel.type == "item" and ChatEdit_InsertLink then ChatEdit_InsertLink(ns.ItemLink(sel.id)) end
end

function R.KeyOf(r) return r.type .. ":" .. tostring(r.id) end

function R.Header()
    local kind = state.kind
    local sub
    if state.running == kind then
        sub = L["Searching..."]
    elseif not state.searched[kind] then
        sub = L["Find items, NPCs and quests by their properties."]
    else
        local rows, total = state.results[kind] or {}, state.total[kind] or 0
        sub = total > #rows and string.format(L["%d results (showing the first %d)"], total, #rows)
            or string.format(L["%d results"], total)
    end
    return {
        icon = "Interface\\Icons\\INV_Misc_Spyglass_03",
        title = L["Advanced search"],
        sub = sub,
        info = L["Set filters on the right page and press Search. Double-click a result to open its page, right-click to go there."],
    }
end

function R.Actions()
    local list = {
        { label = L["Open page"], width = 96, fn = function() OpenPage(state.selected) end },
        { label = L["Take me there"], width = 110, fn = GotoSelected },
    }
    if state.kind == "items" then list[#list + 1] = { label = L["Link"], width = 60, fn = LinkSelected } end
    return list
end

function R.Tabs()
    local keep = not state.reset
    state.reset = nil
    local out = {}
    for _, t in ipairs(TABS) do
        local rows = state.results[t.id] or {}
        out[#out + 1] = {
            id = t.id,
            label = t.label,
            count = state.searched[t.id] and state.total[t.id] or nil,
            table = "search:" .. t.id,
            rows = rows,
            keepOffset = keep,
            empty = state.searched[t.id] and state.running ~= t.id and L["Nothing found."]
                or L["Set filters on the right page and press Search."],
        }
    end
    return out
end

function R.Select(r, tab)
    if tab and tab.id ~= state.kind then
        state.kind = tab.id
        -- the actions and the heading depend on the tab
        if P.Current() then ns.After(0, P.Refresh) end
    end
    state.selected = r and { type = r.type, id = r.id } or nil
    P.ShowPanel("search:" .. state.kind, BuildForm(state.kind))
end

function R.Click(r, button)
    state.selected = r and { type = r.type, id = r.id } or nil
    if IsShiftKeyDown and IsShiftKeyDown() and r.type == "item" then
        LinkSelected()
    elseif button == "RightButton" then
        GotoSelected()
    end
end

R.Open = OpenPage

function R.RowTooltip(tt, r)
    if r.type == "item" then return tt:SetHyperlink("item:" .. r.id) end
    tt:AddLine(r.label, 1, 1, 1)
    if r.kind then tt:AddLine(r.kind, 0.6, 0.6, 0.6) end
    if r.giver and r.giver ~= "" then tt:AddLine(L["Quest giver"] .. ": " .. r.giver, 0.6, 0.6, 0.6) end
    tt:AddLine(L["Double-click to open this source."], 0.5, 0.5, 0.5)
end

P.Register("search", R)

-- ---------------------------------------------------------------- entry points

ns.SearchPage = {}

-- Opens the advanced search on a tab ("items" | "npcs" | "quests"), optionally with filters, and runs
-- the search when filters are given.
function ns.SearchPage.Show(kind, filter)
    kind = kind or state.kind
    state.kind = kind
    if filter then
        local f = state.filters[kind]
        for k in pairs(f) do
            f[k] = nil
        end
        for k, v in pairs(filter) do
            f[k] = v
        end
        if forms[kind] then forms[kind]:Load() end
    end
    P.Show({ type = "search", id = "all", tab = kind })
    if filter then Search(kind) end
    return true
end

function ns.SearchPage._State() return state end

return ns.SearchPage
