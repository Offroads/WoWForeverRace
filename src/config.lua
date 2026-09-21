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

    GuildSyncInterval = 300,   -- periodic guild sync every 5 minutes
    GuildSyncWait = 10,        -- seconds to collect guild offers before picking a partner

    BuddySyncInterval = 600,   -- buddy ping every 10 minutes
    BuddyPingBatchSize = 50,   -- max buddies to ping per cycle (random sample if more)

    DingPushDelay = 10,        -- seconds to batch dings before pushing to guild + buddies

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
        },
    },
    Events = {
        NetworkReady = "NETWORK_READY",
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
        MsgStats = "MSG_STATS",
        BuddyUpdate = "BUDDY_UPDATE",
    },
}
WoWForeverRace.Config = WoWForeverRaceConfig

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
