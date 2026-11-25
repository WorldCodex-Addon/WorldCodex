local _, ns = ...

-- Small movable frame with active goals (one clickable row each) and the current session's gold per hour.
-- Left-click a goal: show it in the browser. Right-click a goal: remove it.
local L = ns.L
local W = ns.Widgets
local T = {}
ns.Tracker = T

local ROW_H = 16
local f
local rows = {}

local function Row(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, f)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", 8, -6 - (i - 1) * ROW_H)
    r:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    W.Color(hl, 1, 1, 1, 0.08)
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.text:SetPoint("LEFT", 2, 0)
    r.text:SetPoint("RIGHT", -2, 0)
    r.text:SetJustifyH("LEFT")
    r.text:SetWordWrap(false)
    r:SetScript("OnClick", function(self, button)
        if not self.itemId then
            if button == "RightButton" then ns.Browser.Toggle("farming") end
            return
        end
        if button == "RightButton" then
            ns.Farm.ClearGoal(self.itemId)
            ns.Print(string.format(L["goal removed: %s"], ns.ItemName(self.itemId, true)))
        else
            if ns.Page then
                ns.Page.Show({ type = "item", id = self.itemId })
            else
                ns.Browser.ShowItem(self.itemId)
            end
        end
    end)
    r:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        if self.itemId then
            GameTooltip:SetHyperlink("item:" .. self.itemId)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(L["Left-click: details, right-click: remove goal"], 0.6, 0.8, 1)
        else
            GameTooltip:AddLine(L["Right-click: farming overview"], 0.6, 0.8, 1)
        end
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and IsShiftKeyDown and IsShiftKeyDown() then f:StartMoving() end
    end)
    r:SetScript("OnMouseUp", function() f:StopMovingOrSizing() end)
    rows[i] = r
    return r
end

local function Create()
    f = CreateFrame("Frame", "WorldCodexTrackerFrame", UIParent, W.BACKDROP_TEMPLATE)
    f:SetSize(240, 40)
    f:SetPoint("RIGHT", -40, 120)
    W.ApplyBackdrop(f, 0.6)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
end

function T.Update()
    local s = ns.db and ns.db.settings
    if not s then return end
    local lines = {}
    local ids = {}
    for itemId in pairs(ns.db.farm.goals) do
        ids[#ids + 1] = itemId
    end
    table.sort(ids)
    for _, itemId in ipairs(ids) do
        local have, target, minutes = ns.Farm.GoalProgress(itemId)
        local color = have >= target and "|cff00ff00" or "|cffffffff"
        lines[#lines + 1] = {
            itemId = itemId,
            text = string.format(
                "%s %s%d/%d|r  %s",
                ns.ItemName(itemId, true),
                color,
                have,
                target,
                have >= target and "" or ("ETA " .. (minutes and ns.Duration(minutes) or "?"))
            ),
        }
    end
    local session = ns.Farm.Current()
    if session and session.last - session.start >= 60 then
        lines[#lines + 1] = {
            text = string.format(
                "|cffaaaaaa%s %s/h · %d %s|r",
                L["Session"],
                ns.Coin(ns.Farm.GoldPerHour(session)),
                session.kills,
                L["kills"]
            ),
        }
    end
    if not s.tracker or not ns.FarmingOn() or #lines == 0 then
        if f then f:Hide() end
        return
    end
    if not f then Create() end
    for i, line in ipairs(lines) do
        local r = Row(i)
        r.itemId = line.itemId
        r.text:SetText(line.text)
        r:Show()
    end
    for i = #lines + 1, #rows do
        rows[i]:Hide()
    end
    f:SetHeight(#lines * ROW_H + 12)
    f:Show()
end

ns.On("DB_READY", function()
    ns.Every(5, T.Update)
    ns.On("GOALS_CHANGED", T.Update)
end)

return T
