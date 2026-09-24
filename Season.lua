-- Season.lua
-- Season-change detection (authoritative signal: C_MythicPlus.GetCurrentSeason(),
-- not the reset-to-zero heuristic) and archive-on-confirm flow, gated to
-- officers.

local ADDON_NAME, MMD = ...

StaticPopupDialogs["MMD_ARCHIVE_SEASON"] = {
    text = "Mythic Meta Data: a new Mythic+ season has been detected.\n\nArchive last season's data before starting fresh?",
    button1 = "Archive",
    button2 = "Not now",
    OnAccept = function(self, seasonID)
        MMD.Season_DoArchive(seasonID)
    end,
    OnCancel = function()
        -- Deliberately does nothing further: re-prompts on next login
        -- (Season_CheckForChange runs again then) rather than nagging
        -- mid-session, per spec.
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Call once on login. If the season ID differs from what's stored and the
-- player is an officer, prompts to archive. Non-officers see a passive
-- notice only -- they can't action it, so a modal dialog would just be a
-- dead end for them.
function MMD.Season_CheckForChange()
    if not MMD.IsFullyLoaded() then
        return -- don't offer to archive off a partially-loaded addon; SelfCheck already told them why
    end
    if not MMD.gdb then return end
    if not (C_MythicPlus and C_MythicPlus.GetCurrentSeason) then
        return
    end
    local currentSeasonID = C_MythicPlus.GetCurrentSeason()
    if currentSeasonID == nil then
        return -- not ready yet this session; caller may retry later
    end

    local storedSeasonID = MMD.gdb.currentSeasonID
    if storedSeasonID == nil then
        -- First run ever -- just record it, nothing to archive.
        MMD.gdb.currentSeasonID = currentSeasonID
        return
    end

    if currentSeasonID ~= storedSeasonID then
        if MMD.Officer_IsOfficer() then
            StaticPopup_Show("MMD_ARCHIVE_SEASON", nil, nil, storedSeasonID)
        else
            print("|cff33ff99MMD|r: new Mythic+ season detected. Awaiting an officer to archive last season's data (/mmd archive).")
        end
    end
end

-- Manual escape hatch: /mmd archive. Same officer gate, same effect,
-- for whenever someone wants to trigger it without waiting on the
-- auto-detected prompt (or dismissed it and changed their mind).
function MMD.Season_ManualArchive()
    if not MMD.IsFullyLoaded() then
        print("|cffff5555MMD|r: addon did not load cleanly this session -- not archiving until that's resolved.")
        return
    end
    if not MMD.Officer_IsOfficer() then
        print("|cff33ff99MMD|r: officer status required to archive a season.")
        return
    end
    if not MMD.gdb then
        print("|cff33ff99MMD|r: not currently in a guild.")
        return
    end
    local oldSeasonID = MMD.gdb.currentSeasonID
    if oldSeasonID == nil then
        print("|cff33ff99MMD|r: no prior season on record to archive.")
        return
    end
    MMD.Season_DoArchive(oldSeasonID)
end

-- Moves the live `characters` table into archives[oldSeasonID], tagged
-- with the dungeon list that was active for that season (frozen at
-- archive time -- next season's derived list will differ), then
-- reinitializes the live table empty against the new season/rotation.
-- Nothing is ever deleted.
function MMD.Season_DoArchive(oldSeasonID)
    local gdb = MMD.gdb
    if not gdb then return end

    gdb.archives[oldSeasonID] = {
        archivedAt = GetServerTime(),
        dungeonList = gdb.dungeons, -- shallow copy is fine; not mutated after archiving
        characters = gdb.characters,
    }

    gdb.characters = {}
    gdb.currentSeasonID = C_MythicPlus.GetCurrentSeason()
    MMD.Data_RequestMapInfo()
    MMD.Data_RefreshDungeonCache()

    print("|cff33ff99MMD|r: season " .. tostring(oldSeasonID) .. " archived. Tracking reset for the new season.")

    if MMD.UI_Refresh then MMD.UI_Refresh() end

    -- NOTE: this is treated as local SavedVariables housekeeping, not a
    -- synced data point -- each client independently detects and (if an
    -- officer) archives on its own next login, per the design decision
    -- to keep this out of the manifest/checksum pipeline.
end
