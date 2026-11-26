local _, ns = ...

-- Page tabs for facts that are not drop rates: who sells an item, what it is crafted from and used
-- for, which trainers teach its recipe and which quests need or start it; on NPC pages what the NPC
-- sells or teaches and which quests it starts or ends.
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

-- Trainer cost: coin, or training points at pet trainers.
local function TrainCost(e, pet)
    if not e.c then return "-" end
    if pet then return string.format(L["%d training points"], e.c) end
    return e.c > 0 and ns.Coin(e.c) or L["free"]
end

local function TrainZone(npc)
    local z = ns.Lookup.Zones(npc, 1)[1]
    return z and z.name or ""
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
    teaches = {
        {
            key = "name",
            title = L["Spell or recipe"],
            w = 180,
            text = function(r) return r.name end,
            icon = function(r) return r.icon end,
        },
        {
            key = "lv",
            title = L["Level"],
            w = 45,
            align = "RIGHT",
            text = function(r) return r.lv > 0 and tostring(r.lv) or "" end,
        },
        {
            key = "sk",
            title = L["Skill"],
            w = 45,
            align = "RIGHT",
            text = function(r) return r.sk > 0 and tostring(r.sk) or "" end,
        },
        { key = "c", title = L["Cost"], w = 110, align = "RIGHT", text = function(r) return r.costText end },
    },
    taught = {
        { key = "name", title = L["Trainer"], w = 140, text = function(r) return r.name end },
        { key = "zone", title = L["Zone"], w = 110, text = function(r) return r.zone end },
        {
            key = "sk",
            title = L["Skill"],
            w = 45,
            align = "RIGHT",
            text = function(r) return r.sk > 0 and tostring(r.sk) or "" end,
        },
        { key = "c", title = L["Cost"], w = 100, align = "RIGHT", text = function(r) return r.costText end },
    },
    reagents = {
        {
            key = "name",
            title = L["Item"],
            w = 220,
            text = function(r) return ns.ItemName(r.openId, true) end,
            icon = function(r) return ns.ItemIcon and ns.ItemIcon(r.openId) end,
        },
        { key = "role", title = L["Role"], w = 120, text = function(r) return r.roleText end },
        {
            key = "count",
            title = L["Qty"],
            w = 60,
            align = "RIGHT",
            text = function(r) return r.countText end,
        },
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
    ns.PageSpell.Columns[colset] = cols
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
    -- the item's own recipe opens the recipe's spell page; recipes using the item open their product
    local sid = role == "made" and ns.Crafting.SpellOf(product) or nil
    local openType = type(product) == "number" and "item" or nil
    if sid then
        openType = "spell"
    elseif role == "made" then
        openType = nil
    end
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
        openType = openType,
        openId = sid or (openType and product) or nil,
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

-- Trainers teaching a recipe (item page: `byItem`, the created item id) or a spell (spell page).
local function TrainerRows(id, bySpell)
    local rows = {}
    local T = ns.Trainers
    if not T then return rows end
    local itemId = not bySpell and id or nil
    local list = {}
    if bySpell then
        for npc in pairs(T.ForSpell(id)) do
            list[npc] = id
        end
    else
        list = T.ForItem(id)
    end
    for npc, service in pairs(list) do
        local info = T.Get(npc)
        local e = info and info.s[service]
        if e then
            local name = ns.Npcs and ns.Npcs.Name(npc) or ("NPC " .. npc)
            local cost = TrainCost(e, info.tt == "pet")
            rows[#rows + 1] = {
                extra = true,
                key = npc,
                itemId = itemId or ("spell:" .. id),
                name = name,
                zone = TrainZone(npc),
                sk = e.sk or 0,
                c = e.c or 0,
                costText = cost,
                openType = "source",
                openId = npc,
                detail = string.format(
                    "%s\n%s\n%s: %s%s",
                    name,
                    T.Label(info),
                    L["Cost"],
                    cost,
                    e.sk and string.format("\n%s: %d", L["Skill"], e.sk) or ""
                ),
            }
        end
    end
    table.sort(rows, function(a, b) return a.c < b.c end)
    return rows
end

-- What a trainer teaches (NPC page).
local function TeachRows(key)
    local rows = {}
    local info = ns.Trainers and ns.Trainers.Get(key)
    if not info then return rows end
    local pet = info.tt == "pet"
    for service, e in pairs(info.s) do
        local spellId = type(service) == "number" and service or nil
        local name = spellId and ns.Spells and ns.Spells.Title(spellId) or ns.Trainers.ServiceName(service, e)
        local cost = TrainCost(e, pet)
        local lines = { name, L["Cost"] .. ": " .. cost }
        if e.lv then lines[#lines + 1] = string.format("%s: %d", L["Level"], e.lv) end
        if e.sk then lines[#lines + 1] = string.format("%s: %d", L["Skill"], e.sk) end
        if e.it then lines[#lines + 1] = L["Creates"] .. ": " .. ns.ItemName(e.it, true) end
        rows[#rows + 1] = {
            extra = true,
            key = key,
            -- row identity only: never an item id (spells and items share number ranges)
            itemId = "service:" .. tostring(service),
            name = name,
            icon = spellId and ns.Spells and ns.Spells.Info(spellId).icon
                or (e.it and ns.ItemIcon and ns.ItemIcon(e.it)),
            lv = e.lv or 0,
            sk = e.sk or 0,
            c = e.c or 0,
            costText = cost,
            spellId = spellId,
            -- spell page (which links the item a recipe creates); without a spell id the item, else nothing
            openType = spellId and "spell" or (e.it and "item") or nil,
            openId = spellId or e.it,
            detail = table.concat(lines, "\n"),
        }
    end
    table.sort(rows, function(a, b)
        if a.sk ~= b.sk then return a.sk < b.sk end
        if a.lv ~= b.lv then return a.lv < b.lv end
        return a.name < b.name
    end)
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

-- What a recipe spell makes and needs (spell page): the created item, then the reagents.
local function SpellRecipeRows(spellId)
    local rows = {}
    local product = ns.Crafting and ns.Crafting.ForSpell(spellId)
    local r = product and ns.Crafting.Get(product)
    local made
    if type(product) == "number" then
        made = product
    else
        -- known only from a trainer: the item the service creates
        for npc in pairs(ns.Trainers and ns.Trainers.ForSpell(spellId) or {}) do
            local info = ns.Trainers.Get(npc)
            local e = info and info.s[spellId]
            if e and e.it then
                made = e.it
                break
            end
        end
    end
    if made then
        local count = r
            and ((r.mx or 1) > (r.mn or 1) and string.format("%d-%d", r.mn or 1, r.mx) or tostring(r.mn or 1))
        rows[#rows + 1] = {
            extra = true,
            key = spellId,
            itemId = made,
            roleText = L["Creates"],
            countText = count or "",
            openType = "item",
            openId = made,
        }
    end
    if r then
        local reagents = {}
        for id, n in pairs(r.r or {}) do
            reagents[#reagents + 1] = {
                extra = true,
                key = spellId,
                itemId = id,
                roleText = L["Reagent"],
                countText = tostring(n),
                openType = "item",
                openId = id,
            }
        end
        table.sort(reagents, function(a, b) return ns.ItemName(a.openId) < ns.ItemName(b.openId) end)
        for _, row in ipairs(reagents) do
            rows[#rows + 1] = row
        end
    end
    return rows, r
end

-- Spell page tabs (UI/PageSpell.lua calls this).
function X.SpellTabs(spellId)
    local tabs = {}
    local taught = TrainerRows(spellId, true)
    if #taught > 0 then
        tabs[#tabs + 1] = { id = "taught", label = L["Taught by"], count = #taught, table = "taught", rows = taught }
    end
    local recipe = SpellRecipeRows(spellId)
    if #recipe > 0 then
        tabs[#tabs + 1] = { id = "recipe", label = L["Recipe"], count = #recipe, table = "reagents", rows = recipe }
    end
    return tabs
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
    local taught = TrainerRows(itemId)
    if #taught > 0 then
        tabs[#tabs + 1] = { id = "taught", label = L["Taught by"], count = #taught, table = "taught", rows = taught }
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
    local teaches = TeachRows(key)
    if #teaches > 0 then
        tabs[#tabs + 1] = { id = "teaches", label = L["Teaches"], count = #teaches, table = "teaches", rows = teaches }
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
    if r.spellId and pcall(tt.SetHyperlink, tt, "spell:" .. r.spellId) then return end
    for line in tostring(r.detail or r.name or ""):gmatch("[^\n]+") do
        tt:AddLine(line, 1, 1, 1)
    end
    if r.openType then tt:AddLine(L["Double-click to open."], 0.5, 0.5, 0.5) end
end

return X
