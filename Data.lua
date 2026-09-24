-- Data.lua
-- Dungeon-list derivation from the live API (no hardcoded rotation list --
-- this is the whole point: it survives season rotations without an
-- addon update) and the record update rules discussed at length.

local ADDON_NAME, MMD = ...

-- ---------------------------------------------------------------------
-- Dungeon list: derived, not hardcoded.
-- ---------------------------------------------------------------------

-- C_MythicPlus.RequestMapInfo() populates the data GetMapTable() depends
-- on; it isn't guaranteed ready at the instant of login, so this is
-- called from OnLogin and again defensively before anything reads the
-- dungeon list, in case the request hadn't resolved yet.
function MMD.Data_RequestMapInfo()
    if C_MythicPlus and C_MythicPlus.RequestMapInfo then
        C_MythicPlus.RequestMapInfo()
    end
end

-- Returns { [mapID] = name } for the current season's rotation, sorted
-- name list also returned for convenience (alphabetical display order,
-- per spec).
function MMD.Data_GetDungeonList()
    local byID, sortedNames = {}, {}

    if not (C_ChallengeMode and C_ChallengeMode.GetMapTable) then
        return byID, sortedNames
    end

    local mapIDs = C_ChallengeMode.GetMapTable()
    for _, mapID in ipairs(mapIDs or {}) do
        local name = C_ChallengeMode.GetMapUIInfo(mapID)
        if name then
            byID[mapID] = name
        end
    end

    for mapID, name in pairs(byID) do
        table.insert(sortedNames, { mapID = mapID, name = name })
    end
    table.sort(sortedNames, function(a, b) return a.name < b.name end)

    return byID, sortedNames
end

-- Caches the derived list into SavedVariables so the UI has something to
-- render even before a fresh RequestMapInfo() round-trip completes.
function MMD.Data_RefreshDungeonCache()
    local byID = MMD.Data_GetDungeonList()
    if next(byID) and MMD.gdb then
        MMD.gdb.dungeons = byID
    end
end

-- ---------------------------------------------------------------------
-- Bag scanning for the physical Keystone item.
--
-- CONFIRMED live in-game: Midnight reverted Mythic+ keystones to
-- physical bag items (the pre-virtual-keystone system). The older
-- C_MythicPlus.GetOwnedKeystone*() family was built for the virtual
-- system used in the interim expansions and is unreliable/stale now
-- that keystones are bag items again -- this is what caused the
-- persistent "Current Key" bugs earlier in development. Scanning bags
-- directly and parsing the item link's bracketed display text is the
-- actual source of truth.
--
-- Confirmed link format via live /run output: the hyperlink's bracketed
-- text reads "Keystone: <Dungeon Name> (<Level>)" -- e.g.
-- "[Keystone: Voidscar Arena (13)]" -- giving both dungeon name and
-- level directly with no tooltip scan required.
-- ---------------------------------------------------------------------

-- Reverse lookup against the already-cached dungeon list (MMD.db.dungeons
-- is { [mapID] = name }) since the keystone link gives us a name, not a
-- mapID directly.
function MMD.Data_GetMapIDByName(name)
    for mapID, dungeonName in pairs(MMD.gdb and MMD.gdb.dungeons or {}) do
        if dungeonName == name then
            return mapID
        end
    end
    return nil
end

-- Scans all bags for a Keystone item. Returns mapID, level, bag, slot on
-- a match, or nil if no keystone is currently held. mapID can come back
-- nil even when a keystone IS found if MMD.db.dungeons hasn't been
-- populated yet this session (e.g. very early at login, before
-- RequestMapInfo's round-trip lands) -- callers should treat that as
-- "try again shortly" rather than "no keystone," and the periodic
-- ticker already re-scans within a minute regardless.
function MMD.Data_ScanBagsForKeystone()
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then
        return nil
    end
    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink then
                local bracketText = info.hyperlink:match("%[(.-)%]")
                if bracketText then
                    local dungeonName, levelStr = bracketText:match("^Keystone: (.+) %((%d+)%)$")
                    if dungeonName then
                        return MMD.Data_GetMapIDByName(dungeonName), tonumber(levelStr), bag, slot
                    end
                end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Character records
-- ---------------------------------------------------------------------

function MMD.Data_GetMyKey()
    local name = UnitName("player") .. "-" .. GetRealmName()
    return name
end

function MMD.Data_GetOrCreateRecord(charKey)
    local gdb = MMD.gdb
    if not gdb then return nil end
    gdb.characters[charKey] = gdb.characters[charKey] or {
        lastUpdated = 0,
        checksum = nil,
        currentKey = nil,
        excused = false,
        dungeons = {},
    }
    return gdb.characters[charKey]
end

-- Applies a completed run. onTime distinguishes an in-time finish (raises
-- `completed`) from an over-time finish (candidate for `depleted`, subject
-- to the "only if strictly higher than completed" rule).
function MMD.Data_ApplyCompletion(record, mapID, level, onTime)
    record.dungeons[mapID] = record.dungeons[mapID] or {}
    local d = record.dungeons[mapID]

    if onTime then
        d.completed = math.max(d.completed or 0, level)
    else
        -- Over-time finish is a depleted candidate, not automatically kept.
        d.depleted = math.max(d.depleted or 0, level)
    end

    -- Any real completion data supersedes an "abandoned" placeholder.
    d.abandoned = nil

    MMD.Data_ReconcileDungeonEntry(record, mapID)
end

-- The rule, restated exactly as specified: depleted is stored ONLY if it
-- is strictly greater than completed for that same dungeon. Must be
-- re-run any time either value changes, since a later `completed` bump
-- can retroactively invalidate a previously-valid `depleted`.
function MMD.Data_ReconcileDungeonEntry(record, mapID)
    local d = record.dungeons[mapID]
    if not d then return end

    local completed = d.completed or 0
    if d.depleted and d.depleted <= completed then
        d.depleted = nil
    end

    -- If there's genuinely nothing here, drop the entry entirely so it
    -- renders as "never attempted" rather than a hollow table.
    if not d.completed and not d.depleted and not d.abandoned then
        record.dungeons[mapID] = nil
    end
end

-- Marks a dungeon as abandoned ONLY if there is no completed/depleted
-- data for it yet -- once real data exists, "abandoned" is not relevant
-- (per spec: "Once a run is done, abandoned is no longer relevant").
function MMD.Data_MarkAbandoned(record, mapID)
    local d = record.dungeons[mapID]
    if d and (d.completed or d.depleted) then
        return -- real data already exists; do not overwrite with abandoned
    end
    record.dungeons[mapID] = record.dungeons[mapID] or {}
    record.dungeons[mapID].abandoned = true
end

-- Seeds both `completed` and `depleted` from Blizzard's own season-best
-- records. Call once per dungeon, typically first login after install or
-- after a season change.
--
-- CONFIRMED (via live error dump): GetSeasonBestForMap returns TWO
-- structured tables, not a plain number -- intimeInfo (the in-time best)
-- and overtimeInfo (the best over-time/depleted finish), each shaped
-- { durationSec, level, completionDate, affixIDs, members }. overtimeInfo
-- is a genuine gift here: it's Blizzard's own record of exactly the
-- "depleted candidate" concept this addon already tracks, so both
-- seed directly into the existing fields and the normal reconcile rule
-- (keep depleted only if > completed) still governs which survives.
function MMD.Data_SeedFromSeasonBest(record, mapID)
    if not (C_MythicPlus and C_MythicPlus.GetSeasonBestForMap) then
        return
    end
    local intimeInfo, overtimeInfo = C_MythicPlus.GetSeasonBestForMap(mapID)

    if intimeInfo and intimeInfo.level then
        record.dungeons[mapID] = record.dungeons[mapID] or {}
        record.dungeons[mapID].completed = math.max(record.dungeons[mapID].completed or 0, intimeInfo.level)
    end

    if overtimeInfo and overtimeInfo.level then
        record.dungeons[mapID] = record.dungeons[mapID] or {}
        record.dungeons[mapID].depleted = math.max(record.dungeons[mapID].depleted or 0, overtimeInfo.level)
    end

    if record.dungeons[mapID] then
        MMD.Data_ReconcileDungeonEntry(record, mapID)
    end
end

-- Finalizes a record after any mutation: stamp lastUpdated + checksum.
-- Every write path (Events.lua, Sync.lua merge) should end by calling this.
function MMD.Data_Finalize(record)
    record.lastUpdated = GetServerTime()
    MMD.Checksum_Stamp(record)
end
