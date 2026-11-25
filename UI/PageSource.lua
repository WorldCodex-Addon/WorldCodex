local _, ns = ...

-- Source page (NPC, node, chest, container, quest, fishing zone): the full drop table with rate
-- bars, coin, corpse-gathering sources of the same mob (skinning, pickpocketing, ...), zones with a
-- small spawn map, and where the player's own numbers differ from everyone else's.
local L = ns.L
local W, P = ns.Widgets, ns.Page
local Lk = ns.Lookup

local R = {}

local function ItemColumns(extra)
    local cols = {
        {
            key = "name",
            title = L["Item"],
            w = 180,
            text = function(r) return ns.ItemName(r.itemId, true) end,
            sort = function(r) return Lk.LowerName(r.itemId) end,
        },
        P.BarColumn(100),
        { key = "rate", title = "%", w = 48, align = "RIGHT", text = P.RateText },
        { key = "n", title = "n", w = 42, align = "RIGHT", text = function(r) return tostring(r.n) end },
        { key = "avgQty", title = L["Qty"], w = 36, align = "RIGHT", text = P.QtyText },
    }
    cols[#cols + 1] = extra
    return cols
end

R.Columns = {
    items = ItemColumns({
        key = "value",
        title = L["Value"],
        w = 64,
        align = "RIGHT",
        text = function(r)
            local v = ns.Prices.UnitValue(r.itemId)
            return v and v > 0 and ns.CoinShort(v) or "-"
        end,
        sort = function(r) return ns.Prices.UnitValue(r.itemId) or 0 end,
    }),
    diffs = ItemColumns({
        key = "diff",
        title = L["You"],
        w = 64,
        align = "RIGHT",
        text = function(r)
            local m = r.mine
            local s = m.n > 0 and ns.Pct(m.d / m.n) or "-"
            if r.diff > 0 then return "|cff46dc5a" .. s .. "|r" end
            if r.diff < 0 then return "|cffeb5046" .. s .. "|r" end
            return s
        end,
        sort = function(r) return r.pv or 1 end,
    }),
}

local function N(n) return n and n > 0 and tostring(n) or "0" end

local ROLE_LABEL = {
    vendor = L["Vendor"],
    trainer = L["Trainer"],
    quest = L["Quest giver"],
    taxi = L["Flight master"],
    banker = L["Banker"],
}
local REACTION = {
    hostile = "|cffff4040" .. L["hostile"] .. "|r",
    neutral = "|cffffff40" .. L["neutral"] .. "|r",
    friendly = "|cff40ff40" .. L["friendly"] .. "|r",
}

function R.Header(key, layer)
    local m = Lk.SourceModel(key, layer)
    local sub = { ns.KIND_LABEL[m.kind] or tostring(m.kind) }
    local roles = {}
    for role in pairs(m.roles or {}) do
        if ROLE_LABEL[role] then roles[#roles + 1] = ROLE_LABEL[role] end
    end
    table.sort(roles)
    if #roles > 0 then sub[1] = table.concat(roles, ", ") end
    if m.reaction then sub[#sub + 1] = REACTION[m.reaction] end
    local lvl = P.LevelText(m)
    if lvl ~= "" then sub[#sub + 1] = L["Level"] .. " " .. lvl end
    sub[#sub + 1] = "#" .. tostring(key)
    if m.zones[1] then
        local z = {}
        for i, zone in ipairs(m.zones) do
            if i > 3 then break end
            z[#z + 1] = zone.name .. " " .. (ns.Pct(zone.share):gsub("%.%d%%", "%%"))
        end
        sub[#sub + 1] = table.concat(z, ", ")
    end
    local info = {}
    local s = m.summary
    local base = m.kind == "mob" and L["corpses looted"] or L["attempts"]
    if s.n > 0 then
        local line = string.format("%d %s", s.n, base)
        local per = ns.Report.PerKillText(key, m.kind)
        if per then line = line .. "  ·  " .. per end
        info[#info + 1] = line
    else
        info[#info + 1] = L["no data yet"]
    end
    local pers = m.personal
    if pers then
        if m.kind == "mob" then
            info[#info + 1] = string.format(
                L["You: %s kills, %s looted, %s empty, %s not looted"],
                N(pers.kills),
                N(pers.lb),
                N(pers.ek),
                N(pers.ul)
            )
        else
            info[#info + 1] = string.format(L["You: %s attempts, %s failed"], N(pers.attempts), N(pers.fails))
        end
    end
    local coin = m.coin
    if coin.mine.n >= 20 and coin.others.n >= 20 then
        info[#info] = (info[#info] or "")
            .. string.format(
                "  ·  %s %s / %s %s",
                L["coin you"],
                ns.Coin(coin.mine.m / coin.mine.n),
                L["community"],
                ns.Coin(coin.others.m / coin.others.n)
            )
    end
    return {
        icon = P.KIND_ICON[m.kind] or "Interface\\Icons\\INV_Misc_QuestionMark",
        npc = m.npcId,
        title = tostring(m.name),
        sub = table.concat(sub, " · "),
        info = table.concat(info, "\n"),
    }
end

function R.Actions(key)
    local list = {
        {
            label = L["Show on map"],
            width = 104,
            fn = function()
                if ns.MapPins and ns.MapPins.ShowSource then ns.MapPins.ShowSource(key, true) end
            end,
        },
        { label = L["Waypoint"], width = 84, fn = function() ns.Nav.GotoSource(key) end },
    }
    if ns.WEB_BASE and ns.WebLink then
        list[#list + 1] = { label = L["Web link"], width = 80, fn = function() ns.WebLink("source", key) end }
    end
    return list
end

function R.Tabs(key, layer)
    local m = Lk.SourceModel(key, layer)
    local tabs = {
        {
            id = "drops",
            label = L["Drops"],
            count = #m.items,
            table = "items",
            rows = m.items,
            empty = layer == "mine" and L["You have no loot from this source yet."] or L["No loot recorded yet."],
        },
    }
    for _, rel in ipairs(m.related) do
        local rm = Lk.SourceModel(rel.key, layer)
        tabs[#tabs + 1] = {
            id = "rel:" .. tostring(rel.key),
            label = ns.KIND_LABEL[rel.kind] or tostring(rel.kind),
            count = #rm.items,
            table = "items",
            rows = rm.items,
        }
    end
    if ns.SourceTabs then
        for _, t in ipairs(ns.SourceTabs(key, layer)) do
            tabs[#tabs + 1] = t
        end
    end
    if #m.diffs > 0 then
        tabs[#tabs + 1] = { id = "diffs", label = L["Differences"], count = #m.diffs, table = "diffs", rows = m.diffs }
    end
    -- only with positions: instance zones (no coordinates) have nothing to plot
    if next(ns.Store.Spawns(key)) then tabs[#tabs + 1] = { id = "map", label = L["Map"], custom = "map" } end
    if m.npcId then tabs[#tabs + 1] = { id = "model", label = L["Model"], custom = "model" } end
    return tabs
end

function R.Select(r, tab)
    if not r then
        P.Analysis(nil, { empty = tab and tab.custom and " " or L["Select an item to see the details."] })
        return
    end
    if r.extra then
        if ns.PageExtra and ns.PageExtra.Select then return ns.PageExtra.Select(r) end
    end
    P.Analysis(r, {
        title = ns.ItemName(r.itemId, true),
        kind = tostring(r.name),
        openType = "item",
        openId = r.itemId,
        openLabel = L["Open item"],
    })
end

function R.Open(r)
    if r.openType then return P.Show({ type = r.openType, id = r.openId }) end
    P.Show({ type = "item", id = r.itemId })
end

function R.RowTooltip(tt, r)
    if r.extra then return ns.PageExtra.Tooltip(tt, r) end
    if r.itemId then tt:SetHyperlink("item:" .. r.itemId) end
end

R.Custom = {}

-- Zones of the source and a small plot of its spawn cells on the busiest map.
local PLOT = 200
function R.Custom.map(parent)
    local fr = CreateFrame("Frame", nil, parent)
    fr:SetAllPoints(parent)
    fr.zones = W.Text(fr, "bodyLarge")
    fr.zones:SetPoint("TOPLEFT", 4, -4)
    fr.zones:SetWidth(240)
    fr.zones:SetHeight(200)
    fr.zones:SetJustifyV("TOP")
    fr.plot = CreateFrame("Frame", nil, fr)
    fr.plot:SetSize(PLOT, PLOT)
    fr.plot:SetPoint("TOPLEFT", 260, -4)
    fr.plot.bg = fr.plot:CreateTexture(nil, "BACKGROUND")
    fr.plot.bg:SetAllPoints()
    W.Color(fr.plot.bg, 0.08, 0.1, 0.12, 0.95)
    fr.plotTitle = W.Text(fr, "headingSmall")
    fr.plotTitle:SetPoint("TOPLEFT", fr.plot, "BOTTOMLEFT", 0, -4)
    fr.dots = {}
    fr.open = W.Button(fr, L["Show on world map"], 150, function()
        if fr.key and ns.MapPins and ns.MapPins.ShowSource then ns.MapPins.ShowSource(fr.key, true) end
    end)
    fr.open:SetPoint("TOPLEFT", fr.plot, "BOTTOMLEFT", 0, -22)
    function fr:Update(key)
        self.key = key
        local zones = Lk.Zones(key, 10)
        local lines = {}
        for _, z in ipairs(zones) do
            lines[#lines + 1] = string.format("%s  %s", z.name, ns.Pct(z.share))
        end
        self.zones:SetText(table.concat(lines, "\n"))
        local top = zones[1]
        local used = 0
        if top then
            local cells = ns.Store.Spawns(key)[top.map] or {}
            local maxc = 1
            for _, cnt in pairs(cells) do
                maxc = math.max(maxc, cnt)
            end
            for cell, cnt in pairs(cells) do
                used = used + 1
                if used > 400 then break end
                local t = self.dots[used] or self.plot:CreateTexture(nil, "ARTWORK")
                self.dots[used] = t
                local x, y = ns.Store.CellXY(cell)
                t:ClearAllPoints()
                t:SetSize(4, 4)
                t:SetPoint("CENTER", self.plot, "TOPLEFT", x * PLOT, -y * PLOT)
                W.Color(t, 0.3, 0.85, 1, math.min(1, 0.35 + cnt / maxc))
                t:Show()
            end
            self.plotTitle:SetText(top.name)
        else
            self.plotTitle:SetText("")
        end
        for i = used + 1, #self.dots do
            self.dots[i]:Hide()
        end
    end
    return fr
end

-- The NPC's 3D model; drag to turn it. Needs the creature in the client's cache (seen once).
function R.Custom.model(parent)
    local fr = CreateFrame("Frame", nil, parent)
    fr:SetAllPoints(parent)
    fr.model = CreateFrame("PlayerModel", nil, fr)
    fr.model:SetSize(300, 300)
    fr.model:SetPoint("TOP", 0, -4)
    fr.model:EnableMouse(true)
    fr.facing = 0
    fr.model:SetScript("OnMouseDown", function(self) self.dragX = GetCursorPosition and GetCursorPosition() or nil end)
    fr.model:SetScript("OnMouseUp", function(self) self.dragX = nil end)
    fr.model:SetScript("OnUpdate", function(self)
        if not self.dragX or not GetCursorPosition then return end
        local x = GetCursorPosition()
        fr.facing = fr.facing + (x - self.dragX) * 0.02
        self.dragX = x
        if self.SetFacing then self:SetFacing(fr.facing) end
    end)
    fr.model.dragX = false
    fr.hint = W.Text(fr, "muted")
    fr.hint:SetPoint("TOP", fr.model, "BOTTOM", 0, -4)
    fr.hint:SetText(L["Drag to turn. Shown once the game knows this creature."])
    function fr:Update(key)
        local npc = Lk.NpcId(key)
        self.npc = npc
        if npc and self.model.SetCreature then
            pcall(self.model.SetCreature, self.model, npc)
            fr.facing = 0
            if self.model.SetFacing then self.model:SetFacing(0) end
        end
    end
    return fr
end

P.Register("source", R)
ns.PageSource = R

-- ---------------------------------------------------------------- compare page

-- Every (source, item) pair where the player's own rate differs significantly from everyone else's.
local CMP = {}

local function PctOf(side) return side.n > 0 and ns.Pct(side.d / side.n) or "-" end

CMP.Columns = {
    cmp = {
        {
            key = "name",
            title = L["Item"],
            w = 150,
            text = function(r) return ns.ItemName(r.itemId, true) end,
            sort = function(r) return Lk.LowerName(r.itemId) end,
        },
        {
            key = "source",
            title = L["Source"],
            w = 130,
            text = function(r) return tostring(r.name) end,
            sort = function(r) return tostring(r.name):lower() end,
        },
        P.BarColumn(84),
        {
            key = "you",
            title = L["You"],
            w = 54,
            align = "RIGHT",
            text = function(r)
                local s = PctOf(r.mine)
                return (r.diff > 0 and "|cff46dc5a" or "|cffeb5046") .. s .. "|r"
            end,
            sort = function(r) return r.mine.n > 0 and r.mine.d / r.mine.n or 0 end,
        },
        {
            key = "others",
            title = L["Others"],
            w = 54,
            align = "RIGHT",
            text = function(r) return PctOf(r.others) end,
            sort = function(r) return r.others.n > 0 and r.others.d / r.others.n or 0 end,
        },
    },
}

function CMP.Header()
    return {
        icon = "Interface\\Icons\\INV_Misc_Spyglass_02",
        title = L["Your data vs everyone else's"],
        sub = string.format(
            L["Pairs with at least %d observations on both sides and a difference that is very unlikely to be chance (p < %s)."],
            ns.Stats.DIFF_MIN_N,
            tostring(ns.Stats.DIFF_P)
        ),
        info = L["Green: you get it more often, red: less often. Large differences can mean a changed loot table on this server or a mistake in how a loot window was attributed."],
    }
end

function CMP.Tabs()
    local list = Lk.Differences(200)
    return {
        {
            id = "diffs",
            label = L["Differences"],
            count = #list,
            table = "cmp",
            rows = list,
            empty = L["no significant differences between your data and everyone else's"],
        },
    }
end

function CMP.Select(r)
    if not r then return P.Analysis(nil) end
    P.Analysis(r, {
        title = ns.ItemName(r.itemId, true),
        kind = tostring(r.name),
        openType = "item",
        openId = r.itemId,
        openLabel = L["Open item"],
    })
end

function CMP.Open(r) P.Show({ type = "source", id = r.key }) end
CMP.RowTooltip = function(tt, r) tt:SetHyperlink("item:" .. r.itemId) end

P.Register("compare", CMP)

return R
