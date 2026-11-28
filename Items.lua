local _, ns = ...

-- Item details for the website and the item page: stats, weapon damage and speed, durability, inventory
-- type, item set, uniqueness, use spell and the effect lines (use / equip / chance on hit / learn).
--
-- Item ids are picked up wherever the client shows an item: bags and equipped gear, items received,
-- chat links (also other players' loot), auction house results, and players the user inspects
-- (INSPECT_READY after the Blizzard inspect window or another addon asked; WorldCodex never sends an
-- inspect request itself). The ids are queued and read later, a few per frame and never in combat: the
-- details need the client's item cache (GET_ITEM_INFO_RECEIVED) and a tooltip build per item.
--
-- Only weapons, armour and items with a use spell get a record in db.items (an auction house full scan
-- lists thousands of trade goods that have nothing to add; their names, levels and icons are recorded by
-- Store.NoteItem). Fields, all optional (docs/export.md):
--   iv inventory type (Enum.InventoryType), st stats { [ITEM_MOD_..._SHORT / RESISTANCEn_NAME / ...] =
--   value } as C_Item.GetItemStats names them (the keys are global string names, the same in every
--   language), wd weapon damage { min, max, speed in ms }, du durability, set item set id, un unique
--   (how many may be equipped), us use spell id, fx effects { { trigger, text } } in the client's
--   language, dv = I.VERSION once read.
-- Stats are the item's base stats (read by item id): random suffixes ("of the Bear") are not included.
local I = {}
ns.Items = I

I.VERSION = 1 -- raise to read every item again (it.dv)

local GEAR = { [2] = true, [4] = true } -- weapon, armour
local TRIGGERS = { [44] = "use", [45] = "equip", [46] = "proc", [38] = "learn" } -- Enum.TooltipDataLineType
I.TRIGGERS = TRIGGERS
local MAX_QUEUE = 20000
local MAX_WAITS = 3 -- cache requests per item and session
local STEP_ITEMS, STEP_MS = 8, 3
local STEP_CHECKS = 64 -- items per step that turn out to have nothing to read (cheap)
local MAX_EFFECTS, MAX_TEXT = 8, 250

local queue, head, queued = {}, 1, {}
local skip = {} -- ids with nothing to record (no gear, no use spell), this session
local waits = {} -- id -> cache requests so far
local waiting = {} -- ids waiting for GET_ITEM_INFO_RECEIVED

I.stats = { queued = 0, read = 0, skipped = 0, changed = 0 }

local function ClassOf(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f then return nil end
    local ok, _, _, _, _, _, classId = pcall(f, id)
    return ok and ns.Plain(classId) or nil
end

function I.Queue(id)
    id = ns.Plain(id)
    if type(id) ~= "number" or id <= 0 or queued[id] or skip[id] then return end
    local it = ns.db and ns.db.items[id]
    if it and it.dv == I.VERSION then return end
    if #queue - head + 1 >= MAX_QUEUE then return end
    queued[id] = true
    queue[#queue + 1] = id
    I.stats.queued = I.stats.queued + 1
end

function I.QueueLink(link) I.Queue(ns.ItemIdFromLink(link)) end

-- Every item link in a chat message (hidden in chat lockdown: instances, restricted combat).
function I.QueueText(text)
    text = ns.Plain(text, "chat text")
    if type(text) ~= "string" or not text:find("|Hitem:", 1, true) then return end
    for id in text:gmatch("|Hitem:(%d+)") do
        I.Queue(tonumber(id))
    end
end

function I.Pending() return #queue - head + 1 end

-- ---------------------------------------------------------------- reading

local function Round(v)
    if v == math.floor(v) then return v end
    return math.floor(v * 10 + 0.5) / 10
end

local function Stats(link)
    local get = C_Item and C_Item.GetItemStats
    if not get or type(link) ~= "string" then return nil end
    local ok, t = pcall(get, link)
    t = ok and ns.Plain(t, "item stats") or nil
    if type(t) ~= "table" then return nil end
    local out, n = {}, 0
    for k, v in pairs(t) do
        k, v = ns.Plain(k), ns.Plain(v)
        if type(k) == "string" and #k <= 48 and k:match("^[%u%d_]+$") and type(v) == "number" and v == v then
            if v ~= 0 and math.abs(v) < 1e6 then
                out[k] = Round(v)
                n = n + 1
            end
        end
    end
    return n > 0 and out or nil
end

local function Escape(s) return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")) end

-- A pattern from one of the client's format strings ("%s - %s Damage", German "%s - %s Schaden"):
-- each placeholder (also positional ones like "%1$s") a capture, everything else literal.
local function Pattern(fmt, fallback)
    if type(fmt) ~= "string" or fmt == "" then fmt = fallback end
    local p = Escape((fmt:gsub("%%%d*%$?[sd]", "\001")))
    return "^" .. p:gsub("\001", "(.-)") .. "$"
end

local patterns
local function Patterns()
    if not patterns then
        local speed = (type(SPEED) == "string" and SPEED ~= "") and SPEED or "Speed"
        patterns = {
            damage = Pattern(DAMAGE_TEMPLATE, "%s - %s Damage"),
            school = Pattern(DAMAGE_TEMPLATE_WITH_SCHOOL, "%s - %s %s Damage"),
            single = Pattern(SINGLE_DAMAGE_TEMPLATE, "%s Damage"),
            durability = Pattern(DURABILITY_TEMPLATE, "Durability %d / %d"),
            speed = "^" .. Escape(speed) .. "%s+(.+)$",
        }
    end
    return patterns
end
I.Pattern = Pattern

local function Int(s)
    if type(s) ~= "string" then return nil end
    return tonumber((s:gsub("[%s%.,]", "")))
end

local function Decimal(s)
    if type(s) ~= "string" then return nil end
    return tonumber((s:gsub("%s", ""):gsub(",", ".")))
end

local function Clean(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|", "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text:sub(1, MAX_TEXT)
end

-- Weapon damage, speed, durability and effect lines from the item's tooltip data (no API has them).
local function Tooltip(id)
    local get = C_TooltipInfo and C_TooltipInfo.GetItemByID
    if not get then return {} end
    local ok, data = pcall(get, id)
    data = ok and ns.Plain(data, "item tooltip") or nil
    local lines = type(data) == "table" and ns.Plain(data.lines, "item tooltip") or nil
    local out = {}
    if type(lines) ~= "table" then return out end
    local p = Patterns()
    for _, line in ipairs(lines) do
        line = ns.Plain(line, "item tooltip")
        if type(line) == "table" then
            local left = ns.Plain(line.leftText, "item tooltip")
            local right = ns.Plain(line.rightText, "item tooltip")
            local kind = ns.Plain(line.type, "item tooltip")
            if type(left) == "string" and left ~= "" then
                if TRIGGERS[kind] then
                    out.fx = out.fx or {}
                    local text = Clean(left)
                    if text ~= "" and #out.fx < MAX_EFFECTS then out.fx[#out.fx + 1] = { TRIGGERS[kind], text } end
                elseif not out.min then
                    local lo, hi = left:match(p.damage)
                    if not (Int(lo) and Int(hi)) then
                        lo, hi = left:match(p.school)
                    end
                    if Int(lo) and Int(hi) then
                        out.min, out.max = Int(lo), Int(hi)
                    elseif left:match(p.single) and Int(left:match(p.single)) then
                        out.min = Int(left:match(p.single))
                        out.max = out.min
                    end
                end
                if not out.du then
                    local _, max = left:match(p.durability)
                    out.du = Int(max)
                end
            end
            if type(right) == "string" and out.min and not out.speed then
                local s = Decimal(right:match(p.speed))
                if s and s > 0 and s < 10 then out.speed = math.floor(s * 1000 + 0.5) end
            end
        end
    end
    return out
end

local function UseSpell(id)
    local get = (C_Item and C_Item.GetItemSpell) or GetItemSpell
    if not get then return nil end
    local ok, _, spellId = pcall(get, id)
    spellId = ok and ns.Plain(spellId) or nil
    return type(spellId) == "number" and spellId > 0 and spellId or nil
end

local function Number(fn, ...)
    if not fn then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    return ns.Plain(a), ns.Plain(b)
end

-- The details of one cached item: { iv, st, wd, du, set, un, us, fx } (nil fields when unknown).
function I.Collect(id, d)
    d = d or ns.ItemDetails(id)
    local e = { us = UseSpell(id), set = d.setId }
    if GEAR[d.classId] then
        e.st = Stats(d.link or ("item:" .. id))
        local iv = Number(C_Item and C_Item.GetItemInventoryTypeByID, id)
        e.iv = type(iv) == "number" and iv > 0 and iv or nil
        local _, limitMax = Number(C_Item and C_Item.GetItemUniqueness, id)
        e.un = type(limitMax) == "number" and limitMax > 0 and limitMax or nil
    end
    local tip = Tooltip(id)
    if tip.min and tip.max and tip.max >= tip.min and GEAR[d.classId] then e.wd = { tip.min, tip.max, tip.speed } end
    e.du = tip.du and tip.du > 0 and tip.du or nil
    e.fx = tip.fx
    return e
end

local FIELDS = { "iv", "st", "wd", "du", "set", "un", "us", "fx" }
I.FIELDS = FIELDS

-- Reads one item: "wait" (cache requested), "later" (not cached, not gear: no request), "skip"
-- (nothing worth recording) or "done".
function I.Read(id)
    local d = ns.ItemDetails(id)
    if not d.name then
        -- trade goods and the like: not worth a cache request (a consumable with a use spell is read
        -- once the client has it cached anyway, e.g. in the bags)
        local class = ClassOf(id)
        if class and not GEAR[class] then return "later" end
        waits[id] = (waits[id] or 0) + 1
        if waits[id] <= MAX_WAITS then
            waiting[id] = true
            local request = C_Item and C_Item.RequestLoadItemDataByID
            if request then pcall(request, id) end
        end
        return "wait"
    end
    local known = ns.db.items[id]
    -- facts recorded from an auction house row before the client had the item cached
    if known and known.bd == nil then ns.Store.RefreshItemInfo(id) end
    if not GEAR[d.classId] and not UseSpell(id) then
        skip[id] = true
        I.stats.skipped = I.stats.skipped + 1
        -- remembered for items with a record (auction house items, drops): not queued again
        if known then known.dv = I.VERSION end
        return "skip"
    end
    local it = ns.Store.Item(id)
    local e = I.Collect(id, d)
    local Ser = ns.Codec.Serialize
    local changed = false
    for _, f in ipairs(FIELDS) do
        if Ser(it[f] == nil and false or it[f]) ~= Ser(e[f] == nil and false or e[f]) then
            it[f] = e[f]
            changed = true
        end
    end
    it.dv = I.VERSION
    I.stats.read = I.stats.read + 1
    if changed then
        I.stats.changed = I.stats.changed + 1
        ns.Store.Mark(it)
    end
    return "done"
end

-- /worldcodex diag item <id or link>: what the client returns for an item and what was recorded (for
-- testing in game; without an id only the queue counters).
function I.Diagnose(id)
    local s = I.stats
    local out = {
        string.format(
            "item details: queued %d, waiting %d, read %d, changed %d, skipped %d",
            s.queued,
            I.Pending(),
            s.read,
            s.changed,
            s.skipped
        ),
    }
    if type(id) ~= "number" then
        out[#out + 1] = "/worldcodex diag item <item id or link>"
        return out
    end
    local d = ns.ItemDetails(id)
    out[#out + 1] = string.format(
        "item %d: %s, class %s, link %s",
        id,
        tostring(d.name or "not cached"),
        tostring(d.classId),
        tostring(d.link and d.link:gsub("|", "||"))
    )
    local get = C_Item and C_Item.GetItemStats
    local ok, raw = false, nil
    if get then
        ok, raw = pcall(get, d.link or ("item:" .. id))
    end
    local stats = {}
    for k, v in pairs(ok and type(ns.Plain(raw)) == "table" and raw or {}) do
        stats[#stats + 1] = tostring(ns.Plain(k)) .. "=" .. tostring(ns.Plain(v))
    end
    table.sort(stats)
    out[#out + 1] = string.format(
        "GetItemStats: %s %s",
        get and (ok and type(raw) or "error") or "missing",
        table.concat(stats, " ")
    )
    local tip = C_TooltipInfo and C_TooltipInfo.GetItemByID
    local tok, data = false, nil
    if tip then
        tok, data = pcall(tip, id)
    end
    data = tok and ns.Plain(data) or nil
    local lines = type(data) == "table" and ns.Plain(data.lines) or nil
    out[#out + 1] = string.format(
        "GetItemByID: %s, %s lines",
        tip and (tok and type(data) or "error") or "missing",
        type(lines) == "table" and #lines or "no"
    )
    for i, line in ipairs(type(lines) == "table" and lines or {}) do
        if i > 20 then break end
        line = ns.Plain(line)
        if type(line) == "table" then
            out[#out + 1] = string.format(
                "  %d [%s] %s | %s",
                i,
                tostring(ns.Plain(line.type)),
                tostring(ns.Plain(line.leftText)):gsub("|", "||"),
                tostring(ns.Plain(line.rightText)):gsub("|", "||")
            )
        end
    end
    local it = ns.db.items[id]
    local saved = {}
    for _, f in ipairs(FIELDS) do
        if it and it[f] ~= nil then saved[#saved + 1] = f .. "=" .. ns.Codec.Serialize(it[f]) end
    end
    out[#out + 1] = string.format(
        "recorded (dv %s): %s",
        tostring(it and it.dv),
        #saved > 0 and table.concat(saved, " ") or "nothing"
    )
    return out
end

function I.Step()
    if head > #queue or not ns.db or ns.InCombat() or ns.Restricted("Combat") then return end
    local clock = debugprofilestop
    local start = clock and clock()
    local reads = 0
    for _ = 1, STEP_CHECKS do
        local id = queue[head]
        if not id then break end
        queue[head] = nil
        head = head + 1
        queued[id] = nil
        local it = ns.db.items[id]
        local result = not (it and it.dv == I.VERSION) and not skip[id] and I.Read(id)
        if result == "done" or result == "wait" then reads = reads + 1 end
        if reads >= STEP_ITEMS or (start and clock() - start > STEP_MS) then break end
    end
    if head > #queue then
        queue, head = {}, 1
    end
end

-- ---------------------------------------------------------------- where item ids come from

local function QueueBags()
    for id in pairs(ns.BagItems()) do
        I.Queue(id)
    end
end

local function QueueEquipped(unit)
    if not GetInventoryItemLink then return end
    for slot = 1, 19 do
        I.QueueLink(ns.Call(GetInventoryItemLink, unit, slot))
    end
end

-- The unit token of an inspected player (the inspect window inspects the target; other addons inspect
-- group members).
local function InspectedUnit(guid)
    guid = ns.Plain(guid)
    if type(guid) ~= "string" or not UnitGUID then return nil end
    local units = { "target", "mouseover", "focus" }
    for i = 1, 4 do
        units[#units + 1] = "party" .. i
    end
    for i = 1, 40 do
        units[#units + 1] = "raid" .. i
    end
    for _, unit in ipairs(units) do
        if ns.Call(UnitGUID, unit) == guid then return unit end
    end
    return nil
end
I.InspectedUnit = InspectedUnit

local CHAT_EVENTS = {
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
    "CHAT_MSG_EMOTE",
    "CHAT_MSG_GUILD",
    "CHAT_MSG_OFFICER",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_WHISPER",
    "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_BN_WHISPER",
    "CHAT_MSG_BN_WHISPER_INFORM",
    "CHAT_MSG_CHANNEL",
    "CHAT_MSG_COMMUNITIES_CHANNEL",
    "CHAT_MSG_LOOT",
    "CHAT_MSG_TRADESKILLS",
}

ns.On("DB_READY", function(db)
    for _, event in ipairs(CHAT_EVENTS) do
        ns.RegisterEvent(event, I.QueueText)
    end
    ns.RegisterEvent("INSPECT_READY", function(guid)
        local unit = InspectedUnit(guid)
        if unit then QueueEquipped(unit) end
    end)
    ns.RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function(slot)
        if GetInventoryItemLink then I.QueueLink(ns.Call(GetInventoryItemLink, "player", slot)) end
    end)
    ns.RegisterEvent("GET_ITEM_INFO_RECEIVED", function(id, success)
        if not waiting[id] then return end
        waiting[id] = nil
        if success ~= false then I.Queue(id) end
    end)
    ns.On("BAGS_CHANGED", QueueBags)
    ns.On("RECEIVED", function(id) I.Queue(id) end)
    ns.On("PRICES_UPDATED", function(id)
        if id then return I.Queue(id) end
        -- a full scan: every listed item (trade goods without a use spell are passed over cheaply, and
        -- remembered once they have a record)
        for itemId in pairs(db.ah) do
            I.Queue(itemId)
        end
    end)
    -- what was recorded before (drops, vendors, recipes) and what the player carries, once settled
    ns.After(15, function()
        for id in pairs(db.items) do
            I.Queue(id)
        end
        for id in pairs(ns.Store.TradeItemIds(nil, true)) do
            I.Queue(id)
        end
        QueueBags()
        QueueEquipped("player")
    end)
    ns.Every(0.25, I.Step)
end)
