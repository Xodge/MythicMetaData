# Changelog

## 1.0.0
- Initial public release
- Per-guild data subdivision: alts in different guilds track independently; cross-guild data coexists in a single SavedVariables file for future cross-guild search
- Automatic purge of departed guild members on roster update; resurrection-blocked in sync so a guildmate's stale copy can't restore a purged record
- Schema migration from flat (pre-1.0) layout to per-guild layout runs automatically on first load
- Physical keystone detection via bag scan (Midnight reverted to bag-item keystones; deprecated virtual-keystone API retired)
- Borrowed-key heuristic: detects when the active run uses someone else's key
- Walkout/abandon detection via PLAYER_ENTERING_WORLD outside an instance with no CHALLENGE_MODE_COMPLETED
- Monospace font (Adobe Source Code Pro, SIL OFL) for aligned per-dungeon table display
- Officer-gated excuse/unexcuse and season archive commands
- Season-change detection with archive prompt; full history preserved across seasons
- 30-day inactivity threshold with per-member officer-settable excusal
- Two-phase guild sync: manifest (cheap) + targeted record fetch/push
- Version mismatch detection in sync handshake
