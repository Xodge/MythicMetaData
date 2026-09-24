-- Checksum.lua
--
-- Deliberately NOT Blizzard's C_EncodingUtil.CRC32 (unconfirmed availability
-- in this patch, and no telling if Blizzard keeps it around). A simple
-- rolling hash is all this needs: it only has to reliably change when the
-- data changes, it doesn't need to be cryptographically strong.
--
-- Threat model (see design discussion): this catches fat-fingered manual
-- edits to the SavedVariables file, not a deliberate forger who reads this
-- function and computes a matching hash by hand. That's an accepted,
-- explicit non-goal.

local ADDON_NAME, MMD = ...

-- Hashes only the SUBSTANTIVE fields of a character record: currentKey,
-- excused, and the dungeons table. Deliberately excludes lastUpdated and
-- checksum itself, so that recomputing a record's own checksum and
-- comparing it to the stored value is a valid tamper check (see
-- Checksum_Verify below), and so a pure timestamp bump never counts as
-- a "difference" on its own.
local function hashString(str)
    -- Simple, dependency-free rolling hash (djb2-style). Good enough to
    -- reliably detect a changed value; not intended to resist deliberate
    -- collision-seeking.
    local hash = 5381
    for i = 1, #str do
        hash = ((hash * 33) + str:byte(i)) % 4294967296 -- keep it in 32-bit range
    end
    return hash
end

local function serializeForHash(record)
    local parts = {}

    local ck = record.currentKey
    if ck then
        -- startedAt deliberately excluded: it's a display-only timestamp
        -- that would otherwise make two nodes with the same logical
        -- state (e.g. after independent reload-time estimation) hash
        -- differently and perpetually re-broadcast for no real reason.
        table.insert(parts, string.format("K:%s:%s:%s:%s", tostring(ck.mapID), tostring(ck.level), tostring(ck.inProgress), tostring(ck.mayNotBeOwnKey == true)))
    else
        table.insert(parts, "K:none")
    end

    table.insert(parts, "E:" .. tostring(record.excused == true))

    -- Sort dungeon keys so the hash is stable regardless of table iteration order.
    local mapIDs = {}
    for mapID in pairs(record.dungeons or {}) do
        table.insert(mapIDs, mapID)
    end
    table.sort(mapIDs)

    for _, mapID in ipairs(mapIDs) do
        local d = record.dungeons[mapID]
        table.insert(parts, string.format("D%s:%s:%s:%s",
            tostring(mapID),
            tostring(d.completed or ""),
            tostring(d.depleted or ""),
            tostring(d.abandoned == true)))
    end

    return table.concat(parts, "|")
end

-- Computes the checksum a record SHOULD have, based on its current fields.
function MMD.Checksum_Compute(record)
    return hashString(serializeForHash(record))
end

-- "Bad Record Found" check: does the record's stored checksum match what
-- its current fields actually hash to? A mismatch means the data was
-- edited without going through addon code (or the record is corrupt).
-- Returns true if the record is internally consistent.
function MMD.Checksum_Verify(record)
    if record.checksum == nil then
        return false
    end
    return record.checksum == MMD.Checksum_Compute(record)
end

-- Call this any time a record's substantive fields change, before storing
-- or broadcasting it, so checksum and data never drift apart under normal
-- addon operation.
function MMD.Checksum_Stamp(record)
    record.checksum = MMD.Checksum_Compute(record)
end
