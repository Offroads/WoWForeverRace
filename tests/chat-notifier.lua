-- load test base
local WoWForeverRace = require("testbase")

local Events = WoWForeverRace.Config.Events
local DRUIDIDX = WoWForeverRace.Config.ClassIndexes["DRUID"]

describe("ChatNotifier", function()
    local config
    local db
    local core
    local eventbus
    local printSpy
    local time = 1000000000

    local function ding(name, level, classIndex, globalRank, classRank, raceRank, raceIndex)
        eventbus:PublishEvent(Events.Ding, {
            name = name,
            level = level,
            classIndex = classIndex,
            raceIndex = raceIndex,
            dingedAt = time,
        }, globalRank, classRank, raceRank)
    end

    before_each(function()
        config = WoWForeverRace.Config
        db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
        db:ResetDB()
        core = WoWForeverRace.Core(config, "Nub", "NubVille")
        function core:Now() return time end
        eventbus = WoWForeverRace.EventBus()
        WoWForeverRace.ChatNotifier(config, core, db, eventbus)
        -- stub instead of spy so the notifications don't end up in the test output
        printSpy = stub(WoWForeverRace, "PPrint")
    end)

    after_each(function()
        printSpy:revert()
    end)

    it("reports dings inside the configured top N", function()
        ding("Nubone", 10, DRUIDIDX, 2, 1)
        assert.spy(printSpy).was_called(1)
    end)

    it("does not report dings outside the configured top N", function()
        ding("Nubone", 10, DRUIDIDX, 40, 30)
        assert.spy(printSpy).was_not_called()
    end)

    it("does not report stale dings unless they are rank 1", function()
        eventbus:PublishEvent(Events.Ding, {
            name = "Nubone", level = 10, classIndex = DRUIDIDX, dingedAt = time - 601,
        }, 2, 2)
        assert.spy(printSpy).was_not_called()

        eventbus:PublishEvent(Events.Ding, {
            name = "Nubone", level = 10, classIndex = DRUIDIDX, dingedAt = time - 601,
        }, 1, 1)
        assert.spy(printSpy).was_called(1)
    end)

    it("reports a player of unknown class without a class rank", function()
        assert.has_no.errors(function()
            ding("Mystery", 10, 0, 3, nil)
            ding("Mystery", config.MaxLevel, 0, 3, nil)
        end)
        assert.spy(printSpy).was_called(2)
    end)

    it("reports the first player to max level even outside the top N", function()
        db.profile.options.globalTopN = 0
        db.profile.options.classTopN = 0

        ding("Nubone", config.MaxLevel, DRUIDIDX, 1, 1)
        assert.spy(printSpy).was_called(1)

        ding("Nubtwo", config.MaxLevel, DRUIDIDX, 2, 2)
        assert.spy(printSpy).was_called(1)
    end)

    it("addresses the player directly for their own ding", function()
        ding("Nub", 10, DRUIDIDX, 1, 1)
        assert.spy(printSpy).was_called_with(match.is_ref(WoWForeverRace), match.has_match("You"))
    end)

    it("announces the end of the race", function()
        eventbus:PublishEvent(Events.RaceFinished)
        assert.spy(printSpy).was_called(1)
        assert.spy(printSpy).was_called_with(match.is_ref(WoWForeverRace),
                "Every class and race leaderboard is full with 50 players at max level, the race is over!")
    end)

    describe("race ranks", function()
        local GNOME = 7

        it("only reports the first of a race by default", function()
            ding("Nubone", 10, DRUIDIDX, 40, 30, 1, GNOME)
            assert.spy(printSpy).was_called(1)
            assert.spy(printSpy).was_called_with(match.is_ref(WoWForeverRace),
                    match.has_match("is first to reach level 10 of all Gnome!$"))

            ding("Nubtwo", 10, DRUIDIDX, 41, 31, 2, GNOME)
            assert.spy(printSpy).was_called(1)
        end)

        it("reports more race ranks with a higher race top N", function()
            db.profile.options.raceTopN = 3

            ding("Nubone", 10, DRUIDIDX, 40, 30, 3, GNOME)
            assert.spy(printSpy).was_called_with(match.is_ref(WoWForeverRace),
                    match.has_match("reached level 10 as #3 of all Gnome!$"))

            ding("Nubtwo", 10, DRUIDIDX, 41, 31, 4, GNOME)
            assert.spy(printSpy).was_called(1)
        end)

        it("reports a player who is only on a race leaderboard", function()
            ding("Nubone", config.MaxLevel, DRUIDIDX, nil, nil, 1, GNOME)
            assert.spy(printSpy).was_called_with(match.is_ref(WoWForeverRace),
                    match.has_match("is the first to reach max level of all Gnome!!$"))
        end)

        it("stays silent about race ranks with race top N at 0", function()
            db.profile.options.raceTopN = 0

            ding("Nubone", 10, DRUIDIDX, 40, 30, 1, GNOME)
            ding("Nubtwo", config.MaxLevel, DRUIDIDX, 40, 30, 1, GNOME)
            assert.spy(printSpy).was_not_called()
        end)

        it("leaves the class and overall messages alone with race top N at 0", function()
            ding("Nubone", 10, DRUIDIDX, 2, 1)
            local without = printSpy.calls[1].vals[2]
            printSpy:clear()

            db.profile.options.raceTopN = 0
            ding("Nubone", 10, DRUIDIDX, 2, 1, 1, GNOME)

            assert.spy(printSpy).was_called(1)
            assert.equals(without, printSpy.calls[1].vals[2])
        end)

        it("adds the race rank to the class and overall message, in one line", function()
            ding("Nubone", 10, DRUIDIDX, 2, 1, 1, GNOME)

            assert.spy(printSpy).was_called(1)
            assert.spy(printSpy).was_called_with(match.is_ref(WoWForeverRace),
                    match.has_match("of all Druid, and #2 for all classes, and #1 of all Gnome!$"))
        end)

        it("leaves a race rank outside race top N out of the message", function()
            ding("Nubone", 10, DRUIDIDX, 2, 1, 2, GNOME)

            assert.spy(printSpy).was_called(1)
            assert.spy(printSpy).was_called_with(match.is_ref(WoWForeverRace),
                    match.has_match("for all classes!$"))
        end)

        it("reports a stale ding of the first of a race", function()
            eventbus:PublishEvent(Events.Ding, {
                name = "Nubone", level = 10, classIndex = DRUIDIDX, raceIndex = GNOME, dingedAt = time - 601,
            }, 40, 30, 2)
            assert.spy(printSpy).was_not_called()

            eventbus:PublishEvent(Events.Ding, {
                name = "Nubone", level = 10, classIndex = DRUIDIDX, raceIndex = GNOME, dingedAt = time - 601,
            }, 40, 30, 1)
            assert.spy(printSpy).was_called(1)
        end)

        it("addresses the player directly for their own race rank", function()
            ding("Nub", 10, DRUIDIDX, 40, 30, 1, GNOME)
            assert.spy(printSpy).was_called_with(match.is_ref(WoWForeverRace),
                    match.has_match("You.* are first to reach level 10 of all Gnome!$"))
        end)

        it("names the Skyborne of the faction", function()
            ding("Nubone", 10, DRUIDIDX, 40, 30, 1, 95)
            assert.spy(printSpy).was_called_with(match.is_ref(WoWForeverRace),
                    match.has_match("of all High Order Skyborne!$"))
        end)
    end)
end)
