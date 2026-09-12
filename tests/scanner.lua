local WoWForeverRace = require("testbase")

describe("Scanner", function()
    local db
    local core
    local eventbus
    local scanner
    local time = 1000000000

    before_each(function()
        SetTime(time)
        SetWhoResults({})
        ResetWhoQuery()
        db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
        db:ResetDB()
        core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
        eventbus = WoWForeverRace.EventBus()
        scanner = WoWForeverRace.Scanner(core, db, eventbus)
    end)

    it("allows the first scan immediately", function()
        SetTime(0)

        scanner:TriggerScan()

        assert.equals("80-90", GetWhoQuery())
    end)
    it("ignores WHO_LIST_UPDATE events that do not belong to a scan", function()
        local eventBusSpy = spy.on(eventbus, "PublishEvent")

        scanner:OnWhoListUpdate()

        assert.spy(eventBusSpy).called_at_most(0)
    end)

    it("widens an empty global scan instead of repeating the same query", function()
        scanner:TriggerScan()
        assert.equals("80-90", GetWhoQuery())

        scanner:OnWhoListUpdate()
        SetTime(time + 16)
        scanner:TriggerScan()

        assert.equals("70-90", GetWhoQuery())
    end)

    it("marks a low-population class complete at the lower bound", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 90, classIndex = 1, dingedAt = time},
        }
        scanner.classScanFloor[1] = 2

        scanner:TriggerScan()
        assert.equals("2-90 c-Warrior", GetWhoQuery())

        scanner:OnWhoListUpdate()
        SetTime(time + 16)
        scanner:TriggerScan()

        -- Warrior is resting, so the rotation moves on to Paladin,
        -- which starts at its own adaptive floor (maxLevel - 20 - LEVEL_STEP)
        assert.equals("60-90 c-Paladin", GetWhoQuery())
    end)

    it("re-scans a completed class after the rest period", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 90, classIndex = 1, dingedAt = time},
        }
        scanner.classScanFloor[1] = 2

        scanner:TriggerScan()
        assert.equals("2-90 c-Warrior", GetWhoQuery())
        scanner:OnWhoListUpdate()

        -- /who only sees online players, so the class must not be retired forever
        scanner.nextScanClassIdx = 1
        SetTime(time + 901)
        scanner:TriggerScan()

        assert.equals("2-90 c-Warrior", GetWhoQuery())
    end)

    it("abandons a pending scan when the /who response is lost", function()
        scanner:TriggerScan()
        assert.equals("80-90", GetWhoQuery())

        -- no WHO_LIST_UPDATE arrives; within the timeout scanning stays blocked
        SetTime(time + 16)
        scanner:TriggerScan()
        assert.equals("80-90", GetWhoQuery())

        -- past the timeout the pending scan is abandoned and scanning resumes
        SetTime(time + 61)
        scanner:TriggerScan()
        assert.equals("70-90", GetWhoQuery())
    end)

    it("does not attribute a manual /who to a pending class scan", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 90, classIndex = 1, dingedAt = time},
        }

        scanner:TriggerScan()
        assert.equals("60-90 c-Warrior", GetWhoQuery())

        -- a manual "/who Orgrimmar" style result: wrong class, level below range
        local eventBusSpy = spy.on(eventbus, "PublishEvent")
        SetWhoResults({{fullName = "Lowbie", level = 30, filename = "MAGE"}})
        scanner:OnWhoListUpdate()

        assert.spy(eventBusSpy).called_at_most(0)
        assert.is_true(scanner.scanPending)
        assert.is_nil(scanner.classScanComplete[1])

        -- the scan's real response still gets consumed afterwards
        SetWhoResults({{fullName = "Warr", level = 65, filename = "WARRIOR"}})
        scanner:OnWhoListUpdate()

        assert.is_false(scanner.scanPending)
        assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus),
                WoWForeverRace.Config.Events.SlashWhoResult,
                {{name = "Warr", level = 65, class = "WARRIOR"}}, 1)
    end)

    it("restores FriendsFrame when the race finishes mid-scan", function()
        scanner:TriggerScan()
        db.factionrealm.finished = true
        local registerSpy = spy.on(_G.FriendsFrame, "RegisterEvent")

        scanner:OnWhoListUpdate()

        assert.spy(registerSpy).was_called_with(match.is_ref(_G.FriendsFrame), "WHO_LIST_UPDATE")
        assert.is_false(scanner.scanPending)
    end)

    it("does not publish players from another realm", function()
        local eventBusSpy = spy.on(eventbus, "PublishEvent")
        scanner:TriggerScan()
        SetWhoResults({
            {fullName = "Other-OtherRealm", level = 90, filename = "WARRIOR"},
        })

        scanner:OnWhoListUpdate()

        assert.spy(eventBusSpy).called_at_most(0)
    end)
end)
