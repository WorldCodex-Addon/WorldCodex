local _, ns = ...

local W = {}
ns.Widgets = W

local BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil
W.BACKDROP_TEMPLATE = BACKDROP_TEMPLATE

function W.ApplyBackdrop(f, alpha)
    if f.SetBackdrop then
        f:SetBackdrop(BACKDROP)
        f:SetBackdropColor(0, 0, 0, alpha or 0.92)
    end
end

function W.Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 110, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

-- Scrollable multi-line edit box. readOnly keeps text from being changed by typing; font is a font
-- object or its name (default ChatFontNormal).
function W.ScrollText(parent, readOnly, font)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject(font or ChatFontNormal)
    eb:SetMaxLetters(0)
    eb:SetWidth(400)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    if readOnly then
        eb:SetScript("OnTextChanged", function(self, user)
            if user and self.fixed then self:SetText(self.fixed) end
        end)
        eb:SetScript("OnEditFocusGained", function(self) self:HighlightText(0, 0) end)
    end
    eb:SetHyperlinksEnabled(true)
    eb:SetScript("OnHyperlinkClick", function(_, link, text, button)
        if SetItemRef then SetItemRef(link, text, button) end
    end)
    scroll:SetScrollChild(eb)
    scroll:SetScript("OnSizeChanged", function(self, w) eb:SetWidth(math.max(50, (w or 400) - 4)) end)
    scroll.edit = eb
    function scroll:SetText(text)
        eb.fixed = text
        eb:SetText(text or "")
        eb:SetCursorPosition(0)
        self:SetVerticalScroll(0)
    end
    function scroll:GetText() return eb:GetText() end
    return scroll
end

function W.Check(parent, label, get, set, font)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    local fs = cb:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    fs:SetText(label)
    cb:SetScript("OnShow", function(self) self:SetChecked(get() and true or false) end)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    return cb
end

function W.Input(parent, width)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(width or 160, 20)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return eb
end

-- Simple vertical slider used as a scroll bar for list views.
function W.Slider(parent)
    local s = CreateFrame("Slider", nil, parent, BACKDROP_TEMPLATE)
    s:SetOrientation("VERTICAL")
    s:SetWidth(14)
    if s.SetBackdrop then
        s:SetBackdrop({
            bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
            edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
            tile = true,
            tileSize = 8,
            edgeSize = 8,
            insets = { left = 3, right = 3, top = 6, bottom = 6 },
        })
    end
    s:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    s:SetMinMaxValues(0, 0)
    s:SetValueStep(1)
    s:SetValue(0)
    return s
end

-- Item / NPC icon with an optional border.
function W.Icon(parent, size)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(size, size)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    function f:SetIcon(texture) self.tex:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark") end
    return f
end

function W.Color(tex, r, g, b, a)
    if tex.SetColorTexture then
        tex:SetColorTexture(r, g, b, a)
    else
        tex:SetTexture(r, g, b, a)
    end
end

-- ---------------------------------------------------------------- spellbook look

-- The WorldCodex window looks like Blizzard's spellbook on this client: the standard window frame with
-- its dark top bar, below it an open book (W.Book). Text on the pages uses Blizzard's system fonts in the
-- spellbook's ink (SPELLBOOK_FONT_COLOR), as the spellbook itself does; text on the window frame uses
-- Blizzard's light standard fonts ("frame..." roles). Colour codes in page text are darkened by W.Ink
-- (white, gold and the quality colours are made for dark backgrounds).

-- Colours drawn on the pages (charts, table rows, rules): W.PAPER, set for the page style by W.Book.
-- ink (0-255) is the default chart colour, so the personal overlay (blue) stands out.
W.PAGE_COLORS = {
    paper = {
        hover = { 0.45, 0.30, 0.10, 0.16 },
        select = { 0.20, 0.42, 0.80, 0.24 },
        well = { 0.35, 0.24, 0.10, 0.2 }, -- chart backgrounds
        track = { 0.30, 0.20, 0.08, 0.3 }, -- rate bar background
        tick = { 0.25, 0.16, 0.06, 0.6 },
        ink = { 150, 100, 35 },
    },
    inset = { -- the dark inset frame of clients without any book art
        hover = { 1, 1, 1, 0.08 },
        select = { 0.25, 0.50, 1, 0.25 },
        well = { 0, 0, 0, 0.35 },
        track = { 1, 1, 1, 0.12 },
        tick = { 1, 1, 1, 0.45 },
        ink = { 205, 175, 125 },
    },
}
W.PAPER = W.PAGE_COLORS.paper

-- The spellbook's ink (SPELLBOOK_FONT_COLOR when the client has it and it is dark), a lighter ink for
-- secondary text and a red-brown one for small headings. Each is { r, g, b }.
local INK_FALLBACK = { 0.24, 0.16, 0.08 }
W.INK = { muted = { 0.36, 0.27, 0.17 }, accent = { 0.42, 0.14, 0.04 } }
function W.InkColor()
    if W.INK.ink then return W.INK.ink end
    local ink = INK_FALLBACK
    local c = SPELLBOOK_FONT_COLOR
    if type(c) == "table" and c.GetRGB then
        local ok, r, g, b = pcall(c.GetRGB, c)
        if ok and type(r) == "number" and type(g) == "number" and type(b) == "number" then
            if 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.35 then ink = { r, g, b } end
        end
    end
    W.INK.ink = ink
    return ink
end

-- role = { Blizzard font, ink } on paper; sizes in pixels as comments.
local PAGE_FONTS = {
    pageTitle = { "SystemFont_Huge1", "ink" }, -- 20, the page heading
    title = { "SystemFont_Large", "ink" }, -- 16
    heading = { "SystemFont_Large", "ink" }, -- 16
    headingSmall = { "SystemFont_Med2", "accent" }, -- 13
    body = { "SystemFont_Med1", "ink" }, -- 12
    bodyLarge = { "SystemFont_Med3", "ink" }, -- 14
    muted = { "SystemFont_Med1", "muted" }, -- 12
    mutedLarge = { "SystemFont_Med3", "muted" }, -- 14
}
-- light fonts: the window frame, and the pages when they are the dark inset
local FRAME_FONTS = {
    pageTitle = "GameFontNormalHuge",
    title = "GameFontNormalLarge",
    heading = "GameFontNormalLarge",
    headingSmall = "GameFontNormal",
    body = "GameFontHighlight",
    bodyLarge = "GameFontHighlightLarge",
    muted = "GameFontDisable",
    mutedLarge = "GameFontDisableLarge",
}
local SMALL_FRAME_FONTS = { body = "GameFontHighlightSmall", muted = "GameFontDisableSmall" }

-- A Blizzard font in one of the inks (created once as WorldCodexPage_<role>); the Blizzard font itself
-- when fonts cannot be made.
local function InkFont(role, spec)
    local name = "WorldCodexPage_" .. role
    if _G[name] then return name end
    local base = _G[spec[1]] ~= nil and spec[1] or "GameFontHighlight"
    if not CreateFont or _G[base] == nil then return base end
    local ok, fo = pcall(CreateFont, name)
    if not ok or not fo then return base end
    if fo.CopyFontObject then
        pcall(fo.CopyFontObject, fo, _G[base])
    elseif fo.SetFontObject then
        pcall(fo.SetFontObject, fo, _G[base])
    end
    local c = spec[2] == "ink" and W.InkColor() or W.INK[spec[2]]
    fo:SetTextColor(c[1], c[2], c[3], 1)
    if fo.SetShadowColor then fo:SetShadowColor(0, 0, 0, 0) end
    return name
end

-- Font object name for a role: "pageTitle", "title", "heading", "headingSmall", "body", "bodyLarge",
-- "muted", "mutedLarge" on the pages; "frameTitle", "frameBody", "frameMuted", ... on the window frame
-- ("frameBody"/"frameMuted" are the small ones).
function W.Font(role)
    local frameRole = type(role) == "string" and role:match("^frame(%u.*)$")
    local name
    if frameRole then
        frameRole = frameRole:sub(1, 1):lower() .. frameRole:sub(2)
        name = SMALL_FRAME_FONTS[frameRole] or FRAME_FONTS[frameRole]
    elseif W.pageStyle == "inset" then
        name = FRAME_FONTS[role]
    elseif PAGE_FONTS[role] then
        return InkFont(role, PAGE_FONTS[role])
    end
    name = name or "GameFontHighlight"
    if _G[name] == nil and _G.GameFontHighlight ~= nil then return "GameFontHighlight" end
    return name
end

function W.Text(parent, role, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", W.Font(role))
    fs:SetJustifyH("LEFT")
    return fs
end

local function Byte(v) return math.max(0, math.min(255, math.floor(v * 255 + 0.5))) end

local function HslToRgb(h, s, l)
    local c = (1 - math.abs(2 * l - 1)) * s
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = l - c / 2
    local r, g, b
    if h < 60 then
        r, g, b = c, x, 0
    elseif h < 120 then
        r, g, b = x, c, 0
    elseif h < 180 then
        r, g, b = 0, c, x
    elseif h < 240 then
        r, g, b = 0, x, c
    elseif h < 300 then
        r, g, b = x, 0, c
    else
        r, g, b = c, 0, x
    end
    return r + m, g + m, b + m
end

-- A colour made for dark backgrounds, as a colour for the paper pages: dark colours stay, white becomes
-- the ink and greys the secondary ink, coloured text keeps its hue at a readable darkness (gold turns
-- brown).
function W.InkHex(hex)
    local r = tonumber(hex:sub(1, 2), 16) / 255
    local g = tonumber(hex:sub(3, 4), 16) / 255
    local b = tonumber(hex:sub(5, 6), 16) / 255
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local l, d = (mx + mn) / 2, mx - mn
    if l <= 0.36 then return hex end
    local s = d == 0 and 0 or d / (1 - math.abs(2 * l - 1))
    if s < 0.25 then
        -- white becomes the ink, greys the lighter secondary ink (both well readable on paper)
        local ink, muted = W.InkColor(), W.INK.muted
        local t = math.max(0, math.min(1, (1 - l) / 0.5))
        return string.format(
            "%02x%02x%02x",
            Byte(ink[1] + (muted[1] - ink[1]) * t),
            Byte(ink[2] + (muted[2] - ink[2]) * t),
            Byte(ink[3] + (muted[3] - ink[3]) * t)
        )
    end
    local h
    if mx == r then
        h = ((g - b) / d) % 6
    elseif mx == g then
        h = (b - r) / d + 2
    else
        h = (r - g) / d + 4
    end
    h = h * 60
    if h >= 35 and h <= 75 then h = 30 end
    local nr, ng, nb = HslToRgb(h, math.max(s, 0.7), 0.3)
    local lum = 0.2126 * nr + 0.7152 * ng + 0.0722 * nb
    if lum > 0.18 then
        local k = 0.18 / lum
        nr, ng, nb = nr * k, ng * k, nb * k
    end
    return string.format("%02x%02x%02x", Byte(nr), Byte(ng), Byte(nb))
end

local inkCache, inkSize = {}, 0

-- Text with every |cAARRGGBB colour code made readable on the paper pages (W.InkHex); cached.
function W.Ink(text)
    if W.pageStyle == "inset" or type(text) ~= "string" or not text:find("|c", 1, true) then return text end
    local hit = inkCache[text]
    if hit then return hit end
    local out = (text:gsub("|c(%x%x)(%x%x%x%x%x%x)", function(a, hex) return "|c" .. a .. W.InkHex(hex) end))
    if inkSize >= 4000 then
        inkCache, inkSize = {}, 0
    end
    inkCache[text], inkSize = out, inkSize + 1
    return out
end

local function IsObject(x) return type(x) == "table" and type(x.GetObjectType) == "function" end

-- false only when the client says the template does not exist; CreateFrame runs in pcall anyway.
local function TemplateKnown(name)
    if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
        local ok, info = pcall(C_XMLUtil.GetTemplateInfo, name)
        if ok then return info ~= nil end
    end
    return true
end

-- The client's own window frame (title bar, portrait ring, close button), or nil.
local function BlizzardFrame(globalName)
    if not TemplateKnown("PortraitFrameTemplate") then return nil end
    local ok, f = pcall(CreateFrame, "Frame", globalName, UIParent, "PortraitFrameTemplate")
    if not ok or not f then return nil end
    if not IsObject(f.CloseButton) then
        f:Hide()
        return nil
    end
    return f
end

local function SetBlizzardTitle(f, text)
    if f.SetTitle and pcall(f.SetTitle, f, text) then return end
    local fs = f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)
    if IsObject(fs) then fs:SetText(text) end
end

local function SetBlizzardPortrait(f, icon)
    if f.SetPortraitToAsset and pcall(f.SetPortraitToAsset, f, icon) then return true end
    local p = f.portrait or f.Portrait or (f.PortraitContainer and f.PortraitContainer.portrait)
    if not IsObject(p) then return false end
    if not (SetPortraitToTexture and pcall(SetPortraitToTexture, p, icon)) then p:SetTexture(icon) end
    return true
end

-- Movable dialog-strata window, closed with Escape (UISpecialFrames).
local function Movable(f, globalName, width, height)
    f:SetSize(width, height)
    f:ClearAllPoints()
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:Hide()
    if globalName and UISpecialFrames then table.insert(UISpecialFrames, globalName) end
    return f
end

-- Classic dialog border with a header and close button: clients without PortraitFrameTemplate.
local function DialogFrame(globalName, title, alpha)
    local f = CreateFrame("Frame", globalName, UIParent, BACKDROP_TEMPLATE)
    f.chrome = "dialog"
    W.ApplyBackdrop(f, alpha)
    local header = f:CreateTexture(nil, "ARTWORK")
    header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    header:SetSize(300, 64)
    header:SetPoint("TOP", 0, 12)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", header, "TOP", 0, -14)
    f.title:SetText(title)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    return f
end

-- The WorldCodex window: the client's standard frame (PortraitFrameTemplate: title bar, portrait ring,
-- close button, its own background), as Blizzard's Adventure Guide uses it; clients without that
-- template get the classic dialog border and header. f.chrome is "blizzard" or "dialog"; the top left
-- 60 x 56 pixels hold the portrait (or the icon in its place).
function W.JournalWindow(globalName, title, width, height, icon)
    local f = BlizzardFrame(globalName)
    if f then
        f.chrome = "blizzard"
        SetBlizzardTitle(f, title)
        SetBlizzardPortrait(f, icon)
    else
        f = DialogFrame(globalName, title, 0.95)
        f.emblem = W.Icon(f, 40)
        f.emblem:SetPoint("TOPLEFT", 14, -14)
        f.emblem:SetIcon(icon)
    end
    return Movable(f, globalName, width, height)
end

-- Other windows (report, export, import, web link): the same standard frame without the portrait, or the
-- classic dialog border. Content starts about 40 pixels below the top edge.
function W.Window(globalName, title, width, height)
    local f = BlizzardFrame(globalName)
    if f then
        f.chrome = "blizzard"
        SetBlizzardTitle(f, title)
        local hidden = f.SetBorder and pcall(f.SetBorder, f, "ButtonFrameTemplateNoPortrait")
        if hidden and f.SetPortraitShown then pcall(f.SetPortraitShown, f, false) end
        if not hidden then SetBlizzardPortrait(f, "Interface\\Icons\\INV_Misc_Book_09") end
    else
        f = DialogFrame(globalName, title)
    end
    return Movable(f, globalName, width, height)
end

-- An open book (anchored by the caller): the spellbook's two page atlases, else the Adventure Guide's
-- journal pages, else the quest frame's parchment (each page), else the client's dark inset frame. What
-- the client has is checked once (W.pageStyle: "spellbook", "journal", "quest" or "inset"); the page fonts
-- and colours follow it. book:SetSplit(x) puts the spine x pixels from the left edge.
local SPELLBOOK_LEFT, SPELLBOOK_RIGHT = "spellbook-Page-Left-C60", "spellbook-Page-Right-C60"
local JOURNAL = "Interface\\EncounterJournal\\UI-EJ-JournalBG"
local QUEST_PAPER = "Interface\\QuestFrame\\QuestBG"
local SPINE, PAGES_RIGHT, PAGES_BOTTOM = 0.3833, 0.7666, 0.8301
-- The spellbook's pages carry a dark band at their top (the spellbook's own tabs sit on it; about 8 % of
-- the height, measured in game); it is cut off so the paper starts at the top of the book.
W.SPELLBOOK_CROP_TOP = 0.078
W.pageStyle = false

-- Whether the client has this atlas / texture file.
function W.HasAtlas(name)
    if not (C_Texture and C_Texture.GetAtlasInfo) then return false end
    local ok, info = pcall(C_Texture.GetAtlasInfo, name)
    return ok and type(info) == "table"
end

local function HasTexture(tex, file)
    local ok, loaded = pcall(tex.SetTexture, tex, file)
    if not ok or loaded == false then return false end
    if not tex.GetTextureFileID then return true end
    local okId, id = pcall(tex.GetTextureFileID, tex)
    return okId and type(id) == "number" and id > 0
end

-- The atlas without its top band (its file and texture coordinates); the whole atlas when the client
-- gives no file for it.
local function SetCroppedAtlas(tex, atlas, crop)
    local ok, info = pcall(C_Texture.GetAtlasInfo, atlas)
    local file = ok and type(info) == "table" and (info.file or info.filename) or nil
    if file and info.topTexCoord and info.bottomTexCoord and info.leftTexCoord and info.rightTexCoord then
        local t, b = info.topTexCoord, info.bottomTexCoord
        tex:SetTexture(file)
        tex:SetTexCoord(info.leftTexCoord, info.rightTexCoord, t + (b - t) * crop, b)
        return true
    end
    tex:SetAtlas(atlas, false)
    return false
end

function W.Book(parent)
    local book = CreateFrame("Frame", nil, parent)
    local left = book:CreateTexture(nil, "BACKGROUND", nil, 1)
    local right = book:CreateTexture(nil, "BACKGROUND", nil, 1)
    book.pages = { left, right }
    if not W.pageStyle then
        if W.HasAtlas(SPELLBOOK_LEFT) and W.HasAtlas(SPELLBOOK_RIGHT) then
            W.pageStyle = "spellbook"
        elseif HasTexture(left, JOURNAL) then
            W.pageStyle = "journal"
        elseif HasTexture(left, QUEST_PAPER) then
            W.pageStyle = "quest"
        else
            W.pageStyle = "inset"
        end
        W.PAPER = W.PAGE_COLORS[W.pageStyle == "inset" and "inset" or "paper"]
    end
    local style = W.pageStyle
    if style == "spellbook" then
        SetCroppedAtlas(left, SPELLBOOK_LEFT, W.SPELLBOOK_CROP_TOP)
        SetCroppedAtlas(right, SPELLBOOK_RIGHT, W.SPELLBOOK_CROP_TOP)
    elseif style == "journal" then
        left:SetTexture(JOURNAL)
        left:SetTexCoord(0, SPINE, 0, PAGES_BOTTOM)
        right:SetTexture(JOURNAL)
        right:SetTexCoord(SPINE, PAGES_RIGHT, 0, PAGES_BOTTOM)
    elseif style == "quest" then
        left:SetTexture(QUEST_PAPER)
        right:SetTexture(QUEST_PAPER)
    else
        for i, tex in ipairs(book.pages) do
            tex:Hide()
            local ok, inset = pcall(CreateFrame, "Frame", nil, book, "InsetFrameTemplate")
            if ok and inset then
                -- on the book's own level, under the content of the pages
                inset:SetFrameLevel(book:GetFrameLevel())
                book.pages[i] = inset
            end
        end
    end
    function book:SetSplit(x)
        local l, r = self.pages[1], self.pages[2]
        l:ClearAllPoints()
        l:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
        l:SetPoint("BOTTOMRIGHT", self, "BOTTOMLEFT", x, 0)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", self, "TOPLEFT", x, 0)
        r:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", 0, 0)
    end
    book:SetSplit(300)
    return book
end

-- The spellbook's ornamental rule under a heading (a thin line on other page styles), from x1 to x2 at
-- y (offsets in parent).
function W.Divider(parent, x1, x2, y)
    local t = parent:CreateTexture(nil, "ARTWORK")
    if W.pageStyle == "spellbook" and W.HasAtlas("spellbook-divider") then
        t:SetAtlas("spellbook-divider", false)
        t:SetHeight(11)
    else
        local c = W.PAPER.tick
        W.Color(t, c[1], c[2], c[3], 0.5)
        t:SetHeight(1)
    end
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", x1, y)
    t:SetPoint("TOPRIGHT", parent, "TOPLEFT", x2, y)
    return t
end

-- The spellbook's frame around an icon button (made for 40 px icons; scaled to the button).
function W.IconFrame(button)
    if not (W.HasAtlas("spellbook-item-iconframe") and button.CreateTexture) then return nil end
    local k = (button:GetWidth() or 40) / 40
    local shadow = button:CreateTexture(nil, "BACKGROUND")
    if W.HasAtlas("spellbook-item-iconframe-shadow") then
        shadow:SetAtlas("spellbook-item-iconframe-shadow", false)
        shadow:SetPoint("TOPLEFT", -12 * k, 3 * k)
        shadow:SetPoint("BOTTOMRIGHT", 2 * k, -8 * k)
    end
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetAtlas("spellbook-item-iconframe", false)
    border:SetPoint("TOPLEFT", -11 * k, 1 * k)
    border:SetPoint("BOTTOMRIGHT", 1 * k, -7 * k)
    button.frameBorder = border
    return border
end

-- Section tabs under a window in the client's style (PanelTabButtonTemplate), else plain buttons.
-- tabs:Set({ {id=, label=} }) rebuilds them, tabs:Select(id) marks one; clicks call onClick(id).
function W.BottomTabs(f, onClick)
    local t = { buttons = {}, selected = false }
    local template = TemplateKnown("PanelTabButtonTemplate") and "PanelTabButtonTemplate" or nil
    local prefix = f:GetName()
    f.maxTabWidth = 160 -- read by the tab template when it sizes itself
    local function Make(i)
        local b
        local name = prefix and (prefix .. "Tab" .. i) or nil
        if template then
            local ok, made = pcall(CreateFrame, "Button", name, f, template)
            if ok and made then
                local text = made.Text or (name and _G[name .. "Text"])
                if IsObject(text) and IsObject(made.Left or (name and _G[name .. "Left"])) then
                    b = made
                    b.blizzard = true
                    -- the newer tab art sits side by side, the older one overlaps by design
                    b.gap = IsObject(made.LeftActive) and 3 or -15
                else
                    made:Hide()
                end
            end
        end
        if not b then
            b = W.Button(f, "", 100)
            b:SetHeight(22)
            b.gap = 2
        end
        b:SetScript("OnClick", function(self)
            if onClick then onClick(self.id) end
        end)
        return b
    end
    function t:Set(list)
        local prev
        for i, tab in ipairs(list) do
            local b = self.buttons[i] or Make(i)
            self.buttons[i] = b
            b.id = tab.id
            b:SetText(tab.label)
            if b.blizzard then
                if not (PanelTemplates_TabResize and pcall(PanelTemplates_TabResize, b, 0)) then b:SetWidth(110) end
            else
                b:SetWidth(math.max(80, math.min(140, #tostring(tab.label) * 7 + 20)))
            end
            b:ClearAllPoints()
            if prev then
                b:SetPoint("LEFT", prev, "RIGHT", b.gap, 0)
            else
                b:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, b.blizzard and 2 or 0)
            end
            b:Show()
            prev = b
        end
        for i = #list + 1, #self.buttons do
            self.buttons[i]:Hide()
            self.buttons[i].id = false
        end
        self:Select(self.selected)
    end
    function t:Select(id)
        self.selected = id or false
        for _, b in ipairs(self.buttons) do
            local on = b.id and b.id == id
            if b.blizzard and PanelTemplates_SelectTab then
                pcall(on and PanelTemplates_SelectTab or PanelTemplates_DeselectTab, b)
            elseif on then
                b:LockHighlight()
            else
                b:UnlockHighlight()
            end
        end
    end
    return t
end

-- Page tabs above the book in the client's style (PanelTopTabButtonTemplate), else plain buttons.
-- tabs:Set({ {id=, label=, width=} }) rebuilds them from tabs.anchor (its bottom left is the bottom left
-- of the first tab, which stands on the page below), tabs:Select(id[, silent]) marks one and calls
-- onSelect(id). The tabs live in their own frame: the template adds every tab to its parent's Tabs list.
function W.Tabs(parent, onSelect)
    local t = { buttons = {}, list = {}, selected = nil }
    local template = TemplateKnown("PanelTopTabButtonTemplate") and "PanelTopTabButtonTemplate" or nil
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetAllPoints(parent)
    holder.maxTabWidth = 160 -- read by the tab template when it sizes itself
    local function Make()
        local b
        if template then
            local ok, made = pcall(CreateFrame, "Button", nil, holder, template)
            if ok and made then
                if IsObject(made.Text) and IsObject(made.Left) then
                    b = made
                    b.blizzard = true
                    b.gap = IsObject(made.LeftActive) and 3 or -15 -- as W.BottomTabs
                else
                    made:Hide()
                end
            end
        end
        if not b then
            b = W.Button(holder, "", 100)
            b:SetHeight(20)
            b.gap = 2
        end
        b:SetScript("OnClick", function(self) t:Select(self.id) end)
        return b
    end
    function t:Select(id, silent)
        self.selected = id
        for _, b in ipairs(self.buttons) do
            local on = b.id == id
            if b.blizzard and PanelTemplates_SelectTab then
                pcall(on and PanelTemplates_SelectTab or PanelTemplates_DeselectTab, b)
            elseif on then
                b:LockHighlight()
            else
                b:UnlockHighlight()
            end
        end
        if not silent and onSelect then onSelect(id) end
    end
    function t:Set(list)
        self.list = list
        local prev
        for i, tab in ipairs(list) do
            local b = self.buttons[i] or Make()
            self.buttons[i] = b
            b.id = tab.id
            b:SetText(tab.label)
            if b.blizzard then
                if not (PanelTemplates_TabResize and pcall(PanelTemplates_TabResize, b, 10)) then b:SetWidth(110) end
            else
                b:SetWidth(tab.width or math.max(70, math.min(140, #tostring(tab.label) * 7 + 16)))
            end
            b:ClearAllPoints()
            if prev then
                b:SetPoint("LEFT", prev, "RIGHT", b.gap, 0)
            else
                b:SetPoint("BOTTOMLEFT", self.anchor or parent, "BOTTOMLEFT", 0, 0)
            end
            b:Show()
            prev = b
        end
        for i = #list + 1, #self.buttons do
            self.buttons[i]:Hide()
        end
    end
    function t:Has(id)
        for _, tab in ipairs(self.list) do
            if tab.id == id then return true end
        end
        return false
    end
    return t
end

-- Search field in the client's style (SearchBoxTemplate: magnifier, "Search" placeholder, clear
-- button), else a plain input box. Its own scripts must be hooked, not replaced (W.OnEdit); onClear runs
-- after the clear button emptied it.
function W.SearchBox(parent, width, onClear)
    local eb
    if TemplateKnown("SearchBoxTemplate") then
        local ok, made = pcall(CreateFrame, "EditBox", nil, parent, "SearchBoxTemplate")
        if ok and made then eb = made end
    end
    if eb then
        eb.blizzard = true
        eb:SetSize(width or 160, 20)
        eb:SetAutoFocus(false)
        if IsObject(eb.clearButton) and onClear then eb.clearButton:HookScript("OnClick", onClear) end
    else
        eb = W.Input(parent, width)
    end
    return eb
end

-- Sets a script of an edit box made by W.SearchBox (hooked on the client's template, which needs its own).
function W.OnEdit(eb, event, fn)
    if eb.blizzard and eb.HookScript then
        eb:HookScript(event, fn)
    else
        eb:SetScript(event, fn)
    end
end

return W
