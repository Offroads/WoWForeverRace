# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A World of Warcraft Classic addon written in Lua that tracks the top 50 players racing to level 60 on each realm. Built on the **Ace3 addon framework** (AceAddon, AceDB, AceComm, AceConfig, AceGUI, AceConsole) with LibWho-2.0 and LibCompress.

## Commands

### Setup
```bash
make setup-dev    # install Lua dev tools: luacheck, busted, luacov
make libs         # download external library dependencies (cached in ./libs)
make fetch-libs   # force-fetch fresh libs via bw-release.sh
```

### Build & Release
```bash
make lint         # run luacheck on ./src
make release      # build and optionally upload release
```

### Testing
```bash
make tests                                 # run all tests with coverage
make tests INCLUDES=scanner.lua               # run tests matching filename pattern
make tests INCLUDES="scan|leaderboard"     # multiple file patterns
make tests TESTS='.*binary.*'              # filter by test name (regex)
make reflex-tests                          # watch mode (requires reflex)
make reflex-tests INCLUDES=scanner.lua        # watch specific file
```

Coverage report is generated automatically; view with `luacov.report.out`. Files excluded from tests (WoW API dependent): `main.lua`, `options.lua`, `gui/*.lua`.

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
  }
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

### Key Conventions
- Player identity format: `"Name-Realm"` (e.g. `"Nubone-NubVille"`)
- Class indices: 1–12 (0 = unknown/all); valid playable classes are `Config.MopClassIndexes` (1–11, no Demon Hunter) — validate remote class indexes with `Config:IsValidClassIndex`
- Leaderboard capped at 50 players per faction-realm
- Race finish: the race is finished only when **every** class leaderboard in `Config.MopClassIndexes` is full at `Config.MaxLevel`. `Tracker:CheckRaceFinished` is the single authority — the scanner's `SCAN_FINISHED(endofrace)` signal is verified against the boards, never trusted directly
- Remote data is untrusted: player levels above `Config.MaxLevel` are rejected before reaching the leaderboards, and only events listed in `Config.Network.Events` are accepted from the wire
- Scanner timings (constants in `scanner.lua`): 15s cooldown between scans, 60s timeout before an unanswered `/who` is abandoned, 15min rest for a fully-scanned class (`/who` only sees online players, so a "complete" result is just a snapshot)
- WHO results are validated against the pending query (level range + class filter) so manual `/who` results are never misattributed to a scan
- Network event names: `PINFOB`, `REQSYNC`, `OFFERSYNC`, `STARTSYNC`, `SYNC`
- Local event names: `WHO_RESULT`, `SCAN_FINISHED`, `RACE_FINISHED`, `DING`, `REFRESH_GUI`
- Debug/trace gates use `@debug@` marker in `.toc`; version uses `@project-version@`
- Keep WoW-API-heavy code in `main.lua`, `options.lua`, and `gui/`; `scanner.lua` has focused API stubs

### Key Files
| File | Purpose |
|------|---------|
| `WoWForeverRace.toc` | Addon manifest: version, lib load order |
| `.pkgmeta` | External library deps (SVN/Git externals) |
| `libs.xml` | WoW XML that loads libraries in correct order |
| `src/config.lua` | Global constants, colors, class mappings |
| `src/core/event-bus.lua` | Pub/sub event system |
| `src/core/scanner.lua` | Protected `/who` queries and result filtering |
| `src/core/leaderboard.lua` | Leaderboard model |
| `src/core/serializer.lua` | Network encoding/decoding |
| `.luacheckrc` | Luacheck config (ignored codes, excluded files) |
| `.luacov` | Coverage config |
