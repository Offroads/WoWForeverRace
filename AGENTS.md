# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, Copilot, etc.) working in this repository.

## Project Overview

A World of Warcraft addon written in Lua that tracks the top 50 players racing to max level on each faction-realm (overall, per class and per player race) and records the first player to reach every level. It supports **WoW Forever only** (1.60.x client line, interface 16001): level cap 60 and the 9 classic classes, Paladin and Shaman on both factions (`Config.MaxLevel`, `Config.MopClassIndexes`), and 5 player races per faction: the 4 classic ones plus the faction's own Skyborne (`Config.FactionRaceIndexes`). There is no expansion detection and no support for other clients. Built on the **Ace3 addon framework** (AceAddon, AceDB, AceComm, AceConfig, AceGUI, AceConsole, AceSerializer) with LibDataBroker, LibDBIcon and LibCompress.

## Commands

The toolchain (Lua 5.1, busted, luacheck, luacov, git, svn, BigWigs packager) is packaged in a Docker image; nothing else needs to be installed on the host. Run every `make` target through it:

```bash
docker compose build dev                          # build the dev image (once)
docker compose run --rm dev                       # lint + tests
docker compose run --rm dev make lint             # luacheck on src/ and tests/
docker compose run --rm dev make tests            # busted with coverage (fetches ./libs first if missing)
docker compose run --rm dev make tests INCLUDES=scanner        # only test files matching a Lua pattern
docker compose run --rm dev make tests TESTS='.*binary.*'     # only test names matching a Lua pattern
docker compose run --rm dev make tests BUSTED_RUN=quick       # skip coverage
docker compose run --rm dev make fetch-libs       # re-download external libraries into ./libs
docker compose run --rm dev make release          # build a release zip into ./.release
```

Windows: `.\scripts\dev.ps1 <build|lint|tests|check|libs|release|shell|deploy>` wraps the same commands; `deploy` junctions the checkout into a WoW `AddOns` folder (the `_classic_beta_` install that serves the WoW Forever beta, or `-AddOnsPath`). macOS/Linux: `make docker-*` targets. With a native Lua 5.1 toolchain the plain `make lint tests` also works (`make setup-dev` installs the rocks).

CI (`.github/workflows/ci.yml`) runs lint + tests in the same image on every PR and on pushes to `main`. Tagging `v*` runs `.github/workflows/release.yml`: the BigWigs packager (v2.6.0+ maps interface 16xxx to game type `forever`) builds the zip, creates the GitHub release and uploads to CurseForge (`X-Curse-Project-ID` in the TOC, `CF_API_KEY` secret). No WoWInterface upload: it has no WoW Forever game type and the packager fails the run.

Coverage report: `luacov.report.out`. Files not exercised by tests (WoW API dependent): `main.lua`, `options.lua`, `gui/*.lua`, `dev.lua`, `updater.lua`.

`CHANGELOG.md` is the release notes: the BigWigs packager ships it in the zip and posts it on CurseForge, so add every user-visible change under `Unreleased` in the PR that makes it, and rename that section to the version when tagging.

`tests/sync-e2e.lua` exercises every sync flow (login zone sync, guild sync, buddy ping, group sync, discovery beacon, ding push, faction lock) between two complete addon stacks wired together through the real network envelope, one of them seeded with `tests/fixtures/horde-pve-factionrealm.lua`: real beta data, the `factionrealm` block of a SavedVariables file with `playerHistory` trimmed to the players on a leaderboard. Regenerate it the same way when the DB layout changes; data fixtures are excluded from busted's file discovery (`.busted`) and from luacheck (`.luacheckrc`).

Test output silences the addon's debug prints; set `WFR_TEST_DEBUG=1` to see them. The stubs in `tests/stubs/` expose `Set*` helpers (`SetTime`, `SetWhoResults(results, total)`, `SetIsInGuild`, `SetFaction(faction)`, `SetGroupState(members, inRaid, inInstanceGroup)`, `SetGroupMembers(members, inRaid)`, `SetGuildRoster(members)`, `SetWhoPanelVisible(visible)`, `SetChatLockdown(lockedDown)`, `SetFaction(faction)`, `SetRaceNames(names)`, `C_Timer.Advance`) to drive the world state; extend them rather than mocking inside individual tests. When the Ace3 libraries start using a new WoW global, stub it in `tests/stubs/misc.lua`; when addon code starts using a WoW API as a bare global, add it to `read_globals` in `.luacheckrc` (access through `_G.Name` needs no entry).

## Architecture

### Component Structure

All components are attached to the `WoWForeverRace` global addon object. No other globals. Dependencies are passed via constructor injection. Components communicate through **EventBus** (pub/sub), which decouples them from each other.

**Data flow:**
1. `Scanner` -> issues protected `/who` queries from hardware-event hooks
2. `Scanner` -> publishes `WHO_RESULT` on EventBus
2b. `Roster` -> publishes guild roster and party / raid member levels as `WHO_RESULT` too (exact levels, no `/who` cost); `Updater` does the same for our own level-ups
3. `Tracker` -> listens for `WHO_RESULT`, updates Leaderboard
4. `Leaderboard` -> detects new players/level-ups, publishes `DING` (player info, overall rank, class rank, race rank)
5. `ChatNotifier` -> listens for `DING`, sends chat messages
6. `StatusFrame` -> listens for `REFRESH_GUI`, redraws UI
7. `Network` -> bridges AceComm <-> EventBus for cross-player sync
8. `Sync` -> on login, requests leaderboard sync via Network

### Database Layout (AceDB, factionrealm scope)
```lua
WoWForeverRace_DB.factionrealm = {
  leaderboard = {
    [0]    = { minLevel, highestLevel, players[] },  -- global (all classes)
    [1..N] = { ... },                                 -- valid per-class
    [100 + raceIndex] = { ... },                      -- per player race of this faction (Config.RaceBoardOffset)
  },                                                  -- players[] = { name, level, dingedAt, classIndex, raceIndex }
  firstToLevel = { [classFilter] = { [level] = {name, classIndex, dingedAt} } },
  playerHistory = { [name] = { classIndex, raceIndex, levels = { [level] = dingedAt } } },  -- raceIndex is local only: not hashed, not synced
  buddies = { [name] = { lastSeen } },
  realmOpenedAt = serverTime,  -- first login with the addon, earliest wins on sync; never before the launch once it passed
  raceStartedAt = serverTime,  -- earliest dingedAt seen (since the launch, once it passed)
}
```
Race data must stay in `factionrealm`: every other scope (`profile`, `global`, `realm`, ...) is shared by the Horde and Alliance characters of an account and holds settings only. `tests/storage.lua` guards this.

### Object-Oriented Pattern
```lua
local Component = {}
Component.__index = Component
WoWForeverRace.Component = Component
setmetatable(Component, { __call = function(cls, ...) return cls.new(...) end })
function Component.new(...)
  local self = setmetatable({}, Component)
  return self
end
```

### Network Serialization
Player batches use a compact legacy format with a tagged delimiter format for levels above 99. A known player race rides along as an optional `.raceIndex` between the class and the name (names never contain a digit or a `.`); a record without it is an unknown race. LibCompress is applied before transmission.

### WoW Forever client notes
- The Forever client is built on the modern (retail, `mainline` family) UI and API with game type `camelot`; its FrameXML lives in the `forever` branch of `Gethe/wow-ui-source`. Check API questions against that branch, not against Classic Era
- Class indexes are part of the wire and DB format (shared with TheClassicRace): `Config.Classes` keeps the gaps at 6, 10 and 12 for the classes that don't exist in WoW Forever - never renumber
- The who list is `LFGWhoListFrame` (load-on-demand `Blizzard_GroupFinder_VanillaStyle`), not `FriendsFrame`; it opens the group finder on every `WHO_LIST_UPDATE`. `Scanner:SuppressWhoUi` / `RestoreWhoUi` unregister and restore the event on whichever who frames exist, looked up at scan time
- `C_FriendList.GetNumWhoResults()` returns `(numWhos, totalNumWhos)`, but the client caps the total at the 50 row cap as well ("50 People Found" for any larger result), so it can't tell a cut off result from a complete one; `C_FriendList.SendWho` is restricted, so scans stay wired to hardware events
- The chat messaging lockdown (`C_ChatInfo.InChatMessagingLockdown()`) covers encounters, PvP matches and whole dungeon/raid maps. `Network:SendObject` holds messages in an outbox (latest only for non-payload events, capped) and `FlushOutbox` sends them once the lockdown ended; `Sync:InitSync` postpones itself the same way
- `Roster` (`src/core/roster.lua`) reads levels the client already has: the guild roster on `GUILD_ROSTER_UPDATE` (requested every 60s by `Roster:InitGuildRosterTicker`, offline members included, no race in the roster) and party / raid units on `GROUP_ROSTER_UPDATE` / `UNIT_LEVEL` (class and race from `UnitClass` / `UnitRace`, only units of the own faction and realm). A level is forwarded once, again when it rises or after 15 min (`RESEND_TTL`); `Roster:ResetState` (from `OnDatabaseReset`) forgets that. Rows travel as `WHO_RESULT`, so they get the same validation, leaderboard update and ding push as a scan
- Scans hang on the world clicks (`WorldFrame` `OnMouseDown`) and the minimap icon. With the option `keypressScanning` (default on) a keyboard frame that propagates its input (`Scanner:UpdateKeypressScanning`) triggers them on key presses too. `SetPropagateKeyboardInput` is protected in combat and a keyboard frame without it swallows every key, so the frame is only created out of combat (else on `PLAYER_REGEN_ENABLED`) and never touched again: turning the option off only silences its handler
- A pending scan is abandoned by a `C_Timer` after `SCAN_TIMEOUT` (`Scanner:AbandonScan`), so the who UI is handed back without a click, also when the race finished meanwhile. After a foreign `C_FriendList.SendWho` (hooked, `Scanner:OnSendWho`) an empty result is not attributed to the scan
- Player races: the 8 classic races have the client's race IDs 1-8; the new race Skyborne exists once per faction, ID 95 "High Order Skyborne" (Alliance) and ID 96 "Windshaper Skyborne" (Horde), both with the internal name `Skyborne`. The client's race table also lists every retail race and `C_CreatureInfo.GetFactionInfo` is unreliable here, so the races per faction are fixed in `Config.FactionRaceIndexes`
- A who row only carries the localized race name (`raceStr`), no ID. `Core:RaceIndexByName` resolves it against `C_CreatureInfo.GetRaceInfo(raceID).raceName` for the races of the own faction; a name that doesn't resolve (other languages may use gendered names) is an unknown race, never an error
- Race scans use the localized race name, quoted: `2-60 r-"Troll"` (`Scanner:RaceWhoFilter`). The filtered scans cycle through `Scanner:ScanSlots`, classes first: a race slot only gets a turn after a round of 9 class scans, or when no class needs a scan (`Scanner:NextDueSlot`). Floor, rest period and probe estimate work per slot, keyed by the slot's leaderboard index
- Race icons are the atlases `raceicon-<name>-male` with the names in `Config.RaceIconAtlas` (Undead is `undead`, not its internal name `scourge`)
- Class scans use the localized class name (`LocalizedClassList`), quoted: `2-60 c-"Warrior"`; `Config.WhoClassFilter` is the English fallback
- The session's first scan is an unfiltered probe (`2-60`, repeated while the leaderboard is empty). `Scanner:RecordProbe` keeps its match count, levels and classes, from which `Scanner:ProbeFloor` estimates per class where a scan fits under the row cap
- The scan floor of a class or race (`Scanner:NextClassFloor`) works from the top down: it starts at the highest level already on that leaderboard (an empty one starts at the probe's estimate, else at the bottom: 2, or the board's `minLevel` once it is full) and comes down one level per visit while the result fits under the 50 row cap. A full result sends it back up, halfway to a floor known to fit, so it settles on the lowest floor that fits, bounded above by the highest level seen (a full result from at or above that level looks one level higher, e.g. `21-60` after a full `20-60`, and doubles that step for every further full result in a row: cut off results are arbitrary, so the highest level seen can lag behind). Floors known to overflow / fit are remembered for `FLOOR_BOUND_TTL`. Player names contain a space (`"First Surname"`), never a `-`
- The TOC declares the WoW Forever interface only (`## Interface: 16001`); bump it with each client patch
- The client has no API for a realm's launch time, so it is hardcoded as `Config.RealmLaunchAt` (UTC epoch). It is one global value for the single WoW Forever launch: correct it if Blizzard moves that launch, but never move it forward for a later one - everything older than it is purged on every client
- `Core:RaceStartTime` measures the race from the launch once it has passed, else (and for dings from before it) from `realmOpenedAt` / `raceStartedAt`
- The released race starts from fresh leaderboards. Once the launch has passed, `Tracker:PurgePreLaunchData` drops this faction-realm's race data and buddies from before it (beta); settings and newer data stay. It runs at login, or when the launch passes mid-session: before the next ding or sync result is processed, else from the discovery beacon
- From then on the Tracker ignores every incoming ding, pioneer record, history level and `realmOpenedAt` from before the launch (checked with `Core:PredatesLaunch`)

### Key Conventions
- Player identity format: `"Name-Realm"` (e.g. `"Nubone-NubVille"`)
- Class indices: 1-12 (0 = unknown/all); valid playable classes are `Config.MopClassIndexes` (historical name: the 9 WoW Forever classes) - validate remote class indexes with `Config:IsValidClassIndex`
- Leaderboard capped at 50 players per faction-realm
- Race indexes are the client's race IDs and part of the wire and DB format - never renumber. Unknown race is nil (0 in hashes, absent on the wire); validate remote race indexes with `Core:IsValidRaceIndex`, which only accepts the races of the own faction. A known race is never replaced by an unknown one, and a record that arrives without a race falls back to the one remembered in `playerHistory`
- Leaderboard indexes: 0 overall, 1-12 classes, `Config.RaceBoardOffset + raceIndex` races. `Core:BoardIndexes(peerHashes)` lists all of them; use it wherever "every leaderboard" is meant
- Pioneers (`firstToLevel`) are overall and per class only, never per race
- "The race" is the leveling competition; the character race is always "player race" / `raceIndex`
- Race finish: the race is finished only when **every** class leaderboard in `Config.MopClassIndexes` and **every** race leaderboard of the own faction is full at `Config.MaxLevel`. `Tracker:CheckRaceFinished` is the single authority - the scanner's `SCAN_FINISHED(endofrace)` signal is verified against the boards, never trusted directly
- Remote data is untrusted: `Tracker:ProcessPlayerInfo` drops entries without a string name or with a level outside `1..Config.MaxLevel`, and only events listed in `Config.Network.Events` are accepted from the wire
- Faction lock: the race is per faction and the wire has no other way to tell the factions apart, so every message envelope is `{event, payload, faction}`. `Network:SendObject` adds `Core:MyFaction()` (`UnitFactionGroup("player")`, the value that also scopes the AceDB `factionrealm` data); `Network:HandleAddonMessage` drops a message whose faction is missing, not a string or not the own faction, before anything is published (debug print only, not counted in the message stats)
- Scanner timings (constants in `scanner.lua`): 5s cooldown between scans, doubled (up to 30s) for the rest of the session whenever a `/who` reply is lost, because the server drops queries that come in too fast and has no API for that limit, 60s timeout before an unanswered `/who` is abandoned, 15min rest for a fully-scanned class (`/who` only sees online players, so a "complete" result is just a snapshot). A result is complete only when it stays under the 50 row cap (and `C_FriendList.GetNumWhoResults()` reports no more matches than rows shown); a result of exactly 50 rows counts as cut off
- WHO results are validated against the pending query (level range + class filter, or for a race scan: no row of another known race) so manual `/who` results are never misattributed to a scan
- `Network:SendObject(..., "GROUP")` routes to `INSTANCE_CHAT` in instance groups, else `RAID`/`PARTY`
- Race leaderboards sync through the per-board hash tables only (discovery beacon, guild sync, buddy ping/pong, group sync); the login handshake (`REQSYNC` / `OFFERSYNC` / zone `STARTSYNC`) still exchanges just the overall and the own class leaderboard
- Chat announcements: the top N sliders `globalTopN`, `classTopN` and `raceTopN` (default 1: only the first of a race) gate a ding; it is always one chat line, the race rank is appended to the class / overall message or gets its own message when only the race gate passes. With `raceTopN` 0 the output is exactly the class / overall one
- Peers can track a different class list (other client, older build on the shared `TCRace` prefix). Wherever a peer's per-board hash table (index i+1 = `leaderboard[i]`, classes and races) is available (`GUILDSYNC`, `BPING`, `BPONG`, `DATAREQ`), full, FTL and per-board comparisons only cover the leaderboards that peer reported (`Config:BoardIndexes(faction, peerHashes)`, `Tracker:ComputeNeedSet`); a missing entry means "not tracked", never "differs". The discovery beacon (`DATAAVAIL`) carries only the full hash, so such peers still cost one `DATAREQ` round trip per beacon, which then sends nothing
- Network event names: `PINFOB`, `REQSYNC`, `OFFERSYNC`, `STARTSYNC`, `SYNC`, `DATAAVAIL`, `DATAREQ`, `GUILDSYNC`, `GUILDOFFR`, `BPING`, `BPONG`, `FTLSYNC`, `PHSYNC`
- Local event names: `NETWORK_READY`, `WHO_RESULT`, `SYNC_RESULT`, `FTL_SYNC_RESULT`, `PH_SYNC_RESULT`, `SCAN_FINISHED`, `RACE_FINISHED`, `DING`, `REFRESH_GUI`, `MSG_STATS`, `BUDDY_UPDATE`
- The addon-channel prefix is still `TCRace` (inherited from TheClassicRace) and the envelope stays readable for older clients (event and payload first), but updated clients drop every message without a faction, so nothing is accepted from TheClassicRace or older WoWForeverRace clients; user-facing names say WoWForeverRace
- Debug/trace gates use `@debug@` marker in `.toc` and `config.lua`; version uses `@project-version@`. `src/dev.lua` (dev-only slash commands, `/wfr help`) is only loaded from an unpackaged checkout
- Keep WoW-API-heavy code in `main.lua`, `options.lua`, and `gui/`; `scanner.lua` has focused API stubs
- Never use em dashes or en dashes anywhere (code, comments, UI text, docs); use a plain hyphen

### Key Files
| File | Purpose |
|------|---------|
| `WoWForeverRace.toc` | Addon manifest: version, lib load order |
| `.pkgmeta` | External library deps (SVN/Git externals) and packaging ignores |
| `libs.xml` | WoW XML that loads libraries in correct order |
| `src/config.lua` | Global constants, colors, class mappings, expansion data |
| `src/core/event-bus.lua` | Pub/sub event system |
| `src/core/scanner.lua` | Protected `/who` queries and result filtering |
| `src/core/roster.lua` | Guild roster and group member levels as a second data source |
| `src/core/tracker.lua` | Applies player info to the leaderboards, pioneers, history; discovery beacons |
| `src/core/leaderboard.lua` | Leaderboard model |
| `src/core/sync.lua` | Login / guild / buddy / group sync negotiation |
| `src/core/serializer.lua` | Network encoding/decoding |
| `src/dev.lua` | Dev-only slash commands (unpackaged checkout only) |
| `media/icon.tga` | In-game icon, 64x64 (TOC `IconTexture`, minimap button); `icon.svg` is its source, `logo.svg` / `logo.png` the full logo. Only the TGA is packaged |
| `tests/testbase.lua` | Test bootstrap: stubs, libs, addon sources |
| `tests/stubs/` | WoW API stubs with `Set*` helpers |
| `tests/sync-e2e.lua` | Two addon stacks syncing real data end to end over the network envelope |
| `tests/fixtures/` | Generated data fixtures (`return {...}`), not test files |
| `.busted` | busted config (roots, patterns, `quick` run without coverage) |
| `.luacheckrc` | Luacheck config: Lua 5.1 std, WoW API read-only globals, test rules |
| `.luacov` | Coverage config |
| `.luarc.json` | Lua Language Server config (editor completion / diagnostics) |
| `Dockerfile`, `docker-compose.yml` | Dev toolchain image |
| `scripts/dev.ps1` | Windows wrapper: docker targets + deploy into WoW AddOns |
| `.github/workflows/` | CI (lint + tests) and tag-triggered release packaging |
| `CHANGELOG.md` | Release notes, shipped in the zip and posted on CurseForge by the packager |
