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

    local function ding(name, level, classIndex, globalRank, classRank)
        eventbus:PublishEvent(Events.Ding, {
            name = name,
            level = level,
            classIndex = classIndex,
            dingedAt = time,
        }, globalRank, classRank)
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
    end)
end)
