local _, ns = ...

-- What merchants sell: recorded from the merchant window (MERCHANT_SHOW / MERCHANT_UPDATE).
-- db.vendors[npcId] = { nm = name, t = last seen, v = visits, sp = { [map] = { [cell] = n } },
--                       i = { [itemId] = { p = price (copper), st = stack, lim = true (limited stock),
--                                          x = { [costItemId] = count } (item costs) } } }
-- The item list is replaced only by a complete scan, never by a window whose links are still loading.
local V = {}
ns.Vendors = V

local Store = ns.Store
local RETRIES = 3

local function Db() return ns.db.vendors end

-- Merchant item i: price, stack size, available (-1 = unlimited). Both API generations.
local function ItemInfo(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
        if ok and type(info) == "table" then return info.price, info.stackCount, info.numAvailable end
    end
    if GetMerchantItemInfo then
        local ok, _, _, price, qty, avail = pcall(GetMerchantItemInfo, i)
        if ok then return price, qty, avail end
    end
    return nil
end

local function Costs(i)
    if not (GetMerchantItemCostInfo and GetMerchantItemCostItem) then return nil end
    local ok, n = pcall(GetMerchantItemCostInfo, i)
    if not ok or type(n) ~= "number" or n <= 0 then return nil end
    local out
    for j = 1, n do
        local ok2, _, value, link = pcall(GetMerchantItemCostItem, i, j)
        local id = ok2 and ns.ItemIdFromLink(link)
        if id and tonumber(value) then
            out = out or {}
            out[id] = tonumber(value)
        end
    end
    return out
end

-- Same merchant list (prices, stacks, limits, item costs)?
local function SameItems(a, b)
    if type(a) ~= "table" then return false end
    local function same(x, y)
        if x.p ~= y.p or x.st ~= y.st or (x.lim or false) ~= (y.lim or false) then return false end
        local cx, cy = x.x or {}, y.x or {}
        for id, n in pairs(cx) do
            if cy[id] ~= n then return false end
        end
        for id in pairs(cy) do
            if cx[id] == nil then return false end
        end
        return true
    end
    for id, e in pairs(b) do
        if not a[id] or not same(a[id], e) then return false end
    end
    for id in pairs(a) do
        if not b[id] then return false end
    end
    return true
end

local visit -- { npc, counted } for the open merchant window
local open = false

-- Reads the open merchant window. Returns true when the list was stored.
function V.Scan(attempt)
    attempt = attempt or 1
    local guid = ns.Call(UnitGUID, "npc")
    local gt = ns.GuidType(guid)
    if gt ~= "Creature" and gt ~= "Vehicle" then return false end
    local npc = ns.GuidId(guid)
    local n = GetMerchantNumItems and GetMerchantNumItems() or 0
    if not npc or n <= 0 then return false end
    local items, complete = {}, true
    for i = 1, n do
        local link = GetMerchantItemLink and GetMerchantItemLink(i)
        local id = ns.ItemIdFromLink(link)
        local price, stack, avail = ItemInfo(i)
        if not id or not price then
            complete = false
        else
            local e = { p = math.max(0, math.floor(price)), st = math.max(1, math.floor(stack or 1)) }
            if avail and avail >= 0 then e.lim = true end
            e.x = Costs(i)
            items[id] = e
        end
    end
    if not complete then
        if attempt < RETRIES then ns.After(0.5, function() V.Scan(attempt + 1) end) end
        return false
    end
    local rec = Db()[npc]
    if not rec then
        rec = { sp = {}, v = 0 }
        Db()[npc] = rec
    end
    local name = ns.Call(UnitName, "npc") or rec.nm
    -- only a different list, name or a new location is news for the next share string
    local changed = name ~= rec.nm or not SameItems(rec.i, items)
    rec.nm = name
    rec.t = ns.time()
    rec.i = items
    if not visit or visit.npc ~= npc or not visit.counted then
        rec.v = (rec.v or 0) + 1
        visit = { npc = npc, counted = true }
        local map, x, y = ns.PlayerLocation()
        if map and x then
            rec.sp[map] = rec.sp[map] or {}
            local cell = Store.CellKey(x, y)
            rec.sp[map][cell] = (rec.sp[map][cell] or 0) + 1
            changed = true
        end
    end
    if changed then Store.Mark(rec) end
    V.indexDirty = true
    ns.Fire("DATA_CHANGED", "vendor", npc)
    return true
end

-- ---------------------------------------------------------------- layers and readers

-- Vendor tables of every layer that is switched on: own first, then guild peers, then community.
function V.Layers()
    local out = { { layer = "me", t = Db() } }
    if ns.db.settings.useGuild then
        for _, peer in pairs(ns.db.peers) do
            if type(peer.vd) == "table" and not Store.IsContributor(peer.uid) then
                out[#out + 1] = { layer = "guild", t = peer.vd }
            end
        end
    end
    local c = Store.Community()
    if c and ns.db.settings.useCommunity and type(c.vendors) == "table" then
        out[#out + 1] = { layer = "community", t = c.vendors }
    end
    return out
end

-- The vendor record to show: the player's own (most recent for them), else the first shared one.
function V.Get(npc)
    for _, l in ipairs(V.Layers()) do
        local rec = l.t[npc]
        if type(rec) == "table" and type(rec.i) == "table" then return rec, l.layer end
    end
    return nil
end

-- Vendor name in the player's language (community names are kept per locale).
function V.Name(npc)
    local rec, layer = V.Get(npc)
    if layer ~= "me" then
        local c = Store.Community()
        local names = c and type(c.names) == "table" and c.names[GetLocale and GetLocale() or ""]
        local n = names and names["vendor:" .. tostring(npc)]
        if n then return n end
    end
    return rec and rec.nm or ("NPC " .. tostring(npc))
end

local index -- itemId -> { [npc] = true }
V.indexDirty = true

local function Rebuild()
    index = {}
    for _, l in ipairs(V.Layers()) do
        for npc, rec in pairs(l.t) do
            if type(rec) == "table" and type(rec.i) == "table" then
                for id in pairs(rec.i) do
                    index[id] = index[id] or {}
                    index[id][npc] = true
                end
            end
        end
    end
    V.indexDirty = false
end

function V.ForItem(itemId)
    if V.indexDirty or not index then Rebuild() end
    return index[itemId] or {}
end

function V.AllIds()
    local ids = {}
    for _, l in ipairs(V.Layers()) do
        for npc in pairs(l.t) do
            ids[npc] = true
        end
    end
    return ids
end

ns.On("DATA_CHANGED", function(what)
    if what ~= "vendor" then V.indexDirty = true end
end)
ns.On("SETTINGS_CHANGED", function() V.indexDirty = true end)

ns.On("DB_READY", function(db)
    db.vendors = type(db.vendors) == "table" and db.vendors or {}
    ns.RegisterEvent("MERCHANT_SHOW", function()
        visit, open = nil, true
        ns.After(0.2, function()
            if open then V.Scan() end
        end)
    end)
    local token = 0
    ns.RegisterEvent("MERCHANT_UPDATE", function()
        token = token + 1
        local mine = token
        ns.After(0.5, function()
            if mine == token and open then V.Scan() end
        end)
    end)
    ns.RegisterEvent("MERCHANT_CLOSED", function()
        visit, open = nil, false
    end)
end)

return V
