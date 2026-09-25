# Changelog

All user-visible changes to WoWForeverRace. The BigWigs packager ships this
file in the release zip and posts it as the CurseForge release notes.

## Unreleased

### Added
- The guild roster and your party or raid feed the leaderboards too, race
  boards included. Their levels are exact, cost no `/who` query and include
  guild members who are offline, so a guild ding shows up right away instead
  of on the next scan.
- Your own level-ups now carry your player race, so you land on your race
  leaderboard without waiting for a scan.
- Dev command `/wfr roster` reads the guild roster and group into the
  leaderboards on demand.

## v0.1.0-beta8 - 2026-09-22

### Added
- Scans also run on key presses (option "Scan on key presses", on by default),
  so the leaderboards fill up while you level instead of only on clicks.

## v0.1.0-beta7 - 2026-09-21

### Added
- Leaderboards for every player race of your faction, next to the overall and
  class ones, with race icons in the status window and a "Race top N" chat
  announcement slider.

### Changed
- Scans run three times as often.
- Each class and race is scanned from its top level downwards, so the top
  players are found first and a full `/who` list settles on the right floor
  faster.

### Fixed
- Race data is only accepted from players of the own faction.

## v0.1.0-beta6 - 2026-09-21

### Changed
- Releases are packaged for the WoW Forever game type and uploaded to
  CurseForge.

## v0.1.0-beta5 - 2026-09-21

### Changed
- The race is measured from the official WoW Forever launch. Beta data from
  before the launch is dropped once the launch has passed, so the released race
  starts from fresh leaderboards.
- Debug output goes to the debug window instead of the chat frame.

### Added
- Dev-only API probe window (`/wfr probe`).

## v0.1.0-beta4 - 2026-09-21

### Added
- Scrollable, copyable debug log window (`/wfr debug`).

## v0.1.0-beta3 - 2026-09-21

### Changed
- The first scan of a session is an unfiltered probe that estimates where each
  class fits under the 50 row `/who` cap, so class scans start at a useful
  level instead of at the bottom.

## v0.1.0-beta2 - 2026-09-20

### Added
- Project logo, also used as the in-game and minimap icon.

### Changed
- WoW Forever only: support for the other WoW clients and their expansions is
  removed.
- Licensed under MIT, crediting TheClassicRace.

## v0.1.0-beta1 - 2026-09-17

First WoWForeverRace release, based on TheClassicRace by Ruben de Vries.

### Added
- Targets WoW Forever: the race goes to level 60, Paladins and Shamans are
  tracked on both factions.
- Addon messages in instance groups go to the instance chat.
- Dev commands `/wfr help` and `/wfr status`.

### Fixed
- Player data from other addon users is validated before it reaches the
  leaderboards: forged timestamps, fractional levels and nameless entries are
  dropped.
- Sync hashes only cover the classes a peer tracks, so peers on a different
  class list no longer mismatch forever.
- The `/who` result count was read the wrong way round, which made complete
  results look cut off.
- Lua error when announcing a ding for a player of unknown class.
- Every remaining TheClassicRace name in user-facing text.
