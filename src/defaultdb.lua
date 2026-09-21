local WoWForeverRace = _G.WoWForeverRace

---@class WoWForeverRaceDefaultDB
local WoWForeverRaceDefaultDB = {
    profile = {
        options = {
            minimap = {
                hide = false,
            },
            networking = true,
            keypressScanning = false,
            maxLevelNotify = true,
            classTopN = 3,
            raceTopN = 1,
            globalTopN = 5,
            debug = false,
        },
        gui = {
            display = true,
            statusFrameStatus = {
                width = 240,
                height = 240,
            },
        },
    },
    factionrealm = {
        dbversion = "0.0.0",
        finished = false,
        buddies = {},
        leaderboard = {
            ['**'] = {
                minLevel = 2,
                highestLevel = 1,
                players = {},
            },
        },
        -- Pioneers: first player to reach each level
        -- realmOpenedAt: GetServerTime() recorded on first-ever DB init for this realm; synced to keep earliest.
        -- Once the realm launch has passed, a value from before it is raised to the launch and not accepted on sync
        realmOpenedAt = nil,
        -- raceStartedAt: earliest dingedAt seen (since the realm launch, once it passed); fallback reference when realmOpenedAt is nil
        raceStartedAt = nil,
        -- playerHistory[name] = {classIndex, levels = {[level] = dingedAt}}
        -- synced once per login (leaderboard players only); non-members are pruned on
        -- login once the leaderboard they compete on is final (full at max level)
        playerHistory = {},
        -- firstToLevel[classFilter][level] = {name, classIndex, dingedAt}
        -- classFilter 0 = overall, 1-12 = per class (see Config.ClassIndexes)
        firstToLevel = {},
        pioneersMigrated = false,
    },
}

WoWForeverRace.DefaultDB = WoWForeverRaceDefaultDB
