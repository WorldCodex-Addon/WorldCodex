local _, ns = ...

-- Welcome window with a short guide: opens once after the first login, later with /worldcodex welcome
-- or from the options. The texts follow the settings (farming, key binding, website, upload address).
local L = ns.L
local W = ns.Widgets
local We = {}
ns.Welcome = We

local WIDTH, PAD, TOP, BOTTOM = 560, 20, 40, 48
local DELAY = 4 -- seconds after login, when the loading screen is gone
local RETRY = 5 -- in combat: asked again

local function PageKey()
    local key = GetBindingKey and ns.Call(GetBindingKey, "WORLDCODEX_HOVER")
    return type(key) == "string" and key ~= "" and key or nil
end

-- { { title, text }, ... }
function We.Sections()
    local out = {}
    local function add(title, text) out[#out + 1] = { title = title, text = text } end
    add(
        L["1. Just play"],
        L["WorldCodex records what you loot and gather, quest rewards, vendors, trainers, recipes and auction prices. You don't have to set anything up. The more you play, the surer the drop rates get."]
    )
    add(
        L["2. Look at tooltips"],
        L["Items show where they drop, how often, and their price. Mobs, chests, herbs and veins show what they drop. Hold Shift over an item for more."]
    )
    add(
        L["3. Open the book"],
        L["Type /wcx or left-click the minimap button. The tabs at the bottom switch between the lists. Click an entry for its facts, double-click it for its page, or type a name into the search box at the top to jump to any item or source. The filter box on a list narrows that list. The item list starts with your bags only; untick that or filter to see everything."]
    )
    local key = PageKey()
    local jump =
        L["Set a key under Key Bindings > AddOns > WorldCodex: it opens the page of the item, NPC or object under your mouse."]
    if key then
        jump = string.format(L["Press %s to open the page of the item, NPC or object under your mouse."], key)
    end
    add(L["4. Jump to a page"], jump .. " " .. L["/wcx item <name> and /wcx mob <name> work too."])
    add(
        L["5. Read the rates"],
        L["The bar shows the drop rate, its band the range the true rate is probably in: the narrower, the surer. All, Mine and Community switch between everyone's data and your own. Quest items only count kills made while you needed them."]
    )
    if ns.FarmingOn() then
        add(
            L["6. Farm (optional)"],
            L["/wcx goto <item> leads you to the best known spot, /wcx goal <item> 20 tracks a goal. Both can be switched off in the options."]
        )
    end
    local sharing =
        L["With your guild and group, drop data is exchanged automatically; you can switch that off in the options. /wcx export and /wcx import exchange it as text with anyone."]
    if ns.WEB_BASE then sharing = sharing .. " " .. string.format(L["Community data: %s"], ns.WEB_BASE) end
    if ns.UPLOAD_URL then
        sharing = sharing
            .. " "
            .. string.format(
                L["Upload your share string from /wcx upload at %s: it goes into the community data that comes with every update of the addon."],
                ns.UPLOAD_URL
            )
    end
    add(L["Sharing"], sharing)
    return out
end

local f

local function Create()
    f = W.Window("WorldCodexWelcomeFrame", L["Welcome to WorldCodex"], WIDTH, 480)
    f.lines = {}
    f.intro = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.intro:SetPoint("TOPLEFT", PAD, -TOP)
    f.intro:SetWidth(WIDTH - 2 * PAD)
    f.intro:SetJustifyH("LEFT")
    local open = W.Button(f, L["Open WorldCodex"], 150, function()
        f:Hide()
        ns.Browser.Toggle("items")
    end)
    open:SetPoint("BOTTOMLEFT", PAD - 4, 14)
    local options = W.Button(f, L["Options"], 110, function()
        -- in combat the options stay closed, so does this window
        if not ns.InCombat() then f:Hide() end
        ns.Options.Open()
    end)
    options:SetPoint("LEFT", open, "RIGHT", 8, 0)
    local close = W.Button(f, L["Close"], 110, function() f:Hide() end)
    close:SetPoint("BOTTOMRIGHT", -(PAD - 4), 14)
    f.buttons = { open = open, options = options, close = close }
end

local function Line(i, font)
    local fs = f.lines[i]
    if not fs then
        fs = f:CreateFontString(nil, "OVERLAY", font)
        fs:SetWidth(WIDTH - 2 * PAD)
        fs:SetJustifyH("LEFT")
        f.lines[i] = fs
    end
    return fs
end

local function Render()
    f.intro:SetText(
        L["Your item database in the game: where every item drops, how often, how sure that number is, and what it is worth."]
    )
    local y = TOP + (f.intro:GetStringHeight() or 24) + 12
    local n = 0
    for _, s in ipairs(We.Sections()) do
        for _, part in ipairs({ { s.title, "GameFontNormal", 3 }, { s.text, "GameFontHighlightSmall", 10 } }) do
            n = n + 1
            local fs = Line(n, part[2])
            fs:SetText(part[1])
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", PAD, -y)
            fs:Show()
            y = y + (fs:GetStringHeight() or 14) + part[3]
        end
    end
    for i = n + 1, #f.lines do
        f.lines[i]:Hide()
    end
    f:SetHeight(y + BOTTOM)
end

function We.Show()
    ns.context = "welcome window"
    if not f then Create() end
    -- shown before measuring: hidden text has no height on some clients
    f:Show()
    Render()
end

function We.IsShown() return f ~= nil and f:IsShown() end

-- For tests.
function We._Frame() return f end

-- First login only; the flag is account-wide like all data.
local function FirstLogin()
    if not ns.db or ns.db.meta.welcomed then return end
    if ns.InCombat() then return ns.After(RETRY, FirstLogin) end
    ns.db.meta.welcomed = true
    ns.Print(
        L["Welcome to WorldCodex! Type /wcx to open it, /wcx welcome for a short guide, /wcx help for all commands."]
    )
    We.Show()
end

ns.RegisterEvent("PLAYER_LOGIN", function() ns.After(DELAY, FirstLogin) end)

return We
