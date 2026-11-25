local _, ns = ...

-- Built-in navigation arrow, used when TomTom is not installed.
local L = ns.L
local A = {}
ns.Arrow = A

local f
local ARRIVE_YARDS = 15

local function Create()
    f = CreateFrame("Button", "WorldCodexArrowFrame", UIParent)
    f:SetSize(64, 84)
    f:SetPoint("TOP", 0, -120)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:RegisterForClicks("RightButtonUp")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetScript("OnClick", function() ns.Nav.ClearWaypoint() end)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(48, 48)
    f.icon:SetPoint("TOP")
    f.icon:SetTexture("Interface\\Minimap\\MinimapArrow")
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.title:SetPoint("TOP", f.icon, "BOTTOM", 0, -2)
    f.dist = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.dist:SetPoint("TOP", f.title, "BOTTOM", 0, -2)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("WorldCodex")
        GameTooltip:AddLine(L["Drag to move, right-click to stop navigation"], 1, 1, 1)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed < 0.05 then return end
        self.elapsed = 0
        A.Update()
    end)
    f:Hide()
end

function A.Update()
    local target = ns.Nav.active
    if not target then
        f:Hide()
        return
    end
    local dist, bearing, why = ns.Nav.Relative(target)
    if not bearing then
        f.icon:Hide()
        f.dist:SetText(why == "zone" and string.format(L["Travel to %s"], ns.MapName(target.map)) or "?")
        return
    end
    f.icon:Show()
    local facing = GetPlayerFacing and GetPlayerFacing()
    if facing and f.icon.SetRotation then f.icon:SetRotation(bearing - facing) end
    if dist then
        if dist < ARRIVE_YARDS then
            f.dist:SetText("|cff00ff00" .. L["Arrived"] .. "|r")
            if not target.arrived then
                target.arrived = true
                ns.After(5, function()
                    if ns.Nav.active == target then ns.Nav.ClearWaypoint(true) end
                end)
            end
        else
            f.dist:SetText(string.format("%d yd", math.floor(dist + 0.5)))
        end
    else
        f.dist:SetText("")
    end
end

ns.On("WAYPOINT", function(target)
    if not f then Create() end
    if target and ns.db.settings.arrow and ns.FarmingOn() and not ns.Nav.tomtomUid then
        f.title:SetText(target.title or "")
        f:Show()
    else
        f:Hide()
    end
end)

return A
