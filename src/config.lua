local WoWForeverRace = _G.WoWForeverRace

---@class WoWForeverRaceColors
local WoWForeverRaceColors = {
    WHITE = "|cFFFFFFFF",
    SYSTEM_EVENT_YELLOW = "|cFFFFFF00",
    BROWN       = "|cFFEDA55F",
    WARRIOR        = "|cFFC79C6E",
    PALADIN        = "|cFFF58CBA",
    HUNTER      = "|cFFABD473",
    ROGUE        = "|cFFFFF569",
    PRIEST        = "|cFFFFFFFF",
    SHAMAN        = "|cFF0070DE",
    MAGE        = "|cFF69CCF0",
    WARLOCK        = "|cFF9482C9",
    DRUID       = "|cFFFF7D0A",
}
WoWForeverRace.Colors = WoWForeverRaceColors

---@class WoWForeverRaceConfig
local WoWForeverRaceConfig = {
    Version = "@project-version@",
    Debug = false,
    Trace = false,
    --@debug@
    Debug = true,
    Trace = false,
    --@end-debug@

    -- WoW Forever level cap
    MaxLevel = 60,
    MaxLeaderboardSize = 50,

    -- Official realm launch, 2026-11-04 23:00 UTC (2026-11-05 00:00 GMT+1), as server time (UTC epoch).
    -- There is no API for this. One global value for the single WoW Forever launch: correct it if that
    -- launch moves, but never move it forward for a later one - once it has passed, every client purges
    -- the race data from before it. nil falls back to the inferred timestamps and purges nothing.
    RealmLaunchAt = 1793833200,

    -- The characters whose realm-wide reset (Tracker:OnNetReset, sent by the dev command
    -- /wfr resetall) every client accepts, until the realm launch. The server sets the
    -- sender of an addon message, so nobody else can pose as them.
    ResetAuthors = {
        ["Offroad Dverg"] = true,
        ["Offroad Hunt"] = true,
    },

    -- OfferSync throttle time window
    RequestSyncWait = 5,
    RetrySyncWait = 30,
    OfferSyncThrottle = 30,

    -- display name used by every window title, the minimap tooltip and the LDB text
    Name = "WoWForeverRace",
    AceConfig = "WoWForeverRace",
    LDB = "WoWForeverRace",

    -- The 9 WoW Forever classes. The indexes are part of the wire and DB format
    -- (shared with TheClassicRace), so the gaps of the classes that don't exist
    -- here (6, 10, 12) stay: never renumber.
    Classes = {
        [1] = "WARRIOR",
        [2] = "PALADIN",
        [3] = "HUNTER",
        [4] = "ROGUE",
        [5] = "PRIEST",
        [7] = "SHAMAN",
        [8] = "MAGE",
        [9] = "WARLOCK",
        [11] = "DRUID",
    },

    -- Indexes of the playable classes, Paladin and Shaman on both factions
    -- (name is historical)
    MopClassIndexes = {1, 2, 3, 4, 5, 7, 8, 9, 11},

    -- English class names used in /who query filters (c-ClassName)
    WhoClassFilter = {
        WARRIOR     = "Warrior",
        PALADIN     = "Paladin",
        HUNTER      = "Hunter",
        ROGUE       = "Rogue",
        PRIEST      = "Priest",
        SHAMAN      = "Shaman",
        MAGE        = "Mage",
        WARLOCK     = "Warlock",
        DRUID       = "Druid",
    },

    -- ClassIndexes is inverse of Classes
    UnknownClassIndex = 0,
    ClassIndexes = {
        WARRIOR = 1,
        PALADIN = 2,
        HUNTER = 3,
        ROGUE = 4,
        PRIEST = 5,
        SHAMAN = 7,
        MAGE = 8,
        WARLOCK = 9,
        DRUID = 11,
    },

    PrettyClassNames = {
        WARRIOR = "Warrior",
        PALADIN = "Paladin",
        HUNTER = "Hunter",
        ROGUE = "Rogue",
        PRIEST = "Priest",
        SHAMAN = "Shaman",
        MAGE = "Mage",
        WARLOCK = "Warlock",
        DRUID = "Druid",
    },

    -- The playable races, by the client's race ID. Like the class indexes these are
    -- part of the wire and DB format: never renumber. The value is the client's
    -- internal name (clientFileString); Skyborne exists once per faction.
    UnknownRaceIndex = 0,
    Races = {
        [1] = "Human",
        [2] = "Orc",
        [3] = "Dwarf",
        [4] = "NightElf",
        [5] = "Scourge",
        [6] = "Tauren",
        [7] = "Gnome",
        [8] = "Troll",
        [95] = "Skyborne",
        [96] = "Skyborne",
    },

    -- The races each faction tracks, also the order of the race scans and race icons.
    -- The client can't tell (C_CreatureInfo.GetFactionInfo is unreliable on WoW Forever)
    FactionRaceIndexes = {
        Alliance = {1, 3, 4, 7, 95},
        Horde = {2, 5, 6, 8, 96},
    },

    -- English race names, the fallback when the client has no localized name
    RaceNames = {
        [1] = "Human",
        [2] = "Orc",
        [3] = "Dwarf",
        [4] = "Night Elf",
        [5] = "Undead",
        [6] = "Tauren",
        [7] = "Gnome",
        [8] = "Troll",
        [95] = "High Order Skyborne",
        [96] = "Windshaper Skyborne",
    },

    -- the <name> in the raceicon-<name>-male atlas (Undead is not named after its clientFileString)
    RaceIconAtlas = {
        [1] = "human",
        [2] = "orc",
        [3] = "dwarf",
        [4] = "nightelf",
        [5] = "undead",
        [6] = "tauren",
        [7] = "gnome",
        [8] = "troll",
        [95] = "skyborne",
        [96] = "skyborne",
    },

    -- A race leaderboard lives at leaderboard[RaceBoardOffset + raceIndex], clear of
    -- the overall board (0) and the class boards (1-12) the race IDs would collide with
    RaceBoardOffset = 100,

    BroadcastInterval = 60,
    YellChunkSize = 10,
    YellChunkDelay = 2,
    DataRequestInterval = 10,  -- at most one DATAREQ per 10s: wait for that answer instead of asking every beacon

    GuildSyncInterval = 300,   -- periodic guild sync every 5 minutes
    GuildSyncWait = 10,        -- seconds to collect guild offers before picking a partner

    BuddySyncInterval = 600,   -- buddy ping every 10 minutes
    BuddyPingBatchSize = 50,   -- max buddies to ping per cycle (random sample if more)
    BuddyMaxAge = 3 * 24 * 60 * 60, -- buddies not heard from for 3 days are dropped at login

    GroupSyncInterval = 300,   -- group sync every 5 minutes while grouped (members already in sync don't answer)
    GroupSyncWait = 5,         -- seconds a group pinger collects pongs before sending to the group

    DingPushDelay = 10,        -- seconds to batch dings before pushing to guild + buddies

    -- Realm channel: a hidden player-made chat channel per faction (RaceChannelPrefix .. faction)
    -- that every addon user of the faction joins. While it carries traffic it is the main
    -- path, and yell, guild, group and buddy sync only run as its backup, see Channel:IsLive.
    RaceChannelPrefix = "WFRace",
    -- A channel that asks for a password is given up for the same name with the next number
    -- (WFRaceHorde2, ...), and the highest number any player is on wins, see Channel:MoveTo
    ChannelMaxIndex = 5,       -- the last number tried
    ChannelMoveDelay = 5,      -- a move heard outside the channel is passed on to it after a random delay up to this
    ChannelJoinDelay = 10,     -- seconds after login before the first join attempt
    ChannelJoinRetry = 5,      -- seconds between join checks
    ChannelJoinMaxWait = 60,   -- join anyway when the client's own channels didn't show up by then
    ChannelJoinAttempts = 5,   -- joins tried before giving up for the session
    -- the channel counts as live this long after another player was heard on it: longer than
    -- the longest gap between two full syncs of one player, so two players keep it live
    ChannelLiveTTL = 4800,
    ChannelSettleTime = 60,    -- after joining, our own dings wait this long for the join sync (they may be old news)
    ChannelDingDelayMin = 2,   -- a ding goes to the channel after a random delay in this range: of the
    ChannelDingDelayMax = 6,   -- clients that spot the same ding, the first to send makes the others drop theirs
    ChannelSyncInterval = 3600, -- full sync over the channel, about once per hour (+-25%)
    ChannelSyncWait = 10,      -- seconds to collect channel offers before picking a partner
    ChannelFollowUp = 300,     -- a full sync that brought us new players is followed by another one this soon
    ChannelOfferTarget = 5,    -- offers a channel sync should draw, however many players are on the channel

    -- playerHistory sync: potentially large (hundreds of players x dozens of levels),
    -- so it's transferred only once per login (pull-only, toward the player who just
    -- logged in) and chunked to stay friendly to the addon channel throttle
    PlayerHistoryChunkSize = 20,   -- players per PHSYNC message
    PlayerHistoryChunkDelay = 2,   -- seconds between PHSYNC messages

    Network = {
        Prefix = "TCRace",
        Events = {
            PlayerInfoBatch = "PINFOB",
            RequestSync = "REQSYNC",
            OfferSync = "OFFERSYNC",
            StartSync = "STARTSYNC",
            SyncPayload = "SYNC",
            DataAvailable = "DATAAVAIL",
            DataRequest = "DATAREQ",
            GuildSync = "GUILDSYNC",
            GuildOffer = "GUILDOFFR",
            BuddyPing = "BPING",
            BuddyPong = "BPONG",
            FTLSync = "FTLSYNC",
            PlayerHistorySync = "PHSYNC",
            ChannelSync = "CHSYNC",
            ChannelOffer = "CHOFFR",
            ChannelMove = "CHMOVE",
            Reset = "RESET",
        },
    },
    Events = {
        NetworkReady = "NETWORK_READY",
        ChannelJoined = "CHANNEL_JOINED",
        -- ChannelHeard(sender): a player of our faction sent something on the realm channel
        ChannelHeard = "CHANNEL_HEARD",
        SlashWhoResult = "WHO_RESULT",
        SyncResult = "SYNC_RESULT",
        FTLSyncResult = "FTL_SYNC_RESULT",
        PHSyncResult = "PH_SYNC_RESULT",
        Ding = "DING",
        -- ScanFinished(endofrace)
        -- should use RaceFinished though if interested in when the race is finished,
        -- because that's only broadcasted once
        ScanFinished = "SCAN_FINISHED",
        RaceFinished = "RACE_FINISHED",
        RefreshGUI = "REFRESH_GUI",
        -- the race data was reset from the network (Tracker:ApplyReset): start over
        DataReset = "DATA_RESET",
        MsgStats = "MSG_STATS",
        BuddyUpdate = "BUDDY_UPDATE",
    },
    -- optional second argument of a WHO_RESULT: where the batch came from, when
    -- that matters to the tracker (nil for /who scans and everything else)
    WhoResultSources = {
        -- party / raid unit levels, which every group member reads itself
        Group = "group",
    },
}
WoWForeverRace.Config = WoWForeverRaceConfig

-- The version to show to the player. An unpackaged checkout still holds the packager's
-- placeholder (it starts with "@"; not spelled out here, the packager would replace it too).
function WoWForeverRaceConfig:DisplayVersion()
    local version = self.Version
    if type(version) ~= "string" or version == "" or version:sub(1, 1) == "@" then
        return "development"
    end
    return version
end

function WoWForeverRaceConfig:IsValidClassIndex(classIndex)
    for _, validClassIndex in ipairs(self.MopClassIndexes) do
        if classIndex == validClassIndex then
            return true
        end
    end

    return false
end

function WoWForeverRaceConfig:RaceIndexes(faction)
    return self.FactionRaceIndexes[faction] or {}
end

function WoWForeverRaceConfig:IsValidRaceIndex(raceIndex, faction)
    for _, validRaceIndex in ipairs(self:RaceIndexes(faction)) do
        if raceIndex == validRaceIndex then
            return true
        end
    end

    return false
end

function WoWForeverRaceConfig:RaceBoardIndex(raceIndex)
    return self.RaceBoardOffset + raceIndex
end

-- Every leaderboard index of a faction: overall (0), the classes, the faction's races.
-- peerHashes: optional per-board hash table received from a peer (index i+1 =
-- leaderboard[i]). Peers can track other boards (other client, older build), so when
-- given, only the boards that peer reported are included: a missing entry means
-- "not tracked", never "differs". Without this such a board looks like a difference
-- forever and is re-sent on every sync round.
function WoWForeverRaceConfig:BoardIndexes(faction, peerHashes)
    local indexes = {0}
    local function add(boardIndex)
        if type(peerHashes) ~= "table" or peerHashes[boardIndex + 1] ~= nil then
            indexes[#indexes + 1] = boardIndex
        end
    end
    for _, classIndex in ipairs(self.MopClassIndexes) do
        add(classIndex)
    end
    for _, raceIndex in ipairs(self:RaceIndexes(faction)) do
        add(self:RaceBoardIndex(raceIndex))
    end
    return indexes
end
