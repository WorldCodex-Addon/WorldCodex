local _, ns = ...

-- Spell page: a spell a trainer teaches or a recipe of a profession window (Spells.lua). Shows the
-- spell's rank and description, which trainers teach it at what cost, and for recipes the item it
-- creates and the reagents. Tabs and rows come from UI/PageExtra.lua (X.SpellTabs).
local L = ns.L
local P = ns.Page

local R = { Columns = {}, noLayers = true }

local function Profession(id)
    local product = ns.Crafting and ns.Crafting.ForSpell(id)
    local r = product and ns.Crafting.Get(product)
    if r and r.pf then return ns.Crafting.ProfessionName(r.pf) end
    for npc in pairs(ns.Trainers and ns.Trainers.ForSpell(id) or {}) do
        local info = ns.Trainers.Get(npc)
        if info and info.tt == "profession" and info.pf then return ns.Trainers.ProfessionName(info.pf) end
        if info and info.tt == "class" and info.cls then return ns.Trainers.ClassName(info.cls) end
    end
    return nil
end

function R.Prepare(id)
    if ns.Spells then ns.Spells.Record(id) end
end

function R.Header(id)
    local info = ns.Spells.Info(id)
    local product = ns.Crafting and ns.Crafting.ForSpell(id)
    local sub = { product and L["Recipe"] or L["Spell"] }
    if info.rank then sub[#sub + 1] = info.rank end
    local level = ns.Spells.Level(id)
    if level then sub[#sub + 1] = L["Level"] .. " " .. level end
    local prof = Profession(id)
    if prof then sub[#sub + 1] = prof end
    sub[#sub + 1] = "#" .. id
    local desc = info.desc or ""
    if #desc > 400 then desc = desc:sub(1, 397) .. "..." end
    return {
        icon = info.icon or 134400,
        link = "spell:" .. id,
        title = info.name or (L["Spell"] .. " " .. id),
        sub = table.concat(sub, " · "),
        info = desc,
    }
end

function R.Actions(id)
    return {
        {
            label = L["Link"],
            width = 60,
            fn = function()
                if ChatEdit_InsertLink then ChatEdit_InsertLink(ns.Spells.Link(id)) end
            end,
        },
    }
end

function R.Tabs(id)
    local tabs = ns.PageExtra.SpellTabs(id)
    if #tabs == 0 then
        tabs[1] = {
            id = "taught",
            label = L["Taught by"],
            count = 0,
            table = "taught",
            rows = {},
            empty = L["No trainer has been seen teaching this spell yet."],
        }
    end
    return tabs
end

function R.Select(r)
    if not r then return P.Analysis(nil, { empty = L["Select a row to see the details."] }) end
    if r.openType == "item" then
        return P.Analysis(nil, { empty = ns.ItemName(r.openId, true) .. "\n" .. tostring(r.roleText or "") })
    end
    return ns.PageExtra.Select(r)
end

function R.Open(r)
    if r and r.openType then return P.Show({ type = r.openType, id = r.openId }) end
    return false
end

function R.RowTooltip(tt, r) return ns.PageExtra.Tooltip(tt, r) end

function R.EmptyText() return L["Select a row to see the details."] end

P.Register("spell", R)
ns.PageSpell = R

return R
