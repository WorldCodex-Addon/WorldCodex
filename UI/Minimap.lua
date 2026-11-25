local _, ns = ...

-- Minimap button (uses LibDataBroker + LibDBIcon when installed, otherwise a small built-in button).
local L = ns.L
local M = {}
ns.Minimap = M

local button

local function OnClick(_, mouse)
    if mouse == "RightButton" then
        ns.Options.Open()
    else
        ns.Browser.Toggle()
    end
end

local function OnTooltip(tt)
    tt:AddLine("WorldCodex")
    tt:AddLine(L["Left-click: open WorldCodex"], 1, 1, 1)
    tt:AddLine(L["Right-click: options"], 1, 1, 1)
    local s = ns.FarmingOn() and ns.Farm.Current()
    if s then tt:AddLine(string.format("%s: %s/h", L["Session"], ns.Coin(ns.Farm.GoldPerHour(s))), 0.8, 0.8, 0.8) end
end

local function Position()
    local angle = math.rad(ns.db.settings.minimapAngle or 220)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function CreateOwn()
    button = CreateFrame("Button", "WorldCodexMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    button:SetScript("OnClick", OnClick)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        OnTooltip(GameTooltip)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            ns.db.settings.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            Position()
        end)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    Position()
end

function M.Update()
    local show = ns.db.settings.minimap
    if M.dbicon then
        if show then
            M.dbicon:Show("WorldCodex")
        else
            M.dbicon:Hide("WorldCodex")
        end
        return
    end
    if not Minimap then return end
    if not button then CreateOwn() end
    if show then
        button:Show()
    else
        button:Hide()
    end
end

ns.On("DB_READY", function()
    local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
    local icon = LibStub and LibStub("LibDBIcon-1.0", true)
    if ldb and icon then
        local obj = ldb:NewDataObject("WorldCodex", {
            type = "launcher",
            icon = "Interface\\Icons\\INV_Misc_Bag_10",
            OnClick = OnClick,
            OnTooltipShow = OnTooltip,
        })
        ns.db.settings.ldbicon = ns.db.settings.ldbicon or {}
        icon:Register("WorldCodex", obj, ns.db.settings.ldbicon)
        M.dbicon = icon
    end
    M.Update()
end)

ns.On("SETTINGS_CHANGED", function(key)
    if key == "minimap" then M.Update() end
    if key == "tracker" or key == "farming" then ns.Tracker.Update() end
end)

return M
