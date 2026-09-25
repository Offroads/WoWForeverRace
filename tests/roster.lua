local WoWForeverRace = require("testbase")

local Events = WoWForeverRace.Config.Events
local WARRIORIDX, MAGEIDX = WoWForeverRace.Config.ClassIndexes["WARRIOR"], WoWForeverRace.Config.ClassIndexes["MAGE"]

describe("Roster", function()
    local db
    local core
    local eventbus
    local roster
    local batches
    local time = 1000000000

    -- every batch the roster published, flattened to {name = {level, class, raceIndex}}
    local function published()
        local players = {}
        for _, batch in ipairs(batches) do
            for _, info in ipairs(batch) do
                players[info.name] = info
            end
        end
        return players
    end

    before_each(function()
        SetTime(time)
        SetIsInGuild(true)
        SetGuildRoster(nil)
        SetGroupMembers(nil)
        SetFaction(nil)
        _G.C_Timer.Reset()
        db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
        db:ResetDB()
        core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
        eventbus = WoWForeverRace.EventBus()
        roster = WoWForeverRace.Roster(core, db, eventbus)

        batches = {}
        eventbus:RegisterCallback(Events.SlashWhoResult, {}, function(_, batch)
            batches[#batches + 1] = batch
        end)
    end)

    after_each(function()
        SetIsInGuild(nil)
        SetGuildRoster(nil)
        SetGroupMembers(nil)
        SetFaction(nil)
    end)

    describe("guild roster", function()
        it("forwards every guild member as a who result", function()
            SetGuildRoster({
                {name = "Alice-NubVille", level = 12, class = "WARRIOR", online = true},
                {name = "Bob-NubVille", level = 34, class = "MAGE", online = false},
            })

            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")

            local players = published()
            assert.equals(1, #batches)
            assert.same({name = "Alice", level = 12, class = "WARRIOR"}, players["Alice"])
            -- offline members count too: their level is exact as of their logout
            assert.same({name = "Bob", level = 34, class = "MAGE"}, players["Bob"])
        end)

        it("resolves a member's race through the GUID", function()
            SetGuildRoster({
                {name = "Alice-NubVille", level = 12, class = "WARRIOR", online = true, race = "NightElf"},
                {name = "Wings-NubVille", level = 20, class = "MAGE", online = true, race = "Skyborne"},
                {name = "Orcish-NubVille", level = 30, class = "SHAMAN", online = true, race = "Orc"},
            })

            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")

            local players = published()
            assert.equals(4, players["Alice"].raceIndex)
            -- the Alliance Skyborne, both share the file string
            assert.equals(95, players["Wings"].raceIndex)
            -- not a race of our faction
            assert.is_nil(players["Orcish"].raceIndex)
        end)

        it("forwards a member again once the client knows the race", function()
            SetGuildRoster({{name = "Alice-NubVille", level = 12, class = "WARRIOR", online = true}})
            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")
            assert.is_nil(batches[1][1].raceIndex)

            SetGuildRoster({{name = "Alice-NubVille", level = 12, class = "WARRIOR", online = true, race = "NightElf"}})
            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")
            assert.equals(2, #batches)
            assert.equals(4, batches[2][1].raceIndex)

            -- known now, no third time
            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")
            assert.equals(2, #batches)
        end)

        it("skips level 1 characters and members of other realms", function()
            SetGuildRoster({
                {name = "Fresh-NubVille", level = 1, class = "WARRIOR", online = true},
                {name = "Alien-OtherRealm", level = 40, class = "MAGE", online = true},
            })

            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")

            assert.equals(0, #batches)
        end)

        it("does nothing outside a guild", function()
            SetIsInGuild(false)
            SetGuildRoster({{name = "Alice-NubVille", level = 12, class = "WARRIOR", online = true}})

            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")

            assert.equals(0, #batches)
        end)

        it("forwards a member again only when the level went up", function()
            SetGuildRoster({{name = "Alice-NubVille", level = 12, class = "WARRIOR", online = true}})
            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")
            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")
            assert.equals(1, #batches)

            SetGuildRoster({{name = "Alice-NubVille", level = 13, class = "WARRIOR", online = true}})
            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")
            assert.equals(2, #batches)
            assert.equals(13, batches[2][1].level)
        end)

        it("forwards an unchanged level again after a while", function()
            SetGuildRoster({{name = "Alice-NubVille", level = 12, class = "WARRIOR", online = true}})
            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")

            SetTime(time + 14 * 60)
            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")
            assert.equals(1, #batches)

            SetTime(time + 15 * 60)
            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")
            assert.equals(2, #batches)
        end)

        it("forwards everyone again after a state reset", function()
            SetGuildRoster({{name = "Alice-NubVille", level = 12, class = "WARRIOR", online = true}})
            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")

            roster:ResetState()
            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")

            assert.equals(2, #batches)
        end)

        it("stays quiet once the race is finished", function()
            db.factionrealm.finished = true
            SetGuildRoster({{name = "Alice-NubVille", level = 60, class = "WARRIOR", online = true}})

            roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")

            assert.equals(0, #batches)
        end)

        it("requests the roster right away and then periodically while in a guild", function()
            roster:InitGuildRosterTicker()
            assert.equals(1, GetGuildRosterRequests())

            _G.C_Timer.Advance(60)
            assert.equals(2, GetGuildRosterRequests())

            SetIsInGuild(false)
            _G.C_Timer.Advance(60)
            assert.equals(2, GetGuildRosterRequests())
        end)
    end)

    describe("group members", function()
        it("forwards party members with their class and race", function()
            SetGroupMembers({
                {name = "Alice", level = 22, class = "WARRIOR", raceIndex = 1},
                {name = "Bob", level = 35, class = "MAGE", raceIndex = 7},
            })

            roster.Thread:FireEvent("GROUP_ROSTER_UPDATE")

            local players = published()
            assert.same({name = "Alice", level = 22, class = "WARRIOR", raceIndex = 1}, players["Alice"])
            assert.same({name = "Bob", level = 35, class = "MAGE", raceIndex = 7}, players["Bob"])
        end)

        it("keeps the full name of a member", function()
            SetGroupMembers({{name = "Alice Wanderer", level = 22, class = "WARRIOR", raceIndex = 1}})

            roster.Thread:FireEvent("GROUP_ROSTER_UPDATE")

            assert.equals(22, published()["Alice Wanderer"].level)
        end)

        it("forwards raid members", function()
            SetGroupMembers({
                {name = "Alice", level = 22, class = "WARRIOR", raceIndex = 1},
            }, true)

            roster.Thread:FireEvent("GROUP_ROSTER_UPDATE")

            assert.equals(22, published()["Alice"].level)
        end)

        it("skips members of the other faction, other realms and unknown levels", function()
            SetGroupMembers({
                {name = "Eve", level = 22, class = "WARRIOR", raceIndex = 2, faction = "Horde"},
                {name = "Alien", realm = "OtherRealm", level = 40, class = "MAGE", raceIndex = 7},
                {name = "Loading", level = 0, class = "MAGE", raceIndex = 7},
            })

            roster.Thread:FireEvent("GROUP_ROSTER_UPDATE")

            assert.equals(0, #batches)
        end)

        it("drops a race that isn't one of our faction", function()
            SetGroupMembers({{name = "Alice", level = 22, class = "WARRIOR", raceIndex = 8}})

            roster.Thread:FireEvent("GROUP_ROSTER_UPDATE")

            assert.is_nil(published()["Alice"].raceIndex)
        end)

        it("picks up a member leveling up", function()
            SetGroupMembers({{name = "Alice", level = 22, class = "WARRIOR", raceIndex = 1}})
            roster.Thread:FireEvent("GROUP_ROSTER_UPDATE")

            SetGroupMembers({{name = "Alice", level = 23, class = "WARRIOR", raceIndex = 1}})
            roster.Thread:FireEvent("UNIT_LEVEL", "party1")

            assert.equals(2, #batches)
            assert.equals(23, batches[2][1].level)
        end)

        it("does nothing outside a group", function()
            roster.Thread:FireEvent("GROUP_ROSTER_UPDATE")

            assert.equals(0, #batches)
        end)
    end)

    it("lands guild and group members on the leaderboards", function()
        local network = {SendObject = function() end}
        local tracker = WoWForeverRace.Tracker(WoWForeverRace.Config, core, db, eventbus, network)

        SetGuildRoster({{name = "Alice-NubVille", level = 12, class = "WARRIOR", online = true, race = "Human"}})
        SetGroupMembers({{name = "Bob", level = 35, class = "MAGE", raceIndex = 7}})
        roster.Thread:FireEvent("GUILD_ROSTER_UPDATE")
        roster.Thread:FireEvent("GROUP_ROSTER_UPDATE")

        local overall = db.factionrealm.leaderboard[0].players
        assert.equals(2, #overall)
        assert.equals("Bob", overall[1].name)
        assert.equals(35, overall[1].level)
        assert.equals(MAGEIDX, overall[1].classIndex)
        assert.equals(7, overall[1].raceIndex)
        assert.equals("Alice", overall[2].name)
        assert.equals(WARRIORIDX, overall[2].classIndex)
        assert.equals("Alice", db.factionrealm.leaderboard[WARRIORIDX].players[1].name)
        assert.equals("Alice", db.factionrealm.leaderboard[WoWForeverRace.Config.RaceBoardOffset + 1].players[1].name)
        assert.equals("Bob", db.factionrealm.leaderboard[WoWForeverRace.Config.RaceBoardOffset + 7].players[1].name)
        assert.equals(12, tracker.lbGlobal.lbdb.players[2].level)
    end)
end)
