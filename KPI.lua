local _, ns = ...

-- Measures the KPIs from the roadmap inside the game. K.Rows() returns one row per KPI for the KPI
-- page (UI/PageKPI.lua): value, target, a gauge scale, status and the data for its chart.
local K = {}
ns.KPI = K

local L = ns.L
local MIN_N_FOR_PREDICTION = 30

-- Before an attempt is counted: store predicted drop chance per known item vs. what dropped.
-- Uses the per-looted-attempt rate so empty, unlootable corpses don't bias the check.
function K.RecordPrediction(rec, items)
    local n = rec.attempts or 0
    if n < MIN_N_FOR_PREDICTION then return end
    local cal = ns.db.kpi.cal
    for itemId, l in pairs(rec.loot) do
        local p = math.min(1, l.d / n)
        if p > 0 and not ns.Store.IsGated(itemId) then -- quest items: not every attempt can drop them
            local bin = math.min(10, math.floor(p * 10) + 1)
            local b = cal[bin]
            if not b then
                b = { pred = 0, obs = 0, c = 0 }
                cal[bin] = b
            end
            b.pred = b.pred + p
            b.obs = b.obs + (items[itemId] and 1 or 0)
            b.c = b.c + 1
        end
    end
end

-- For bins with enough samples: share where observed frequency lies in the 95% CI of the prediction.
function K.Calibration()
    local rows, inside, total = {}, 0, 0
    for bin = 1, 10 do
        local b = ns.db.kpi.cal[bin]
        if b and b.c > 0 then
            local pred, obs = b.pred / b.c, b.obs / b.c
            local se = math.sqrt(math.max(pred * (1 - pred), 1e-9) / b.c)
            local ok = math.abs(obs - pred) <= 1.96 * se
            rows[#rows + 1] = { bin = bin, pred = pred, obs = obs, c = b.c, se = se, ok = ok }
            if b.c >= 30 then
                total = total + 1
                if ok then inside = inside + 1 end
            end
        end
    end
    return rows, total > 0 and inside / total or nil
end

function K.Compute()
    local db = ns.db
    local now = ns.time()
    local m = {}

    -- Coverage: looted items with a solid source (n>=30) and a fresh price (<24h).
    local looted, covered, ages, ciWidths = 0, 0, {}, {}
    for itemId, it in pairs(db.items) do
        if it.src and next(it.src) then
            looted = looted + 1
            local best = ns.Nav.Best(itemId)
            local price = ns.Prices.Get(itemId)
            if price then ages[#ages + 1] = price.age end
            if best and best.n >= 30 and price and price.age < 86400 then covered = covered + 1 end
            for key in pairs(it.src) do
                local d, n = ns.Store.Combined(key, itemId)
                if n >= 10 and d > 0 then
                    local lo, hi = ns.Stats.Wilson(d, n)
                    ciWidths[#ciWidths + 1] = (hi - lo) / 2
                end
            end
        end
    end
    m.coverage = looted > 0 and covered / looted or nil
    m.looted, m.covered = looted, covered
    m.ages, m.ciWidths = ages, ciWidths
    m.priceAge = ns.Stats.Median(ages)
    m.ciHalfWidth = ns.Stats.Median(ciWidths)

    -- Farming uplift: gold/hour of sessions that followed a recommendation vs. the others.
    local withNav, without = {}, {}
    for _, s in ipairs(db.farm.hist) do
        local gph = ns.Farm.GoldPerHour(s)
        if s.nav then
            withNav[#withNav + 1] = gph
        else
            without[#without + 1] = gph
        end
    end
    local a, b = ns.Stats.Mean(withNav), ns.Stats.Mean(without)
    m.uplift = (a and b and b > 0) and (a / b - 1) or nil
    m.navGph, m.otherGph = a, b
    m.navSessions, m.otherSessions = #withNav, #without

    m.gotoIssued = db.kpi.gotoIssued or 0
    m.gotoHits = db.kpi.gotoHits or 0
    m.gotoRate = m.gotoIssued > 0 and m.gotoHits / m.gotoIssued or nil

    m.calRows, m.calibration = K.Calibration()

    local cs = ns.Collector.stats
    m.dupes = cs.dupes
    m.lootEvents, m.unknown = cs.lootEvents, cs.unknown
    m.unknownShare = cs.lootEvents > 0 and cs.unknown / cs.lootEvents or nil

    m.perf = ns.perf

    if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
        pcall(UpdateAddOnMemoryUsage)
        local ok, kb = pcall(GetAddOnMemoryUsage, ns.ADDON)
        if ok then m.memoryKB = kb end
    end
    local sources = 0
    for _ in pairs(db.sources) do
        sources = sources + 1
    end
    m.sources = sources

    local c = ns.Store.Community()
    local contributors, pairsCount = 0, 0
    if c then
        for _ in pairs(c.contributors or {}) do
            contributors = contributors + 1
        end
        if type(c.pairs) == "number" then
            pairsCount = c.pairs -- packed file: counted by merge.py, no need to decode every record
        else
            for _, s in pairs(c.sources) do
                for _ in pairs(s.l or {}) do
                    pairsCount = pairsCount + 1
                end
            end
        end
    end
    m.contributors, m.communityPairs = contributors, pairsCount
    local peers = 0
    for _ in pairs(db.peers) do
        peers = peers + 1
    end
    m.peers = peers

    local today = math.floor(now / 86400)
    local active, days = 0, {}
    for i = 13, 0, -1 do
        days[#days + 1] = db.kpi.days[today - i] and true or false
        if db.kpi.days[today - i] then active = active + 1 end
    end
    m.activeDays14, m.days = active, days
    return m
end

-- ---------------------------------------------------------------- rows for the KPI page

-- Chart colours (0-255) on the book pages: target met, missed, neutral, no data.
K.GOOD, K.BAD, K.INK, K.NONE = { 60, 150, 60 }, { 190, 70, 50 }, { 150, 100, 35 }, { 160, 145, 120 }

-- Counts per bucket: edges are ascending upper bounds, the last bucket is open.
local function Buckets(values, edges)
    local counts = {}
    for i = 1, #edges + 1 do
        counts[i] = 0
    end
    for _, v in ipairs(values) do
        local b = #edges + 1
        for i, e in ipairs(edges) do
            if v < e then
                b = i
                break
            end
        end
        counts[b] = counts[b] + 1
    end
    return counts
end

-- Column values for a histogram; buckets up to `goodUpTo` meet the target.
local function Histogram(counts, goodUpTo)
    local out = {}
    for i, c in ipairs(counts) do
        out[i] = { v = c, color = i <= goodUpTo and K.GOOD or K.INK }
    end
    return out
end

local function Ms(v) return string.format("%.2f ms", v) end

-- One row per KPI (farming KPIs only with the farming features on). Row fields: id (number in the
-- README), group, name, desc, valueText, targetText, ok (true / false / nil = no target or no data),
-- gauge = { value, max, target } on one scale, chart = { kind = "columns" | "stack", label, values |
-- parts, opts } (optional) and note (text under the chart).
function K.Rows()
    local m = K.Compute()
    local VALUE, QUALITY, TECH, COMMUNITY =
        L["Value to the player"], L["Data quality"], L["Technical"], L["Community / adoption"]
    local rows = {}
    local function add(r)
        r.valueText = r.valueText or "-"
        r.targetText = r.targetText or "-"
        rows[#rows + 1] = r
    end
    -- true / false, or nil when there is no value to judge
    local function MetOr(v, good)
        if v == nil then return nil end
        return good(v) and true or false
    end

    -- 1 time to answer
    local tip = m.perf.tooltip
    local tipAvg = tip and tip.n > 0 and tip.total / tip.n or nil
    add({
        id = 1,
        group = VALUE,
        name = L["Time to answer"],
        desc = L["How long the tooltip lookup takes. Hovering an item gives the answer with no clicks."],
        valueText = tipAvg and Ms(tipAvg),
        targetText = string.format(L["under %s"], "1 s"),
        ok = MetOr(tipAvg, function(v) return v < 1000 end),
        gauge = { tipAvg, 2000, 1000 },
        note = tip and string.format(L["%d lookups, slowest %s"], tip.n, Ms(tip.max)) or L["no tooltip shown yet"],
    })

    -- 2 coverage
    add({
        id = 2,
        group = VALUE,
        name = L["Coverage"],
        desc = L["Share of looted items with at least 30 observations at one source and an auction price less than 24 hours old."],
        valueText = m.coverage and ns.Pct(m.coverage),
        targetText = string.format(L["at least %s"], "80%"),
        ok = MetOr(m.coverage, function(v) return v >= 0.8 end),
        gauge = { m.coverage, 1, 0.8 },
        chart = m.looted > 0 and {
            kind = "stack",
            label = L["Looted items"],
            parts = { { v = m.covered, color = K.GOOD }, { v = m.looted - m.covered, color = K.NONE } },
        } or nil,
        note = string.format(L["%d of %d looted items covered"], m.covered, m.looted),
    })

    if ns.FarmingOn() then
        -- 3 farming uplift
        add({
            id = 3,
            group = VALUE,
            name = L["Farming uplift"],
            desc = L["Gold per hour in farming sessions that followed a recommendation, compared with the others."],
            valueText = m.uplift and string.format("%+.0f%%", m.uplift * 100),
            targetText = string.format(L["at least %s"], "+20%"),
            ok = MetOr(m.uplift, function(v) return v >= 0.2 end),
            gauge = { m.uplift and math.max(0, m.uplift), 0.5, 0.2 },
            chart = (m.navGph or m.otherGph) and {
                kind = "columns",
                label = L["Gold per hour"],
                values = { { v = m.otherGph or 0, color = K.INK }, { v = m.navGph or 0, color = K.GOOD } },
                opts = { left = L["without"], right = L["with recommendation"] },
            } or nil,
            note = string.format(
                "%s: %s (%d)\n%s: %s (%d)",
                L["with recommendation"],
                m.navGph and ns.ShortCoin(m.navGph) or "-",
                m.navSessions,
                L["without"],
                m.otherGph and ns.ShortCoin(m.otherGph) or "-",
                m.otherSessions
            ),
        })

        -- 4 route usefulness
        add({
            id = 4,
            group = VALUE,
            name = L["Route usefulness"],
            desc = L["Share of waypoints after which you killed a mob at the target within 10 minutes."],
            valueText = m.gotoRate and ns.Pct(m.gotoRate),
            targetText = string.format(L["at least %s"], "70%"),
            ok = MetOr(m.gotoRate, function(v) return v >= 0.7 end),
            gauge = { m.gotoRate, 1, 0.7 },
            chart = m.gotoIssued > 0 and {
                kind = "stack",
                label = L["Waypoints"],
                parts = {
                    { v = m.gotoHits, color = K.GOOD },
                    { v = m.gotoIssued - m.gotoHits, color = K.BAD },
                },
            } or nil,
            note = string.format(L["%d of %d waypoints led to a kill"], m.gotoHits, m.gotoIssued),
        })
    end

    -- 5 calibration
    local bins = {}
    local counted = 0
    for bin = 1, 10 do
        bins[bin] = { v = 0, color = K.NONE }
    end
    for _, r in ipairs(m.calRows) do
        local lo = math.max(0, r.pred - 1.96 * r.se)
        local hi = math.min(1, r.pred + 1.96 * r.se)
        local color = r.c < 30 and K.NONE or (r.ok and K.GOOD or K.BAD)
        bins[r.bin] = { v = r.obs, lo = lo, hi = hi, color = color }
        counted = counted + r.c
    end
    add({
        id = 5,
        group = QUALITY,
        name = L["Calibration"],
        desc = L["Predicted drop chances are checked against what drops next. Share of rate ranges (with at least 30 checks) where the observed rate lies in the 95% interval of the prediction."],
        valueText = m.calibration and ns.Pct(m.calibration),
        targetText = string.format(L["at least %s"], "90%"),
        ok = MetOr(m.calibration, function(v) return v >= 0.9 end),
        gauge = { m.calibration, 1, 0.9 },
        chart = #m.calRows > 0 and {
            kind = "columns",
            label = L["Observed rate per predicted range"],
            values = bins,
            opts = { max = 1, left = "0%", right = "100%" },
        } or nil,
        note = string.format(L["%d checks. Whiskers: predicted 95%% interval; grey: fewer than 30 checks."], counted),
    })

    -- 6 CI width
    add({
        id = 6,
        group = QUALITY,
        name = L["Interval width"],
        desc = L["Median half-width of the 95% interval of drop rates with at least 10 observations. Smaller means surer numbers."],
        valueText = m.ciHalfWidth and ("±" .. ns.Pct(m.ciHalfWidth)),
        targetText = string.format(L["under %s"], "±5%"),
        ok = MetOr(m.ciHalfWidth, function(v) return v < 0.05 end),
        gauge = { m.ciHalfWidth, 0.15, 0.05 },
        chart = #m.ciWidths > 0 and {
            kind = "columns",
            label = L["Drop rates by interval half-width"],
            values = Histogram(Buckets(m.ciWidths, { 0.01, 0.02, 0.05, 0.1 }), 3),
            opts = { left = "< 1%", right = "> 10%" },
        } or nil,
        note = string.format(L["%d drop rates with at least 10 observations"], #m.ciWidths),
    })

    -- 7 price freshness
    add({
        id = 7,
        group = QUALITY,
        name = L["Price freshness"],
        desc = L["Median age of the latest auction price of looted items."],
        valueText = m.priceAge and ns.Age(m.priceAge),
        targetText = string.format(L["under %s"], "24h"),
        ok = MetOr(m.priceAge, function(v) return v < 86400 end),
        gauge = { m.priceAge, 3 * 86400, 86400 },
        chart = #m.ages > 0 and {
            kind = "columns",
            label = L["Prices by age"],
            values = Histogram(Buckets(m.ages, { 3600, 6 * 3600, 86400, 3 * 86400, 7 * 86400 }), 3),
            opts = { left = "< 1h", right = "> 7d" },
        } or nil,
        note = string.format(L["%d looted items with a price"], #m.ages),
    })

    -- 8 attribution
    add({
        id = 8,
        group = QUALITY,
        name = L["Attribution"],
        desc = L["Loot that could not be assigned to a source. Duplicate corpses are recognised and not counted twice."],
        valueText = m.unknownShare and ns.Pct(m.unknownShare),
        targetText = string.format(L["at most %s"], "1%"),
        ok = MetOr(m.unknownShare, function(v) return v <= 0.01 end),
        gauge = { m.unknownShare, 0.05, 0.01 },
        chart = m.lootEvents > 0 and {
            kind = "stack",
            label = L["Loot windows this session"],
            parts = {
                { v = m.lootEvents - m.unknown, color = K.GOOD },
                { v = m.unknown, color = K.BAD },
            },
        } or nil,
        note = string.format(
            L["%d loot windows, %d without a source, %d duplicate corpses not counted"],
            m.lootEvents,
            m.unknown,
            m.dupes
        ),
    })

    -- 9 performance
    local worst, handlers = 0, {}
    for name, p in pairs(m.perf) do
        handlers[#handlers + 1] = { name = name, p = p }
        if p.max > worst then worst = p.max end
    end
    table.sort(handlers, function(x, y) return x.p.max > y.p.max end)
    local values, lines = {}, {}
    for i, h in ipairs(handlers) do
        if i > 12 then break end
        values[i] = { v = h.p.max, color = h.p.max >= 16 and K.BAD or K.GOOD }
        if i <= 6 then
            lines[#lines + 1] =
                string.format("%s: %s / %s (%d)", h.name, Ms(h.p.n > 0 and h.p.total / h.p.n or 0), Ms(h.p.max), h.p.n)
        end
    end
    add({
        id = 9,
        group = TECH,
        name = L["Performance"],
        desc = L["Slowest run of any event handler; above 16 ms a frame stutters."],
        valueText = #handlers > 0 and Ms(worst) or nil,
        targetText = string.format(L["under %s"], "16 ms"),
        ok = MetOr(#handlers > 0 and worst or nil, function(v) return v < 16 end),
        gauge = { #handlers > 0 and worst or nil, 32, 16 },
        chart = #handlers > 0 and {
            kind = "columns",
            label = L["Slowest run per handler"],
            values = values,
            opts = { max = math.max(32, worst), left = handlers[1].name, right = "" },
        } or nil,
        note = #lines > 0 and (L["average / slowest (calls)"] .. "\n" .. table.concat(lines, "\n")) or nil,
    })

    -- 10 footprint
    add({
        id = 10,
        group = TECH,
        name = L["Footprint"],
        desc = L["Memory used by the addon. The saved data should stay under 5 MB."],
        valueText = m.memoryKB and string.format("%.1f MB", m.memoryKB / 1024),
        targetText = string.format(L["under %s"], "5 MB"),
        ok = MetOr(m.memoryKB, function(v) return v < 5120 end),
        gauge = { m.memoryKB, 10240, 5120 },
        note = string.format(L["%d own sources"], m.sources),
    })

    -- 11 community
    add({
        id = 11,
        group = COMMUNITY,
        name = L["Community"],
        desc = L["Size of the community data in this version and guild members who shared data with you."],
        valueText = tostring(m.contributors),
        note = string.format(
            L["%d contributors, %d source/item pairs, %d guild peers"],
            m.contributors,
            m.communityPairs,
            m.peers
        ),
    })

    -- 12 retention
    local dayCols = {}
    for i, on in ipairs(m.days) do
        dayCols[i] = { v = on and 1 or 0.08, color = on and K.GOOD or K.NONE }
    end
    add({
        id = 12,
        group = COMMUNITY,
        name = L["Active days"],
        desc = L["Days with recorded data out of the last 14."],
        valueText = string.format("%d / 14", m.activeDays14),
        gauge = { m.activeDays14, 14 },
        chart = {
            kind = "columns",
            label = L["Last 14 days"],
            values = dayCols,
            opts = { max = 1, left = string.format(L["%d days ago"], 13), right = L["today"] },
        },
    })
    return rows
end

return K
