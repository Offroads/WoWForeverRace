# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, Copilot, etc.) working in this repository.

## Project Overview

A World of Warcraft addon written in Lua that tracks the top 50 players racing to max level on each faction-realm (overall, per class and per player race) and records the first player to reach every level. It supports **WoW Forever only** (1.60.x client line, interface 16001): level cap 60 and the 9 classic classes, Paladin and Shaman on both factions (`Config.MaxLevel`, `Config.MopClassIndexes`), and 5 player races per faction: the 4 classic ones plus the faction's own Skyborne (`Config.FactionRaceIndexes`). There is no expansion detection and no support for other clients. Built on the **Ace3 addon framework** (AceAddon, AceDB, AceComm, AceConfig, AceGUI, AceConsole, AceSerializer) with LibDataBroker, LibDBIcon and LibCompress.

## Commands

The toolchain (Lua 5.1, busted, luacheck, luacov, LuaBitOp, git, svn, BigWigs packager) is packaged in a Docker image; nothing else needs to be installed on the host. Rebuild the image (`docker compose build dev`) when the `Dockerfile` changes: LuaBitOp came later, and `make netsize` needs it. Run every `make` target through it:

```bash
docker compose build dev                          # build the dev image (once)
docker compose run --rm dev                       # lint + tests
docker compose run --rm dev make lint             # luacheck on src/, tests/ and scripts/
docker compose run --rm dev make tests            # busted with coverage (fetches ./libs first if missing)
docker compose run --rm dev make tests INCLUDES=scanner        # only test files matching a Lua pattern
docker compose run --rm dev make tests TESTS='.*binary.*'     # only test names matching a Lua pattern
docker compose run --rm dev make tests BUSTED_RUN=quick       # skip coverage
docker compose run --rm dev make sim              # simulate addon traffic in a party, raid, guild, zone or on the realm channel (SCENARIO=, SIZES=, SV=, CHANNEL=nochannel)
docker compose run --rm dev make netsize          # message sizes of a full update through the real compression (SV=)
docker compose run --rm dev make fetch-libs       # re-download external libraries into ./libs
docker compose run --rm dev make release          # build a release zip into ./.release
```

Windows: `.\scripts\dev.ps1 <build|lint|tests|check|sim|netsize|libs|release|shell|deploy>` wraps the same commands; `deploy` junctions the checkout into a WoW `AddOns` folder (the `_classic_beta_` install that serves the WoW Forever beta, or `-AddOnsPath`). macOS/Linux: `make docker-*` targets. With a native Lua 5.1 toolchain the plain `make lint tests` also works (`make setup-dev` installs the rocks).

CI (`.github/workflows/ci.yml`) runs lint + tests in the same image on every PR and on pushes to `main`. Tagging `v*` runs `.github/workflows/release.yml`: the BigWigs packager (v2.6.0+ maps interface 16xxx to game type `forever`) builds the zip, creates the GitHub release and uploads to CurseForge (`X-Curse-Project-ID` in the TOC, `CF_API_KEY` secret). No WoWInterface upload: it has no WoW Forever game type and the packager fails the run.

Coverage report: `luacov.report.out`. Files not exercised by tests (WoW API dependent): `main.lua`, `options.lua`, `gui/*.lua`, `dev.lua`, `updater.lua`.

`CHANGELOG.md` is the release notes: the BigWigs packager ships it in the zip and posts it on GitHub and CurseForge (`manual-changelog` in `.pkgmeta`, else it posts the raw git log), so add every user-visible change under `Unreleased` in the PR that makes it, and rename that section to the version when tagging.

`tests/sync-e2e.lua` exercises every sync flow (login zone sync, guild sync, buddy ping, group sync, discovery beacon, ding push, faction lock, and the realm channel: join sync, ding, full sync, relay, backup) between two (for the group, three) complete addon stacks wired together through the real network envelope, one of them seeded with `tests/fixtures/horde-pve-factionrealm.lua`: real beta data, the `factionrealm` block of a SavedVariables file with `playerHistory` trimmed to the players on a leaderboard. Regenerate it the same way when the DB layout changes; data fixtures are excluded from busted's file discovery (`.busted`) and from luacheck (`.luacheckrc`).

Test output silences the addon's debug prints; set `WFR_TEST_DEBUG=1` to see them. The stubs in `tests/stubs/` expose `Set*` helpers (`SetTime`, `SetWhoResults(results, total)`, `SetIsInGuild`, `SetFaction(faction)`, `SetGroupState(members, inRaid, inInstanceGroup)`, `SetGroupMembers(members, inRaid)`, `SetGuildRoster(members)`, `SetWhoPanelVisible(visible)`, `SetChatLockdown(lockedDown)`, `SetChatChannels(names)`, `SetChannelJoinRefused(true or names)`, `SetFaction(faction)`, `SetRaceNames(names)`, `C_Timer.Advance`) to drive the world state; extend them rather than mocking inside individual tests. When the Ace3 libraries start using a new WoW global, stub it in `tests/stubs/misc.lua`; when addon code starts using a WoW API as a bare global, add it to `read_globals` in `.luacheckrc` (access through `_G.Name` needs no entry).

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
9. `Channel` -> joins the hidden realm channel, publishes `CHANNEL_JOINED`; `Tracker` sends dings there, `Sync` runs the full sync over it

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
  buddies = { [name] = { lastSeen } },  -- dropped after Config.BuddyMaxAge without contact (Sync:PruneBuddies at login)
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
- `Roster` (`src/core/roster.lua`) reads levels the client already has: the guild roster on `GUILD_ROSTER_UPDATE` (requested every 60s by `Roster:InitGuildRosterTicker`, offline members included; the row has no race, so it is resolved from the member's GUID with `GetPlayerInfoByGUID` and `Core:RaceIndexByFileString`, nil until the client knows that player) and party / raid units on `GROUP_ROSTER_UPDATE` / `UNIT_LEVEL` (name from `GetUnitName(unit, true)`, since `UnitName` returns the surname in its realm slot on this client; class and race from `UnitClass` / `UnitRace`; only units of the own faction and realm). A level is forwarded once, again when it rises, when its race turns up, or after 15 min (`RESEND_TTL`); `Roster:Refresh` (from `OnDatabaseReset` and `/wfr roster`) forgets that and reads both again right away. Rows travel as `WHO_RESULT`, so they get the same validation, leaderboard update and ding push as a scan
- Scans hang on the world clicks (`WorldFrame` `OnMouseDown`) and the minimap icon. With the option `keypressScanning` (default on) a keyboard frame that propagates its input (`Scanner:UpdateKeypressScanning`) triggers them on key presses too. `SetPropagateKeyboardInput` is protected in combat and a keyboard frame without it swallows every key, so the frame is only created out of combat (else on `PLAYER_REGEN_ENABLED`) and never touched again: turning the option off only silences its handler
- A pending scan is abandoned by a `C_Timer` after `SCAN_TIMEOUT` (`Scanner:AbandonScan`), so the who UI is handed back without a click, also when the race finished meanwhile. After a foreign `C_FriendList.SendWho` (hooked, `Scanner:OnSendWho`) an empty result is not attributed to the scan
- Player races: the 8 classic races have the client's race IDs 1-8; the new race Skyborne exists once per faction, ID 95 "High Order Skyborne" (Alliance) and ID 96 "Windshaper Skyborne" (Horde), both with the internal name `Skyborne`. The client's race table also lists every retail race and `C_CreatureInfo.GetFactionInfo` is unreliable here, so the races per faction are fixed in `Config.FactionRaceIndexes`
- A who row only carries the localized race name (`raceStr`), no ID. `Core:RaceIndexByName` resolves it against `C_CreatureInfo.GetRaceInfo(raceID).raceName` for the races of the own faction; a name that doesn't resolve (other languages may use gendered names) is an unknown race, never an error
- Race scans use the localized race name, quoted: `2-60 r-"Troll"` (`Scanner:RaceWhoFilter`). The filtered scans cycle through `Scanner:ScanSlots`, classes first: a race slot only gets a turn after a round of 9 class scans, or when no class needs a scan (`Scanner:NextDueSlot`). Floor, rest period and probe estimate work per slot, keyed by the slot's leaderboard index
- Race icons are the atlases `raceicon-<name>-male` with the names in `Config.RaceIconAtlas` (Undead is `undead`, not its internal name `scourge`)
- Class scans use the localized class name (`LocalizedClassList`), quoted: `2-60 c-"Warrior"`; `Config.WhoClassFilter` is the English fallback
- The session's first scan is an unfiltered probe (`2-60`, repeated while the leaderboard is empty). `Scanner:RecordProbe` keeps its match count, levels and classes, from which `Scanner:ProbeFloor` estimates per class where a scan fits under the row cap
- The scan floor of a class or race (`Scanner:NextClassFloor`) works from the top down: it starts at the highest level already on that leaderboard (an empty one starts at the probe's estimate, else at the bottom: 2, or the board's `minLevel` once it is full) and comes down one level per visit while the result fits under the 50 row cap. A full result sends it back up, halfway to a floor known to fit, so it settles on the lowest floor that fits, bounded above by the highest level seen (a full result from at or above that level looks one level higher, e.g. `21-60` after a full `20-60`, and doubles that step for every further full result in a row: cut off results are arbitrary, so the highest level seen can lag behind). Floors known to overflow / fit are remembered for `FLOOR_BOUND_TTL`. Player names contain a space (`"First Surname"`), never a `-`
- Chat channels: the server refuses addon messages on its own channels (General, Trade, LocalDefense, Services: `SendAddonMessage` returns success, a `NOT_ALLOWED_IN_CHANNEL` notice follows), a player-made channel carries them (`"CHANNEL"` with the channel number as target; the sender hears its own message back, without a realm in `sender`). `JoinTemporaryChannel(name)` works from a timer, is not saved with the chat settings and, without a chat frame argument, adds the channel to no chat window: Blizzard's chat frame drops messages and notices of channels that are not in its `channelList` (`Blizzard_ChatFrameBase/Mainline/ChatFrameOverrides.lua`). Joining a channel that has a password fires `CHANNEL_PASSWORD_REQUEST(channelName)`, and Blizzard's UI answers it with the `CHAT_CHANNEL_PASSWORD` dialog and a sound (`Blizzard_Game/Shared/EventImplementation.lua`); `StaticPopup_Hide("CHAT_CHANNEL_PASSWORD", channelName)` closes it. `CHAT_MSG_CHANNEL_NOTICE` is `(noticeType, ..., channelIndex, channelBaseName)` as args 1, 8 and 9; the notice type is a secret value during a chat messaging lockdown (`issecretvalue`). ChatThrottleLib only retries a send the client throttled (`AddonMessageThrottle`), a `ChannelThrottle` result drops the message
- The TOC declares the WoW Forever interface only (`## Interface: 16001`); bump it with each client patch
- The client has no API for a realm's launch time, so it is hardcoded as `Config.RealmLaunchAt` (UTC epoch). It is one global value for the single WoW Forever launch: correct it if Blizzard moves that launch, but never move it forward for a later one - everything older than it is purged on every client
- `Core:RaceStartTime` measures the race from the launch once it has passed, else (and for dings from before it) from `realmOpenedAt` / `raceStartedAt`
- The released race starts from fresh leaderboards. Once the launch has passed, `Tracker:PurgePreLaunchData` drops this faction-realm's race data and buddies from before it (beta); settings and newer data stay. It runs at login, or when the launch passes mid-session: before the next ding or sync result is processed, else from the discovery beacon
- From then on the Tracker ignores every incoming ding, pioneer record, history level and `realmOpenedAt` from before the launch (checked with `Core:PredatesLaunch`)

### Key Conventions
- Player identity format: `"Name-Realm"` (e.g. `"Nubone-NubVille"`). Our own name comes from `Core.PlayerIdentity()` (`GetUnitName("player", true)` and `GetNormalizedRealmName()`): `UnitName` / `UnitFullName("player")` return the surname in the realm slot on this client ("Offroad", "Hunt"), while every other source says "Offroad Hunt"
- Class indices: 1-12 (0 = unknown/all); valid playable classes are `Config.MopClassIndexes` (historical name: the 9 WoW Forever classes) - validate remote class indexes with `Config:IsValidClassIndex`
- Leaderboard capped at 50 players per faction-realm
- Race indexes are the client's race IDs and part of the wire and DB format - never renumber. Unknown race is nil (0 in hashes, absent on the wire); validate remote race indexes with `Core:IsValidRaceIndex`, which only accepts the races of the own faction. A known race is never replaced by an unknown one, and a record that arrives without a race falls back to the one remembered in `playerHistory`
- Leaderboard indexes: 0 overall, 1-12 classes, `Config.RaceBoardOffset + raceIndex` races. `Core:BoardIndexes(peerHashes)` lists all of them; use it wherever "every leaderboard" is meant
- Pioneers (`firstToLevel`) are overall and per class only, never per race
- "The race" is the leveling competition; the character race is always "player race" / `raceIndex`
- Race finish: the race is finished only when **every** class leaderboard in `Config.MopClassIndexes` and **every** race leaderboard of the own faction is full at `Config.MaxLevel`. `Tracker:CheckRaceFinished` is the single authority - the scanner's `SCAN_FINISHED(endofrace)` signal is verified against the boards, never trusted directly
- Remote data is untrusted: `Tracker:ProcessPlayerInfo` drops entries without a string name or with a level outside `1..Config.MaxLevel`, and only events listed in `Config.Network.Events` are accepted from the wire
- Faction lock: the race is per faction and the wire has no other way to tell the factions apart, so every message envelope is `{event, payload, faction}` (plus the realm channel number as a fourth element once it is above 1, see the realm channel). `Network:SendObject` adds `Core:MyFaction()` (`UnitFactionGroup("player")`, the value that also scopes the AceDB `factionrealm` data); `Network:HandleAddonMessage` drops a message whose faction is missing, not a string or not the own faction, before anything is published (debug print only, not counted in the message stats)
- Scanner timings (constants in `scanner.lua`): 5s cooldown between scans, doubled (up to 30s) for the rest of the session whenever a `/who` reply is lost, because the server drops queries that come in too fast and has no API for that limit, 60s timeout before an unanswered `/who` is abandoned, 15min rest for a fully-scanned class (`/who` only sees online players, so a "complete" result is just a snapshot). A result is complete only when it stays under the 50 row cap (and `C_FriendList.GetNumWhoResults()` reports no more matches than rows shown); a result of exactly 50 rows counts as cut off
- WHO results are validated against the pending query (level range + class filter, or for a race scan: no row of another known race) so manual `/who` results are never misattributed to a scan
- `Network:SendObject(..., "GROUP")` routes to `INSTANCE_CHAT` in instance groups, else `RAID`/`PARTY`
- Realm channel (`src/networking/channel.lua`): one hidden player-made chat channel per faction, `Config.RaceChannelPrefix .. faction` (`WFRaceHorde`, `WFRaceAlliance`), joined `ChannelJoinDelay` after login once the client's own channels are listed (a channel joined before them takes a low number). `Network:SendObject(..., "RACE")` resolves to `"CHANNEL"` plus the channel's current number (looked up per send), or drops the message when we are not in it. A `/leave` or kick is not fought (rejoin at the next login), a ban means no channel this session. Turning the sharing option off leaves the channel
- Channel numbers: a channel that asks for a password when we join (`CHANNEL_PASSWORD_REQUEST`, or a `WRONG_PASSWORD` notice) is given up for the same name with the next number (`WFRaceHorde2`, ... up to `ChannelMaxIndex`, `Channel:OnLocked`). Every login starts at the first name again, nothing is saved. Players who were in a channel before it got its password stay in it, and once the password is gone new logins land on the old name again, so two names alone would split the realm into groups that stop syncing. Hence the highest number wins: from the second name on, every envelope carries the sender's channel number as its fourth element (`Network:ChannelIndexTag`), and a client that hears a higher one moves there (`Network:FollowChannel`, `Channel:MoveTo`; it leaves the old channel `ChannelJoinRetry` later). Heard on our own channel, everybody on it heard it too. Heard elsewhere (a whisper, yell, guild or group message of a player on the higher channel), we pass it on to our channel first as `CHMOVE`, after a random `ChannelMoveDelay` and only if nobody else did. A move with the whole channel keeps the settle state and the players heard, and runs a regular sync round at a random moment within `ChannelFollowUp` instead of a join round (`ChannelJoined` carries `moved`). Never probe a lower or locked channel again: each attempt opens the client's password dialog with a sound, which `Channel:OnPasswordRequest` hides
- The realm channel is the main sync path, everything else is its backup. `Channel:IsLive()` is true while we are in the channel and heard another player on it within `ChannelLiveTTL` (an addon message of our faction on `"CHANNEL"`, or an offer answering our announce): only then is the channel known to carry traffic. While it is live a client starts none of the older flows (ding yell / group / guild / buddy pushes, discovery beacon, periodic guild sync, buddy pings, group sync) but still answers them, so players outside the channel keep being served. While it is joined but not live, dings go to the channel and to the backup paths. The login sync (`InitSync`: zone `REQSYNC` and guild) runs before the channel is joined and is unchanged
- Dings on the channel (`Tracker:ScheduleChannelDingPush`): one `PINFOB` `{batchstr, false, 0}` to `"RACE"` after a random `ChannelDingDelayMin..Max`. Many clients spot the same level-up: a waiting ding is dropped when the channel brought the same level at the same or an earlier time, or a higher level, meanwhile (`DropHeardDings`), and at send time when our leaderboards no longer hold it as we saw it (`DingStillStands`). For `ChannelSettleTime` after joining, our own dings wait (the join sync may show they are old news). What reaches a settled client outside the channel and changes its leaderboards (a whispered / group `SYNC`, a `PINFOB` by yell, guild, group or whisper) is passed on to the channel the same way (`RelayToChannel`), never what came from the channel itself and nothing while settling. A change is a new player, a higher level, or an earlier time for the level we already had (`Leaderboard:ProcessPlayerInfo` reports that as its fourth return, `Tracker:ProcessPlayerInfo` as its third); an earlier time alone is no `DING`, so nothing is announced in chat for it
- Full sync over the channel (`Sync:SendChannelSync`): at the join, then about every `ChannelSyncInterval` (+-25%, `InitChannelTicker`). `CHSYNC` `{fullHash, ftlHash}` to `"RACE"`; a ready client whose hashes differ whispers `CHOFFR` `{fullHash, ftlHash}` after a random delay, with chance `ChannelOfferTarget / Channel:Size()` (the players heard on the channel within a sync interval), so about `ChannelOfferTarget` offers come back whatever the channel size. After `ChannelSyncWait` the announcer whispers a `BPING` to one random offerer and the two trade their differing boards and pioneers like buddies do; the partner's gains reach everyone through `RelayToChannel`. Full boards never go to the channel. The join round's `BPING` carries the history hash as field 4 when no login sync brought history yet (the partner answers with `PHSYNC`), and restarts the settle time. A trade that brought us new players is followed by another round after `ChannelFollowUp` (`FollowUpChannelSync`), one that brought nothing is not
- The group is used freely, but a raid multiplies every group message by up to 40 senders and 39 receivers. `Sync:ScheduleGroupSync` (BPING to `GROUP`, debounced 2s) runs on `GROUP_ROSTER_UPDATE`, once the login sync is done (`SetReady`, for a login or `/reload` inside a group) and every `Config.GroupSyncInterval` (`Sync:InitGroupTicker`). A member already in sync does not answer a group BPING (`OnNetBuddyPing` gets the distribution from `Network:HandleAddonMessage`, which publishes every wire event as `(payload, sender, distribution)`), so a converged raid costs one message per member per interval; `SendBuddyPings` skips buddies in the group. A ding push goes to `GROUP` right away next to the zone `YELL`, except for a batch from the group roster (`Config.WhoResultSources.Group`), which every member reads itself
- A group ping never makes members trade data in pairs. A member that differs only whispers its hashes back (BPONG with `true` as field 4). `Sync:SendGroupSync` opens a round (`self.groupRound`): after `Config.GroupSyncWait` the pinger sends every board any of those members lacks to `GROUP` once (`PushGroupRound`, a late pong only adds boards nobody sent yet that round) and picks one of them at random (`AskGroupResponder`), whose STARTSYNC carries `true` as field 5: that member sends its boards that differ from the pinger's to `GROUP` (`OnNetStartSync`). So a ping has at most two senders of data, heard by every member; what the other members hold goes out on their own ping. Group sync never negotiates player history
- The guild sync partner is picked at random among the offers (`Sync:DoGuildSync`), so no member serves the whole guild; `loginTime` still rides along in `GUILDSYNC` / `GUILDOFFR` but decides nothing
- Discovery beacon: a client sends at most one `DATAREQ` per `Config.DataRequestInterval` (`Tracker:OnNetDataAvailable`) and waits for that answer instead of asking every beacon of a crowded zone. A discovery answer (`Tracker:SendBatches`) is `PINFOB` `{batchstr, true, boardIndex, batchHash}`, a ding push `{batchstr, false, 0}`. `batchHash` hashes the players the answer sends for that board (`Tracker:BatchPlayers`: a class or race board leaves out the players on the sender's overall board), never the whole board: two owners with the same class board but different overall boards send different players for it. `Tracker:CollectBoardYell` gathers the chunks of a discovery yell heard and records it (`Tracker:RecordBoardYell`) only once the players received hash to what it announced: the announced hash alone is untrusted, a yell without the players never counts. Before each of its own yell chunks an owner skips a board when another player's answer sent exactly the players its own would send now since its window opened (`Tracker:BoardYellTaken`). Different data is always yelled, so listeners keep the earliest ding; of two owners that both started the same data, the lower name finishes it
- Buddies not heard from for `Config.BuddyMaxAge` (3 days) are dropped at every login (`Sync:PruneBuddies`); there is no cap on the count, pings and ding pushes sample `BuddyPingBatchSize` of them
- Race leaderboards sync through the per-board hash tables only (discovery beacon, guild sync, buddy ping/pong, group sync); the login handshake (`REQSYNC` / `OFFERSYNC` / zone `STARTSYNC`) still exchanges just the overall and the own class leaderboard
- Chat announcements: the top N sliders `globalTopN`, `classTopN` and `raceTopN` (default 1: only the first of a race) gate a ding; it is always one chat line, the race rank is appended to the class / overall message or gets its own message when only the race gate passes. With `raceTopN` 0 the output is exactly the class / overall one
- Peers can track a different class list (other client, older build on the shared `TCRace` prefix). Wherever a peer's per-board hash table (index i+1 = `leaderboard[i]`, classes and races) is available (`GUILDSYNC`, `BPING`, `BPONG`, `DATAREQ`), full, FTL and per-board comparisons only cover the leaderboards that peer reported (`Config:BoardIndexes(faction, peerHashes)`, `Tracker:ComputeNeedSet`); a missing entry means "not tracked", never "differs". The discovery beacon (`DATAAVAIL`) carries only the full hash, so such peers still cost one `DATAREQ` round trip per beacon, which then sends nothing
- Network event names: `PINFOB`, `REQSYNC`, `OFFERSYNC`, `STARTSYNC`, `SYNC`, `DATAAVAIL`, `DATAREQ`, `GUILDSYNC`, `GUILDOFFR`, `BPING`, `BPONG`, `FTLSYNC`, `PHSYNC`, `CHSYNC`, `CHOFFR`, `CHMOVE`
- Local event names: `NETWORK_READY`, `CHANNEL_JOINED`, `WHO_RESULT`, `SYNC_RESULT`, `FTL_SYNC_RESULT`, `PH_SYNC_RESULT`, `SCAN_FINISHED`, `RACE_FINISHED`, `DING`, `REFRESH_GUI`, `MSG_STATS`, `BUDDY_UPDATE`
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
| `src/core/sync.lua` | Login / guild / buddy / group / realm channel sync negotiation |
| `src/networking/channel.lua` | Joins the hidden realm channel, tracks who is heard on it (live, size) |
| `src/core/serializer.lua` | Network encoding/decoding |
| `src/dev.lua` | Dev-only slash commands (unpackaged checkout only) |
| `media/icon.tga` | In-game icon, 64x64 (TOC `IconTexture`, minimap button); `icon.svg` is its source, `logo.svg` / `logo.png` the full logo. Only the TGA is packaged |
| `tests/testbase.lua` | Test bootstrap: stubs, libs, addon sources. Loads a pass-through LibCompress, or the real one when `WFR_REAL_LIBCOMPRESS` is set (scripts that measure sizes) |
| `tests/stubs/` | WoW API stubs with `Set*` helpers |
| `tests/sync-e2e.lua` | Two addon stacks syncing real data end to end over the network envelope; three for group sync |
| `tests/fixtures/` | Generated data fixtures (`return {...}`), not test files |
| `.busted` | busted config (roots, patterns, `quick` run without coverage) |
| `.luacheckrc` | Luacheck config: Lua 5.1 std, WoW API read-only globals, test rules |
| `.luacov` | Coverage config |
| `.luarc.json` | Lua Language Server config (editor completion / diagnostics) |
| `Dockerfile`, `docker-compose.yml` | Dev toolchain image |
| `scripts/dev.ps1` | Windows wrapper: docker targets + deploy into WoW AddOns |
| `scripts/groupsim.lua` | Traffic simulation (`make sim`): 5 / 40 complete addon stacks in one group over the real network envelope, paced like ChatThrottleLib; reports messages, bytes, queueing and time to get back in sync per scenario. `guild` and `zone` put the stacks in one guild (out of yell range) or in one crowded zone instead, the `realm*` scenarios leave them only the realm channel. Every stack is in the realm channel unless `CHANNEL=nochannel` (the backup flows alone). Runs against older checkouts too, to compare versions: copy the script into a checkout of the older version |
| `scripts/netsize.lua` | Message sizes (`make netsize`): every leaderboard, the pioneers and the login history pull, sent the way the addon sends them through the real serializer, LibCompress and AceComm chunking, with the ChatThrottleLib cost of each. Run it again when the wire format changes |
| `.github/workflows/` | CI (lint + tests) and tag-triggered release packaging |
| `CHANGELOG.md` | Release notes, shipped in the zip and posted on CurseForge by the packager |
