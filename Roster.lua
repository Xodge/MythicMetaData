-- Roster.lua
--
-- Purges live (current-season) records for characters who are no longer
-- in the guild, and gives Sync.lua a membership check so a purged
-- record can't be pulled straight back in from a guildmate who still
-- has a stale copy.
--
-- Source of truth is the guild roster itself (GetGuildRosterInfo), not
-- the "X has left the guild" system message: the roster also catches
-- kicks, departures that happened while this client was offline, and
-- anyone who left before this feature existed (e.g. Venefica).
--
-- FAIL-OPEN RULE: until a trustworthy roster has actually been read
-- this session, nobody is treated as a non-member and nothing is
-- purged. Missing information must never delete data. "Trustworthy"
-- means: we're in a guild, the roster has entries, and the player's own
-- character appears in it (guards against acting on an empty or
-- half-populated roster early in login).
--
-- Archives are deliberately NOT touched -- they're frozen history of a
-- past season, and that season's roster included this person.
--
-- NAME MATCHING: record keys are built from GetRealmName(), which keeps
-- spaces ("Gezia-Blood Furnace"); the guild roster returns the
-- normalized realm ("Gezia-BloodFurnace"). normalizeKey() strips spaces
-- and punctuation from the realm part on BOTH sides and lowercases, so
-- the two forms compare equal without changing how records are keyed
-- on disk (no schema change).

local ADDON_NAME, MMD = ...

local rosterSet = nil -- [normalizedKey] = true once a trustworthy roster is read; nil = unknown
local rebuildPending = false

local REBUILD_DELAY = 2 -- seconds; GUILD_ROSTER_UPDATE fires in bursts, collapse them into one pass

local function normalizeKey(charKey)
    if type(charKey) ~= "string" or charKey == "" then return nil end
    local name, realm = charKey:match("^([^%-]+)%-(.+)$")
    if not name then
        -- Bare name (no realm): same-realm member in some API returns.
        name = charKey
        realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or ""
    end
    local cleanRealm = realm:gsub("[%s%p]", "")
    return (name .. "-" .. cleanRealm):lower()
end

local function requestRoster()
    if not IsInGuild() then return end
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

-- Reads the full roster (offline members included) into rosterSet.
-- Returns true if the result is trustworthy enough to act on.
function MMD.Roster_Rebuild()
    rosterSet = nil
    if not IsInGuild() then return false end

    local numTotal = GetNumGuildMembers()
    if not numTotal or numTotal == 0 then return false end

    local set = {}
    for i = 1, numTotal do
        local fullName = GetGuildRosterInfo(i)
        local key = normalizeKey(fullName)
        if key then set[key] = true end
    end

    -- Our own character must be present, or this is a partial roster.
    if not set[normalizeKey(MMD.Data_GetMyKey())] then return false end

    rosterSet = set
    return true
end

-- Fail-open: returns true (treat as member) whenever the roster isn't known.
function MMD.Roster_IsMember(charKey)
    if not rosterSet then return true end
    return rosterSet[normalizeKey(charKey)] == true
end

-- Removes live records for anyone not on the current roster. Deletes
-- data, so it's gated on a clean load like the other write actions.
function MMD.Roster_Purge()
    if not MMD.IsFullyLoaded() then return end
    if not rosterSet then return end
    if not MMD.gdb then return end

    local purged = {}
    for charKey in pairs(MMD.gdb.characters) do
        if not rosterSet[normalizeKey(charKey)] then
            table.insert(purged, charKey)
        end
    end
    if #purged == 0 then return end

    table.sort(purged)
    for _, charKey in ipairs(purged) do
        MMD.gdb.characters[charKey] = nil
    end

    print("|cff33ff99MMD|r: removed " .. #purged .. " former guild member(s): " .. table.concat(purged, ", ") .. ".")
    if MMD.UI_Refresh then MMD.UI_Refresh() end
end

local function scheduleRebuild()
    if rebuildPending then return end
    rebuildPending = true
    C_Timer.After(REBUILD_DELAY, function()
        rebuildPending = false
        if MMD.Roster_Rebuild() then
            MMD.Roster_Purge()
        end
    end)
end

local rosterFrame = CreateFrame("Frame")
rosterFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
rosterFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
rosterFrame:RegisterEvent("PLAYER_GUILD_UPDATE")
rosterFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_ENTERING_WORLD" then
        -- Login/reload only; a plain zone change doesn't need a roster pull.
        if arg1 or arg2 then requestRoster() end
        return
    end
    -- GUILD_ROSTER_UPDATE (roster data arrived/changed -- joins, leaves,
    -- kicks) or PLAYER_GUILD_UPDATE (our own guild status changed).
    if event == "PLAYER_GUILD_UPDATE" then
        -- Re-point MMD.gdb at whichever guild (if any) we now belong to
        -- before the roster rebuild runs against it.
        if MMD.InitGuildDB then MMD.InitGuildDB() end
    end
    scheduleRebuild()
end)
