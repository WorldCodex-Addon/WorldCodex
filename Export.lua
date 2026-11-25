local _, ns = ...

-- Export of everything WorldCodex collected (the player's own data; guild and community data are
-- not the player's and stay out): drops, quests, items, auction prices and their history,
-- vendors, recipes, NPCs, map names and personal statistics. As Lua, JSON (for the website and
-- other tools) or CSV, one table per kind of data. The compact share string for uploads lives in
-- Report.ExportString.
local Ex = {}
ns.Export = Ex

local L = ns.L
local Store = ns.Store

Ex.FORMAT = 1 -- version of the full export structure (docs/export.md)

Ex.SECTIONS = {
    { id = "sources", label = L["Drops"] },
    { id = "quests", label = L["Quests"] },
    { id = "items", label = L["Items"] },
    { id = "prices", label = L["Prices"] },
    { id = "history", label = L["Price history"] },
    { id = "vendors", label = L["Vendors"] },
    { id = "recipes", label = L["Recipes"] },
    { id = "npcs", label = L["NPCs"] },
    { id = "maps", label = L["Maps"] },
    { id = "personal", label = L["Sessions & goals"] },
}

Ex.CSV = { "drops", "quests", "items", "prices", "history", "vendors", "recipes", "npcs" }

-- Deep copy without `rv` (the revision of a record's last change: bookkeeping for share strings).
local function Copy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do
        if k ~= "rv" then c[k] = Copy(x) end
    end
    return c
end

local function Sorted(t, numeric)
    local keys = {}
    for k in pairs(t or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        if numeric and type(a) == "number" and type(b) == "number" then return a < b end
        if type(a) ~= type(b) then return type(a) == "number" end
        return tostring(a) < tostring(b)
    end)
    return keys
end
Ex.Sorted = Sorted

local function Cell(map, cell)
    local x, y = Store.CellXY(cell)
    return { map = map, zone = ns.MapName(map), x = math.floor(x * 1000) / 10, y = math.floor(y * 1000) / 10 }
end

-- ---------------------------------------------------------------- sections

local function QuestId(key) return ns.Quests and ns.Quests.IdFromKey(key) end

local function Sources()
    local out = {}
    for key, rec in pairs(ns.db.sources) do
        if not QuestId(key) then
            local c = Copy(rec)
            c.n = Store.Base(rec) -- the rate denominator, so rates can be computed without our rules
            -- quest items: only attempts made while their quest was active, with their own denominator
            for id, l in pairs(c.loot) do
                if Store.IsGated(id) then
                    l.n, l.d, l.q, l.h = Store.OwnCounts(rec, id, true)
                    l.h = Copy(l.h)
                end
            end
            c.qb, c.qp = nil, nil
            c.lk = nil -- session clock, meaningless outside the game
            out[key] = c
        end
    end
    return out
end

local function Quests()
    local out = {}
    for key, rec in pairs(ns.db.sources) do
        local qid = QuestId(key)
        if qid then
            local rewards = {}
            for id, l in pairs(rec.loot) do
                rewards[id] = {
                    perTurnIn = rec.attempts > 0 and l.q / rec.attempts or 0,
                    times = l.d,
                    total = l.q,
                    choice = rec.choice and rec.choice[id] or nil,
                }
            end
            local accept
            for map, cells in pairs(rec.spawns or {}) do
                for cell in pairs(cells) do
                    accept = accept or Cell(map, cell)
                end
            end
            out[qid] = {
                title = rec.name,
                repeats = rec.rep,
                giver = rec.giver,
                giverKey = rec.gid,
                turnInKey = rec.tid,
                startItem = rec.si,
                required = Copy(rec.req),
                turnIns = rec.attempts,
                money = rec.money,
                rewards = rewards,
                accepted = accept,
                first = rec.first,
                last = rec.last,
            }
        end
    end
    -- accepted, not yet turned in
    for qid, s in pairs(ns.db.questStarts or {}) do
        if not out[qid] then
            out[qid] = {
                title = s.title,
                giver = s.giver,
                giverKey = s.gid,
                startItem = s.si,
                inProgress = true,
                accepted = s.map and s.x and { map = s.map, zone = ns.MapName(s.map), x = s.x * 100, y = s.y * 100 }
                    or nil,
            }
        end
    end
    return out
end

-- Every item id the data mentions.
local function ItemIds()
    local ids = {}
    local function add(id)
        if type(id) == "number" then ids[id] = true end
    end
    for id in pairs(ns.db.items) do
        add(id)
    end
    for id in pairs(ns.db.ah) do
        add(id)
    end
    for _, rec in pairs(ns.db.sources) do
        for id in pairs(rec.loot) do
            add(id)
        end
        for id in pairs(type(rec.req) == "table" and rec.req or {}) do
            add(id)
        end
        add(rec.si)
    end
    for _, v in pairs(ns.db.vendors or {}) do
        for id, e in pairs(v.i or {}) do
            add(id)
            for cost in pairs(e.x or {}) do
                add(cost)
            end
        end
    end
    for product, r in pairs(ns.db.recipes or {}) do
        add(product)
        for id in pairs(r.r or {}) do
            add(id)
        end
    end
    return ids
end

local function Items()
    local out = {}
    for id in pairs(ItemIds()) do
        local it = ns.db.items[id]
        local e = it and Copy(it) or {}
        e.src = nil -- the item -> source index is rebuilt from the drops
        if not e.n then
            -- not looted ourselves (prices, vendors, recipes): ask the client cache
            local d = ns.ItemDetails(id)
            if d.name then
                e.n, e.ql, e.v, e.il, e.rq = d.name, d.quality, d.sellPrice, d.ilvl, d.minLevel
                e.cl, e.sc, e.eq, e.ic, e.sk, e.bd = d.classId, d.subclassId, d.equipLoc, d.texture, d.stack, d.bind
            end
        end
        out[id] = e
    end
    return out
end

local function Prices(history)
    local out = {}
    for id, rec in pairs(ns.db.ah) do
        if history then
            if rec.days and next(rec.days) then out[id] = Copy(rec.days) end
        elseif rec.last then
            local c = Copy(rec.last)
            local p = ns.Prices.Get(id)
            c.market = p and p.market or nil
            out[id] = c
        end
    end
    return out
end

local function Personal()
    local db = ns.db
    return {
        totals = Copy(db.totals),
        sessions = Copy(db.farm.hist),
        currentSession = Copy(db.farm.cur),
        goals = Copy(db.farm.goals),
        activeDays = Copy(db.kpi.days),
        calibration = Copy(db.kpi.cal),
        created = db.meta.created,
    }
end

local BUILD = {
    sources = Sources,
    quests = Quests,
    items = Items,
    prices = function() return Prices(false) end,
    history = function() return Prices(true) end,
    vendors = function() return Copy(ns.db.vendors or {}) end,
    recipes = function() return Copy(ns.db.recipes or {}) end,
    npcs = function() return Copy(ns.db.npcs or {}) end,
    maps = function() return Copy(ns.db.maps) end,
    personal = Personal,
}

-- selection: { [sectionId] = true } or nil for everything
function Ex.Collect(selection)
    local db = ns.db
    local out = {
        format = Ex.FORMAT,
        addon = ns.VERSION,
        exported = ns.time(),
        uid = db.meta.uid,
        rev = db.meta.rev,
        locale = db.meta.locale,
        realm = db.meta.realm,
        faction = db.meta.faction,
    }
    for _, s in ipairs(Ex.SECTIONS) do
        if not selection or selection[s.id] then out[s.id] = BUILD[s.id]() end
    end
    return out
end

-- ---------------------------------------------------------------- Lua and JSON

function Ex.Lua(selection) return "WorldCodex_Export = " .. ns.Report.Ser(Ex.Collect(selection)) end

local ESC =
    { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function JsonString(s)
    return '"' .. s:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

-- 1..n without gaps -> JSON array, everything else -> object with string keys
local function IsArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return false end
        n = n + 1
    end
    return n > 0 and n == #t
end

local function Json(v, out)
    local tv = type(v)
    if tv == "nil" then
        out[#out + 1] = "null"
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            out[#out + 1] = "null"
        elseif v == math.floor(v) and math.abs(v) < 2 ^ 53 then
            out[#out + 1] = string.format("%d", v)
        else
            out[#out + 1] = string.format("%.10g", v)
        end
    elseif tv == "string" then
        out[#out + 1] = JsonString(v)
    elseif tv == "table" then
        if IsArray(v) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                Json(v[i], out)
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local first = true
            for _, k in ipairs(Sorted(v)) do
                if not first then out[#out + 1] = "," end
                first = false
                out[#out + 1] = JsonString(tostring(k))
                out[#out + 1] = ":"
                Json(v[k], out)
            end
            out[#out + 1] = "}"
        end
    else
        out[#out + 1] = "null"
    end
end

function Ex.JsonEncode(v)
    local out = {}
    Json(v, out)
    return table.concat(out)
end

function Ex.Json(selection) return Ex.JsonEncode(Ex.Collect(selection)) end

-- ---------------------------------------------------------------- CSV

local function Q(s)
    if s == nil or s == "" then return "" end
    if type(s) == "number" or type(s) == "boolean" then return tostring(s) end
    return '"' .. tostring(s):gsub('"', '""') .. '"'
end

local function Row(lines, ...)
    local t = { ... }
    local n = select("#", ...)
    for i = 1, n do
        t[i] = Q(t[i])
    end
    lines[#lines + 1] = table.concat(t, ",", 1, n)
end

local function Day(day) return ns.date("%Y-%m-%d", day * 86400) end

local CSV = {}

CSV.drops = function() return ns.Report.ExportCSV() end

CSV.quests = function()
    local lines = {
        "quest_id,title,repeats,giver,giver_key,turn_in_key,turn_ins,money_copper,relation,item_id,item_name,quantity,choice",
    }
    local q = Quests()
    for _, qid in ipairs(Sorted(q, true)) do
        local e = q[qid]
        local function line(relation, id, qty, choice)
            Row(
                lines,
                qid,
                e.title,
                e.repeats,
                e.giver,
                e.giverKey,
                e.turnInKey,
                e.turnIns,
                e.money,
                relation,
                id,
                id and ns.ItemName(id) or nil,
                qty,
                choice
            )
        end
        local any = false
        for _, id in ipairs(Sorted(e.rewards or {}, true)) do
            local r = e.rewards[id]
            line("reward", id, string.format("%.2f", r.perTurnIn), r.choice and true or false)
            any = true
        end
        for _, id in ipairs(Sorted(e.required or {}, true)) do
            line("required", id, e.required[id], nil)
            any = true
        end
        if e.startItem then
            line("starts_with", e.startItem, 1, nil)
            any = true
        end
        if not any then line(e.inProgress and "in_progress" or "", nil, nil, nil) end
    end
    return table.concat(lines, "\n")
end

CSV.items = function()
    local lines = {
        "item_id,name,quality,item_level,required_level,class_id,subclass_id,equip_slot,icon,stack,bind,vendor_sell_copper",
    }
    local items = Items()
    for _, id in ipairs(Sorted(items, true)) do
        local e = items[id]
        Row(lines, id, e.n, e.ql, e.il, e.rq, e.cl, e.sc, e.eq, e.ic, e.sk, e.bd, e.v)
    end
    return table.concat(lines, "\n")
end

CSV.prices = function()
    local lines = {
        "item_id,item_name,scanned_at,min_copper,median_copper,avg_copper,max_copper,market_copper,listed_qty",
    }
    local p = Prices(false)
    for _, id in ipairs(Sorted(p, true)) do
        local e = p[id]
        Row(lines, id, ns.ItemName(id), e.t and ns.date("%Y-%m-%d %H:%M", e.t), e.mi, e.md, e.mn, e.mx, e.market, e.q)
    end
    return table.concat(lines, "\n")
end

CSV.history = function()
    local lines = { "item_id,item_name,day,min_copper,median_copper,avg_copper,max_copper,listed_qty,scans" }
    local h = Prices(true)
    for _, id in ipairs(Sorted(h, true)) do
        local name = ns.ItemName(id)
        for _, day in ipairs(Sorted(h[id], true)) do
            local d = h[id][day]
            Row(lines, id, name, Day(day), d.mi, d.md, d.mn, d.mx, d.q, d.c)
        end
    end
    return table.concat(lines, "\n")
end

CSV.vendors = function()
    local lines = { "npc_id,vendor_name,item_id,item_name,price_copper,stack,limited,item_costs,zone,x,y,last_seen" }
    local vendors = ns.db.vendors or {}
    for _, npc in ipairs(Sorted(vendors, true)) do
        local v = vendors[npc]
        local spot
        for map, cells in pairs(v.sp or {}) do
            for cell in pairs(cells) do
                spot = spot or Cell(map, cell)
            end
        end
        for _, id in ipairs(Sorted(v.i or {}, true)) do
            local e = v.i[id]
            local costs = {}
            for _, cid in ipairs(Sorted(e.x or {}, true)) do
                costs[#costs + 1] = e.x[cid] .. "x" .. cid
            end
            Row(
                lines,
                npc,
                v.nm,
                id,
                ns.ItemName(id),
                e.p,
                e.st,
                e.lim and true or false,
                table.concat(costs, ";"),
                spot and spot.zone,
                spot and spot.x,
                spot and spot.y,
                v.t and ns.date("%Y-%m-%d", v.t)
            )
        end
    end
    return table.concat(lines, "\n")
end

CSV.recipes = function()
    local lines = { "product,product_name,profession,made_min,made_max,reagent_id,reagent_name,reagent_count" }
    local recipes = ns.db.recipes or {}
    for _, product in ipairs(Sorted(recipes)) do
        local r = recipes[product]
        local name = type(product) == "number" and ns.ItemName(product) or product
        for _, id in ipairs(Sorted(r.r or {}, true)) do
            Row(lines, product, name, r.pf, r.mn, r.mx, id, ns.ItemName(id), r.r[id])
        end
    end
    return table.concat(lines, "\n")
end

CSV.npcs = function()
    local lines = {
        "npc_key,name,level_min,level_max,classification,reaction,roles,map_id,zone,x,y,times_seen,last_seen",
    }
    local npcs = ns.db.npcs or {}
    for _, key in ipairs(Sorted(npcs)) do
        local r = npcs[key]
        local roles = {}
        for _, role in ipairs(Sorted(r.f or {})) do
            roles[#roles + 1] = role
        end
        local function line(map, cell, count)
            local c = map and Cell(map, cell) or {}
            Row(
                lines,
                key,
                r.nm,
                r.lv and r.lv[1],
                r.lv and r.lv[2],
                r.cl,
                r.r,
                table.concat(roles, ";"),
                map,
                c.zone,
                c.x,
                c.y,
                count,
                r.t and ns.date("%Y-%m-%d", r.t)
            )
        end
        local any = false
        for _, map in ipairs(Sorted(r.sp or {}, true)) do
            for _, cell in ipairs(Sorted(r.sp[map], true)) do
                line(map, cell, r.sp[map][cell])
                any = true
            end
        end
        if not any then line(nil, nil, nil) end
    end
    return table.concat(lines, "\n")
end

function Ex.Csv(dataset)
    local fn = CSV[dataset or "drops"] or CSV.drops
    return fn()
end

return Ex
