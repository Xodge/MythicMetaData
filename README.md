# Mythic Meta Data

A World of Warcraft addon for tracking guild members' Mythic+ keystones, in-progress runs, and per-dungeon completed/depleted bests — without hardcoding the dungeon rotation.

## What it does

- Shows each guildie's currently held keystone (dungeon + level) in a single movable window
- Tracks in-progress runs with elapsed time and borrowed-key detection
- Records each member's highest completed (in-time) and highest depleted (over-time) level per dungeon, for the current season
- Flags members inactive past a configurable threshold (default 30 days) and recommends removal
- Archives each season's data when a new season begins, keeping full history on disk
- Syncs automatically over guild addon messages — no external server, no configuration

## Requirements

Every member you want to track needs the addon installed. Data is shared peer-to-peer over guild addon messages; members without the addon don't broadcast or receive.

## Usage

| Command | Effect |
|---|---|
| `/mmd` or `/mmd show` | Open / close the window |
| `/mmd sync` | Manually request a manifest sync |
| `/mmd inactivedays <n>` | Set inactivity threshold (default 30) |

**Officer-only:**

| Command | Effect |
|---|---|
| `/mmd excuse <Name-Realm>` | Mark a member excused (suppresses removal recommendation) |
| `/mmd unexcuse <Name-Realm>` | Clear excused status |
| `/mmd archive` | Manually archive current season and reset for the new one |

Click any row in the window to expand the full per-dungeon breakdown. **Expand All** in the title bar toggles all rows at once.

## Notes

- Data is stored account-wide, subdivided by guild, so alts in different guilds track independently and never contaminate each other
- The dungeon list is derived from the game's own API at runtime — no addon update needed when the season rotation changes
- Keystones are detected by bag scan (Midnight reverted to physical bag items); the addon does not use the deprecated virtual-keystone API

## Installation

Drop the `MythicMetaData` folder into `World of Warcraft\_retail_\Interface\AddOns\`.

## License

All Rights Reserved. Personal and guild use permitted; do not redistribute modified versions without permission.
