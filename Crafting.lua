local _, ns = ...

-- Recipes of the professions the player opens: what an item is made from, and what it is used for.
-- db.recipes[productKey] = { pf = profession key, mn = min made, mx = max made, r = { [reagentId] = n },
--                           sid = recipe spell id, t }
-- productKey is the created item id, or "enchant:<spellId>" for recipes that create no item.
-- Read through C_TradeSkillUI (WoW Forever has no GetTradeSkill*/GetCraft* functions, see the in-game
-- API dump in .claude/skills/wow-forever-api): all recipes of the open profession window, including
-- ones the player has not learned, read in the background. The window itself is never changed.
local Cr = {}
ns.Crafting = Cr

local Store = ns.Store

-- Locale-neutral profession keys from the profession spell names of this client.
Cr.PROFESSION_SPELLS = {
    alchemy = 2259,
    blacksmithing = 2018,
    enchanting = 7411,
    engineering = 4036,
    leatherworking = 2108,
    tailoring = 3908,
    cooking = 2550,
    firstaid = 3273,
    smelting = 2656,
    jewelcrafting = 25229,
    inscription = 45357,
    poisons = 2842,
}

local profByName
function Cr.ProfessionKey(name)
    if type(name) ~= "string" or name == "" then return "other" end
    if not profByName then
        profByName = {}
        for key, spell in pairs(Cr.PROFESSION_SPELLS) do
            local n = ns.SpellName(spell)
            if n then profByName[n:lower()] = key end
        end
    end
    return profByName[name:lower()] or name:lower():gsub("[^%w]", "")
end

-- Localized profession name for a key (falls back to the key).
function Cr.ProfessionName(key)
    local spell = Cr.PROFESSION_SPELLS[key]
    return spell and ns.SpellName(spell) or tostring(key)
end

local function Db() return ns.db.recipes end

-- Same recipe facts (profession, amount made, reagents)?
local function SameRecipe(a, b)
    if a.pf ~= b.pf or a.mn ~= b.mn or a.mx ~= b.mx or a.sid ~= b.sid or type(a.r) ~= "table" then return false end
    for id, n in pairs(b.r) do
        if a.r[id] ~= n then return false end
    end
    for id in pairs(a.r) do
        if b.r[id] == nil then return false end
    end
    return true
end

-- Enum.Profession names -> profession keys (the same in every client language). Mining's crafting
-- window is smelting.
local PROFESSION_ENUM = {
    FirstAid = "firstaid",
    Blacksmithing = "blacksmithing",
    Leatherworking = "leatherworking",
    Alchemy = "alchemy",
    Cooking = "cooking",
    Mining = "smelting",
    Tailoring = "tailoring",
    Engineering = "engineering",
    Enchanting = "enchanting",
    Jewelcrafting = "jewelcrafting",
    Inscription = "inscription",
}

-- Profession key of a ProfessionInfo (C_TradeSkillUI.GetBaseProfessionInfo / GetProfessionInfoByRecipeID).
function Cr.ProfessionKeyOf(info)
    if type(info) ~= "table" then return nil end
    local profession = info.profession
    if profession ~= nil and Enum and Enum.Profession then
        for name, value in pairs(Enum.Profession) do
            if value == profession and PROFESSION_ENUM[name] then return PROFESSION_ENUM[name] end
        end
    end
    local name = info.parentProfessionName or info.professionName
    if type(name) == "string" and name ~= "" then return Cr.ProfessionKey(name) end
    return nil
end

local function EnumValue(enum, name, default)
    local e = Enum and Enum[enum]
    return e and e[name] or default
end

-- One recipe (spell id) from the client's recipe data: productKey, record; nil for recipes that are no
-- crafting recipe (salvage, gathering, recraft) or whose reagents cannot all be read.
function Cr.ReadRecipe(recipeID, pf)
    local T = C_TradeSkillUI
    if not (T and T.GetRecipeSchematic) or type(recipeID) ~= "number" then return nil end
    local info = ns.Call(T.GetRecipeInfo, recipeID)
    if type(info) == "table" then
        if info.isSalvageRecipe or info.isGatheringRecipe or info.isRecraft or info.isDummyRecipe then return nil end
    end
    local schematic = ns.Call(T.GetRecipeSchematic, recipeID, false)
    if type(schematic) ~= "table" then return nil end
    local product
    if schematic.recipeType == EnumValue("TradeskillRecipeType", "Enchant", 3) then
        product = "enchant:" .. recipeID
    elseif schematic.recipeType == nil or schematic.recipeType == EnumValue("TradeskillRecipeType", "Item", 1) then
        product = schematic.outputItemID
        if not product then
            local out = ns.Call(T.GetRecipeOutputItemData, recipeID)
            product = type(out) == "table" and (out.itemID or ns.ItemIdFromLink(out.hyperlink)) or nil
        end
    end
    if not product then return nil end
    -- required basic reagents only: optional and finishing reagents change the result, not the recipe
    local basic = EnumValue("CraftingReagentType", "Basic", 1)
    local reagents = {}
    local slots = type(schematic.reagentSlotSchematics) == "table" and schematic.reagentSlotSchematics or {}
    for _, slot in ipairs(slots) do
        if type(slot) == "table" and slot.reagentType == basic then
            local first = type(slot.reagents) == "table" and slot.reagents[1]
            local id = type(first) == "table" and first.itemID
            local n = tonumber(slot.quantityRequired)
            if not id or not n or n <= 0 then return nil end -- a currency or unreadable reagent
            reagents[id] = (reagents[id] or 0) + n
        end
    end
    if not next(reagents) then return nil end
    local mn = math.max(1, tonumber(schematic.quantityMin) or 1)
    local mx = math.max(mn, tonumber(schematic.quantityMax) or mn)
    return product, { pf = pf or "other", mn = mn, mx = mx, r = reagents, sid = recipeID }
end

-- Stores a recipe; true when its facts changed (then it is news for the next share string).
local function Save(product, rec)
    if rec.sid and ns.Spells then ns.Spells.Record(rec.sid) end
    local old = Db()[product]
    rec.t, rec.rv = ns.time(), old and old.rv
    Db()[product] = rec
    if old and SameRecipe(old, rec) then return false end
    Store.Mark(rec)
    return true
end

local function Changed(count)
    if count > 0 then
        Cr.indexDirty = true
        ns.Fire("DATA_CHANGED", "recipes")
    end
end

local RESCAN_AFTER = 600
local scanned = {} -- "professionID:recipe count" -> time of the last full read

-- Reads every recipe of the open profession window, a few milliseconds per frame (ns.RunJob). The same
-- profession with the same number of recipes is read again only after RESCAN_AFTER seconds.
function Cr.ScanOpenProfession()
    local T = C_TradeSkillUI
    if not (T and T.GetRecipeSchematic) then return false end
    if T.IsTradeSkillReady and not ns.Call(T.IsTradeSkillReady) then return false end
    -- while the data source changes the list is incomplete; TRADE_SKILL_LIST_UPDATE follows
    if ns.Call(T.IsDataSourceChanging) or ns.Call(T.IsNPCCrafting) or ns.Call(T.IsRuneforging) then return false end
    local ids = ns.Call(T.GetAllRecipeIDs) or ns.Call(T.GetFilteredRecipeIDs)
    if type(ids) ~= "table" or #ids == 0 then return false end
    local base = ns.Call(T.GetBaseProfessionInfo)
    local pf = Cr.ProfessionKeyOf(base)
    local key = tostring(type(base) == "table" and base.professionID or "?") .. ":" .. #ids
    if scanned[key] and GetTime() - scanned[key] < RESCAN_AFTER then return false end
    scanned[key] = GetTime()
    local list = {}
    for i, id in ipairs(ids) do
        list[i] = id
    end
    ns.RunJob("recipes", function()
        local stored, changed = 0, 0
        for _, id in ipairs(list) do
            local product, rec = Cr.ReadRecipe(id, pf or Cr.ProfessionKeyOf(ns.Call(T.GetProfessionInfoByRecipeID, id)))
            if product then
                stored = stored + 1
                if Save(product, rec) then changed = changed + 1 end
            end
            ns.Yield()
        end
        return { recipes = #list, stored = stored, changed = changed, profession = pf }
    end, function(ok, result)
        if not ok or type(result) ~= "table" then return end
        Cr.lastScan = result
        Changed(result.changed)
    end)
    return true
end

-- A recipe just learned: read at once.
function Cr.ReadLearned(recipeID)
    local T = C_TradeSkillUI
    if not T then return end
    local pf = Cr.ProfessionKeyOf(ns.Call(T.GetProfessionInfoByRecipeID, recipeID))
    local product, rec = Cr.ReadRecipe(recipeID, pf)
    if product and Save(product, rec) then Changed(1) end
end

-- ---------------------------------------------------------------- layers and readers

function Cr.Layers()
    local out = { { layer = "me", t = Db() } }
    if ns.db.settings.useGuild then
        for _, peer in pairs(ns.db.peers) do
            if type(peer.rc) == "table" and not Store.IsContributor(peer.uid) then
                out[#out + 1] = { layer = "guild", t = peer.rc }
            end
        end
    end
    local c = Store.Community()
    if c and ns.db.settings.useCommunity and type(c.recipes) == "table" then
        out[#out + 1] = { layer = "community", t = c.recipes }
    end
    return out
end

function Cr.Get(product)
    for _, l in ipairs(Cr.Layers()) do
        local r = l.t[product]
        if type(r) == "table" and type(r.r) == "table" then return r, l.layer end
    end
    return nil
end

local using, bySpell -- reagentId -> { [productKey] = true }; recipe spell id -> productKey
Cr.indexDirty = true

local function Rebuild()
    using, bySpell = {}, {}
    for _, l in ipairs(Cr.Layers()) do
        for product, r in pairs(l.t) do
            if type(r) == "table" and type(r.r) == "table" then
                for id in pairs(r.r) do
                    using[id] = using[id] or {}
                    using[id][product] = true
                end
                local sid = tonumber(r.sid) or tonumber(tostring(product):match("^enchant:(%d+)$"))
                if sid and bySpell[sid] == nil then bySpell[sid] = product end
            end
        end
    end
    Cr.indexDirty = false
end

function Cr.Using(reagentId)
    if Cr.indexDirty or not using then Rebuild() end
    return using[reagentId] or {}
end

-- Product key of a recipe spell (nil when unknown).
function Cr.ForSpell(spellId)
    if Cr.indexDirty or not bySpell then Rebuild() end
    return bySpell[spellId]
end

-- Recipe spell id of a product key (nil when unknown).
function Cr.SpellOf(product)
    local r = Cr.Get(product)
    local sid = r and tonumber(r.sid)
    return sid or tonumber(tostring(product):match("^enchant:(%d+)$"))
end

ns.On("DATA_CHANGED", function(what)
    if what ~= "recipes" then Cr.indexDirty = true end
end)
ns.On("SETTINGS_CHANGED", function() Cr.indexDirty = true end)

ns.On("DB_READY", function(db)
    db.recipes = type(db.recipes) == "table" and db.recipes or {}
    -- the window sends these often (filters, crafting); one read shortly after the last of them
    local token = 0
    local function Soon()
        token = token + 1
        local mine = token
        ns.After(0.5, function()
            if mine == token then Cr.ScanOpenProfession() end
        end)
    end
    for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED" }) do
        ns.RegisterEvent(event, Soon)
    end
    ns.RegisterEvent("NEW_RECIPE_LEARNED", function(recipeID) Cr.ReadLearned(recipeID) end)
end)

return Cr
