-- Events.lua
-- Login orchestration plus the state machine for key tracking:
--   CHALLENGE_MODE_START      -> mark in-progress, snapshot key
--   CHALLENGE_MODE_COMPLETED  -> resolve in-progress, update completed/depleted
--                                (this event carries NO payload -- details
--                                come from C_ChallengeMode.GetChallengeCompletionInfo(),
--                                which returns a single table; the old positional
--                                GetCompletionInfo() was removed in TWW)
--   PLAYER_ENTERING_WORLD     -> if still in-progress and now outside any
--                                instance, that's the walkout/abandon case
--                                (confirmed: CHALLENGE_MODE_COMPLETED never
--                                fires on a walkout, only on an actual
--                                boss-kill finish, in-time or not).
--
-- HELD-KEY DETECTION, CONFIRMED VIA LIVE TESTING: Midnight reverted
-- Mythic+ keystones to physical bag items. The C_MythicPlus
-- GetOwnedKeystone*() family was built for the virtual-keystone system
-- used in prior expansions and is unreliable/stale now -- this was the
-- actual root cause of the recurring "Current Key" bugs earlier in
-- development (wrong ID namespace, then just not reflecting reality at
-- all). MMD.Data_ScanBagsForKeystone() (Data.lua) is the real source of
-- truth now: it finds the physical item and parses dungeon+level
-- directly from its link. Every "what do I hold" check in this file
-- goes through that, never GetOwnedKeystone*().
--
-- OWNERSHIP HEURISTIC (confirmed sound, not just plausible): while a
-- run is active, if a keystone is STILL sitting in bags, it cannot be
-- the one just slotted -- your own key is consumed/placed to start a
-- run, so it would no longer be in your bags. Presence of a bag
-- keystone during an active run therefore means the active run is on a
-- BORROWED key; absence means it's (as far as we can tell) your own.
-- This fully replaces the earlier before/after GetOwnedKeystoneLevel
-- comparison approach, which depended on the same broken API.

local ADDON_NAME, MMD = ...

-- { mapID, runLevel, startedAt, wasOwnKey } or nil, this session only.
-- runLevel is the active run's level (ownership-agnostic, from
-- C_ChallengeMode.GetActiveKeystoneInfo -- a different, still-reliable
-- API, not part of the broken owned-keystone family). wasOwnKey comes
-- from the bag-scan heuristic above, captured at CHALLENGE_MODE_START.
local inProgressState = nil

-- Applies the held-key bag scan to a record's currentKey. Shared by
-- every place that needs to show "what do I hold right now" while not
-- mid-run: login, the periodic ticker, and right after a run ends.
local function applyHeldKeyFromBags(record)
    local heldMapID, heldLevel = MMD.Data_ScanBagsForKeystone()
    if heldMapID then
        record.currentKey = { mapID = heldMapID, level = heldLevel, inProgress = false }
    else
        record.currentKey = nil
    end
end

-- ---------------------------------------------------------------------
-- Login orchestration
-- ---------------------------------------------------------------------

-- Retry counter for seedCurrentCharacter. Reset to 0 on each login/reload.
local seedAttempts = 0
local MAX_SEED_ATTEMPTS = 6 -- 5 seconds apart = 30 seconds total

-- Refresh dungeon cache and seed this character's history from Blizzard's
-- season-best records. If dungeon data isn't ready yet (RequestMapInfo
-- round-trip still in flight), retries itself every 5 seconds up to
-- MAX_SEED_ATTEMPTS times, then gives up. Idempotent once data is present.
local function seedCurrentCharacter()
    if not MMD.gdb then return end
    if MMD.Data_RefreshDungeonCache then MMD.Data_RefreshDungeonCache() end

    if not next(MMD.gdb.dungeons) then
        seedAttempts = seedAttempts + 1
        if seedAttempts < MAX_SEED_ATTEMPTS then
            C_Timer.After(5, seedCurrentCharacter)
        end
        return
    end

    seedAttempts = 0

    local myKey = MMD.Data_GetMyKey and MMD.Data_GetMyKey()
    if not myKey then return end
    local myRecord = MMD.Data_GetOrCreateRecord and MMD.Data_GetOrCreateRecord(myKey)
    if not myRecord then return end

    if not inProgressState and myRecord.currentKey == nil then
        applyHeldKeyFromBags(myRecord)
    end

    if MMD.Data_SeedFromSeasonBest then
        for mapID in pairs(MMD.gdb.dungeons) do
            MMD.Data_SeedFromSeasonBest(myRecord, mapID)
        end
    end

    if MMD.Data_Finalize then MMD.Data_Finalize(myRecord) end
    if MMD.UI_Refresh then MMD.UI_Refresh() end
end

function MMD.OnLogin()
    seedAttempts = 0
    MMD.InitGuildDB()
    if not MMD.gdb then
        -- Not in a guild; nothing to track.
        return
    end

    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(MMD.PREFIX)
    end

    -- Dungeon names need to be available before the bag-scan's
    -- name-to-mapID lookup can resolve, so request/refresh first,
    -- best-effort. If this hasn't landed yet, applyHeldKeyFromBags may
    -- come back with a nil mapID even though a keystone was found --
    -- the periodic ticker re-scans within a minute regardless.
    MMD.Data_RequestMapInfo()
    MMD.Data_RefreshDungeonCache()

    local myKey = MMD.Data_GetMyKey()
    local record = MMD.Data_GetOrCreateRecord(myKey)

    -- Base state: whatever keystone is currently HELD, via bag scan,
    -- regardless of whether a run is actively underway.
    applyHeldKeyFromBags(record)

    -- Layered on top: is a run already actively in progress right now
    -- (e.g. after a /reload mid-dungeon, where CHALLENGE_MODE_START
    -- never fired this session)? If so, this overrides the held-key
    -- snapshot above with the active run's info and sets inProgress.
    if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
        local activeMapID = C_ChallengeMode.GetActiveChallengeMapID()
        if activeMapID then
            local activeLevel = C_ChallengeMode.GetActiveKeystoneInfo and C_ChallengeMode.GetActiveKeystoneInfo()
            local bagMapID = MMD.Data_ScanBagsForKeystone()
            local wasOwnKey = bagMapID == nil

            inProgressState = { mapID = activeMapID, runLevel = activeLevel, startedAt = GetServerTime(), wasOwnKey = wasOwnKey }
            record.currentKey = { mapID = activeMapID, level = activeLevel, inProgress = true, startedAt = inProgressState.startedAt, mayNotBeOwnKey = not wasOwnKey }
        end
    end

    MMD.Data_Finalize(record)
    if MMD.UI_Refresh then MMD.UI_Refresh() end

    -- GetSeasonBestForMap/GetCurrentSeason may not have real data the
    -- instant login fires; a short delay gives RequestMapInfo's
    -- round-trip a chance to land before seeding from it. Re-running
    -- this costs nothing if the data was already ready. Also re-applies
    -- the held-key bag scan, in case the dungeon-name lookup couldn't
    -- resolve on the first pass above.
    C_Timer.After(3, function()
        -- Fallback: if CHALLENGE_MODE_MAPS_UPDATE already fired and seeded,
        -- this is a harmless no-op (SeedFromSeasonBest uses math.max).
        -- If it hasn't fired yet (slow round-trip), this catches it.
        seedCurrentCharacter()
        if MMD.Season_CheckForChange then MMD.Season_CheckForChange() end
        if MMD.Sync_RequestManifest then MMD.Sync_RequestManifest() end
    end)

    -- Low-frequency catch-all, two jobs:
    -- 1. Re-scan bags for the held keystone when not mid-run, so a
    --    manual swap (Lindormi, a Vault reward, trading with someone)
    --    that fires no event this addon hooks still shows up within a
    --    minute instead of going stale until the next login.
    -- 2. Recompute-and-compare the checksum independent of any specific
    --    event hook, to catch anything else the tracked events missed.
    C_Timer.NewTicker(60, function()
        local myKey = MMD.Data_GetMyKey()
        local record = MMD.gdb and MMD.gdb.characters[myKey]
        if not record then return end

        if not inProgressState then
            applyHeldKeyFromBags(record)
        end

        local freshChecksum = MMD.Checksum_Compute(record)
        if freshChecksum ~= record.checksum then
            MMD.Data_Finalize(record) -- re-stamps checksum + lastUpdated
            if MMD.UI_Refresh then MMD.UI_Refresh() end
            MMD.Sync_BroadcastRecord(myKey, record)
        end
    end)
end

-- ---------------------------------------------------------------------
-- Key state machine
-- ---------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("CHALLENGE_MODE_START")
eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
eventFrame:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHALLENGE_MODE_START" then
        -- CHALLENGE_MODE_START's payload IS the mapID directly.
        local mapID = ...

        -- The level of the RUN being started -- ownership-agnostic,
        -- from a different (still-reliable) API than the broken
        -- owned-keystone family.
        local runLevel = C_ChallengeMode.GetActiveKeystoneInfo and C_ChallengeMode.GetActiveKeystoneInfo()

        -- Ownership heuristic: a keystone still in bags right as the
        -- run begins can't be the one just slotted -- yours would have
        -- been consumed. Presence = borrowed; absence = yours.
        local bagMapID = MMD.Data_ScanBagsForKeystone()
        local wasOwnKey = bagMapID == nil

        inProgressState = { mapID = mapID, runLevel = runLevel, startedAt = GetServerTime(), wasOwnKey = wasOwnKey }

        local myKey = MMD.Data_GetMyKey()
        local record = MMD.Data_GetOrCreateRecord(myKey)
        record.currentKey = { mapID = mapID, level = runLevel, inProgress = true, startedAt = inProgressState.startedAt, mayNotBeOwnKey = not wasOwnKey }
        MMD.Data_Finalize(record)
        if MMD.UI_Refresh then MMD.UI_Refresh() end
        MMD.Sync_BroadcastRecord(myKey, record)

    elseif event == "CHALLENGE_MODE_COMPLETED" then
        -- CHALLENGE_MODE_COMPLETED carries NO payload. Details come from
        -- C_ChallengeMode.GetChallengeCompletionInfo(), which returns a
        -- single table (replaced the old positional GetCompletionInfo(),
        -- removed in TWW -- calling it was the line-191 nil-call error).
        -- Old API kept as a fallback only in case it ever reappears.
        -- Called here while still inside the dungeon, before the outbound
        -- loading screen, so inProgressState is always resolved before
        -- PLAYER_ENTERING_WORLD can ever see "outside an instance."
        local mapID, level, onTime
        if C_ChallengeMode.GetChallengeCompletionInfo then
            local info = C_ChallengeMode.GetChallengeCompletionInfo()
            if info then
                mapID, level, onTime = info.mapChallengeModeID, info.level, info.onTime
            end
        elseif C_ChallengeMode.GetCompletionInfo then
            local _time
            mapID, level, _time, onTime = C_ChallengeMode.GetCompletionInfo()
        end

        -- Last resort: if neither API gave us anything, we still KNOW a
        -- run completed (this event only fires on a finish) -- use the
        -- snapshot from CHALLENGE_MODE_START. onTime is unknown, so don't
        -- record a result; the season-best seed fills it in instead.
        if not mapID and inProgressState then
            mapID, level = inProgressState.mapID, inProgressState.runLevel
        end

        -- Clear FIRST, so an error anywhere below can never leave a stale
        -- in-progress state for PLAYER_ENTERING_WORLD to misread as a walkout.
        inProgressState = nil

        if mapID then
            local myKey = MMD.Data_GetMyKey()
            local record = MMD.Data_GetOrCreateRecord(myKey)
            if onTime ~= nil then
                MMD.Data_ApplyCompletion(record, mapID, level, onTime)
            else
                MMD.Data_SeedFromSeasonBest(record, mapID)
            end

            -- Re-scan bags for the actually-held key now that the run
            -- is over, rather than just clearing inProgress on the
            -- run's key -- that key may not have been yours.
            applyHeldKeyFromBags(record)

            MMD.Data_Finalize(record)
            if MMD.UI_Refresh then MMD.UI_Refresh() end
            MMD.Sync_BroadcastRecord(myKey, record)
        end

    elseif event == "CHALLENGE_MODE_MAPS_UPDATE" then
        -- RequestMapInfo's round-trip just completed: dungeon names and IDs
        -- are now live. Seed from season bests immediately rather than
        -- waiting for the 3-second fallback timer.
        seedCurrentCharacter()

    elseif event == "PLAYER_ENTERING_WORLD" then
        local isLogin, isReload = ...
        if isLogin or isReload then
            return -- handled by MMD.OnLogin instead; not a walkout signal
        end

        if inProgressState then
            local inInstance, instanceType = IsInInstance()
            if not inInstance or instanceType ~= "party" then
                -- We were in-progress and are now outside any instance
                -- with no CHALLENGE_MODE_COMPLETED having fired in
                -- between: walkout/abandon.
                local mapID = inProgressState.mapID
                local myKey = MMD.Data_GetMyKey()
                local record = MMD.Data_GetOrCreateRecord(myKey)

                if inProgressState.wasOwnKey then
                    -- Confirmed behavior: your own key always drops by
                    -- exactly one level on a walkout, same dungeon.
                    -- Route it through the normal depleted-candidate path
                    -- so the "only keep depleted if > completed" rule
                    -- still applies.
                    MMD.Data_ApplyCompletion(record, mapID, inProgressState.runLevel, false)
                else
                    -- Someone else's key: no impact on your own held
                    -- keystone. The walkout itself is still marked
                    -- Abandon for this dungeon -- Data_MarkAbandoned
                    -- already ignores that marker if completed/depleted
                    -- data already exists, so a genuine prior result
                    -- always wins over an abandon flag.
                    MMD.Data_MarkAbandoned(record, mapID)
                end

                applyHeldKeyFromBags(record)
                MMD.Data_Finalize(record)
                if MMD.UI_Refresh then MMD.UI_Refresh() end
                MMD.Sync_BroadcastRecord(myKey, record)
            end
            inProgressState = nil
        end
    end
end)
