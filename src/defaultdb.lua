local WoWForeverRace = _G.WoWForeverRace

---@class WoWForeverRaceDefaultDB
local WoWForeverRaceDefaultDB = {
    profile = {
        options = {
            minimap = {
                hide = false,
            },
            networking = true,
            keypressScanning = true,
            scanCooldown = 10,
            maxLevelNotify = true,
            classTopN = 1,
            raceTopN = 1,
            globalTopN = 1,
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
    -- shared by every character of the account: nothing of the race belongs here
    global = {
        -- newerVersion = {buildTime, version}: the newest build other players announced,
        -- dropped at login once we run it (VersionCheck)
        newerVersion = nil,
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
        -- resetAt: time of the latest realm-wide reset (Tracker:ApplyReset); race data from before it
        -- is neither kept nor accepted
        resetAt = nil,
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
        -- whether the buddies were emptied once for the realm channel per ruleset: the
        -- faction-only channel made players of every ruleset buddies, see DBMigrations
        buddiesPerRuleset = false,
    },
}

WoWForeverRace.DefaultDB = WoWForeverRaceDefaultDB

-- Empties the race data of the faction-realm the AceDB `db` belongs to and returns its
-- fresh factionrealm table, filled with the defaults. Only that one: the SavedVariables
-- table is shared by the whole account and holds a faction-realm per faction and ruleset,
-- which AceDB's own db:ResetDB() would empty together with every profile.
function WoWForeverRace.ResetFactionRealm(db)
    local saved = db.sv.factionrealm
    if saved then
        saved[db.keys.factionrealm] = nil
    end
    -- the next access creates the section anew from the defaults
    rawset(db, "factionrealm", nil)
    return db.factionrealm
end
