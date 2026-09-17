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
        _G.C_Timer.Reset()
        -- a test may end with a scan still pending, i.e. the who panel silenced
        _G.LFGWhoListFrame:RegisterEvent("WHO_LIST_UPDATE")
        SetWhoPanelVisible(false)
        db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
        db:ResetDB()
        core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
        eventbus = WoWForeverRace.EventBus()
        scanner = WoWForeverRace.Scanner(core, db, eventbus)
    end)

    it("allows the first scan immediately", function()
        SetTime(0)

        scanner:TriggerScan()

        assert.equals("50-60", GetWhoQuery())
    end)
    it("ignores WHO_LIST_UPDATE events that do not belong to a scan", function()
        local eventBusSpy = spy.on(eventbus, "PublishEvent")

        scanner:OnWhoListUpdate()

        assert.spy(eventBusSpy).called_at_most(0)
    end)

    it("widens an empty global scan instead of repeating the same query", function()
        scanner:TriggerScan()
        assert.equals("50-60", GetWhoQuery())

        scanner:OnWhoListUpdate()
        SetTime(time + 16)
        scanner:TriggerScan()

        assert.equals("40-60", GetWhoQuery())
    end)

    it("treats a result the server truncated as incomplete", function()
        scanner:TriggerScan()
        assert.equals("50-60", GetWhoQuery())

        -- one row shown, but the server reports many more matches: the range
        -- is too wide, so the floor moves up instead of widening further
        SetWhoResults({{fullName = "Top", level = 60, filename = "MAGE"}}, 120)
        scanner:OnWhoListUpdate()
        SetTime(time + 16)
        scanner:TriggerScan()

        assert.equals("59-60", GetWhoQuery())
    end)

    it("treats a result with exactly the cap as complete when the server agrees", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }
        scanner.classScanFloor[1] = 2

        scanner:TriggerScan()
        assert.equals("2-60 c-\"Warrior\"", GetWhoQuery())

        -- 50 rows shown and the server says there are exactly 50 matches
        local rows = {}
        for i = 1, 50 do rows[i] = {fullName = "Warr" .. i, level = 60, filename = "WARRIOR"} end
        SetWhoResults(rows, 50)
        scanner:OnWhoListUpdate()

        assert.is_false(scanner.lastResultFull[1])
        assert.is_not_nil(scanner.classScanComplete[1])
    end)

    it("falls back to the row cap when the server total is unknown", function()
        scanner:TriggerScan()
        assert.equals("50-60", GetWhoQuery())

        local rows = {}
        for i = 1, 50 do rows[i] = {fullName = "Top" .. i, level = 60, filename = "MAGE"} end
        SetWhoResults(rows, false)
        scanner:OnWhoListUpdate()

        assert.is_true(scanner.globalResultFull)
    end)

    it("marks a low-population class complete at the lower bound", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }
        scanner.classScanFloor[1] = 2

        scanner:TriggerScan()
        assert.equals("2-60 c-\"Warrior\"", GetWhoQuery())

        scanner:OnWhoListUpdate()
        SetTime(time + 16)
        scanner:TriggerScan()

        -- Warrior is resting, so the rotation moves on to Paladin,
        -- which starts at its own adaptive floor (maxLevel - 20 - LEVEL_STEP)
        assert.equals("30-60 c-\"Paladin\"", GetWhoQuery())
    end)

    it("re-scans a completed class after the rest period", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }
        scanner.classScanFloor[1] = 2

        scanner:TriggerScan()
        assert.equals("2-60 c-\"Warrior\"", GetWhoQuery())
        scanner:OnWhoListUpdate()

        -- /who only sees online players, so the class must not be retired forever
        scanner.nextScanClassIdx = 1
        SetTime(time + 901)
        scanner:TriggerScan()

        assert.equals("2-60 c-\"Warrior\"", GetWhoQuery())
    end)

    it("abandons a pending scan when the /who response is lost", function()
        scanner:TriggerScan()
        assert.equals("50-60", GetWhoQuery())

        -- no WHO_LIST_UPDATE arrives; within the timeout scanning stays blocked
        SetTime(time + 16)
        scanner:TriggerScan()
        assert.equals("50-60", GetWhoQuery())

        -- past the timeout the pending scan is abandoned and scanning resumes
        SetTime(time + 61)
        scanner:TriggerScan()
        assert.equals("40-60", GetWhoQuery())
    end)

    it("does not attribute a manual /who to a pending class scan", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }

        scanner:TriggerScan()
        assert.equals("30-60 c-\"Warrior\"", GetWhoQuery())

        -- a manual "/who Orgrimmar" style result: wrong class, level below range
        local eventBusSpy = spy.on(eventbus, "PublishEvent")
        SetWhoResults({{fullName = "Lowbie", level = 20, filename = "MAGE"}})
        scanner:OnWhoListUpdate()

        assert.spy(eventBusSpy).called_at_most(0)
        assert.is_true(scanner.scanPending)
        assert.is_nil(scanner.classScanComplete[1])

        -- the scan's real response still gets consumed afterwards
        SetWhoResults({{fullName = "Warr", level = 45, filename = "WARRIOR"}})
        scanner:OnWhoListUpdate()

        assert.is_false(scanner.scanPending)
        assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus),
                WoWForeverRace.Config.Events.SlashWhoResult,
                {{name = "Warr", level = 45, class = "WARRIOR"}})
    end)

    it("restores the who panel when the race finishes mid-scan", function()
        scanner:TriggerScan()
        db.factionrealm.finished = true
        assert.is_false(_G.LFGWhoListFrame:IsEventRegistered("WHO_LIST_UPDATE"))

        scanner:OnWhoListUpdate()

        assert.is_true(_G.LFGWhoListFrame:IsEventRegistered("WHO_LIST_UPDATE"))
        assert.is_false(scanner.scanPending)
    end)

    it("restores the who panel when the race finishes and the reply is lost", function()
        scanner:TriggerScan()
        db.factionrealm.finished = true

        SetTime(time + 61)
        scanner:TriggerScan()

        assert.is_true(_G.LFGWhoListFrame:IsEventRegistered("WHO_LIST_UPDATE"))
        assert.is_false(scanner.scanPending)
    end)

    it("restores the who panel after the timeout without waiting for a click", function()
        scanner:TriggerScan()
        assert.is_false(_G.LFGWhoListFrame:IsEventRegistered("WHO_LIST_UPDATE"))

        _G.C_Timer.Advance(61)

        assert.is_true(_G.LFGWhoListFrame:IsEventRegistered("WHO_LIST_UPDATE"))
        assert.is_false(scanner.scanPending)
    end)

    it("never registers WHO_LIST_UPDATE on a frame that was not listening", function()
        scanner:TriggerScan()
        scanner:OnWhoListUpdate()

        assert.is_false(_G.FriendsFrame:IsEventRegistered("WHO_LIST_UPDATE"))
    end)

    it("does not take an empty result for its own after somebody else's /who", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }
        scanner.classScanFloor[1] = 2
        scanner:TriggerScan()

        -- the player types "/who Nonexistentname" while our scan is pending
        scanner:OnSendWho()
        scanner:OnWhoListUpdate()

        assert.is_true(scanner.scanPending)
        assert.is_nil(scanner.classScanComplete[1])
    end)

    it("uses the localized class name in class scans", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }
        _G.LocalizedClassList = function() return {WARRIOR = "Krieger"} end

        scanner:TriggerScan()
        _G.LocalizedClassList = nil

        assert.equals('30-60 c-"Krieger"', GetWhoQuery())
    end)

    it("keeps the WoW Forever who panel from popping up during a scan", function()
        scanner:TriggerScan()
        assert.is_false(_G.LFGWhoListFrame:IsEventRegistered("WHO_LIST_UPDATE"))

        scanner:OnWhoListUpdate()
        assert.is_true(_G.LFGWhoListFrame:IsEventRegistered("WHO_LIST_UPDATE"))
    end)

    it("hands short /who results back to chat unless the who panel is on screen", function()
        local whoToUiSpy = spy.on(_G.C_FriendList, "SetWhoToUi")

        scanner:TriggerScan()
        scanner:OnWhoListUpdate()
        assert.spy(whoToUiSpy).was_called_with(false)

        whoToUiSpy:clear()
        SetWhoPanelVisible(true)
        SetTime(time + 16)
        scanner:TriggerScan()
        scanner:OnWhoListUpdate()
        SetWhoPanelVisible(false)

        assert.spy(whoToUiSpy).was_not_called_with(false)
    end)

    it("does not publish players from another realm", function()
        local eventBusSpy = spy.on(eventbus, "PublishEvent")
        scanner:TriggerScan()
        SetWhoResults({
            {fullName = "Other-OtherRealm", level = 60, filename = "WARRIOR"},
        })

        scanner:OnWhoListUpdate()

        assert.spy(eventBusSpy).called_at_most(0)
    end)
end)
