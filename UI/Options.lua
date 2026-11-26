local _, ns = ...

local L = ns.L
local W = ns.Widgets
local O = {}
ns.Options = O

local panel, category

-- Encyclopedia (left) and the optional farming features (right).
local OPTIONS = {
    { "tooltip", L["Show item tooltip info"] },
    { "tooltipBars", L["Rate bars in item tooltips"] },
    { "tooltipPageHint", L["Show the page key in tooltips"] },
    { "tooltipUnit", L["Show mob tooltip info"] },
    { "tooltipObject", L["Show info on chests, herbs and veins"] },
    { "tooltipObjectHook", L["Chest info on clients without object tooltips (/reload, may cause UI errors)"] },
    { "altClickPage", L["Alt-click item links opens the item page"] },
    { "autoScanAH", L["Scan AH automatically when opened"] },
    { "sync", L["Share data with guild and group"] },
    { "useGuild", L["Use guild data"] },
    { "useCommunity", L["Use community data"] },
    { "countGroupKills", L["Count kills in groups"] },
    { "useCombatLog", L["Use combat log for kills (/reload; not allowed on every client)"] },
    { "minimap", L["Show minimap button"] },
    { "debug", L["Debug output"] },
}
local FARMING = {
    { "farming", L["Farming features (goals, tracker, arrow, sessions, best farm)"] },
    { "tracker", L["Show goal tracker"] },
    { "arrow", L["Show navigation arrow"] },
    { "streakAlerts", L["Dry-streak alerts"] },
}

local function Set(key, v)
    ns.db.settings[key] = v
    -- an explicit choice is kept, also when a farming addon is installed or removed later
    if key == "farming" then ns.db.settings.farmingAuto = false end
    ns.Store.indexDirty = true
    ns.Fire("SETTINGS_CHANGED", key, v)
end

local function Create()
    panel = CreateFrame("Frame", "WorldCodexOptionsPanel", UIParent)
    panel.name = "WorldCodex"
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("WorldCodex " .. ns.VERSION)
    local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    sub:SetText(L["Drop rates, sources and prices of every item, learned from play. /worldcodex help"])
    local guide = W.Button(panel, L["How to use WorldCodex"], 190, function() ns.Welcome.Show() end)
    guide:SetPoint("TOPRIGHT", -16, -16)
    if ns.UPLOAD_URL then
        local upload = W.Button(panel, L["Upload data"], 130, function() ns.Slash("upload") end)
        upload:SetPoint("RIGHT", guide, "LEFT", -8, 0)
    end
    local function Group(title, list, x)
        local head = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        head:SetPoint("TOPLEFT", x, -64)
        head:SetText(title)
        local y = -86
        for _, o in ipairs(list) do
            local key = o[1]
            local cb = W.Check(panel, o[2], function()
                if key == "farming" then return ns.FarmingOn() end
                return ns.db.settings[key]
            end, function(v) Set(key, v) end)
            cb:SetPoint("TOPLEFT", x, y)
            y = y - 28
        end
        return y
    end
    local y = Group(L["Encyclopedia"], OPTIONS, 16)
    local fy = Group(L["Farming (optional)"], FARMING, 340)
    local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", 344, fy - 4)
    note:SetWidth(280)
    note:SetJustifyH("LEFT")
    note:SetText(
        L["Off by default when Blackthornes Farmer is installed. Drop rates, pages and tooltips work the same either way."]
    )
    local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 20, y - 6)
    label:SetText(L["Sources shown in tooltip"])
    local input = W.Input(panel, 40)
    input:SetPoint("LEFT", label, "RIGHT", 10, 0)
    input:SetNumeric(true)
    input:SetScript("OnShow", function(self) self:SetText(tostring(ns.db.settings.tooltipSources or 3)) end)
    input:SetScript("OnTextChanged", function(self)
        local n = tonumber(self:GetText())
        if n and n >= 0 and n <= 10 then ns.db.settings.tooltipSources = n end
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        category = Settings.RegisterCanvasLayoutCategory(panel, "WorldCodex")
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

function O.Open()
    ns.context = "options open"
    if ns.InCombat() then
        ns.Print(L["options can't be opened in combat"])
        return
    end
    if not panel then Create() end
    if Settings and Settings.OpenToCategory and category then
        Settings.OpenToCategory(category.GetID and category:GetID() or category.ID)
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end

ns.On("DB_READY", function()
    if not panel then Create() end
end)

return O
