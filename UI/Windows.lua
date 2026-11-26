local _, ns = ...

local L = ns.L
local W = ns.Widgets
local UI = ns.UI or {}
ns.UI = UI

local function TextWindow(globalName, title, readOnly)
    local f = W.Window(globalName, title, 680, 480)
    f.text = W.ScrollText(f, readOnly)
    f.text:SetPoint("TOPLEFT", 16, -40)
    f.text:SetPoint("BOTTOMRIGHT", -34, 44)
    return f
end

-- ---------------------------------------------------------------- report

local report
function UI.ShowReport()
    if not report then
        report = TextWindow("WorldCodexReportFrame", "WorldCodex - " .. L["Report"], true)
        local refresh = W.Button(report, L["Refresh"], 110, function() report.text:SetText(ns.Report.ReportText()) end)
        refresh:SetPoint("BOTTOMLEFT", 14, 12)
        local exp = W.Button(report, L["Export"] .. "...", 110, function() UI.ShowExport("lua") end)
        exp:SetPoint("LEFT", refresh, "RIGHT", 8, 0)
    end
    report.text:SetText(ns.Report.ReportText())
    report:Show()
end

-- ---------------------------------------------------------------- KPIs

-- The KPIs are a page of the WorldCodex window (UI/PageKPI.lua).
function UI.ShowKPI() return ns.Page.Show({ type = "kpi", id = "all" }) end

-- ---------------------------------------------------------------- export

local export

-- What the export window shows: the share string (upload / guild import), the full export as Lua or
-- JSON with a choice of sections, or one CSV table. The share string is built in the background
-- (Report.ExportStringAsync), the others at once.
local function ExportText(fmt, dataset, sections)
    if fmt == "csv" then return ns.Export.Csv(dataset) end
    if fmt == "lua" then return ns.Export.Lua(sections) end
    return ns.Export.Json(sections)
end

local SHARE_HINT =
    L["Compact text with everything that can be shared: drops, quests, vendors, recipes, NPCs, items and current prices. Paste it into /worldcodex import or upload it to the website."]

local function ShareHint(info)
    if not info then return SHARE_HINT end
    local counts = string.format(L["%d sources, %d items, %d prices"], info.sources, info.items, info.prices)
    if info.base then
        return string.format(
            L["Only what changed since your upload in the community data (%s). Upload it like a full string; it is added to your earlier upload."],
            counts
        )
    end
    return SHARE_HINT .. " (" .. counts .. ")"
end

local function ShowText(e, text)
    e.text:SetText(text)
    local lines = select(2, text:gsub("\n", "")) + 1
    e.status:SetText(string.format(L["%.1f KB, %d lines"], #text / 1024, lines))
    e.shownText = text
    e.text.edit:SetFocus()
    e.text.edit:HighlightText()
end

local FORMATS = {
    { id = "string", label = L["Share string"] },
    { id = "lua", label = "Lua" },
    { id = "json", label = "JSON" },
    { id = "csv", label = "CSV" },
}

local CSV_LABEL = {
    drops = L["Drops"],
    quests = L["Quests"],
    items = L["Items"],
    prices = L["Prices"],
    history = L["Price history"],
    vendors = L["Vendors"],
    recipes = L["Recipes"],
    trainers = L["Trainers"],
    spells = L["Spells"],
    npcs = L["NPCs"],
}

local function Render()
    local e = export
    for _, b in ipairs(e.formatButtons) do
        if b.id == e.fmt then
            b:LockHighlight()
        else
            b:UnlockHighlight()
        end
    end
    local full = e.fmt == "lua" or e.fmt == "json"
    e.sectionFrame:SetShown(full)
    e.csvFrame:SetShown(e.fmt == "csv")
    e.hint:SetShown(e.fmt == "string")
    e.onlyNew:SetShown(e.fmt == "string" and ns.Store.DeltaBase() ~= nil)
    if e.upload then e.upload:SetShown(e.fmt == "string") end
    for _, b in ipairs(e.csvButtons) do
        if b.id == e.dataset then
            b:LockHighlight()
        else
            b:UnlockHighlight()
        end
    end
    if e.fmt == "string" then
        -- years of data take a moment: built over several frames, the game keeps running
        local token = {}
        e.token, e.shownText = token, nil
        e.text:SetText(L["Building the share string..."])
        e.status:SetText("")
        e.hint:SetText(SHARE_HINT)
        ns.Report.ExportStringAsync(e.fullShare, function(text, info, err)
            if e.token ~= token then return end -- another format or option was chosen meanwhile
            if not text then
                e.text:SetText(tostring(err))
                return
            end
            e.hint:SetText(ShareHint(info))
            ShowText(e, text)
        end)
        return
    end
    e.token = nil
    ShowText(e, ExportText(e.fmt, e.dataset, e.sections))
end

local function CreateExport()
    export = W.Window("WorldCodexExportFrame", "WorldCodex - " .. L["Export"], 780, 540)
    export.fmt, export.dataset = "string", "drops"
    export.sections = {}
    for _, sec in ipairs(ns.Export.SECTIONS) do
        export.sections[sec.id] = true
    end
    export.formatButtons, export.csvButtons = {}, {}
    local x = 16
    for _, f in ipairs(FORMATS) do
        local b = W.Button(export, f.label, 110, function()
            export.fmt = f.id
            Render()
        end)
        b.id = f.id
        b:SetPoint("TOPLEFT", x, -38)
        x = x + 114
        export.formatButtons[#export.formatButtons + 1] = b
    end

    export.hint = export:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    export.hint:SetPoint("TOPLEFT", 18, -68)
    export.hint:SetWidth(740)
    export.hint:SetJustifyH("LEFT")
    export.hint:SetText(SHARE_HINT)
    -- share string: only what changed since the upload in the community file, or everything
    export.fullShare = false
    export.onlyNew = W.Check(
        export,
        L["Only what is new since your upload in the community data"],
        function() return not export.fullShare end,
        function(v)
            export.fullShare = not v
            Render()
        end,
        "GameFontHighlightSmall"
    )
    export.onlyNew:SetPoint("TOPLEFT", 14, -94)

    -- share string: where to upload it. Addon text cannot be clicked open, so the address is a
    -- copyable field (selected on click) instead of a comment inside the share string.
    if ns.UPLOAD_URL then
        local up = CreateFrame("Frame", nil, export)
        up:SetPoint("TOPRIGHT", -34, -94)
        up:SetSize(360, 22)
        up.input = W.Input(up, 250)
        up.input:SetPoint("RIGHT", 0, 0)
        up.input:SetText(ns.UPLOAD_URL)
        up.input:SetCursorPosition(0)
        -- read-only: typing puts the address back
        up.input:SetScript("OnTextChanged", function(self, user)
            if user then self:SetText(ns.UPLOAD_URL) end
        end)
        up.input:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        up.input:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0) end)
        up.label = up:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        up.label:SetPoint("RIGHT", up.input, "LEFT", -10, 0)
        up.label:SetText(L["Upload at:"])
        export.upload = up
    else
        export.upload = false
    end

    -- full export: which sections
    export.sectionFrame = CreateFrame("Frame", nil, export)
    export.sectionFrame:SetPoint("TOPLEFT", 14, -64)
    export.sectionFrame:SetSize(750, 52)
    for i, sec in ipairs(ns.Export.SECTIONS) do
        local cb = W.Check(export.sectionFrame, sec.label, function() return export.sections[sec.id] end, function(v)
            export.sections[sec.id] = v or nil
            Render()
        end)
        local col, row = (i - 1) % 6, math.floor((i - 1) / 6)
        cb:SetPoint("TOPLEFT", col * 125, -row * 24)
    end

    -- CSV: which table
    export.csvFrame = CreateFrame("Frame", nil, export)
    export.csvFrame:SetPoint("TOPLEFT", 16, -66)
    export.csvFrame:SetSize(750, 24)
    local cx = 0
    for _, id in ipairs(ns.Export.CSV) do
        local b = W.Button(export.csvFrame, CSV_LABEL[id] or id, 72, function()
            export.dataset = id
            Render()
        end)
        b.id = id
        b:SetHeight(20)
        b:SetPoint("TOPLEFT", cx, 0)
        cx = cx + 75
        export.csvButtons[#export.csvButtons + 1] = b
    end

    export.text = W.ScrollText(export, false)
    export.text:SetPoint("TOPLEFT", 16, -120)
    export.text:SetPoint("BOTTOMRIGHT", -34, 44)
    local all = W.Button(export, L["Select all"], 110, function()
        export.text.edit:SetFocus()
        export.text.edit:HighlightText()
    end)
    all:SetPoint("BOTTOMLEFT", 14, 12)
    export.status = export:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    export.status:SetPoint("LEFT", all, "RIGHT", 12, 0)
    local copy = export:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    copy:SetPoint("BOTTOMRIGHT", -36, 18)
    copy:SetText(L["select all, Ctrl+C"])
end

-- fmt: "string" (default), "lua", "json" or "csv"; dataset: CSV table (drops, quests, items, ...)
function UI.ShowExport(fmt, dataset)
    if not export then CreateExport() end
    if fmt == "lua" or fmt == "json" or fmt == "csv" then
        export.fmt = fmt
    else
        export.fmt = "string"
    end
    if dataset then
        for _, id in ipairs(ns.Export.CSV) do
            if id == dataset then export.dataset = dataset end
        end
    end
    export:Show()
    Render()
end

-- For tests: what the export window shows.
function UI.ExportState()
    if not export then return nil end
    return {
        fmt = export.fmt,
        dataset = export.dataset,
        text = export.shownText,
        sections = export.sections,
        hint = export.hint:GetText(),
        onlyNew = export.onlyNew:IsShown() and not export.fullShare,
        upload = export.upload and export.upload:IsShown() and export.upload.input:GetText() or nil,
    }
end

-- ---------------------------------------------------------------- web link

local web
function UI.ShowWebLink(url)
    if not url then return end
    if not web then
        web = W.Window("WorldCodexWebLinkFrame", "WorldCodex - " .. L["Web link"], 460, 110)
        web.input = W.Input(web, 420)
        web.input:SetPoint("TOP", 0, -46)
        web.hint = web:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        web.hint:SetPoint("TOP", web.input, "BOTTOM", 0, -8)
        web.hint:SetText(L["select all, Ctrl+C"])
    end
    web.input:SetText(url)
    web:Show()
    web.input:SetFocus()
    web.input:HighlightText()
end
ns.WebLink = function(kind, id) UI.ShowWebLink(ns.WebUrl(kind, id)) end

-- ---------------------------------------------------------------- import

local import
function UI.ShowImport()
    if not import then
        import = TextWindow(
            "WorldCodexImportFrame",
            "WorldCodex - " .. L["Import"] .. " (" .. L["paste a share string"] .. ")",
            false
        )
        local status = import:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        status:SetPoint("BOTTOMLEFT", 250, 18)
        local b = W.Button(import, L["Import"], 110, function()
            local ok, res = ns.Report.Import(import.text:GetText())
            if ok then
                status:SetText(string.format("|cff00ff00" .. L["imported %d sources"] .. "|r", res))
                ns.Print(string.format(L["imported %d sources"], res))
            else
                status:SetText("|cffff4040" .. tostring(res) .. "|r")
            end
        end)
        b:SetPoint("BOTTOMLEFT", 14, 12)
        local clear = W.Button(import, L["Clear"], 110, function()
            import.text:SetText("")
            status:SetText("")
        end)
        clear:SetPoint("LEFT", b, "RIGHT", 8, 0)
    end
    import.text:SetText("")
    import:Show()
    import.text.edit:SetFocus()
end

return UI
