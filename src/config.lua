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
    DEATHKNIGHT = "|cFFC41F3B",
    SHAMAN        = "|cFF0070DE",
    MAGE        = "|cFF69CCF0",
    WARLOCK        = "|cFF9482C9",
    MONK        = "|cFF00FF96",
    DRUID       = "|cFFFF7D0A",
    DEMONHUNTER = "|cFFEDA55F",
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

    -- defaults target WoW Forever, overwritten at startup by ApplyExpansionConfig
    MaxLevel = 60,
    MaxLeaderboardSize = 50,

    -- OfferSync throttle time window
    RequestSyncWait = 5,
    RetrySyncWait = 30,
    OfferSyncThrottle = 30,

    -- display name used by every window title, the minimap tooltip and the LDB text
    Name = "WoWForeverRace",
    AceConfig = "WoWForeverRace",
    LDB = "WoWForeverRace",

    Classes = {
        "WARRIOR",
        "PALADIN",
        "HUNTER",
        "ROGUE",
        "PRIEST",
        "DEATHKNIGHT",
        "SHAMAN",
        "MAGE",
        "WARLOCK",
        "MONK",
        "DRUID",
        "DEMONHUNTER",
    },

    -- Class indexes playable on the running client (name is historical), filled
    -- from ExpansionData at startup. Default: the 9 WoW Forever classes
    MopClassIndexes = {1, 2, 3, 4, 5, 7, 8, 9, 11},

    -- English class names used in /who query filters (c-ClassName)
    WhoClassFilter = {
        WARRIOR     = "Warrior",
        PALADIN     = "Paladin",
        HUNTER      = "Hunter",
        ROGUE       = "Rogue",
        PRIEST      = "Priest",
        DEATHKNIGHT = "Death Knight",
        SHAMAN      = "Shaman",
        MAGE        = "Mage",
        WARLOCK     = "Warlock",
        MONK        = "Monk",
        DRUID       = "Druid",
        DEMONHUNTER = nil,
    },

    -- ClassIndexes is inverse of Classes
    UnknownClassIndex = 0,
    ClassIndexes = {
        WARRIOR = 1,
        PALADIN = 2,
        HUNTER = 3,
        ROGUE = 4,
        PRIEST = 5,
        DEATHKNIGHT = 6,
        SHAMAN = 7,
        MAGE = 8,
        WARLOCK = 9,
        MONK = 10,
        DRUID = 11,
        DEMONHUNTER = 12,
    },

    PrettyClassNames = {
        WARRIOR = "Warrior",
        PALADIN = "Paladin",
        HUNTER = "Hunter",
        ROGUE = "Rogue",
        PRIEST = "Priest",
        DEATHKNIGHT = "DK",
        SHAMAN = "Shaman",
        MAGE = "Mage",
        WARLOCK = "Warlock",
        MONK = "Monk",
        DRUID = "Druid",
        DEMONHUNTER = "Poo",
    },

    ExpansionData = {
        -- WoW Forever: level 60, Paladin and Shaman playable by both factions
        FOREVER = { maxLevel = 60,  validClassIndexes = {1,2,3,4,5,7,8,9,11} },
        CLASSIC = { maxLevel = 60,  validClassIndexes = {1,2,3,4,5,7,8,9,11}, hordeOnly = {7}, allianceOnly = {2} },
        TBC     = { maxLevel = 70,  validClassIndexes = {1,2,3,4,5,7,8,9,11} },
        WRATH   = { maxLevel = 80,  validClassIndexes = {1,2,3,4,5,6,7,8,9,11} },
        CATA    = { maxLevel = 85,  validClassIndexes = {1,2,3,4,5,6,7,8,9,11} },
        MOP     = { maxLevel = 90,  validClassIndexes = {1,2,3,4,5,6,7,8,9,10,11} },
        WOD     = { maxLevel = 100, validClassIndexes = {1,2,3,4,5,6,7,8,9,10,11} },
        LEGION  = { maxLevel = 110, validClassIndexes = {1,2,3,4,5,6,7,8,9,10,11,12} },
    },

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

function WoWForeverRaceConfig:DetectExpansion()
    local _, _, _, tocVersion = GetBuildInfo()
    -- WoW Forever is the 1.60+ client line, Classic Era stays on 1.13-1.15
    if tocVersion >= 16000 and tocVersion < 20000 then
        return "FOREVER"
    elseif tocVersion < 20000 then
        return "CLASSIC"
    elseif tocVersion < 30000 then
        return "TBC"
    elseif tocVersion < 40000 then
        return "WRATH"
    elseif tocVersion < 50000 then
        return "CATA"
    elseif tocVersion < 60000 then
        return "MOP"
    elseif tocVersion < 70000 then
        return "WOD"
    else
        return "LEGION"
    end
end
