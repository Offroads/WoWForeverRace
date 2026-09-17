local WoWForeverRace = require("testbase")

describe("Scanner", function()
    local db
    local core
    local eventbus
    local scanner
    local time = 1000000000
    -- an already recorded probe without rows: class scans start right away, at the bottom
    local NO_PROBE = {levels = {}, classCount = {}}

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

        assert.equals("2-60", GetWhoQuery())
    end)
    it("ignores WHO_LIST_UPDATE events that do not belong to a scan", function()
        local eventBusSpy = spy.on(eventbus, "PublishEvent")

        scanner:OnWhoListUpdate()

        assert.spy(eventBusSpy).called_at_most(0)
    end)

    it("repeats the unfiltered probe while the leaderboard is empty", function()
        scanner:TriggerScan()
        assert.equals("2-60", GetWhoQuery())

        scanner:OnWhoListUpdate()
        SetTime(time + 16)
        scanner:TriggerScan()

        assert.equals("2-60", GetWhoQuery())
    end)

    it("probes all classes once before the class scans", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 7, classIndex = 1, dingedAt = time},
        }

        scanner:TriggerScan()
        assert.equals("2-60", GetWhoQuery())

        SetWhoResults({{fullName = "Mage", level = 3, filename = "MAGE"}}, 120)
        scanner:OnWhoListUpdate()
        SetTime(time + 16)
        scanner:TriggerScan()

        assert.equals("2-60 c-\"Warrior\"", GetWhoQuery())
    end)

    it("starts a crowded class where the probe expects it to fit under the cap", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 7, classIndex = 1, dingedAt = time},
        }
        db.factionrealm.leaderboard[0].highestLevel = 7

        -- 50 of 400 players: 25 warriors (so about 200 online), 25 mages,
        -- and a quarter of the sample at level 4 or higher
        local rows = {}
        for i = 1, 50 do
            rows[i] = {
                fullName = "Player" .. i,
                level    = i <= 4 and 6 or (i <= 12 and 4 or 2),
                filename = i % 2 == 0 and "WARRIOR" or "MAGE",
            }
        end
        scanner:TriggerScan()
        SetWhoResults(rows, 400)
        scanner:OnWhoListUpdate()
        SetTime(time + 16)
        scanner:TriggerScan()

        -- 50 of ~200 warriors fit: the top quarter of the sample starts at level 4
        assert.equals("4-60 c-\"Warrior\"", GetWhoQuery())
    end)

    it("rests every class when the probe saw everybody online", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 7, classIndex = 1, dingedAt = time},
        }
        db.factionrealm.leaderboard[0].highestLevel = 7

        scanner:TriggerScan()
        SetWhoResults({{fullName = "Warr", level = 5, filename = "WARRIOR"}}, 1)
        scanner:OnWhoListUpdate()
        SetTime(time + 16)
        scanner:TriggerScan()

        -- no class scan: straight to the global top range
        assert.equals("7-60", GetWhoQuery())
    end)

    it("treats a result with exactly the cap as complete when the server agrees", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }
        scanner.probe = NO_PROBE
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
        assert.equals("2-60", GetWhoQuery())

        local rows = {}
        for i = 1, 50 do rows[i] = {fullName = "Top" .. i, level = 60, filename = "MAGE"} end
        SetWhoResults(rows, false)
        scanner:OnWhoListUpdate()

        -- not complete: the classes are not rested
        assert.is_nil(scanner.classScanComplete[1])
    end)

    it("marks a low-population class complete at the lower bound", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }
        scanner.probe = NO_PROBE
        scanner.classScanFloor[1] = 2

        scanner:TriggerScan()
        assert.equals("2-60 c-\"Warrior\"", GetWhoQuery())

        scanner:OnWhoListUpdate()
        SetTime(time + 16)
        scanner:TriggerScan()

        -- Warrior is resting, so the rotation moves on to Paladin
        assert.equals("2-60 c-\"Paladin\"", GetWhoQuery())
    end)

    it("bisects the class floor between the bottom and the highest level seen", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 7, classIndex = 1, dingedAt = time},
        }
        scanner.probe = NO_PROBE
        db.factionrealm.leaderboard[0].highestLevel = 7

        local function warriors(count, level)
            local rows = {}
            for i = 1, count do rows[i] = {fullName = "Warr" .. i, level = level, filename = "WARRIOR"} end
            return rows
        end
        local now = time
        local function nextWarriorScan(rows, total)
            SetWhoResults(rows, total)
            scanner:OnWhoListUpdate()
            now = now + 16
            SetTime(now)
            scanner.nextScanClassIdx = 1
            scanner:TriggerScan()
            return GetWhoQuery()
        end

        scanner:TriggerScan()
        assert.equals("2-60 c-\"Warrior\"", GetWhoQuery())

        -- over the cap: halfway up to the highest level seen
        assert.equals("5-60 c-\"Warrior\"", nextWarriorScan(warriors(50, 5), 300))
        -- fits: halfway back down, staying above the floor that overflowed
        assert.equals("4-60 c-\"Warrior\"", nextWarriorScan(warriors(3, 6), 3))
        assert.equals("3-60 c-\"Warrior\"", nextWarriorScan(warriors(20, 4), 20))
        -- overflows again: back to the floor known to fit, and stay there
        assert.equals("4-60 c-\"Warrior\"", nextWarriorScan(warriors(50, 3), 80))
        assert.equals("4-60 c-\"Warrior\"", nextWarriorScan(warriors(20, 4), 20))
    end)

    it("repeats the class floor when the /who response was lost", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }
        scanner.probe = NO_PROBE
        scanner.classScanFloor[1] = 30
        scanner.lastResultFull[1] = true

        scanner:TriggerScan()
        assert.equals("31-60 c-\"Warrior\"", GetWhoQuery())

        scanner.nextScanClassIdx = 1
        SetTime(time + 61)
        scanner:TriggerScan()
        assert.equals("31-60 c-\"Warrior\"", GetWhoQuery())
    end)

    it("re-scans a completed class after the rest period", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }
        scanner.probe = NO_PROBE
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
        assert.equals("2-60", GetWhoQuery())

        -- no WHO_LIST_UPDATE arrives; within the timeout scanning stays blocked
        SetTime(time + 16)
        scanner:TriggerScan()
        assert.equals("2-60", GetWhoQuery())

        -- past the timeout the pending scan is abandoned and scanning resumes
        SetTime(time + 61)
        scanner:TriggerScan()
        assert.equals("2-60", GetWhoQuery())
    end)

    it("does not attribute a manual /who to a pending class scan", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }
        scanner.probe = NO_PROBE

        scanner:TriggerScan()
        assert.equals("2-60 c-\"Warrior\"", GetWhoQuery())

        -- a manual "/who Orgrimmar" style result: wrong class
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

    it("never registers WHO_LIST_UPDATE on a who panel that was not listening", function()
        _G.LFGWhoListFrame:UnregisterEvent("WHO_LIST_UPDATE")

        scanner:TriggerScan()
        scanner:OnWhoListUpdate()

        assert.is_false(_G.LFGWhoListFrame:IsEventRegistered("WHO_LIST_UPDATE"))
    end)

    it("does not take an empty result for its own after somebody else's /who", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }
        scanner.probe = NO_PROBE
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
        scanner.probe = NO_PROBE
        _G.LocalizedClassList = function() return {WARRIOR = "Krieger"} end

        scanner:TriggerScan()
        _G.LocalizedClassList = nil

        assert.equals('2-60 c-"Krieger"', GetWhoQuery())
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
