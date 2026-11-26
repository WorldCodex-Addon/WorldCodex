local _, ns = ...

-- Text views (chat, report window, detail pane) and file-style exports.
local R = {}
ns.Report = R

local L = ns.L
local Store = ns.Store
local QtyCsv

local function SortedKeys(t, cmp)
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys, cmp or function(a, b) return tostring(a) < tostring(b) end)
    return keys
end
R.SortedKeys = SortedKeys

local function Ser(v)
    local tv = type(v)
    if tv == "number" or tv == "boolean" then return tostring(v) end
    if tv == "string" then return string.format("%q", v) end
    if tv == "table" then
        local parts = {}
        for _, k in ipairs(SortedKeys(v)) do
            local kk = type(k) == "number" and ("[" .. k .. "]") or string.format("[%q]", k)
            parts[#parts + 1] = kk .. "=" .. Ser(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "nil"
end
R.Ser = Ser

function R.FindSource(query)
    local db = ns.db
    query = ns.Trim(query)
    local num = tonumber(query)
    if num and db.sources[num] then return num end
    if db.sources[query] then return query end
    local q = query:lower()
    local exact, partial, mobHit
    for key in pairs(Store.AllSourceKeys()) do
        local name, kind = Store.SourceMeta(key)
        local ln = tostring(name or ""):lower()
        if ln == q then
            if kind == "mob" then return key end
            exact = exact or key
        elseif ln:find(q, 1, true) then
            if kind == "mob" then mobHit = mobHit or key end
            partial = partial or key
        end
    end
    return exact or mobHit or partial
end

-- Expected value of one attempt at a source: items at market/vendor value plus coin.
function R.SourceValue(key)
    local n, money = Store.SourceBaseCombined(key)
    if n <= 0 then return 0, 0, 0 end
    local ev, evVendor = 0, 0
    for id in pairs(Store.SourceItems(key)) do
        local d, nn, q = Store.Combined(key, id)
        if nn > 0 and d > 0 then
            ev = ev + (q / nn) * ns.Prices.UnitValue(id)
            evVendor = evVendor + (q / nn) * ns.Prices.Vendor(id)
        end
    end
    local coin = money / n
    return ev + coin, evVendor + coin, n
end

-- "1 kill" / "5 kills" ("attempts" for gathering and containers, "turn-ins" for quests).
local function CountWord(n, kind)
    local one, many = L["attempt"], L["attempts"]
    if kind == "mob" then
        one, many = L["kill"], L["kills"]
    elseif kind == "quest" then
        one, many = L["turn-in"], L["turn-ins"]
    end
    return string.format("%d %s", n, n == 1 and one or many)
end
R.CountWord = CountWord

-- Who the numbers are from: the player, guild members, the other players in the community file, or
-- (when only one side is shown) everyone else.
R.LAYER_NAME = {
    me = L["Your data"],
    guild = L["Guild members"],
    community = L["Other players"],
    others = L["Everyone else"],
}

-- Short form for tooltips: "Your data: 0 of 1 kill · Other players: 1 of 5 kills".
local function PartsText(parts, kind)
    local out = {}
    for _, p in ipairs(parts or {}) do
        out[#out + 1] = string.format(
            "%s: %s",
            R.LAYER_NAME[p.layer] or p.layer,
            string.format(L["%d of %s"], p.d, CountWord(p.n, kind))
        )
    end
    return table.concat(out, " · ")
end
R.PartsText = PartsText

-- Long form for the analysis panel, one entry per layer: { layer =, label =, text = } with text like
-- "5 kills, 1 of them with Wool Cloth (20.0%)".
function R.PartsLines(parts, kind, itemName)
    local out = {}
    for _, p in ipairs(parts or {}) do
        out[#out + 1] = {
            layer = p.layer,
            label = R.LAYER_NAME[p.layer] or p.layer,
            text = string.format(
                L["%s, %d of them with %s (%s)"],
                CountWord(p.n, kind),
                p.d,
                itemName,
                ns.Pct(p.n > 0 and p.d / p.n or 0)
            ),
        }
    end
    return out
end

function R.PriceLine(itemId)
    local p = ns.Prices.Get(itemId)
    if not p then return nil end
    if not p.min then
        return string.format("%s: %s (%s %s)", L["Auction house"], L["none listed"], L["seen"], ns.Age(p.age))
    end
    return string.format(
        "%s %s · %s %s · %s %s · %s %s (%s%s)",
        L["min"],
        ns.Coin(p.min),
        L["avg"],
        ns.Coin(p.avg),
        L["max"],
        ns.Coin(p.max),
        L["market"],
        ns.Coin(p.market),
        ns.Age(p.age),
        p.origin == "guild" and (", " .. L["Guild"]) or ""
    )
end

-- Stack sizes of an item at a source: min, max, average per drop / per attempt and the distribution.
function R.Qty(key, itemId)
    local d, n, q = Store.Combined(key, itemId)
    local h, total = Store.QtyHist(key, itemId)
    local info = { avg = d > 0 and q / d or 0, perAttempt = n > 0 and q / n or 0, total = total, dist = {} }
    for size, cnt in pairs(h) do
        info.min = math.min(info.min or size, size)
        info.max = math.max(info.max or size, size)
        info.dist[#info.dist + 1] = { size = size, share = cnt / total, count = cnt }
    end
    table.sort(info.dist, function(a, b) return a.size < b.size end)
    return info
end

-- "1-3 (Ø 1.6)", "always 2", or "x1.6" when no stack sizes were recorded yet.
function R.QtyRange(info)
    if not info.min then return string.format("x%.1f", info.avg) end
    if info.min == info.max then return string.format("%s %d", L["always"], info.min) end
    return string.format("%d-%d (%s %.1f)", info.min, info.max, L["Avg"], info.avg)
end

-- "1× 55% · 2× 35% · 3× 10%" (at most `limit` sizes, the rest summed up)
function R.QtyDist(info, limit)
    limit = limit or 6
    local parts, rest = {}, 0
    for i, e in ipairs(info.dist) do
        if i <= limit then
            parts[#parts + 1] = string.format("%d× %s", e.size, ns.Pct(e.share):gsub("%.0%%", "%%"))
        else
            rest = rest + e.share
        end
    end
    if rest > 0 then parts[#parts + 1] = string.format("%s %s", L["more"], ns.Pct(rest)) end
    return table.concat(parts, " · ")
end

-- Colours (0-255) for rates by how sure they are, shared by tooltips and charts.
R.CONF_COLOR = {
    none = { 120, 120, 120 },
    low = { 150, 150, 150 },
    medium = { 230, 160, 40 },
    high = { 70, 200, 90 },
}
local TRACK = { 55, 55, 55 }
local BAR = "|TInterface\\Buttons\\WHITE8X8:%d:%d:0:0:8:8:0:8:0:8:%d:%d:%d|t"

-- Rate bar made of inline textures for tooltips and chat-like text: log scale from 0.1 % to 100 %,
-- the 95 % interval as a band and the rate as a bright marker. Segments narrower than 1 px are
-- left out (a 0 width would render at text size).
function R.RateBarText(lo, p, hi, width, height, conf)
    width, height = math.floor(width or 60), math.floor(height or 8)
    local pos = ns.Stats.LogPos
    local m = math.min(width - 2, math.max(0, math.floor(pos(p) * width + 0.5)))
    local a = math.min(m, math.max(0, math.floor(pos(lo) * width + 0.5)))
    local b = math.min(width, math.max(m + 2, math.floor(pos(hi) * width + 0.5)))
    local c = R.CONF_COLOR[conf or "high"] or R.CONF_COLOR.high
    local band = { math.floor(c[1] * 0.55), math.floor(c[2] * 0.55), math.floor(c[3] * 0.55) }
    local out, total = {}, 0
    local function seg(w, col)
        if w < 1 then return end
        total = total + w
        out[#out + 1] = string.format(BAR, height, w, col[1], col[2], col[3])
    end
    seg(a, TRACK)
    seg(m - a, band)
    seg(2, c)
    seg(b - m - 2, band)
    seg(width - b, TRACK)
    return table.concat(out), total
end

-- "Ø 2.3 items (1.8 stacks, max 5) · coin 12s 3c in 80% (5s-30s)"
function R.PerKillText(key, kind)
    local s = Store.SourceSummary(key)
    if s.n <= 0 then return nil end
    local per = (kind == "mob") and L["per kill"] or L["per attempt"]
    local parts = {
        string.format(
            "%s %s: %.2f %s (%.2f %s%s)",
            L["Avg"],
            per,
            s.items,
            L["items"],
            s.stacks,
            L["stacks"],
            s.imax and string.format(", %s %d", L["max"], s.imax) or ""
        ),
    }
    if s.coin > 0 or s.coinChance then
        local coin = string.format("%s %s", L["coin"], ns.Coin(s.coin))
        if s.coinChance then
            coin = coin .. string.format(" (%s %s", L["drops in"], ns.Pct(s.coinChance))
            if s.coinMin then coin = coin .. string.format(", %s-%s", ns.Coin(s.coinMin), ns.Coin(s.coinMax)) end
            coin = coin .. ")"
        end
        parts[#parts + 1] = coin
    end
    return table.concat(parts, " · ")
end

-- ---------------------------------------------------------------- item and source facts

-- What the panel next to the lists and the chat / report texts show about an item or a source, as
-- data: UI/Details.lua lays it out on the book page, R.FactsText turns it into lines.
--   { title, icon, id | key, subtitle, sections = { { title, rows = { row, ... } } } }
--   row: { label, value } | { entry = true, name, tag, value, sub, weak, key | itemId } | { note }
local SHOW_SOURCES, SHOW_DROPS = 6, 12

-- 22946 -> "22.946" on a German client (the client's own grouping), else plain.
local function BigNumber(n)
    n = math.floor((n or 0) + 0.5)
    if BreakUpLargeNumbers then
        local ok, s = pcall(BreakUpLargeNumbers, n)
        if ok and type(s) == "string" then return s end
    end
    return tostring(n)
end

local function AttemptsWord(kind)
    if kind == "mob" then return L["kills"] end
    if kind == "quest" then return L["turn-ins"] end
    return L["attempts"]
end

-- "1-3 per drop (avg 1.6)", "2 per drop", "avg 1.6 per drop"; nil when it is always one.
function R.StackText(info)
    if not info.min then
        if info.avg >= 1.05 then return string.format(L["avg %.1f per drop"], info.avg) end
        return nil
    end
    if info.min == info.max then
        if info.min > 1 then return string.format(L["%d per drop"], info.min) end
        return nil
    end
    return string.format(L["%d-%d per drop (avg %.1f)"], info.min, info.max, info.avg)
end

local function Spot(s) return string.format("%s (%.0f, %.0f)", ns.MapName(s.map), s.x * 100, s.y * 100) end

local CLASSIFICATION = {
    elite = L["elite"],
    rare = L["rare"],
    rareelite = L["rare elite"],
    worldboss = L["world boss"],
}
R.CLASSIFICATION = CLASSIFICATION

local function PriceRows(itemId)
    local rows = {}
    local p = ns.Prices.Get(itemId)
    if not p then
        rows[#rows + 1] = { note = L["no auction data yet"] }
    elseif p.min then
        rows[#rows + 1] = { label = L["Market value"], value = ns.Coin(p.market) }
        local range = ns.Coin(p.min)
        if p.max and p.max > p.min then range = range .. " – " .. ns.Coin(p.max) end
        rows[#rows + 1] = { label = L["Auction house"], value = range }
        if p.qty and p.qty > 0 then
            rows[#rows + 1] = { label = L["On offer"], value = string.format(L["%s pcs."], BigNumber(p.qty)) }
        end
        if p.min14 and p.min14 < p.min then rows[#rows + 1] = { label = L["14d low"], value = ns.Coin(p.min14) } end
        local hist = ns.Prices.History(itemId)
        if #hist > 1 then
            rows[#rows + 1] = {
                label = string.format(L["Trend (%d days)"], #hist),
                -- no arrow: the game's fonts have no glyph for it
                value = string.format(L["from %s to %s"], ns.CoinShort(hist[1].d.md), ns.CoinShort(hist[#hist].d.md)),
            }
        end
    else
        rows[#rows + 1] = { label = L["Auction house"], value = L["none listed"] }
    end
    if p then
        local when = string.format(L["%s ago"], ns.Age(p.age))
        if p.origin == "guild" then when = when .. " · " .. L["Guild"] end
        rows[#rows + 1] = { label = L["Last scan"], value = when }
    end
    local vendor = ns.Prices.Vendor(itemId)
    if vendor > 0 then rows[#rows + 1] = { label = L["Vendor price"], value = ns.Coin(vendor) } end
    return rows
end

local function SourceEntry(r, itemId)
    local name = tostring(r.name)
    if r.kind == "quest" then name = L["Quest"] .. ": " .. name end
    local parts = { string.format(L["%d of %d %s"], r.d, r.n, AttemptsWord(r.kind)) }
    local zone = ns.Lookup.Zones(r.key, 1)[1]
    if zone then parts[#parts + 1] = zone.name end
    parts[#parts + 1] = R.StackText(R.Qty(r.key, itemId))
    if r.choice then parts[#parts + 1] = L["choice"] end
    if r.done then parts[#parts + 1] = L["done"] end
    local weak = r.n < ns.Lookup.FEW
    if weak then parts[#parts + 1] = L["few data"] end
    return {
        entry = true,
        name = name,
        tag = r.kind ~= "mob" and r.kind ~= "quest" and ns.KIND_LABEL[r.kind] or nil,
        value = ns.Pct(r.rate),
        sub = table.concat(parts, " · "),
        weak = weak,
        key = r.key,
    }
end

-- Label of a stat key from C_Item.GetItemStats: the client's own global string ("Ausdauer" for
-- ITEM_MOD_STAMINA_SHORT on a German client), else the key.
local function StatLabel(key)
    local label = _G[key]
    if type(label) == "string" and label ~= "" and not ns.IsSecret(label) then return label end
    return key
end

R.StatLabel = StatLabel

local SHOWN_APART = { RESISTANCE0_NAME = true, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = true }

-- Stats, weapon damage, durability and effects recorded by Items.lua (queued when nothing is known yet).
function R.ItemDetailRows(itemId)
    local it = ns.db.items[itemId]
    local rows = {}
    if not (it and it.dv == (ns.Items and ns.Items.VERSION)) and ns.Items then
        -- not read yet: now, unless in combat (then queued); nothing recorded for trade goods
        if ns.InCombat() then
            ns.Items.Queue(itemId)
        else
            ns.Items.Read(itemId)
        end
        it = ns.db.items[itemId]
    end
    if not (it and it.dv) then return rows end
    local st = type(it.st) == "table" and it.st or {}
    if type(it.wd) == "table" and it.wd[1] then
        rows[#rows + 1] = { label = L["Damage"], value = string.format("%d - %d", it.wd[1], it.wd[2]) }
        local speed = it.wd[3]
        if speed and speed > 0 then
            rows[#rows + 1] = { label = L["Speed"], value = string.format("%.2f", speed / 1000) }
            local dps = st.ITEM_MOD_DAMAGE_PER_SECOND_SHORT or (it.wd[1] + it.wd[2]) / 2 / (speed / 1000)
            rows[#rows + 1] = { label = L["Damage per second"], value = string.format("%.1f", dps) }
        end
    end
    if st.RESISTANCE0_NAME then rows[#rows + 1] = { label = L["Armor"], value = tostring(st.RESISTANCE0_NAME) } end
    local keys = {}
    for key, v in pairs(st) do
        if not SHOWN_APART[key] and type(v) == "number" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local v = st[key]
        rows[#rows + 1] = { label = StatLabel(key), value = (v > 0 and "+" or "") .. tostring(v) }
    end
    if it.du then rows[#rows + 1] = { label = L["Durability"], value = tostring(it.du) } end
    if it.un then rows[#rows + 1] = { label = L["Unique"], value = tostring(it.un) } end
    if it.set then
        local get = C_Item and C_Item.GetItemSetInfo
        local name = get and ns.Call(get, it.set)
        rows[#rows + 1] = { label = L["Item set"], value = type(name) == "string" and name or ("#" .. it.set) }
    end
    for _, x in ipairs(type(it.fx) == "table" and it.fx or {}) do
        rows[#rows + 1] = { note = x[2] }
    end
    return rows
end

function R.ItemFacts(itemId)
    local d = ns.ItemDetails(itemId)
    local facts = { id = itemId, icon = d.texture, title = ns.ItemName(itemId, true), sections = {} }
    local sub = {}
    if d.subclass and d.subclass ~= "" then
        sub[#sub + 1] = d.subclass
    elseif d.class and d.class ~= "" then
        sub[#sub + 1] = d.class
    end
    if d.ilvl and d.ilvl > 1 then sub[#sub + 1] = string.format(L["item level %d"], d.ilvl) end
    if #sub > 0 then facts.subtitle = table.concat(sub, " · ") end
    facts.sections[1] = { title = L["Price"], rows = PriceRows(itemId) }

    local m = ns.Lookup.ItemModel(itemId, "all")
    local all = {}
    for _, section in ipairs(m.order) do
        for _, r in ipairs(m.sections[section]) do
            all[#all + 1] = r
        end
    end
    table.sort(all, ns.Lookup.RowOrder)
    local rows = {}
    for i = 1, math.min(SHOW_SOURCES, #all) do
        rows[#rows + 1] = SourceEntry(all[i], itemId)
    end
    if #all > SHOW_SOURCES then
        rows[#rows + 1] = { note = string.format(L["%d more on the item page"], #all - SHOW_SOURCES) }
    end
    if #all == 0 then rows[1] = { note = L["no drops recorded yet"] } end
    facts.sections[2] = { title = L["Sources"], rows = rows }
    local item = R.ItemDetailRows(itemId)
    if #item > 0 then facts.sections[#facts.sections + 1] = { title = L["Item"], rows = item } end

    if ns.FarmingOn() then
        local farm = {}
        local fastest = ns.Nav.Best(itemId)
        if fastest then
            farm[#farm + 1] = { label = L["Fastest"], value = ns.Nav.Label(fastest) }
            farm[#farm + 1] = { label = L["Time per drop"], value = "≈ " .. ns.Duration(fastest.minutes) }
            local spot = ns.Nav.PickHotspot(fastest.key)
            if spot then farm[#farm + 1] = { label = L["Best spot"], value = Spot(spot) } end
        end
        local have, target, minutes = ns.Farm.GoalProgress(itemId)
        if have then
            local goal = string.format("%d / %d", have, target)
            if minutes then goal = goal .. " · " .. string.format(L["ready in %s"], ns.Duration(minutes)) end
            farm[#farm + 1] = { label = L["Goal"], value = goal }
        end
        if #farm > 0 then facts.sections[#facts.sections + 1] = { title = L["Farming"], rows = farm } end
    end
    return facts
end

function R.SourceFacts(key)
    local m = ns.Lookup.SourceModel(key, "all")
    local kind = m.kind
    local facts = { key = key, title = tostring(m.name), sections = {} }
    local sub = { ns.KIND_LABEL[kind] or kind }
    if m.lmin and m.lmax and m.lmax ~= m.lmin then
        sub[#sub + 1] = string.format(L["level %d-%d"], m.lmin, m.lmax)
    elseif m.lmin then
        sub[#sub + 1] = string.format(L["level %d"], m.lmin)
    end
    if m.cls and CLASSIFICATION[m.cls] then sub[#sub + 1] = CLASSIFICATION[m.cls] end
    if m.zones[1] then sub[#sub + 1] = m.zones[1].name end
    facts.subtitle = table.concat(sub, " · ")

    local s, mob = m.summary, kind == "mob"
    local overview = {}
    if s.n > 0 then
        overview[#overview + 1] = { label = L["Recorded"], value = BigNumber(s.n) .. " " .. AttemptsWord(kind) }
        local ev, evVendor = R.SourceValue(key)
        overview[#overview + 1] = { label = mob and L["Value per kill"] or L["Value per attempt"], value = ns.Coin(ev) }
        if math.floor(evVendor + 0.5) ~= math.floor(ev + 0.5) then
            overview[#overview + 1] = { label = L["at vendor prices"], value = ns.Coin(evVendor) }
        end
        local items = string.format("%.1f", s.items)
        if s.imax then items = items .. string.format(" (%s %d)", L["max"], s.imax) end
        overview[#overview + 1] = { label = mob and L["Items per kill"] or L["Items per attempt"], value = items }
        if s.coin > 0 then
            local label = mob and L["Coin per kill"] or L["Coin per attempt"]
            overview[#overview + 1] = { label = label, value = ns.Coin(s.coin) }
        end
        if s.coinChance then
            local coin = ns.Pct(s.coinChance)
            if s.coinMin and s.coinMax and s.coinMax > s.coinMin then
                coin = coin .. " · " .. ns.Coin(s.coinMin) .. " – " .. ns.Coin(s.coinMax)
            end
            overview[#overview + 1] = { label = L["Coin chance"], value = coin }
        end
    end
    local spots = ns.Nav.Hotspots(key)
    if spots[1] then
        overview[#overview + 1] = { label = L["Location"], value = Spot(spots[1]) }
    elseif m.zones[1] then
        overview[#overview + 1] = { label = L["Location"], value = m.zones[1].name } -- instance: no position
    end
    local trainer = ns.Trainers and ns.Trainers.Get(key)
    if trainer then
        local n = 0
        for _ in pairs(trainer.s) do
            n = n + 1
        end
        overview[#overview + 1] = { label = ns.Trainers.Label(trainer), value = string.format(L["teaches %d"], n) }
    end
    if #overview > 0 then facts.sections[#facts.sections + 1] = { title = L["Overview"], rows = overview } end

    local drops = {}
    for i = 1, math.min(SHOW_DROPS, #m.items) do
        local r = m.items[i]
        local parts = { string.format(L["%d of %d %s"], r.d, r.n, AttemptsWord(kind)) }
        parts[#parts + 1] = R.StackText(R.Qty(key, r.itemId))
        local value = ns.Prices.UnitValue(r.itemId)
        if value > 0 then parts[#parts + 1] = ns.Coin(value) end
        local weak = r.n < ns.Lookup.FEW
        if weak then parts[#parts + 1] = L["few data"] end
        drops[#drops + 1] = {
            entry = true,
            name = ns.ItemName(r.itemId, true),
            value = ns.Pct(r.rate),
            sub = table.concat(parts, " · "),
            weak = weak,
            itemId = r.itemId,
        }
    end
    if #m.items > SHOW_DROPS then
        drops[#drops + 1] = { note = string.format(L["%d more on the source page"], #m.items - SHOW_DROPS) }
    end
    if #m.items == 0 then drops[1] = { note = L["no drops recorded yet"] } end
    facts.sections[#facts.sections + 1] = { title = L["Drops"], rows = drops }

    local rec = ns.db.sources[key]
    if rec then
        local own = {}
        local function add(label, n, note)
            if n and n > 0 then
                own[#own + 1] = { label = label, value = BigNumber(n) .. (note and (" (" .. note .. ")") or "") }
            end
        end
        if mob then
            add(L["Kills"], rec.kills)
            add(L["Looted"], rec.attempts)
            add(L["Empty corpses"], rec.ek)
            add(L["Not looted"], rec.ul, L["not counted"])
            add(L["In group"], rec.gk)
        else
            add(L["Attempts"], rec.attempts)
            add(L["Failed or interrupted"], rec.fails, L["not counted"])
        end
        if #own > 0 then facts.sections[#facts.sections + 1] = { title = L["Your data"], rows = own } end
    end
    return facts
end

-- The facts as text lines (chat, report window).
function R.FactsText(facts)
    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    add(facts.title .. (facts.id and ("  |cff888888#" .. facts.id .. "|r") or ""))
    if facts.subtitle and facts.subtitle ~= "" then add("|cff888888" .. facts.subtitle .. "|r") end
    for _, section in ipairs(facts.sections) do
        add("")
        add("|cffffd100" .. section.title .. "|r")
        for _, row in ipairs(section.rows) do
            if row.entry then
                local tag = row.tag and (" |cff888888(" .. row.tag .. ")|r") or ""
                add(string.format("  %s%s  %s", row.name, tag, row.value))
                if row.sub and row.sub ~= "" then add("      |cff888888" .. row.sub .. "|r") end
            elseif row.note then
                add("  |cff888888" .. row.note .. "|r")
            else
                add(string.format("  %s: %s", row.label, row.value))
            end
        end
    end
    return table.concat(lines, "\n")
end

function R.ItemDetail(itemId) return R.FactsText(R.ItemFacts(itemId)) end

function R.SourceDetail(key) return R.FactsText(R.SourceFacts(key)) end

local function StripColors(s)
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", ""))
end
R.StripColors = StripColors

function R.ReportText()
    local db = ns.db
    local lines = {}
    local count = 0
    for _ in pairs(db.sources) do
        count = count + 1
    end
    lines[#lines + 1] = string.format(
        "WorldCodex report | sources: %d | kills: %d | loot attempts: %d | items recorded: %d",
        count,
        db.totals.kills,
        db.totals.attempts,
        db.totals.items
    )
    lines[#lines + 1] =
        "rate = drops / (kills for mobs, attempts otherwise) | CI = 95% Wilson interval | value = expected value per attempt"
    local byKind = {}
    for key, rec in pairs(db.sources) do
        local kind = rec.kind or "other"
        byKind[kind] = byKind[kind] or {}
        table.insert(byKind[kind], key)
    end
    for _, kind in ipairs(ns.KIND_ORDER) do
        local keys = byKind[kind]
        if keys then
            table.sort(keys, function(a, b) return Store.Base(db.sources[a]) > Store.Base(db.sources[b]) end)
            lines[#lines + 1] = ""
            lines[#lines + 1] = "== " .. (ns.KIND_LABEL[kind] or kind) .. " =="
            for _, key in ipairs(keys) do
                lines[#lines + 1] = R.SourceDetail(key)
                lines[#lines + 1] = ""
            end
        end
    end
    return table.concat(lines, "\n")
end

-- Everything collected, as one Lua table (see Export.lua).
function R.ExportLua() return ns.Export.Lua() end

local function Csv(s) return '"' .. tostring(s or ""):gsub('"', '""') .. '"' end

-- "min,max,1:12;2:7;3:1" for the CSV export (personal stack-size histogram)
function QtyCsv(h)
    if type(h) ~= "table" or not next(h) then return ",," end
    local sizes = {}
    for size in pairs(h) do
        sizes[#sizes + 1] = size
    end
    table.sort(sizes)
    local parts = {}
    for _, size in ipairs(sizes) do
        parts[#parts + 1] = size .. ":" .. h[size]
    end
    return sizes[1] .. "," .. sizes[#sizes] .. "," .. table.concat(parts, ";")
end

function R.ExportCSV()
    local db = ns.db
    local lines = {
        "source_key,source_name,kind,kills,attempts,sample_n,item_id,item_name,times_dropped,total_quantity,"
            .. "rate_pct,ci95_low_pct,ci95_high_pct,avg_qty_per_drop,avg_qty_per_attempt,qty_min,qty_max,qty_distribution,"
            .. "dry_streak,vendor_copper,"
            .. "ah_min_copper,ah_avg_copper,ah_max_copper,ah_market_copper,ah_scanned_at,ev_per_attempt_copper,"
            .. "items_per_attempt,coin_per_attempt_copper,coin_drop_pct,coin_min_copper,coin_max_copper",
    }
    for _, key in ipairs(SortedKeys(db.sources)) do
        local rec = db.sources[key]
        local ev = R.SourceValue(key)
        local sum = Store.SourceSummary(key)
        local srcCols = table.concat({
            string.format("%.4f", sum.items),
            string.format("%.0f", sum.coin),
            sum.coinChance and string.format("%.2f", sum.coinChance * 100) or "",
            sum.coinMin or "",
            sum.coinMax or "",
        }, ",")
        for _, id in ipairs(SortedKeys(rec.loot, function(a, b) return a < b end)) do
            -- quest items: only attempts made while their quest was active
            local n, d, q, h = Store.OwnCounts(rec, id, Store.IsGated(id))
            local l = { d = d, q = q, h = h }
            local lo, hi = ns.Stats.Wilson(l.d, n)
            local p = ns.Prices.Get(id)
            lines[#lines + 1] = table.concat({
                Csv(key),
                Csv(rec.name),
                rec.kind,
                rec.kills,
                rec.attempts,
                n,
                id,
                Csv(ns.ItemName(id)),
                l.d,
                l.q,
                string.format("%.4f", n > 0 and l.d / n * 100 or 0),
                string.format("%.4f", lo * 100),
                string.format("%.4f", hi * 100),
                string.format("%.4f", l.d > 0 and l.q / l.d or 0),
                string.format("%.4f", n > 0 and l.q / n or 0),
                QtyCsv(l.h),
                rec.streak[id] or 0,
                ns.Prices.Vendor(id),
                p and p.min or "",
                p and p.avg or "",
                p and p.max or "",
                p and p.market or "",
                p and ns.date("%Y-%m-%d %H:%M", p.t) or "",
                string.format("%.0f", ev),
                srcCols,
            }, ",")
        end
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------- share string

-- When the shipped community file already contains this installation's upload (contributors[uid]),
-- the share string only carries what changed since then (a delta, v = 2): after years of play that
-- is a small part of everything. merge.py adds it on top of the earlier upload. `full` forces
-- everything, e.g. when the website no longer has the earlier upload.
local shareCache = {} -- [full] = { key, text, info }

local function ShareKey(base) return table.concat({ ns.db.meta.rev, Store.gen, base or "full" }, ":") end

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do
        n = n + 1
    end
    return n
end

-- Revision of our upload in the community file the share string builds on, or nil (full string).
function R.ShareBase(full)
    if full then return nil end
    return Store.DeltaBase()
end

-- Returns text, info { base, rev, sources, items, prices, bytes }. Yields inside jobs (ns.RunJob).
function R.ExportString(full)
    local base = R.ShareBase(full)
    local key = ShareKey(base)
    local cached = shareCache[full and true or false]
    if cached and cached.key == key then return cached.text, cached.info end
    local snap = Store.Snapshot({
        minN = 1,
        cells = 16,
        ah = true,
        ahMaxAge = 30 * 86400,
        vendors = true,
        recipes = true,
        npcs = true,
        trainers = true,
        spells = true,
        items = true,
        questBases = true,
        since = base,
    })
    local text = ns.Codec.Encode(snap)
    local info = {
        base = base,
        rev = snap.rev,
        sources = Count(snap.src),
        items = Count(snap.it),
        prices = Count(snap.ah),
        vendors = Count(snap.vd),
        npcs = Count(snap.np),
        trainers = Count(snap.tr),
        bytes = #text,
    }
    -- this revision is published now: the next change opens a new one (Store.Mark)
    Store.Seal(snap.rev)
    shareCache[full and true or false] = { key = key, text = text, info = info }
    return text, info
end

-- Builds the share string over several frames; done(text, info) or done(nil, nil, err). A cached
-- string (nothing changed since) is handed over at once.
function R.ExportStringAsync(full, done)
    local cached = shareCache[full and true or false]
    if cached and cached.key == ShareKey(R.ShareBase(full)) then return done(cached.text, cached.info) end
    ns.RunJob("share", function()
        local text, info = R.ExportString(full)
        return { text = text, info = info }
    end, function(ok, res)
        if ok and res then
            done(res.text, res.info)
        else
            done(nil, nil, res)
        end
    end)
end

function R.Import(str)
    local snap, err = ns.Codec.Decode(str)
    if not snap then return false, err end
    local id = "import:" .. tostring(snap.uid or "?")
    local ok, why = Store.ImportPeer(id, snap, L["Imported"] .. " " .. ns.date("%Y-%m-%d"))
    if not ok then return false, why end
    local n = 0
    for _ in pairs(ns.db.peers[id].src) do
        n = n + 1
    end
    return true, n
end

-- ---------------------------------------------------------------- chat output

function R.PrintItem(query)
    local id = ns.Nav.FindItem(ns.Trim(query))
    if not id then
        ns.Print(string.format(L["nothing found for '%s'"], query))
        return
    end
    for line in R.ItemDetail(id):gmatch("[^\n]+") do
        ns.Print(line)
    end
end

function R.PrintSource(query)
    local key = R.FindSource(query)
    if not key then
        ns.Print(string.format(L["nothing found for '%s'"], query))
        return
    end
    local i = 0
    for line in R.SourceDetail(key):gmatch("[^\n]+") do
        i = i + 1
        if i > 30 then
            ns.Print("... /worldcodex")
            break
        end
        ns.Print(line)
    end
end

-- Chat list of (source, item) pairs where the player's rate differs from everyone else's.
function R.PrintDifferences(limit)
    local list = ns.Lookup.Differences(limit or 15)
    if #list == 0 then
        ns.Print(L["no significant differences between your data and everyone else's"])
        return
    end
    for _, r in ipairs(list) do
        ns.Print(
            string.format(
                "%s @ %s: %s %d/%d (%s) · %s %d/%d (%s)",
                ns.ItemName(r.itemId, true),
                tostring(r.name),
                L["You"],
                r.mine.d,
                r.mine.n,
                ns.Pct(r.mine.d / r.mine.n),
                L["Community"],
                r.others.d,
                r.others.n,
                ns.Pct(r.others.d / r.others.n)
            )
        )
    end
end

function R.PrintTop(n)
    local db = ns.db
    local keys = SortedKeys(db.sources, function(a, b) return Store.Base(db.sources[a]) > Store.Base(db.sources[b]) end)
    for i = 1, math.min(n, #keys) do
        local rec = db.sources[keys[i]]
        ns.Print(
            string.format(
                "%d. %s (%s) n=%d, value %s",
                i,
                tostring(rec.name),
                ns.KIND_LABEL[rec.kind] or rec.kind,
                Store.Base(rec),
                ns.Coin((R.SourceValue(keys[i])))
            )
        )
    end
    if #keys == 0 then ns.Print(L["nothing recorded yet"]) end
end

function R.PrintKinds()
    local counts = {}
    for _, rec in pairs(ns.db.sources) do
        counts[rec.kind] = (counts[rec.kind] or 0) + 1
    end
    for _, kind in ipairs(ns.KIND_ORDER) do
        if counts[kind] then ns.Print(string.format("%s: %d", ns.KIND_LABEL[kind] or kind, counts[kind])) end
    end
end

function R.PrintStatus()
    local db = ns.db
    local count = 0
    for _ in pairs(db.sources) do
        count = count + 1
    end
    ns.Print(
        string.format(
            "v%s | sources: %d | kills: %d | loot attempts: %d | items: %d",
            ns.VERSION,
            count,
            db.totals.kills,
            db.totals.attempts,
            db.totals.items
        )
    )
    local gen, contributors = ns.CommunityInfo()
    if gen then
        ns.Print(string.format(L["Community data from %s, %d contributors"], ns.date("%Y-%m-%d", gen), contributors))
    else
        ns.Print(L["No community data in this version."])
    end
    ns.Print(ns.AH.Status())
    ns.Print(ns.Sync.Status())
end

return R
