-- load test base
local WoWForeverRace = require("testbase")

local function merge(...)
    local config = {}
    for _, c in pairs({...}) do
        for k, v in pairs(c) do
            config[k] = v
        end
    end

    return config
end

describe("Leaderboard", function()
    ---@type WoWForeverRaceConfig
    local config
    local db
    local dbboard
    ---@type WoWForeverRaceLeaderboard
    local leaderboard
    local time = 1000000000

    local base = {dingedAt = time, classIndex = 11}

    before_each(function()
        config = merge(WoWForeverRace.Config, {MaxLeaderboardSize = 5})
        db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
        db:ResetDB()
        dbboard = db.factionrealm.leaderboard[0]
        leaderboard = WoWForeverRace.Leaderboard(config, dbboard)
    end)

    describe("ComputeHash", function()
        it("returns same hash for same data", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})
            leaderboard:ProcessPlayerInfo({name = "Nub2", level = 4, dingedAt = time, classIndex = 11})
            local h1 = WoWForeverRace.Leaderboard.ComputeHash(dbboard)
            local h2 = WoWForeverRace.Leaderboard.ComputeHash(dbboard)
            assert.equals(h1, h2)
        end)

        it("returns different hash when a player is added", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})
            local h1 = WoWForeverRace.Leaderboard.ComputeHash(dbboard)
            leaderboard:ProcessPlayerInfo({name = "Nub2", level = 4, dingedAt = time, classIndex = 11})
            local h2 = WoWForeverRace.Leaderboard.ComputeHash(dbboard)
            assert.not_equals(h1, h2)
        end)

        it("returns different hash when a player levels up", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})
            local h1 = WoWForeverRace.Leaderboard.ComputeHash(dbboard)
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 6, dingedAt = time, classIndex = 11})
            local h2 = WoWForeverRace.Leaderboard.ComputeHash(dbboard)
            assert.not_equals(h1, h2)
        end)

        it("returns different hash when dingedAt changes", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time + 10, classIndex = 11})
            local h1 = WoWForeverRace.Leaderboard.ComputeHash(dbboard)
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})
            local h2 = WoWForeverRace.Leaderboard.ComputeHash(dbboard)
            assert.not_equals(h1, h2)
        end)

        it("returns consistent hash for empty leaderboard", function()
            local h1 = WoWForeverRace.Leaderboard.ComputeHash(dbboard)
            local h2 = WoWForeverRace.Leaderboard.ComputeHash(dbboard)
            assert.equals(h1, h2)
        end)

        it("is insertion-order independent", function()
            local players = {
                {name = "Alice", level = 6, dingedAt = time, classIndex = 3},
                {name = "Bob", level = 5, dingedAt = time - 10, classIndex = 1},
                {name = "Zebra", level = 5, dingedAt = time, classIndex = 11},
                {name = "Aardvark", level = 5, dingedAt = time, classIndex = 0},
            }

            leaderboard:ProcessPlayerInfo(players[1])
            leaderboard:ProcessPlayerInfo(players[2])
            leaderboard:ProcessPlayerInfo(players[3])
            leaderboard:ProcessPlayerInfo(players[4])
            local h1 = WoWForeverRace.Leaderboard.ComputeHash(dbboard)

            local dbboard2 = db.factionrealm.leaderboard[1]
            local leaderboard2 = WoWForeverRace.Leaderboard(config, dbboard2)
            leaderboard2:ProcessPlayerInfo(players[4])
            leaderboard2:ProcessPlayerInfo(players[3])
            leaderboard2:ProcessPlayerInfo(players[2])
            leaderboard2:ProcessPlayerInfo(players[1])
            local h2 = WoWForeverRace.Leaderboard.ComputeHash(dbboard2)

            assert.equals(h1, h2)
            assert.same(dbboard.players, dbboard2.players)
        end)
    end)

    describe("SortPlayers", function()
        it("orders legacy data canonically", function()
            local players = {
                {name = "Zebra", level = 5, dingedAt = time, classIndex = 11},
                {name = "NoDing", level = 5, classIndex = 1},
                {name = "Aardvark", level = 5, dingedAt = time, classIndex = 0},
                {name = "Top", level = 7, dingedAt = time, classIndex = 3},
                {name = "Early", level = 5, dingedAt = time - 10, classIndex = 1},
            }
            WoWForeverRace.Leaderboard.SortPlayers(players)

            assert.same({"Top", "Early", "Aardvark", "Zebra", "NoDing"},
                    {players[1].name, players[2].name, players[3].name, players[4].name, players[5].name})
        end)
    end)

    describe("leaderboard", function()
        it("adds players", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub2", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub3", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub4", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub5", level = 5, classIndex = 6}, base), false)

            assert.equals(5, #dbboard.players)
            assert.same({
                merge({name = "Nub1", level = 5, classIndex = 11}, base),
                merge({name = "Nub2", level = 5, classIndex = 11}, base),
                merge({name = "Nub3", level = 5, classIndex = 11}, base),
                merge({name = "Nub4", level = 5, classIndex = 11}, base),
                merge({name = "Nub5", level = 5, classIndex = 6}, base),
            }, dbboard.players)
        end)

        it("doesn't add duplicates", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)

            assert.equals(1, #dbboard.players)
        end)

        it("doesn't add beyond max", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub2", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub3", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub4", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub5", level = 5}, base), false)
            -- max
            leaderboard:ProcessPlayerInfo(merge({name = "Nub6", level = 5}, base), false)
            assert.equals(5, #dbboard.players)
            assert.same({
                merge({name = "Nub1", level = 5, classIndex = 11}, base),
                merge({name = "Nub2", level = 5, classIndex = 11}, base),
                merge({name = "Nub3", level = 5, classIndex = 11}, base),
                merge({name = "Nub4", level = 5, classIndex = 11}, base),
                merge({name = "Nub5", level = 5, classIndex = 11}, base),
            }, dbboard.players)
        end)

        it("bumps on ding", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 6}, base), false)

            assert.equals(1, #dbboard.players)
            assert.equals(6, dbboard.players[1].level)
        end)

        it("reorders on ding", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub2", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub3", level = 5}, base), false)

            leaderboard:ProcessPlayerInfo(merge({name = "Nub2", level = 6}, base), false)
            assert.equals(3, #dbboard.players)
            assert.same({
                merge({name = "Nub2", level = 6, classIndex = 11}, base),
                merge({name = "Nub1", level = 5, classIndex = 11}, base),
                merge({name = "Nub3", level = 5, classIndex = 11}, base),
            }, dbboard.players)
        end)

        it("inserts new player with earlier dingedAt before same-level players", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time + 10, classIndex = 11})
            leaderboard:ProcessPlayerInfo({name = "Nub2", level = 5, dingedAt = time + 20, classIndex = 11})
            leaderboard:ProcessPlayerInfo({name = "Nub3", level = 5, dingedAt = time, classIndex = 11})

            assert.equals(3, #dbboard.players)
            assert.equals("Nub3", dbboard.players[1].name)
            assert.equals("Nub1", dbboard.players[2].name)
            assert.equals("Nub2", dbboard.players[3].name)
        end)

        it("updates dingedAt for existing player and reorders", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time + 20, classIndex = 11})
            leaderboard:ProcessPlayerInfo({name = "Nub2", level = 5, dingedAt = time + 10, classIndex = 11})
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})

            assert.equals(2, #dbboard.players)
            assert.equals("Nub1", dbboard.players[1].name)
            assert.equals(time, dbboard.players[1].dingedAt)
            assert.equals("Nub2", dbboard.players[2].name)
        end)

        it("ignores later dingedAt for existing player", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})
            local _, changed = leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time + 10, classIndex = 11})

            assert.equals(1, #dbboard.players)
            assert.equals(time, dbboard.players[1].dingedAt)
            assert.is_nil(changed)
        end)

        it("ignores stale lower-level info for existing player", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 25, dingedAt = time, classIndex = 11})
            -- an earlier dingedAt at a lower level is stale data, not an update
            local _, changed = leaderboard:ProcessPlayerInfo({name = "Nub1", level = 20, dingedAt = time - 100, classIndex = 11})

            assert.equals(1, #dbboard.players)
            assert.equals(25, dbboard.players[1].level)
            assert.equals(time, dbboard.players[1].dingedAt)
            assert.is_nil(changed)
        end)

        it("fills in a previously unknown classIndex in place", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 0})
            local _, changed = leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})

            assert.equals(1, #dbboard.players)
            assert.equals(11, dbboard.players[1].classIndex)
            -- not a ding, no notification
            assert.is_nil(changed)
        end)

        it("keeps a known classIndex when a ding comes without class info", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 6, dingedAt = time + 10, classIndex = 0})

            assert.equals(1, #dbboard.players)
            assert.equals(6, dbboard.players[1].level)
            assert.equals(11, dbboard.players[1].classIndex)
        end)

        it("fills in a missing dingedAt from a synced copy", function()
            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, classIndex = 11})
            assert.is_nil(dbboard.players[1].dingedAt)

            leaderboard:ProcessPlayerInfo({name = "Nub1", level = 5, dingedAt = time, classIndex = 11})
            assert.equals(1, #dbboard.players)
            assert.equals(time, dbboard.players[1].dingedAt)
        end)

        it("truncates on ding", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub2", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub3", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub4", level = 5}, base), false)
            leaderboard:ProcessPlayerInfo(merge({name = "Nub5", level = 5}, base), false)

            leaderboard:ProcessPlayerInfo(merge({name = "Nub6", level = 6}, base), false)
            assert.equals(5, #dbboard.players)

            assert.same({
                merge({name = "Nub6", level = 6, classIndex = 11}, base),
                merge({name = "Nub1", level = 5, classIndex = 11}, base),
                merge({name = "Nub2", level = 5, classIndex = 11}, base),
                merge({name = "Nub3", level = 5, classIndex = 11}, base),
                merge({name = "Nub4", level = 5, classIndex = 11}, base),
            }, dbboard.players)
        end)
    end)

    describe("Race", function()
        it("stores the race of a new player", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5, raceIndex = 4}, base))
            assert.equals(4, dbboard.players[1].raceIndex)
        end)

        it("fills in an unknown race without a change in rank", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base))
            assert.is_nil(dbboard.players[1].raceIndex)

            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5, raceIndex = 4}, base))
            assert.equals(4, dbboard.players[1].raceIndex)
        end)

        it("keeps a known race over an unknown one", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5, raceIndex = 4}, base))
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base))
            assert.equals(4, dbboard.players[1].raceIndex)

            -- also when the player dings
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 6, raceIndex = 0}, base))
            assert.equals(6, dbboard.players[1].level)
            assert.equals(4, dbboard.players[1].raceIndex)
        end)

        it("hashes the race, so a filled in race reaches the other clients", function()
            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5}, base))
            local withoutRace = WoWForeverRace.Leaderboard.ComputeHash(dbboard)

            leaderboard:ProcessPlayerInfo(merge({name = "Nub1", level = 5, raceIndex = 4}, base))
            local withRace = WoWForeverRace.Leaderboard.ComputeHash(dbboard)
            assert.not_equals(withoutRace, withRace)

            -- a client that knew the race all along agrees
            local other = {players = {merge({name = "Nub1", level = 5, raceIndex = 4}, base)}}
            assert.equals(withRace, WoWForeverRace.Leaderboard.ComputeHash(other))
        end)
    end)
end)
