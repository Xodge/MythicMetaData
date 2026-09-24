-- Sync.lua
--
-- Two-phase exchange over GUILD addon-message traffic:
--   1. Manifest: {name, checksum, lastUpdated} per character -- cheap,
--      sent/received in bulk.
--   2. Targeted fetch/push: only for characters where the manifest
--      compare actually found a difference worth reconciling.
--
-- NOTE on scale: individual messages here are small enough (one
-- character's record is ~16 numbers/booleans) to not need chunking at
-- the 2-person scale this was designed for. If this grows to a full
-- guild roster, swap the raw SendAddonMessage calls below for
-- AceComm-3.0 (sits on ChatThrottleLib, handles chunking/throttling
-- automatically) rather than hand-rolling chunking here.

local ADDON_NAME, MMD = ...

local COMM = {
    MANIFEST_REQ = "MREQ",
    MANIFEST_RESP = "MRSP",
    RECORD_REQ = "RREQ",
    RECORD_RESP = "RRSP",
}

-- ---------------------------------------------------------------------
-- Addon version -- embedded in the manifest handshake messages' envelope
-- (see VERSIONED_MSG_TYPES below), not the per-record payload, so
-- version-mismatch detection rides on login/manual-sync traffic that
-- already happens rather than needing a dedicated message.
-- Read from the .toc's ## Version line via the metadata API, with a
-- fallback for the older global in case this patch's API surface has
-- moved (as several others turned out to have this session).
-- ---------------------------------------------------------------------

local function getAddonVersion()
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        return C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "0.0.0"
    elseif GetAddOnMetadata then
        return GetAddOnMetadata(ADDON_NAME, "Version") or "0.0.0"
    end
    return "0.0.0"
end

local MMD_VERSION = getAddonVersion()

-- Dot-separated numeric version compare: returns 1 if a>b, -1 if a<b,
-- 0 if equal. Numeric-component comparison (not string comparison) so
-- "0.10.0" correctly sorts after "0.9.0".
local function compareVersions(a, b)
    local function parts(v)
        local t = {}
        for n in v:gmatch("%d+") do table.insert(t, tonumber(n)) end
        return t
    end
    local aParts, bParts = parts(a), parts(b)
    for i = 1, math.max(#aParts, #bParts) do
        local av, bv = aParts[i] or 0, bParts[i] or 0
        if av > bv then return 1 end
        if av < bv then return -1 end
    end
    return 0
end

-- Announced at most once per (sender, version) pair per session, so a
-- chatty sync exchange doesn't spam the same notice on every message.
local announcedNewerVersions = {}

local function checkSenderVersion(senderName, senderVersion)
    if not senderVersion or senderVersion == "" then return end
    if compareVersions(senderVersion, MMD_VERSION) > 0 then
        local key = senderName .. ":" .. senderVersion
        if not announcedNewerVersions[key] then
            announcedNewerVersions[key] = true
            print(string.format(
                "|cffff9900MMD|r: there is a newer version of Mythic Meta Data (v%s, from %s) than yours (v%s). You may want to update.",
                senderVersion, senderName, MMD_VERSION))
        end
    end
end

-- ---------------------------------------------------------------------
-- Minimal hand-rolled serialization -- WoW's Lua sandbox has no builtin
-- JSON. Flat "key=value;key=value" pairs are sufficient for our record
-- shape (currentKey, excused, dungeons table) and avoid depending on
-- C_EncodingUtil's JSON/CBOR helpers, whose availability in this patch
-- hasn't been confirmed.
-- ---------------------------------------------------------------------

local function serializeRecord(charKey, record)
    local parts = { "NAME=" .. charKey, "TS=" .. tostring(record.lastUpdated), "CK=" .. tostring(record.checksum) }

    if record.currentKey then
        local ck = record.currentKey
        table.insert(parts, string.format("KEY=%s,%s,%s,%s,%s",
            tostring(ck.mapID), tostring(ck.level), tostring(ck.inProgress),
            tostring(ck.mayNotBeOwnKey == true), tostring(ck.startedAt or "")))
    end

    table.insert(parts, "EX=" .. tostring(record.excused == true))

    local dungeonParts = {}
    for mapID, d in pairs(record.dungeons or {}) do
        table.insert(dungeonParts, string.format("%s:%s:%s:%s",
            mapID, tostring(d.completed or ""), tostring(d.depleted or ""), tostring(d.abandoned == true)))
    end
    table.insert(parts, "DG=" .. table.concat(dungeonParts, ","))

    return table.concat(parts, ";")
end

local function deserializeRecord(payload)
    local fields = {}
    for kv in payload:gmatch("[^;]+") do
        local k, v = kv:match("^(%a+)=(.*)$")
        if k then fields[k] = v end
    end
    if not fields.NAME then return nil end

    local record = {
        lastUpdated = tonumber(fields.TS) or 0,
        checksum = tonumber(fields.CK) or fields.CK,
        excused = fields.EX == "true",
        dungeons = {},
    }

    if fields.KEY then
        local mapID, level, inProgress, mayNotBeOwnKey, startedAt =
            fields.KEY:match("^(%-?%d+),(%-?%d+),(%a+),(%a+),(%-?%d*)$")
        if mapID then
            record.currentKey = {
                mapID = tonumber(mapID),
                level = tonumber(level),
                inProgress = inProgress == "true",
                mayNotBeOwnKey = mayNotBeOwnKey == "true" or nil,
                startedAt = tonumber(startedAt),
            }
        end
    end

    if fields.DG and fields.DG ~= "" then
        for entry in fields.DG:gmatch("[^,]+") do
            local mapID, completed, depleted, abandoned = entry:match("^(%-?%d+):([^:]*):([^:]*):(%a+)$")
            if mapID then
                record.dungeons[tonumber(mapID)] = {
                    completed = tonumber(completed),
                    depleted = tonumber(depleted),
                    abandoned = abandoned == "true" or nil,
                }
            end
        end
    end

    return fields.NAME, record
end

-- ---------------------------------------------------------------------
-- Outgoing
-- ---------------------------------------------------------------------

-- Only the manifest handshake messages (login + /mmd sync -- the
-- natural "checking in with the group" moments) carry the real version
-- string. The much more frequent per-event RECORD_REQ/RECORD_RESP
-- broadcasts (every completed run, excuse toggle, the 60s checksum
-- tick) send an empty version field instead -- the version isn't going
-- to have changed between one gameplay event and the next, so
-- re-announcing it every time would be pure repetition for no benefit.
local VERSIONED_MSG_TYPES = { [COMM.MANIFEST_REQ] = true, [COMM.MANIFEST_RESP] = true }

-- Guild-membership gate (Roster.lua). Fails open: if Roster.lua didn't
-- load, or the roster isn't known yet this session, everyone counts as
-- a member. Once the roster IS known, records for departed members are
-- never advertised, pushed, served, or accepted -- so a guildmate still
-- holding a stale copy can't resurrect a purged record.
local function isMember(charKey)
    return not MMD.Roster_IsMember or MMD.Roster_IsMember(charKey)
end

local function send(msgType, payload)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        local versionField = VERSIONED_MSG_TYPES[msgType] and MMD_VERSION or ""
        C_ChatInfo.SendAddonMessage(MMD.PREFIX, msgType .. "|" .. versionField .. "|" .. payload, "GUILD")
    end
end

function MMD.Sync_RequestManifest()
    if not IsInGuild() then return end
    send(COMM.MANIFEST_REQ, "")
end

local function buildManifestPayload()
    if not MMD.gdb then return "" end
    local entries = {}
    for charKey, record in pairs(MMD.gdb.characters) do
        if isMember(charKey) then
            table.insert(entries, string.format("%s:%s:%s", charKey, tostring(record.checksum), tostring(record.lastUpdated)))
        end
    end
    return table.concat(entries, ",")
end

-- Broadcasts a single record immediately -- used right after a local
-- state change (e.g. Officer_TryExcuse, or a completed run) so other
-- online guildies don't have to wait for the next manifest round to
-- see it.
function MMD.Sync_BroadcastRecord(charKey, record)
    if not IsInGuild() then return end
    if not isMember(charKey) then return end
    send(COMM.RECORD_RESP, serializeRecord(charKey, record))
end

-- ---------------------------------------------------------------------
-- Merge logic: bad-record rejection, excused-difference notice,
-- timestamp-wins application.
-- ---------------------------------------------------------------------

local KNOWN_DUNGEON_CAP_LEVEL = 40 -- generous ceiling; anything beyond this is nonsense, not a real outlier

local function isSaneRecord(record)
    if type(record.excused) ~= "boolean" then return false end
    if record.lastUpdated > GetServerTime() + 300 then return false end -- >5min in the future = clock skew or garbage

    if record.currentKey then
        local ck = record.currentKey
        if type(ck.mapID) ~= "number" or type(ck.level) ~= "number" then return false end
        if ck.level < 0 or ck.level > KNOWN_DUNGEON_CAP_LEVEL then return false end
    end

    for mapID, d in pairs(record.dungeons or {}) do
        if type(mapID) ~= "number" then return false end
        if d.completed and (d.completed < 0 or d.completed > KNOWN_DUNGEON_CAP_LEVEL) then return false end
        if d.depleted then
            if d.depleted < 0 or d.depleted > KNOWN_DUNGEON_CAP_LEVEL then return false end
            -- Structurally invalid: depleted must never be <= completed.
            if d.depleted <= (d.completed or 0) then return false end
        end
    end

    return true
end

local function mergeIncomingRecord(charKey, incoming)
    -- Former guild member: silently drop (not "bad", just not ours to keep).
    if not isMember(charKey) then return end
    if not MMD.gdb then return end

    -- Bad Record Found: reject outright, don't merge any part of it.
    if not isSaneRecord(incoming) then
        print("|cff33ff99MMD|r: bad record found for '" .. charKey .. "' -- rejected.")
        return
    end

    local existing = MMD.gdb.characters[charKey]

    -- Difference Found: only meaningful when reconciling an EXISTING
    -- record's excused flag against a genuinely different incoming
    -- value -- not on first contact with a brand-new character.
    if existing and existing.excused ~= incoming.excused then
        print(string.format("|cff33ff99MMD|r: difference found -- %s's excused status changed to %s.",
            charKey, tostring(incoming.excused)))
    end

    -- Timestamp-wins, no provenance check, applied uniformly to every
    -- field including excused -- per the explicit design decision that
    -- excused is not a special case in the merge rule.
    if not existing or incoming.lastUpdated > existing.lastUpdated then
        MMD.gdb.characters[charKey] = incoming
        if MMD.UI_Refresh then MMD.UI_Refresh() end
    end
end

-- ---------------------------------------------------------------------
-- Incoming
-- ---------------------------------------------------------------------

local commFrame = CreateFrame("Frame")
commFrame:RegisterEvent("CHAT_MSG_ADDON")
commFrame:SetScript("OnEvent", function(_, _, prefix, message, channel, sender)
    if prefix ~= MMD.PREFIX then return end
    if sender == UnitName("player") then return end -- ignore our own broadcasts

    local msgType, senderVersion, payload = message:match("^(%a+)|([^|]*)|(.*)$")
    if not msgType then return end

    checkSenderVersion(sender, senderVersion)

    if msgType == COMM.MANIFEST_REQ then
        send(COMM.MANIFEST_RESP, buildManifestPayload())

    elseif msgType == COMM.MANIFEST_RESP then
        for entry in payload:gmatch("[^,]+") do
            local charKey, checksum, ts = entry:match("^([^:]+):([^:]+):([^:]+)$")
            if charKey and isMember(charKey) then
                checksum = tonumber(checksum) or checksum
                ts = tonumber(ts) or 0
                local existing = MMD.gdb.characters[charKey]

                if not existing or existing.checksum ~= checksum then
                    if not existing or ts > existing.lastUpdated then
                        -- Theirs is different and newer: ask for the full record.
                        send(COMM.RECORD_REQ, charKey)
                    elseif existing and existing.lastUpdated > ts then
                        -- Ours is newer: push it to them unprompted, don't wait to be asked.
                        MMD.Sync_BroadcastRecord(charKey, existing)
                    end
                end
            end
        end

    elseif msgType == COMM.RECORD_REQ then
        local charKey = payload
        local record = MMD.gdb and MMD.gdb.characters[charKey]
        if record and isMember(charKey) then
            send(COMM.RECORD_RESP, serializeRecord(charKey, record))
        end

    elseif msgType == COMM.RECORD_RESP then
        local charKey, record = deserializeRecord(payload)
        if charKey and record then
            mergeIncomingRecord(charKey, record)
        end
    end
end)
