local _, ns = ...

-- Auction house adapter for C_AuctionHouse (item keys, commodities, ReplicateItems).
local M = { name = "modern" }
ns.AH.adapters.modern = M

local MAX_ROWS = 500
local REPLICATE_DEBOUNCE = 2
local REPLICATE_PER_FRAME = 2000 -- at most, and only while within the frame budget
local READ_BUDGET_MS = 4

local state

local function API() return C_AuctionHouse end

function M.Available()
    local ah = API()
    return ah ~= nil and ah.SendSearchQuery ~= nil and ah.MakeItemKey ~= nil
end

function M.Reset() state = nil end
function M.Busy() return state ~= nil end

function M.CanQuery()
    local ah = API()
    if ah.IsThrottledMessageSystemReady then return ah.IsThrottledMessageSystemReady() and true or false end
    return true
end

local function Sorts()
    local order = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0
    return { { sortOrder = order, reverse = false } }
end

function M.SearchItem(itemId)
    local ah = API()
    local okKey, key = pcall(ah.MakeItemKey, itemId)
    if not okKey or not key then return false, "no item key for " .. tostring(itemId) end
    state = { mode = "item", id = itemId, key = key }
    local ok, err = pcall(ah.SendSearchQuery, key, Sorts(), true)
    if not ok then
        state = nil
        return false, tostring(err)
    end
    return true
end

-- On timeout: hand back whatever arrived so far instead of discarding it.
function M.Partial()
    if not state or state.mode ~= "item" then return nil end
    local id, list = state.id, state.list
    state = nil
    return id, list
end

local function ReadCommodities(itemId)
    local ah = API()
    local n = ah.GetNumCommoditySearchResults(itemId) or 0
    local list = {}
    for i = 1, math.min(n, MAX_ROWS) do
        local r = ah.GetCommoditySearchResultInfo(itemId, i)
        if r and r.unitPrice and r.quantity then list[#list + 1] = { p = r.unitPrice, q = r.quantity } end
    end
    local full = not ah.HasFullCommoditySearchResults or ah.HasFullCommoditySearchResults(itemId)
    return list, n, full
end

local function ReadItems(itemKey)
    local ah = API()
    local n = ah.GetNumItemSearchResults(itemKey) or 0
    local list = {}
    for i = 1, math.min(n, MAX_ROWS) do
        local r = ah.GetItemSearchResultInfo(itemKey, i)
        local price = r and (r.buyoutAmount or r.bidAmount)
        if price and price > 0 then list[#list + 1] = { p = price, q = r.quantity or 1 } end
    end
    local full = not ah.HasFullItemSearchResults or ah.HasFullItemSearchResults(itemKey)
    return list, n, full
end

local function Finish()
    local id, list = state.id, state.list or {}
    state = nil
    ns.AH.ItemDone(id, list)
end

-- Handles both *_UPDATED and *_ADDED events; also records searches the player runs in the AH UI.
local function OnCommodityResults(itemId)
    if type(itemId) ~= "number" then return end
    local mine = state and state.mode == "item" and state.id == itemId
    -- the AH window sends these events for every search and scroll: read rows only when they are used
    if not mine and (state or not ns.AH.PassiveWanted(itemId)) then return end
    local list, n, full = ReadCommodities(itemId)
    if mine then
        state.list = list
        if not full and n < MAX_ROWS and API().RequestMoreCommoditySearchResults then
            if pcall(API().RequestMoreCommoditySearchResults, itemId) then return end
        end
        Finish()
    elseif not state and (full or n >= MAX_ROWS) then
        ns.AH.Passive(itemId, list)
    end
end

local function OnItemResults(itemKey)
    if type(itemKey) ~= "table" or not itemKey.itemID then return end
    local mine = state and state.mode == "item" and itemKey.itemID == state.id
    if not mine and (state or not ns.AH.PassiveWanted(itemKey.itemID)) then return end
    local list, n, full = ReadItems(itemKey)
    if mine then
        state.list = list
        if not full and n < MAX_ROWS and API().RequestMoreItemSearchResults then
            if pcall(API().RequestMoreItemSearchResults, itemKey) then return end
        end
        Finish()
    elseif not state and (full or n >= MAX_ROWS) then
        ns.AH.Passive(itemKey.itemID, list)
    end
end

function M.FullScan()
    local ah = API()
    if not ah.ReplicateItems then
        ns.Print(ns.L["full scan is not supported on this client"])
        return false
    end
    state = { mode = "replicate", sent = GetTime(), map = {}, info = {} }
    ah.ReplicateItems()
    ns.Print(ns.L["AH full scan started - allowed once every 15 minutes"])
    return true
end

-- Reads the full scan a few milliseconds per frame. Listings are collected per item as price levels
-- ({ [unit price] = quantity }): a table per auction meant tens of MB of garbage on a busy realm.
function M.Tick(now)
    local st = state
    if not st or st.mode ~= "replicate" then return end
    local ah = API()
    if st.rows then
        local r = st.rows
        local clock = debugprofilestop
        local deadline = clock and clock() + READ_BUDGET_MS
        local levels, info, last, i, stop = st.map, st.info, r.n - 1, r.i, r.i + REPLICATE_PER_FRAME
        while i <= last and i < stop do
            local name, texture, count, quality, _, _, _, _, _, buyout, _, _, _, _, _, _, itemId =
                ah.GetReplicateItemInfo(i)
            count, buyout = tonumber(count) or 0, tonumber(buyout) or 0
            -- the item as the auction house names it (nil name: not in the client's item cache yet)
            -- (false: facts complete already; a table only per item, never per auction)
            local hint = itemId and info[itemId]
            if itemId and hint == nil then
                local it = ns.db.items[itemId]
                info[itemId] = not (it and it.n and it.bd ~= nil) and { n = name, ql = quality, ic = texture }
            elseif hint and name and not hint.n then
                hint.n, hint.ql, hint.ic = name, quality, texture
            end
            if itemId and count > 0 and buyout > 0 then
                local lv = levels[itemId]
                if not lv then
                    lv = {}
                    levels[itemId] = lv
                end
                local unit = buyout / count
                lv[unit] = (lv[unit] or 0) + count
            end
            i = i + 1
            if deadline and i % 32 == 0 and clock() >= deadline then break end
        end
        r.i = i
        if r.i > last then
            state = nil
            ns.AH.FullDone(st.map, st.info)
        end
        return
    end
    if st.dirty and now - st.dirty >= REPLICATE_DEBOUNCE then
        st.rows = { i = 0, n = ah.GetNumReplicateItems() or 0 }
    elseif not st.dirty and now - st.sent > 120 then
        state = nil
        ns.Print(ns.L["AH full scan: no answer from the server (still on the 15 minute cooldown?)"])
    end
end

ns.RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED", OnCommodityResults)
ns.RegisterEvent("COMMODITY_SEARCH_RESULTS_ADDED", OnCommodityResults)
ns.RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED", OnItemResults)
ns.RegisterEvent("ITEM_SEARCH_RESULTS_ADDED", OnItemResults)
-- Browse results (the AH window's category lists and name searches): no prices (only the lowest one per
-- item), but every listed item is recorded.
local function KeyHint(itemKey)
    local get = API().GetItemKeyInfo
    local ok, ki = false, nil
    if get then
        ok, ki = pcall(get, itemKey)
    end
    if not ok or type(ki) ~= "table" then return {} end
    return { n = ki.itemName, ql = ki.quality, ic = ki.iconFileID }
end

local function OnBrowse(results)
    if type(results) ~= "table" then
        local get = API().GetBrowseResults
        local ok
        ok, results = pcall(get or error)
        if not ok or type(results) ~= "table" then return end
    end
    for _, r in ipairs(results) do
        local key = type(r) == "table" and r.itemKey
        local id = type(key) == "table" and key.itemID
        -- battle pets all share the pet cage item
        if type(id) == "number" and not ((key.battlePetSpeciesID or 0) > 0) and not ns.AH.Seen(id) then
            ns.AH.SeeItem(id, KeyHint(key))
        end
    end
end
M.OnBrowse = OnBrowse

ns.RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function() OnBrowse(nil) end)
ns.RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", OnBrowse)
-- an item the browse list showed before the client had it cached
ns.RegisterEvent("ITEM_KEY_ITEM_INFO_RECEIVED", function(itemId)
    if ns.AH.Seen(itemId) then ns.Store.NoteItem(itemId) end
end)
ns.RegisterEvent("REPLICATE_ITEM_LIST_UPDATE", function()
    if state and state.mode == "replicate" and not state.rows then state.dirty = GetTime() end
end)

return M
