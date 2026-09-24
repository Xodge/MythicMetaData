-- Officer.lua
--
-- CONFIRMED live (via /mmd dumpofficer): C_GuildInfo.IsGuildOfficer()
-- called with no arguments returns the current player's officer status
-- directly -- true for a GM, no priming, no Guild-window setup step, no
-- per-rank data to cache or sync. This replaced two earlier approaches
-- that both turned out to be dead ends in the current client:
--   1. The old global GuildControlSetRank/GuildControlGetRankFlags API
--      and GUILDCONTROL_UPDATE event -- removed entirely.
--   2. Their C_GuildInfo-namespaced successor,
--      GuildControlGetRankFlags(rankOrder) -- callable without error,
--      but returns an empty permissions table even for a GM, consistent
--      with reports that granular rank-permission data has been walled
--      off from addons in this patch (the same pattern seen elsewhere,
--      e.g. combat log and guild notes).
-- IsGuildOfficer(), being a plain boolean rather than a data table,
-- isn't subject to that restriction and is the right tool here.

local ADDON_NAME, MMD = ...

-- The actual permission check used to gate /mmd excuse, /mmd unexcuse,
-- and season archiving. No caching, no sync, no setup step needed --
-- every client can just ask this directly, live, every time.
function MMD.Officer_IsOfficer()
    if not IsInGuild() then
        return false
    end
    if not (C_GuildInfo and C_GuildInfo.IsGuildOfficer) then
        return false
    end
    local ok, result = pcall(C_GuildInfo.IsGuildOfficer)
    return ok and result == true
end

-- Diagnostic only -- kept in case IsGuildOfficer's behavior ever needs
-- re-verifying (e.g. testing from a non-officer alt to confirm it
-- correctly returns false, not just true for a GM).
function MMD.Officer_DumpOfficerCheck()
    if not (C_GuildInfo and C_GuildInfo.IsGuildOfficer) then
        print("|cff33ff99MMD|r: C_GuildInfo.IsGuildOfficer not available.")
        return
    end
    local ok, result = pcall(C_GuildInfo.IsGuildOfficer)
    print(string.format("|cff33ff99MMD|r IsGuildOfficer(): ok=%s result=%s", tostring(ok), tostring(result)))
end

-- Shared entry point for /mmd excuse and /mmd unexcuse. `value` is
-- true to excuse, false to clear.
function MMD.Officer_TryExcuse(nameArg, value)
    if not MMD.IsFullyLoaded() then
        print("|cffff5555MMD|r: addon did not load cleanly this session -- not running officer actions until that's resolved. (/reload after fixing, or check for a self-check message from login.)")
        return
    end
    if not MMD.Officer_IsOfficer() then
        print("|cff33ff99MMD|r: officer status required for this command.")
        return
    end
    if not nameArg or nameArg == "" then
        print("|cff33ff99MMD|r: usage /mmd excuse <name> (or /mmd unexcuse <name>)")
        return
    end

    if not MMD.gdb then
        print("|cff33ff99MMD|r: not currently in a guild.")
        return
    end
    local record = MMD.gdb.characters[nameArg]
    if not record then
        print("|cff33ff99MMD|r: no cached record for '" .. nameArg .. "' yet.")
        return
    end

    record.excused = value
    MMD.Data_Finalize(record)
    print("|cff33ff99MMD|r: " .. nameArg .. (value and " marked excused." or " excuse cleared."))

    if MMD.UI_Refresh then MMD.UI_Refresh() end
    if MMD.Sync_BroadcastRecord then MMD.Sync_BroadcastRecord(nameArg, record) end
end
