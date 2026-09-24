-- Core.lua
-- Addon-wide namespace, SavedVariables bootstrap, and slash command dispatch.

local ADDON_NAME, MMD = ...
_G.MMD = MMD -- convenient global for debugging via /run; not relied on internally

MMD.PREFIX = "MMD1" -- addon message prefix; bump this if you ever ship a
                     -- wire-format-breaking change so old/new clients don't
                     -- try to parse each other's messages.

-- ---------------------------------------------------------------------
-- SavedVariables shape (account-wide, NOT per-character, per design:
-- the window needs to open in the same spot and show the same roster
-- data regardless of which of Louis's own toons is logged in).
--
-- MythicMetaDataDB = {
--   schemaVersion = <number>,
--   config = {
--     inactiveDays = 30,
--   },
--   windowPos = { point, relTo, relPoint, x, y } or nil,
--   guilds = {
--     ["GuildName-Realm"] = {
--       currentSeasonID = <number> or nil,
--       dungeons = { [mapID] = true, ... },   -- cached derived rotation list
--       characters = {
--         ["Name-Realm"] = {
--           lastUpdated = <epoch>,
--           checksum = <string/number>,
--           currentKey = { mapID=, level=, inProgress=, startedAt= } or nil,
--           excused = true/false,
--           dungeons = {
--             [mapID] = { completed = n, depleted = n, abandoned = true/nil },
--           },
--         },
--       },
--       archives = {
--         [seasonID] = {
--           archivedAt = <epoch>,
--           dungeonList = { mapID, ... },
--           characters = { ... same shape as above ... },
--         },
--       },
--     },
--     ["OtherGuild-Realm"] = { ... },  -- Loutevier's guild, a second alt's
--   },                                  -- guild, etc. all coexist here
-- }
--
-- MMD.db  = the full MythicMetaDataDB (all guilds, config, windowPos)
-- MMD.gdb = MMD.db.guilds[currentGuildKey] -- shortcut to the active
--           guild's sub-table, set by InitGuildDB() on login and on any
--           guild change. Nil when not in a guild.
--
-- Having everything in one file (rather than one file per guild) means
-- a future cross-guild "who holds a key for X" search is just an
-- iteration over MMD.db.guilds.
--
-- schemaVersion is SEPARATE from the .toc's ## Version. ## Version
-- identifies which CODE you're running; schemaVersion identifies what
-- SHAPE the saved DATA on disk is in. They change independently.
-- schemaVersion only needs to move when a field is added/renamed/
-- restructured in a way that OLD saved data wouldn't already satisfy.
-- ---------------------------------------------------------------------

local CURRENT_SCHEMA_VERSION = 2

-- MIGRATIONS[N] upgrades saved data from schema version N to N+1,
-- mutating db in place. Applied in order from whatever version was
-- found on disk up to CURRENT_SCHEMA_VERSION.
local MIGRATIONS = {
    -- v1 → v2: wrap the old flat top-level fields (characters, dungeons,
    -- currentSeasonID, archives) into the new per-guild guilds[] table.
    [1] = function(db)
        db.guilds = db.guilds or {}

        -- Best-effort: identify the guild this data belongs to.
        -- GetGuildInfo usually works at ADDON_LOADED time. If it doesn't
        -- (rare edge case on first-ever login), data lands under "Legacy"
        -- and InitGuildDB() will fold it into the real key later.
        local guildName = GetGuildInfo("player")
        local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or "Unknown"
        local cleanRealm = realm:gsub("[%s%p]", "")
        local guildKey = guildName and (guildName .. "-" .. cleanRealm) or "Legacy"

        db.guilds[guildKey] = {
            currentSeasonID = db.currentSeasonID,
            dungeons   = db.dungeons   or {},
            characters = db.characters or {},
            archives   = db.archives   or {},
        }

        db.currentSeasonID = nil
        db.dungeons        = nil
        db.characters      = nil
        db.archives        = nil
    end,
}

local DEFAULTS = {
    schemaVersion = CURRENT_SCHEMA_VERSION,
    config = { inactiveDays = 30 },
    windowPos = nil,
    guilds = {},
}

-- Per-guild sub-table defaults, applied by InitGuildDB on first access.
-- Kept separate from DEFAULTS because the key isn't known until login.
local GUILD_DEFAULTS = {
    currentSeasonID = nil,
    dungeons   = {},
    characters = {},
    archives   = {},
}

local function applyDefaults(db, defaults)
    for k, v in pairs(defaults) do
        if db[k] == nil then
            if type(v) == "table" then
                db[k] = {}
                applyDefaults(db[k], v)
            else
                db[k] = v
            end
        elseif type(v) == "table" and type(db[k]) == "table" then
            applyDefaults(db[k], v)
        end
    end
end

local function runMigrations(db)
    local fromVersion = db.schemaVersion or 0

    if fromVersion > CURRENT_SCHEMA_VERSION then
        print(string.format(
            "|cffff9900MMD|r: saved data is in a newer format (v%d) than this addon version supports (v%d). Update the addon before this data is fully usable.",
            fromVersion, CURRENT_SCHEMA_VERSION))
        return
    end

    for v = fromVersion, CURRENT_SCHEMA_VERSION - 1 do
        local migrate = MIGRATIONS[v]
        if migrate then
            local ok, err = pcall(migrate, db)
            if not ok then
                print(string.format("|cffff5555MMD|r: migration from schema v%d failed: %s -- data left at v%d.", v, tostring(err), v))
                return
            end
        end
    end

    db.schemaVersion = CURRENT_SCHEMA_VERSION
end

-- ---------------------------------------------------------------------
-- Per-guild sub-table management
-- ---------------------------------------------------------------------

-- Sets MMD.gdb to the current guild's sub-table, creating it on first
-- access. Sets MMD.gdb = nil if not in a guild or guild info isn't
-- available yet (callers treat nil as "not applicable, do nothing").
-- Absorbs any "Legacy" entry left by a migration that ran before
-- GetGuildInfo was ready.
-- Called at ADDON_LOADED, OnLogin, and on PLAYER_GUILD_UPDATE.
function MMD.InitGuildDB()
    local guildName = GetGuildInfo("player")
    if not guildName then
        MMD.gdb = nil
        MMD.currentGuildKey = nil
        return
    end

    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or "Unknown"
    local cleanRealm = realm:gsub("[%s%p]", "")
    local guildKey = guildName .. "-" .. cleanRealm

    -- Fold any "Legacy" migration data into the real key on first contact.
    if MMD.db.guilds["Legacy"] and not MMD.db.guilds[guildKey] then
        MMD.db.guilds[guildKey] = MMD.db.guilds["Legacy"]
        MMD.db.guilds["Legacy"] = nil
    end

    MMD.db.guilds[guildKey] = MMD.db.guilds[guildKey] or {}
    local gdb = MMD.db.guilds[guildKey]

    for k, v in pairs(GUILD_DEFAULTS) do
        if gdb[k] == nil then
            if type(v) == "table" then gdb[k] = {} else gdb[k] = v end
        end
    end

    MMD.gdb = gdb
    MMD.currentGuildKey = guildKey
end

-- Known top-level keys in MythicMetaDataDB. Anything else is an orphan
-- from a prior version and gets pruned automatically on load.
local KNOWN_TOP_LEVEL_KEYS = {
    schemaVersion = true,
    config        = true,
    windowPos     = true,
    guilds        = true,
}

local function pruneOrphanedKeys(db)
    local pruned = {}
    for k in pairs(db) do
        if not KNOWN_TOP_LEVEL_KEYS[k] then
            table.insert(pruned, k)
        end
    end
    for _, k in ipairs(pruned) do
        db[k] = nil
    end
end

-- ---------------------------------------------------------------------
-- Loader
-- ---------------------------------------------------------------------

local loaderFrame = CreateFrame("Frame")
loaderFrame:RegisterEvent("ADDON_LOADED")
loaderFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
loaderFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        MythicMetaDataDB = MythicMetaDataDB or {}
        applyDefaults(MythicMetaDataDB, DEFAULTS)
        MMD.db = MythicMetaDataDB
        runMigrations(MMD.db)
        pruneOrphanedKeys(MMD.db)

        -- Best-effort early init; may be nil if GetGuildInfo isn't ready
        -- yet. OnLogin re-runs this with a reliable result.
        MMD.InitGuildDB()

        MMD.SelfCheck()

    elseif event == "PLAYER_ENTERING_WORLD" then
        local isLogin, isReload = arg1, arg2
        if (isLogin or isReload) and MMD.OnLogin and not MMD.hasRunOnLogin then
            MMD.hasRunOnLogin = true
            MMD.OnLogin()
        end
    end
end)

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------

local EXPECTED_FUNCTIONS = {
    ["Checksum.lua"] = { "Checksum_Compute", "Checksum_Verify", "Checksum_Stamp" },
    ["Data.lua"] = { "Data_RequestMapInfo", "Data_GetDungeonList", "Data_RefreshDungeonCache",
                      "Data_GetMyKey", "Data_GetOrCreateRecord", "Data_ApplyCompletion",
                      "Data_ReconcileDungeonEntry", "Data_MarkAbandoned", "Data_SeedFromSeasonBest", "Data_Finalize",
                      "Data_GetMapIDByName", "Data_ScanBagsForKeystone" },
    ["Officer.lua"] = { "Officer_IsOfficer", "Officer_TryExcuse", "Officer_DumpOfficerCheck" },
    ["Roster.lua"]  = { "Roster_Rebuild", "Roster_IsMember", "Roster_Purge" },
    ["Season.lua"] = { "Season_CheckForChange", "Season_ManualArchive", "Season_DoArchive" },
    ["Sync.lua"] = { "Sync_RequestManifest", "Sync_BroadcastRecord" },
    ["UI.lua"] = { "UI_Refresh", "UI_Toggle" },
}

function MMD.SelfCheck()
    local missingFiles = {}
    for fileName, functionNames in pairs(EXPECTED_FUNCTIONS) do
        for _, fnName in ipairs(functionNames) do
            if MMD[fnName] == nil then
                missingFiles[fileName] = true
                break
            end
        end
    end

    if next(missingFiles) then
        MMD.loadOK = false
        local names = {}
        for fileName in pairs(missingFiles) do table.insert(names, fileName) end
        table.sort(names)
        print("|cffff5555MMD|r: the following file(s) did not load correctly: " ..
            table.concat(names, ", ") ..
            ". Re-check your AddOns/MythicMetaData folder -- these files should be directly inside it, not nested, and none should be missing or duplicated.")
    else
        MMD.loadOK = true
    end
end

function MMD.IsFullyLoaded()
    return MMD.loadOK == true
end

-- ---------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------

SLASH_MYTHICMETADATA1 = "/mmd"
SlashCmdList["MYTHICMETADATA"] = function(msg)
    local args = {}
    for word in msg:gmatch("%S+") do
        table.insert(args, word)
    end
    local cmd = (args[1] or ""):lower()

    if cmd == "show" or cmd == "" then
        MMD.UI_Toggle()
    elseif cmd == "inactivedays" then
        local n = tonumber(args[2])
        if n and n > 0 then
            MMD.db.config.inactiveDays = n
            print("|cff33ff99MMD|r: inactivity threshold set to " .. n .. " days.")
        else
            print("|cff33ff99MMD|r: usage /mmd inactivedays <number>")
        end
    elseif cmd == "excuse" then
        MMD.Officer_TryExcuse(args[2], true)
    elseif cmd == "unexcuse" then
        MMD.Officer_TryExcuse(args[2], false)
    elseif cmd == "archive" then
        MMD.Season_ManualArchive()
    elseif cmd == "sync" then
        MMD.Sync_RequestManifest()
    elseif cmd == "dumpofficer" then
        if MMD.Officer_DumpOfficerCheck then MMD.Officer_DumpOfficerCheck() end
    else
        local commands = { "show", "sync", "inactivedays <n>" }
        if MMD.Officer_IsOfficer and MMD.Officer_IsOfficer() then
            table.insert(commands, "excuse <name>")
            table.insert(commands, "unexcuse <name>")
            table.insert(commands, "archive")
        end
        print("|cff33ff99MMD|r commands: " .. table.concat(commands, ", "))
    end
end
