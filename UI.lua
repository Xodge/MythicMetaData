-- UI.lua
--
-- Overview: one line per character (alphabetical, full names), showing
-- current key + status, or an inactivity-recommendation overwrite.
-- Characters with no key held AND no current-season history are omitted
-- from the display entirely, unless they carry a pending removal flag
-- (see hasAnythingToShow below).
-- Click a row to expand it inline into the full per-dungeon table.
--
-- The expanded per-dungeon table uses a bundled monospace font (Adobe
-- Source Code Pro, SIL OFL -- freely redistributable) so that
-- fixed-width string.format padding actually lines up visually: with a
-- proportional font, padding characters in a string don't correspond to
-- equal pixel widths, so numbers never truly align no matter how the
-- string is built. A real monospace font is what makes "%6s"-style
-- right-justification (aligning the ones digit of +10 vs +8) actually
-- render aligned rather than just being aligned in the source string.

local ADDON_NAME, MMD = ...

local ROW_HEIGHT = 20
local expandedState = {} -- [charKey] = true/false, this session only, not saved

local frame

-- Bundled monospace font for the tabular per-dungeon rows only. Header
-- rows stay on the normal UI font since they're prose, not a table.
local MMD_MONO_FONT = CreateFont("MMDMonoFont")
MMD_MONO_FONT:SetFont("Interface\\AddOns\\MythicMetaData\\Fonts\\SourceCodePro-Regular.ttf", 11, "")
MMD_MONO_FONT:SetTextColor(1, 1, 1)

-- Column widths in CHARACTERS (meaningful here specifically because the
-- font above is monospace -- every character is the same pixel width).
local NAME_COL_WIDTH = 22
local COMPLETED_COL_WIDTH = 6 -- right-justified so the ones digit of any level lines up regardless of digit count

-- Defined up here (not next to the formatters) because hasAnythingToShow
-- below needs it, and a Lua local must be declared before the function
-- that references it -- otherwise the reference silently resolves to a
-- nil global.
local function isInactive(record)
    local threshold = (MMD.db.config.inactiveDays or 30) * 86400
    return (GetServerTime() - (record.lastUpdated or 0)) > threshold
end

-- Display filter: a character is shown if they currently hold a key (or
-- are mid-run), OR have any current-season dungeon history --
-- completed, depleted, or abandoned all count -- OR carry a pending
-- "Recommend removal for inactivity" flag (inactive and not excused),
-- so officers still see who's up for removal. Everyone else is just
-- clutter. This is display-only: the record stays in SavedVariables and
-- keeps syncing, so the character reappears automatically the moment
-- they pick up a key or log a run. (Deleting instead wouldn't stick
-- anyway -- the next manifest exchange would re-fetch it from a guildmate.)
-- Archived seasons don't count as "history" here; this is current-season only.
local function hasAnythingToShow(record)
    if record.currentKey then return true end
    if record.dungeons ~= nil and next(record.dungeons) ~= nil then return true end
    if isInactive(record) and not record.excused then return true end -- pending removal flag
    return false
end

local function getSortedCharacterKeys()
    local keys = {}
    for charKey, record in pairs(MMD.gdb and MMD.gdb.characters or {}) do
        if hasAnythingToShow(record) then
            table.insert(keys, charKey)
        end
    end
    table.sort(keys) -- alphabetical, full "Name-Realm" strings, per spec
    return keys
end

local function getSortedDungeonList()
    local list = {}
    for mapID, name in pairs(MMD.gdb and MMD.gdb.dungeons or {}) do
        table.insert(list, { mapID = mapID, name = name })
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Not in an instance: show the Current Key alone (this is a direct
-- read of the player's own held keystone -- no ambiguity).
-- In an instance: show a Status (elapsed time) separately from the
-- Current Key, with a caveat -- the key/level shown reflects whatever
-- run is actually active, which may belong to someone else in the
-- group, not necessarily the key this character personally holds.
local function formatCurrentKeyLine(record)
    if not record.currentKey then
        return "Idle - no key held"
    end
    local ck = record.currentKey
    local dungeonName = (MMD.gdb and MMD.gdb.dungeons or {})[ck.mapID] or ("Map " .. tostring(ck.mapID))
    local keyText = string.format("%s +%s", dungeonName, tostring(ck.level))

    if ck.inProgress then
        local elapsedMin = math.floor((GetServerTime() - (ck.startedAt or GetServerTime())) / 60)
        local status = string.format("In Progress, %dm", elapsedMin)
        if ck.mayNotBeOwnKey then
            keyText = keyText .. " (may not be own key)"
        end
        return string.format("%s -- %s", status, keyText)
    end

    return keyText
end

-- Returns just the stats portion (completed/depleted/placeholder) for a
-- dungeon cell -- the name column is built separately in UI_Refresh,
-- both for the final line and for measuring the divider's pixel
-- position, so the padding logic for the name column only lives in one
-- place.
local function formatDungeonStats(record, mapID)
    local d = record.dungeons[mapID]

    if not d then
        return string.format("%" .. COMPLETED_COL_WIDTH .. "s", "-") -- placeholder: never attempted
    end
    if d.abandoned and not d.completed and not d.depleted then
        return "Abandoned"
    end

    local completedStr = d.completed and ("+" .. d.completed) or "-"
    local stats = string.format("%" .. COMPLETED_COL_WIDTH .. "s", completedStr)
    if d.depleted then
        stats = stats .. string.format("  (failed +%d)", d.depleted)
    end
    return stats
end

-- ---------------------------------------------------------------------
-- Frame construction
-- ---------------------------------------------------------------------

local function createFrame()
    local f = CreateFrame("Frame", "MythicMetaDataFrame", UIParent, "BackdropTemplate")
    f:SetSize(420, 320)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        f:SetBackdropColor(0, 0, 0, 0.85)
    end

    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        MMD.db.windowPos = { point = point, relPoint = relPoint, x = x, y = y }
    end)

    -- Title bar (drag handle + close button)
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    titleBar:SetHeight(24)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local point, _, relPoint, x, y = f:GetPoint()
        MMD.db.windowPos = { point = point, relPoint = relPoint, x = x, y = y }
    end)

    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", 8, 0)
    title:SetText("Mythic Meta Data")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local expandAllBtn = CreateFrame("Button", nil, titleBar, "UIPanelButtonTemplate")
    expandAllBtn:SetSize(80, 20)
    expandAllBtn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
    expandAllBtn:SetText("Expand All")
    expandAllBtn:SetScript("OnClick", function()
        local allOpen = true
        for _, charKey in ipairs(getSortedCharacterKeys()) do
            if not expandedState[charKey] then allOpen = false end
        end
        for _, charKey in ipairs(getSortedCharacterKeys()) do
            expandedState[charKey] = not allOpen
        end
        MMD.UI_Refresh()
    end)

    -- Scrollable body
    local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 8, -28)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 1) -- height is resized dynamically in UI_Refresh; width is fixed up below and in UI_Refresh
    scrollFrame:SetScrollChild(content)
    content:SetWidth(scrollFrame:GetWidth())

    f.scrollFrame = scrollFrame
    f.content = content
    content.rowPool = {}

    f:Hide()
    f:SetScript("OnHide", function()
        local point, _, relPoint, x, y = f:GetPoint()
        MMD.db.windowPos = { point = point, relPoint = relPoint, x = x, y = y }
    end)

    return f
end

local function acquireRow(index, parent)
    local row = parent.rowPool[index]
    if not row then
        row = CreateFrame("Button", nil, parent)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("LEFT", parent, "LEFT", 0, 0)
        row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetPoint("RIGHT", -4, 0)

        -- Thin vertical divider between the name column and the stats
        -- columns, shown only for detail (dungeon) rows. Position is set
        -- per-refresh based on the monospace name column's actual pixel
        -- width via row.text:GetStringWidth(), so it stays correct even
        -- if NAME_COL_WIDTH is ever tuned.
        row.divider = row:CreateTexture(nil, "ARTWORK")
        row.divider:SetColorTexture(1, 1, 1, 0.15)
        row.divider:SetWidth(1)
        row.divider:SetPoint("TOP", row, "TOP", 0, 0)
        row.divider:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
        row.divider:Hide()

        parent.rowPool[index] = row
    end
    row:Show()
    return row
end

-- Renders the full window content from current SavedVariables state.
-- Called after any data mutation (local event, sync merge) and on toggle.
function MMD.UI_Refresh()
    if not frame or not frame:IsShown() then return end

    local content = frame.content
    content:SetWidth(frame.scrollFrame:GetWidth()) -- keep in sync in case the scroll area's width ever changes
    local yOffset = 0
    local rowIndex = 0

    for _, charKey in ipairs(getSortedCharacterKeys()) do
        local record = MMD.gdb and MMD.gdb.characters[charKey]
        rowIndex = rowIndex + 1
        local headerRow = acquireRow(rowIndex, content)
        headerRow:ClearAllPoints()
        headerRow:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOffset)
        headerRow:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -yOffset)
        headerRow.text:SetFontObject(GameFontHighlightSmall) -- rows are pooled/reused, so always reset explicitly rather than assuming prior state
        headerRow.divider:Hide()

        local arrow = expandedState[charKey] and "v " or "> "

        if isInactive(record) and not record.excused then
            local days = math.floor((GetServerTime() - record.lastUpdated) / 86400)
            headerRow.text:SetText(string.format("%s%s: |cffff5555Recommend removal for inactivity|r - %dd", arrow, charKey, days))
        else
            headerRow.text:SetText(string.format("%s%s: %s", arrow, charKey, formatCurrentKeyLine(record)))
        end

        headerRow:SetScript("OnClick", function()
            expandedState[charKey] = not expandedState[charKey]
            MMD.UI_Refresh()
        end)

        yOffset = yOffset + ROW_HEIGHT

        if expandedState[charKey] then
            for _, dungeon in ipairs(getSortedDungeonList()) do
                rowIndex = rowIndex + 1
                local detailRow = acquireRow(rowIndex, content)
                detailRow:ClearAllPoints()
                detailRow:SetPoint("TOPLEFT", content, "TOPLEFT", 16, -yOffset)
                detailRow:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -yOffset)
                detailRow:SetScript("OnClick", nil)
                detailRow.text:SetFontObject(MMD_MONO_FONT)

                local nameCol = string.format("%-" .. NAME_COL_WIDTH .. "s", dungeon.name .. ":")

                -- Measure the name column alone (in the same monospace
                -- font it will actually render in) to place the divider
                -- exactly where that column ends, then overwrite with
                -- the real full line.
                detailRow.text:SetText(nameCol)
                local dividerX = 4 + detailRow.text:GetStringWidth() + 3
                detailRow.divider:ClearAllPoints()
                detailRow.divider:SetPoint("TOP", detailRow, "TOP", 0, 0)
                detailRow.divider:SetPoint("BOTTOM", detailRow, "BOTTOM", 0, 0)
                detailRow.divider:SetPoint("LEFT", detailRow, "LEFT", dividerX, 0)
                detailRow.divider:Show()

                detailRow.text:SetText(nameCol .. formatDungeonStats(record, dungeon.mapID))
                yOffset = yOffset + ROW_HEIGHT
            end
        end
    end

    -- Hide any pooled rows beyond what's needed this refresh.
    for i = rowIndex + 1, #content.rowPool do
        content.rowPool[i]:Hide()
    end

    content:SetHeight(math.max(yOffset, 1))
end

function MMD.UI_Toggle()
    if not frame then
        frame = createFrame()

        local pos = MMD.db.windowPos
        if pos then
            frame:ClearAllPoints()
            frame:SetPoint(pos.point or "TOPRIGHT", UIParent, pos.relPoint or "TOPRIGHT", pos.x or 0, pos.y or 0)
        end
    end

    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        -- Only fires if the user opens the window before Blizzard's dungeon
        -- data has landed. CHALLENGE_MODE_MAPS_UPDATE will populate it
        -- automatically; this just explains the empty window rather than
        -- leaving them wondering if the addon is broken.
        if MMD.gdb and not next(MMD.gdb.dungeons) then
            print("|cff33ff99MMD|r: dungeon data is still loading from Blizzard's servers — the window will populate automatically. This is normal on a fresh login.")
        end
        MMD.UI_Refresh()
    end
end
