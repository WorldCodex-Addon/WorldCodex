local _, ns = ...

local S = {}
ns.Stats = S

local floor, sqrt, log, max, min = math.floor, math.sqrt, math.log, math.max, math.min
local Z95 = 1.959964

function S.Wilson(d, n, z)
    if not n or n <= 0 then return 0, 0 end
    z = z or Z95
    d = min(d, n)
    local p = d / n
    local z2 = z * z
    local denom = 1 + z2 / n
    local center = (p + z2 / (2 * n)) / denom
    local half = z * sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / denom
    return max(0, center - half), min(1, center + half)
end

function S.Rate(d, n)
    if not n or n <= 0 then return 0 end
    return d / n
end

-- Same summary from price levels { [unit price] = quantity }. A full auction house scan collects
-- listings this way: no table per auction, and sorting plain numbers needs no Lua comparator.
function S.SummarizeLevels(levels)
    local prices, n = {}, 0
    for p, q in pairs(levels) do
        if p > 0 and q > 0 then
            n = n + 1
            prices[n] = p
        end
    end
    if n == 0 then return nil end
    table.sort(prices)
    local total = 0
    for i = 1, n do
        total = total + levels[prices[i]]
    end
    local function quantile(frac)
        local target, acc = total * frac, 0
        for i = 1, n do
            acc = acc + levels[prices[i]]
            if acc >= target then return prices[i] end
        end
        return prices[n]
    end
    local q1, md, q3 = quantile(0.25), quantile(0.5), quantile(0.75)
    local iqr = q3 - q1
    local upper = max(q3 + 1.5 * iqr, md * 2.5)
    local lower = min(q1 - 1.5 * iqr, md / 2.5)
    local sum, qty, mx = 0, 0, prices[1]
    for i = 1, n do
        local p = prices[i]
        if p <= upper and p >= lower then
            local q = levels[p]
            sum = sum + p * q
            qty = qty + q
            if p > mx then mx = p end
        end
    end
    local mean = qty > 0 and sum / qty or md
    return {
        mi = floor(prices[1] + 0.5),
        md = floor(md + 0.5),
        mn = floor(mean + 0.5),
        mx = floor(mx + 0.5),
        q = total,
        l = n,
    }
end

-- Returns min / weighted median / IQR-trimmed mean / trimmed max / total quantity / listings.
-- listings: array of { p = unit price (copper), q = quantity }
function S.Summarize(listings)
    local levels, count = {}, 0
    for i = 1, #listings do
        local e = listings[i]
        local p, q = tonumber(e.p), tonumber(e.q) or 1
        if p and p > 0 and q > 0 then
            levels[p] = (levels[p] or 0) + q
            count = count + 1
        end
    end
    local s = S.SummarizeLevels(levels)
    if s then s.l = count end
    return s
end

-- points: array of { x = day, v = value }; exponentially weighted towards the latest day.
function S.EWMA(points, halfLife)
    if #points == 0 then return nil end
    local last = points[1].x
    for i = 2, #points do
        if points[i].x > last then last = points[i].x end
    end
    local wsum, vsum = 0, 0
    for i = 1, #points do
        local w = 0.5 ^ ((last - points[i].x) / halfLife)
        wsum = wsum + w
        vsum = vsum + w * points[i].v
    end
    if wsum <= 0 then return nil end
    return vsum / wsum
end

function S.PNoDrop(p, n)
    if not p or p <= 0 then return 1 end
    if p >= 1 then return n > 0 and 0 or 1 end
    return (1 - p) ^ n
end

-- Attempts needed so that at least one drop happens with probability `conf`.
function S.AttemptsFor(p, conf)
    if not p or p <= 0 then return math.huge end
    if p >= 1 then return 1 end
    return math.ceil(log(1 - conf) / log(1 - p))
end

function S.Median(arr)
    local n = #arr
    if n == 0 then return nil end
    local c = {}
    for i = 1, n do
        c[i] = arr[i]
    end
    table.sort(c)
    if n % 2 == 1 then return c[(n + 1) / 2] end
    return (c[n / 2] + c[n / 2 + 1]) / 2
end

function S.Mean(arr)
    if #arr == 0 then return nil end
    local s = 0
    for i = 1, #arr do
        s = s + arr[i]
    end
    return s / #arr
end

-- Expected values for one attempt at a source.
function S.Expectation(d, n, totalQty, unitValue)
    if not n or n <= 0 or not d or d <= 0 then return 0, 0 end
    local rate = d / n
    local avgQty = totalQty / d
    return rate * avgQty * (unitValue or 0), avgQty
end

-- Minutes until one expected drop, using a conservative rate (CI lower bound).
function S.MinutesPerDrop(rate, perHour)
    if not rate or rate <= 0 or not perHour or perHour <= 0 then return math.huge end
    return 60 / (rate * perHour)
end

-- Binomial outlier check: is d unusually far from what pooled rate p predicts for n trials?
function S.IsOutlier(d, n, p, zLimit)
    if n < 20 or p <= 0 or p >= 1 then return false end
    local sd = sqrt(n * p * (1 - p))
    if sd <= 0 then return false end
    return math.abs(d - n * p) / sd > (zLimit or 5)
end

-- Chance of at least one drop in k attempts at rate p.
function S.CumChance(p, k)
    if not p or p <= 0 or not k or k <= 0 then return 0 end
    if p >= 1 then return 1 end
    return 1 - (1 - p) ^ k
end

local LN10 = log(10)

-- Position of a rate on a log scale from `floor` (0) to 100% (1). Rare drops stay visible.
function S.LogPos(p, floor_)
    floor_ = floor_ or 0.001
    if not p or p <= floor_ then return 0 end
    if p >= 1 then return 1 end
    local lf = log(floor_) / LN10
    return (log(p) / LN10 - lf) / -lf
end

-- How much a rate can be trusted: "none", "low", "medium" or "high".
function S.Confidence(d, n)
    if not n or n <= 0 then return "none" end
    if n < 10 then return "low" end
    d = min(d or 0, n)
    if d == 0 then return n >= 100 and "medium" or "low" end
    local lo, hi = S.Wilson(d, n)
    local rel = (hi - lo) / (2 * d / n)
    if rel > 0.75 then return "low" end
    if rel > 0.3 then return "medium" end
    return "high"
end

-- Standard normal CDF (Abramowitz & Stegun 7.1.26, error < 1.5e-7).
function S.NormalCDF(z)
    local sign = z < 0 and -1 or 1
    local x = math.abs(z) / sqrt(2)
    local t = 1 / (1 + 0.3275911 * x)
    local y = 1
        - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592)
            * t
            * math.exp(-x * x)
    return 0.5 * (1 + sign * y)
end

-- Two-proportion z-test: is d1/n1 different from d2/n2? Returns z and the two-sided p-value.
function S.TwoProportion(d1, n1, d2, n2)
    if not n1 or not n2 or n1 <= 0 or n2 <= 0 then return 0, 1 end
    local p = (d1 + d2) / (n1 + n2)
    if p <= 0 or p >= 1 then return 0, 1 end
    local se = sqrt(p * (1 - p) * (1 / n1 + 1 / n2))
    if se <= 0 then return 0, 1 end
    local z = (d1 / n1 - d2 / n2) / se
    return z, 2 * (1 - S.NormalCDF(math.abs(z)))
end

-- A personal rate is flagged as different only with enough samples on both sides.
S.DIFF_MIN_N = 20
S.DIFF_P = 0.01
function S.Differs(d1, n1, d2, n2)
    if (n1 or 0) < S.DIFF_MIN_N or (n2 or 0) < S.DIFF_MIN_N then return false, 0, 1 end
    local z, pv = S.TwoProportion(d1, n1, d2, n2)
    return pv < S.DIFF_P, z, pv
end

-- Share of players with the same number of attempts who got fewer drops (mid-p binomial CDF):
-- 0.9 means "luckier than 90 %".
function S.LuckPercentile(d, n, p)
    if not n or n <= 0 or not p or p <= 0 or p >= 1 then return nil end
    d = min(max(0, floor(d or 0)), n)
    local lq, lp = log(1 - p), log(p)
    local logPmf = n * lq -- k = 0
    local below, at = 0, 0
    for k = 0, d do
        if k > 0 then logPmf = logPmf + log((n - k + 1) / k) + lp - lq end
        local v = math.exp(logPmf)
        if k < d then
            below = below + v
        else
            at = v
        end
    end
    return min(1, below + at / 2)
end

return S
