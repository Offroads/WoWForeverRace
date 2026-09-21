# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, Copilot, etc.) working in this repository.

## Project Overview

A World of Warcraft addon written in Lua that tracks the top 50 players racing to max level on each faction-realm (overall and per class) and records the first player to reach every level. It supports **WoW Forever only** (1.60.x client line, interface 16001): level cap 60 and the 9 classic classes, Paladin and Shaman on both factions (`Config.MaxLevel`, `Config.MopClassIndexes`). There is no expansion detection and no support for other clients. Built on the **Ace3 addon framework** (AceAddon, AceDB, AceComm, AceConfig, AceGUI, AceConsole, AceSerializer) with LibDataBroker, LibDBIcon and LibCompress.

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

CI (`.github/workflows/ci.yml`) runs lint + tests in the same image on every PR and on pushes to `main`. Tagging `v*` runs `.github/workflows/release.yml` (BigWigs packager, GitHub release).

Coverage report: `luacov.report.out`. Files not exercised by tests (WoW API dependent): `main.lua`, `options.lua`, `gui/*.lua`, `dev.lua`, `updater.lua`.

Test output silences the addon's debug prints; set `WFR_TEST_DEBUG=1` to see them. The stubs in `tests/stubs/` expose `Set*` helpers (`SetTime`, `SetWhoResults(results, total)`, `SetIsInGuild`, `SetGroupState(members, inRaid, inInstanceGroup)`, `SetWhoPanelVisible(visible)`, `SetChatLockdown(lockedDown)`, `C_Timer.Advance`) to drive the world state; extend them rather than mocking inside individual tests. When the Ace3 libraries start using a new WoW global, stub it in `tests/stubs/misc.lua`; when addon code starts using a WoW API as a bare global, add it to `read_globals` in `.luacheckrc` (access through `_G.Name` needs no entry).

## Architecture

### Component Structure

All components are attached to the `WoWForeverRace` global addon object. No other globals. Dependencies are passed via constructor injection. Components communicate through **EventBus** (pub/sub), which decouples them from each other.

**Data flow:**
1. `Scanner` -> issues protected `/who` queries from hardware-event hooks
2. `Scanner` -> publishes `WHO_RESULT` on EventBus
3. `Tracker` -> listens for `WHO_RESULT`, updates Leaderboard
4. `Leaderboard` -> detects new players/level-ups, publishes `DING`
5. `ChatNotifier` -> listens for `DING`, sends chat messages
6. `StatusFrame` -> listens for `REFRESH_GUI`, redraws UI
7. `Network` -> bridges AceComm <-> EventBus for cross-player sync
8. `Sync` -> on login, requests leaderboard sync via Network

### Database Layout (AceDB, factionrealm scope)
```lua
WoWForeverRace_DB.factionrealm = {
  leaderboard = {
    [0]    = { minLevel, highestLevel, players[] },  -- global (all classes)
    [1..N] = { ... }                                  -- valid per-class
  },
  firstToLevel = { [classFilter] = { [level] = {name, classIndex, dingedAt} } },
  playerHistory = { [name] = { classIndex, levels = { [level] = dingedAt } } },
  buddies = { [name] = { lastSeen } },
  realmOpenedAt = serverTime,  -- first login with the addon, earliest wins on sync
  raceStartedAt = serverTime,  -- earliest dingedAt ever seen
}
```

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
Player batches use a compact legacy format with a tagged delimiter format for levels above 99. LibCompress is applied before transmission.

### WoW Forever client notes
- The Forever client is built on the modern (retail, `mainline` family) UI and API with game type `camelot`; its FrameXML lives in the `forever` branch of `Gethe/wow-ui-source`. Check API questions against that branch, not against Classic Era
- Class indexes are part of the wire and DB format (shared with TheClassicRace): `Config.Classes` keeps the gaps at 6, 10 and 12 for the classes that don't exist in WoW Forever - never renumber
- The who list is `LFGWhoListFrame` (load-on-demand `Blizzard_GroupFinder_VanillaStyle`), not `FriendsFrame`; it opens the group finder on every `WHO_LIST_UPDATE`. `Scanner:SuppressWhoUi` / `RestoreWhoUi` unregister and restore the event on whichever who frames exist, looked up at scan time
- `C_FriendList.GetNumWhoResults()` returns `(numWhos, totalNumWhos)`; `C_FriendList.SendWho` is restricted, so scans stay wired to hardware events
- The chat messaging lockdown (`C_ChatInfo.InChatMessagingLockdown()`) covers encounters, PvP matches and whole dungeon/raid maps. `Network:SendObject` holds messages in an outbox (latest only for non-payload events, capped) and `FlushOutbox` sends them once the lockdown ended; `Sync:InitSync` postpones itself the same way
- A pending scan is abandoned by a `C_Timer` after `SCAN_TIMEOUT` (`Scanner:AbandonScan`), so the who UI is handed back without a click, also when the race finished meanwhile. After a foreign `C_FriendList.SendWho` (hooked, `Scanner:OnSendWho`) an empty result is not attributed to the scan
- Class scans use the localized class name (`LocalizedClassList`), quoted: `2-60 c-"Warrior"`; `Config.WhoClassFilter` is the English fallback
- The session's first scan is an unfiltered probe (`2-60`, repeated while the leaderboard is empty). `Scanner:RecordProbe` keeps its match count, levels and classes, from which `Scanner:ProbeFloor` estimates per class where a scan fits under the row cap
- The class scan floor (`Scanner:NextClassFloor`) starts at the probe's estimate, else at the bottom (2, or the board's `minLevel` once it is full), and bisects towards the lowest floor whose result still fits under the 50 row cap, bounded above by the highest level seen. Floors known to overflow / fit are remembered for `FLOOR_BOUND_TTL`. Player names contain a space (`"First Surname"`), never a `-`
- The TOC declares the WoW Forever interface only (`## Interface: 16001`); bump it with each client patch
- The client has no API for a realm's launch time, so it is hardcoded as `Config.RealmLaunchAt` (UTC epoch); update it for each launch. `Core:RaceStartTime` measures the race from it once it has passed, else (and for dings from before it) from `realmOpenedAt` / `raceStartedAt`

### Key Conventions
- Player identity format: `"Name-Realm"` (e.g. `"Nubone-NubVille"`)
- Class indices: 1-12 (0 = unknown/all); valid playable classes are `Config.MopClassIndexes` (historical name: the 9 WoW Forever classes) - validate remote class indexes with `Config:IsValidClassIndex`
- Leaderboard capped at 50 players per faction-realm
- Race finish: the race is finished only when **every** class leaderboard in `Config.MopClassIndexes` is full at `Config.MaxLevel`. `Tracker:CheckRaceFinished` is the single authority - the scanner's `SCAN_FINISHED(endofrace)` signal is verified against the boards, never trusted directly
- Remote data is untrusted: `Tracker:ProcessPlayerInfo` drops entries without a string name or with a level outside `1..Config.MaxLevel`, and only events listed in `Config.Network.Events` are accepted from the wire
- Scanner timings (constants in `scanner.lua`): 15s cooldown between scans, 60s timeout before an unanswered `/who` is abandoned, 15min rest for a fully-scanned class (`/who` only sees online players, so a "complete" result is just a snapshot). A result is complete only when `C_FriendList.GetNumWhoResults()` reports no more server-side matches than rows shown
- WHO results are validated against the pending query (level range + class filter) so manual `/who` results are never misattributed to a scan
- `Network:SendObject(..., "GROUP")` routes to `INSTANCE_CHAT` in instance groups, else `RAID`/`PARTY`
- Peers can track a different class list (other client, older build on the shared `TCRace` prefix). Wherever a peer's per-class hash table is available (`GUILDSYNC`, `BPING`, `BPONG`, `DATAREQ`), full, FTL and per-class comparisons only cover the leaderboards that peer reported (`leaderboardClassIndexes(config, peerHashes)`, `Tracker:ComputeNeedSet`); a missing entry means "not tracked", never "differs". The discovery beacon (`DATAAVAIL`) carries only the full hash, so such peers still cost one `DATAREQ` round trip per beacon, which then sends nothing
- Network event names: `PINFOB`, `REQSYNC`, `OFFERSYNC`, `STARTSYNC`, `SYNC`, `DATAAVAIL`, `DATAREQ`, `GUILDSYNC`, `GUILDOFFR`, `BPING`, `BPONG`, `FTLSYNC`, `PHSYNC`
- Local event names: `NETWORK_READY`, `WHO_RESULT`, `SYNC_RESULT`, `FTL_SYNC_RESULT`, `PH_SYNC_RESULT`, `SCAN_FINISHED`, `RACE_FINISHED`, `DING`, `REFRESH_GUI`, `MSG_STATS`, `BUDDY_UPDATE`
- The addon-channel prefix is still `TCRace` (inherited from TheClassicRace) so clients of both addons keep exchanging data; user-facing names say WoWForeverRace
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
| `src/core/tracker.lua` | Applies player info to the leaderboards, pioneers, history; discovery beacons |
| `src/core/leaderboard.lua` | Leaderboard model |
| `src/core/sync.lua` | Login / guild / buddy / group sync negotiation |
| `src/core/serializer.lua` | Network encoding/decoding |
| `src/dev.lua` | Dev-only slash commands (unpackaged checkout only) |
| `media/icon.tga` | In-game icon, 64x64 (TOC `IconTexture`, minimap button); `icon.svg` is its source, `logo.svg` / `logo.png` the full logo. Only the TGA is packaged |
| `tests/testbase.lua` | Test bootstrap: stubs, libs, addon sources |
| `tests/stubs/` | WoW API stubs with `Set*` helpers |
| `.busted` | busted config (roots, patterns, `quick` run without coverage) |
| `.luacheckrc` | Luacheck config: Lua 5.1 std, WoW API read-only globals, test rules |
| `.luacov` | Coverage config |
| `.luarc.json` | Lua Language Server config (editor completion / diagnostics) |
| `Dockerfile`, `docker-compose.yml` | Dev toolchain image |
| `scripts/dev.ps1` | Windows wrapper: docker targets + deploy into WoW AddOns |
| `.github/workflows/` | CI (lint + tests) and tag-triggered release packaging |
