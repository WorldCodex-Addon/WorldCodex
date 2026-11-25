local _, ns = ...

-- Page tabs for facts that are not drop rates: who sells an item, what it is crafted from and used
-- for, and which quests need or start it; on NPC pages what the NPC sells and which quests it
-- starts or ends.
local X = {}
ns.PageExtra = X

local L = ns.L
local P = ns.Page

local function TopZone(spawns)
    local best, bestW
    for map, cells in pairs(type(spawns) == "table" and spawns or {}) do
        local w = 0
        for _, n in pairs(cells) do
            w = w + n
        end
        if not bestW or w > bestW then
            best, bestW = map, w
        end
    end
    return best and ns.MapName(best) or ""
end

-- "1g 20s", "12 x [Token]", or both
function X.PriceText(e)
    local parts = {}
    if (e.p or 0) > 0 then parts[#parts + 1] = ns.Coin(e.p) end
    for id, n in pairs(e.x or {}) do
        parts[#parts + 1] = string.format("%d x %s", n, ns.ItemName(id))
    end
    return #parts > 0 and table.concat(parts, " + ") or "-"
end

local function Reagents(r)
    local parts = {}
    for id, n in pairs(r.r or {}) do
        parts[#parts + 1] = string.format("%dx %s", n, ns.ItemName(id))
    end
    table.sort(parts)
    return table.concat(parts, ", ")
end

local function ProductName(product)
    if type(product) == "number" then return ns.ItemName(product, true) end
    local spell = tonumber(tostring(product):match("enchant:(%d+)"))
    return spell and (ns.SpellName(spell) or ("enchant " .. spell)) or tostring(product)
end

local function QuestName(key) return tostring((ns.Store.SourceMeta(key))) end

-- ---------------------------------------------------------------- columns

local COLUMNS = {
    vendor = {
        { key = "name", title = L["Vendor"], w = 130, text = function(r) return r.name end },
        { key = "zone", title = L["Zone"], w = 110, text = function(r) return r.zone end },
        {
            key = "p",
            title = L["Price"],
            w = 100,
            align = "RIGHT",
            text = function(r) return X.PriceText(r.entry) end,
        },
        { key = "st", title = L["Stack"], w = 40, align = "RIGHT", text = function(r) return tostring(r.st) end },
        { key = "lim", title = L["Limited"], w = 50, text = function(r) return r.lim and L["yes"] or "" end },
    },
    sells = {
        { key = "name", title = L["Item"], w = 170, text = function(r) return ns.ItemName(r.itemId, true) end },
        {
            key = "p",
            title = L["Price"],
            w = 120,
            align = "RIGHT",
            text = function(r) return X.PriceText(r.entry) end,
        },
        { key = "st", title = L["Stack"], w = 40, align = "RIGHT", text = function(r) return tostring(r.st) end },
        { key = "lim", title = L["Limited"], w = 50, text = function(r) return r.lim and L["yes"] or "" end },
    },
    recipe = {
        { key = "name", title = L["Item"], w = 130, text = function(r) return ProductName(r.product) end },
        { key = "role", title = L["Role"], w = 80, text = function(r) return r.roleText end },
        { key = "pf", title = L["Profession"], w = 80, text = function(r) return r.pfName end },
        { key = "reagents", title = L["Reagents"], w = 140, text = function(r) return r.reagents end },
    },
    quest = {
        { key = "name", title = L["Quest"], w = 220, text = function(r) return r.name end },
        { key = "role", title = L["Role"], w = 160, text = function(r) return r.roleText end },
        {
            key = "count",
            title = L["Qty"],
            w = 50,
            align = "RIGHT",
            text = function(r) return r.count and tostring(r.count) or "" end,
        },
    },
}

for colset, cols in pairs(COLUMNS) do
    ns.PageItem.Columns[colset] = cols
    ns.PageSource.Columns[colset] = cols
end
-- item pages show drop tables of processing sources with the source page's columns
ns.PageItem.Columns.items = ns.PageSource.Columns.items

-- ---------------------------------------------------------------- rows

local function VendorRows(itemId)
    local rows = {}
    if not ns.Vendors then return rows end
    for npc in pairs(ns.Vendors.ForItem(itemId)) do
        local rec = ns.Vendors.Get(npc)
        local e = rec and rec.i and rec.i[itemId]
        if e then
            rows[#rows + 1] = {
                extra = true,
                key = npc,
                itemId = itemId,
                name = ns.Vendors.Name(npc),
                zone = TopZone(rec.sp),
                entry = e,
                p = e.p or 0,
                st = e.st or 1,
                lim = e.lim,
                openType = "source",
                openId = npc,
                detail = string.format(
                    "%s\n%s %s\n%s",
                    ns.Vendors.Name(npc),
                    L["Price"],
                    X.PriceText(e),
                    e.lim and L["Limited stock: the vendor restocks over time."] or ""
                ),
            }
        end
    end
    table.sort(rows, function(a, b) return a.p < b.p end)
    return rows
end

local function RecipeRow(product, r, role, itemId)
    return {
        extra = true,
        key = product,
        itemId = itemId,
        product = product,
        role = role,
        roleText = role == "made" and L["Created by"] or L["Reagent for"],
        pf = r.pf,
        pfName = ns.Crafting.ProfessionName(r.pf),
        reagents = Reagents(r),
        name = ProductName(product),
        openType = type(product) == "number" and "item" or nil,
        openId = type(product) == "number" and product or nil,
        detail = string.format(
            "%s\n%s: %s\n%s: %s%s",
            ProductName(product),
            L["Profession"],
            ns.Crafting.ProfessionName(r.pf),
            L["Reagents"],
            Reagents(r),
            (r.mx or 1) > 1 and string.format("\n%s %d-%d", L["Made"], r.mn or 1, r.mx) or ""
        ),
    }
end

local function RecipeRows(itemId)
    local rows = {}
    if not ns.Crafting then return rows end
    local own = ns.Crafting.Get(itemId)
    if own then rows[#rows + 1] = RecipeRow(itemId, own, "made", itemId) end
    for product in pairs(ns.Crafting.Using(itemId)) do
        local r = ns.Crafting.Get(product)
        if r then rows[#rows + 1] = RecipeRow(product, r, "reagent", itemId) end
    end
    return rows
end

local function QuestRow(key, roleText, count, itemId)
    return {
        extra = true,
        key = key,
        itemId = itemId or roleText,
        name = QuestName(key),
        roleText = roleText,
        count = count,
        openType = "source",
        openId = key,
        detail = QuestName(key) .. "\n" .. roleText,
    }
end

local function ObjectiveRows(itemId)
    local rows = {}
    if not ns.Quests then return rows end
    local idx = ns.Quests.Index()
    for _, e in ipairs(idx.requires[itemId] or {}) do
        rows[#rows + 1] = QuestRow(e.key, L["Required for the quest"], e.count, itemId)
    end
    for _, key in ipairs(idx.startedBy[itemId] or {}) do
        rows[#rows + 1] = QuestRow(key, L["Starts the quest"], nil, itemId)
    end
    return rows
end

-- What processing this item gives ("de:<id>", "mill:<id>", "prospect:<id>" sources): the source's
-- drop table, shown on the input item's page. Rows are copies so the cached model stays untouched.
local PROCESS = {
    { prefix = "de", label = L["Disenchants into"] },
    { prefix = "mill", label = L["Mills into"] },
    { prefix = "prospect", label = L["Prospects into"] },
}

local function ProcessTabs(itemId, layer, tabs)
    for _, p in ipairs(PROCESS) do
        local key = p.prefix .. ":" .. itemId
        if ns.Store.HasSource(key) then
            local rows = {}
            for _, r in ipairs(ns.Lookup.SourceModel(key, layer).items) do
                local c = {}
                for k, v in pairs(r) do
                    c[k] = v
                end
                c.asItem, c.openType, c.openId = true, "item", r.itemId
                rows[#rows + 1] = c
            end
            tabs[#tabs + 1] = { id = p.prefix, label = p.label, count = #rows, table = "items", rows = rows }
        end
    end
end

-- Extra item tabs (UI/PageItem.lua calls this).
function ns.ItemTabs(itemId, layer)
    local tabs = {}
    ProcessTabs(itemId, layer, tabs)
    local vendors = VendorRows(itemId)
    if #vendors > 0 then
        tabs[#tabs + 1] = { id = "vendors", label = L["Sold by"], count = #vendors, table = "vendor", rows = vendors }
    end
    local recipes = RecipeRows(itemId)
    if #recipes > 0 then
        tabs[#tabs + 1] = { id = "crafting", label = L["Crafting"], count = #recipes, table = "recipe", rows = recipes }
    end
    local objectives = ObjectiveRows(itemId)
    if #objectives > 0 then
        tabs[#tabs + 1] =
            { id = "objective", label = L["Objective of"], count = #objectives, table = "quest", rows = objectives }
    end
    return tabs
end

-- Extra source tabs (UI/PageSource.lua calls this).
function ns.SourceTabs(key)
    local tabs = {}
    local rec = ns.Vendors and ns.Vendors.Get(key)
    if rec then
        local rows = {}
        for id, e in pairs(rec.i) do
            rows[#rows + 1] = {
                extra = true,
                key = key,
                itemId = id,
                entry = e,
                p = e.p or 0,
                st = e.st or 1,
                lim = e.lim,
                name = ns.ItemName(id),
                openType = "item",
                openId = id,
                detail = ns.ItemName(id, true) .. "\n" .. L["Price"] .. " " .. X.PriceText(e),
            }
        end
        table.sort(rows, function(a, b) return a.name < b.name end)
        tabs[#tabs + 1] = { id = "sells", label = L["Sells"], count = #rows, table = "sells", rows = rows }
    end
    if ns.Quests then
        local idx = ns.Quests.Index()
        local rows = {}
        for _, q in ipairs(idx.starts[key] or {}) do
            rows[#rows + 1] = QuestRow(q, L["Starts the quest"], nil, "starts")
        end
        for _, q in ipairs(idx.ends[key] or {}) do
            rows[#rows + 1] = QuestRow(q, L["Quest turn-in"], nil, "ends")
        end
        if #rows > 0 then
            tabs[#tabs + 1] = { id = "quests", label = L["Quests"], count = #rows, table = "quest", rows = rows }
        end
    end
    return tabs
end

function X.Select(r) P.Analysis(nil, { empty = r.detail or "" }) end

function X.Tooltip(tt, r)
    if r.openType == "item" and r.openId then
        tt:SetHyperlink("item:" .. r.openId)
        return
    end
    for line in tostring(r.detail or r.name or ""):gmatch("[^\n]+") do
        tt:AddLine(line, 1, 1, 1)
    end
    if r.openType then tt:AddLine(L["Double-click to open."], 0.5, 0.5, 0.5) end
end

return X
