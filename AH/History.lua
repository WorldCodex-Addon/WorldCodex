local _, ns = ...

-- Price history: one summary per scan (last) plus a daily rollup kept for KEEP_DAYS days.
local P = {}
ns.Prices = P

local DAY = 86400
local KEEP_DAYS = 60
local WINDOW_DAYS = 14

function P.Day(t) return math.floor((t or ns.time()) / DAY) end

-- listings: array of { p, q }; or levels = { [unit price] = quantity } from a full scan.
function P.Commit(itemId, listings, t, db, levels)
    db = db or ns.db
    t = t or ns.time()
    local rec = db.ah[itemId]
    if not rec then
        rec = { days = {} }
        db.ah[itemId] = rec
    end
    rec.days = rec.days or {}
    -- a new scan is new data for the next share string
    if ns.Store and ns.Store.Mark then ns.Store.Mark(rec, db) end
    local s = levels and ns.Stats.SummarizeLevels(levels) or ns.Stats.Summarize(listings or {})
    if not s then
        rec.last = { t = t, q = 0 }
        return rec
    end
    rec.last = { t = t, mi = s.mi, md = s.md, mn = s.mn, mx = s.mx, q = s.q }
    local day = P.Day(t)
    local d = rec.days[day]
    if not d then
        rec.days[day] = { mi = s.mi, md = s.md, mn = s.mn, mx = s.mx, q = s.q, c = 1 }
    else
        local c = d.c or 1
        d.mi = math.min(d.mi, s.mi)
        d.mx = math.max(d.mx, s.mx)
        d.md = math.floor((d.md * c + s.md) / (c + 1) + 0.5)
        d.mn = math.floor((d.mn * c + s.mn) / (c + 1) + 0.5)
        d.q = math.floor((d.q * c + s.q) / (c + 1) + 0.5)
        d.c = c + 1
    end
    for k in pairs(rec.days) do
        if k < day - KEEP_DAYS then rec.days[k] = nil end
    end
    return rec
end

local function PeerLatest(itemId)
    local best
    if not ns.db.settings.useGuild then return nil end
    for _, peer in pairs(ns.db.peers) do
        local a = peer.ah and peer.ah[itemId]
        if a and a.t and (not best or a.t > best.t) then best = a end
    end
    return best
end

-- Returns a price summary table or nil when nothing is known.
function P.Get(itemId)
    local db = ns.db
    if not db then return nil end
    local rec = db.ah[itemId]
    local last = rec and rec.last
    local origin = "me"
    local peer = PeerLatest(itemId)
    if peer and (not last or not last.md or peer.t > (last.t or 0)) then
        last = peer
        origin = "guild"
    end
    if not last or not last.t then return nil end
    local today = P.Day()
    local points, avgs, maxv, min14, days = {}, {}, nil, nil, 0
    if rec and rec.days then
        for day, d in pairs(rec.days) do
            if day > today - WINDOW_DAYS then
                days = days + 1
                points[#points + 1] = { x = day, v = d.md }
                avgs[#avgs + 1] = d.mn
                maxv = math.max(maxv or 0, d.mx)
                min14 = math.min(min14 or d.mi, d.mi)
            end
        end
    end
    local market = ns.Stats.EWMA(points, 3)
    local avg = ns.Stats.Mean(avgs)
    return {
        min = last.mi,
        median = last.md,
        avg = avg and math.floor(avg + 0.5) or last.mn,
        max = maxv or last.mx,
        market = market and math.floor(market + 0.5) or last.md,
        min14 = min14,
        qty = last.q or 0,
        t = last.t,
        age = ns.time() - last.t,
        days = days,
        origin = origin,
    }
end

function P.Value(itemId)
    local g = P.Get(itemId)
    if g and g.market and g.market > 0 then return g.market end
    return nil
end

function P.Vendor(itemId)
    local it = ns.db.items[itemId]
    if it and it.v then return it.v end
    local _, _, sell = ns.ItemInfo(itemId)
    if sell and sell > 0 then
        if it then it.v = sell end
        return sell
    end
    return 0
end

-- Best realistic value of one unit: AH market if known, else vendor price.
function P.UnitValue(itemId) return P.Value(itemId) or P.Vendor(itemId) end

function P.History(itemId)
    local rec = ns.db.ah[itemId]
    local out = {}
    if not rec or not rec.days then return out end
    for day, d in pairs(rec.days) do
        out[#out + 1] = { day = day, d = d }
    end
    table.sort(out, function(a, b) return a.day < b.day end)
    return out
end

return P
