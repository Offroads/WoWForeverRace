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
    it("waits for the cooldown between two scans", function()
        scanner:TriggerScan()
        scanner:OnWhoListUpdate()
        ResetWhoQuery()

        SetTime(time + 4)
        scanner:TriggerScan()
        assert.is_nil(GetWhoQuery())

        SetTime(time + 5)
        scanner:TriggerScan()
        assert.equals("2-60", GetWhoQuery())
    end)

    describe("key press scanning", function()
        after_each(function()
            SetInCombat(false)
        end)

        it("scans on a key press by default", function()
            -- the keys must still reach the game
            assert.is_true(scanner.keyFrame.propagateKeyboardInput)
            assert.is_true(scanner.keyFrame.keyboardEnabled)

            scanner.keyFrame:GetScript("OnKeyDown")(scanner.keyFrame, "W")
            assert.equals("2-60", GetWhoQuery())
        end)

        it("stops scanning on a key press once the option is off", function()
            db.profile.options.keypressScanning = false
            scanner:UpdateKeypressScanning()

            scanner.keyFrame:GetScript("OnKeyDown")(scanner.keyFrame, "W")
            assert.is_nil(GetWhoQuery())
        end)

        it("does not hook the keyboard while the option is off", function()
            db.profile.options.keypressScanning = false
            scanner = WoWForeverRace.Scanner(core, db, eventbus)
            assert.is_nil(scanner.keyFrame)

            db.profile.options.keypressScanning = true
            scanner:UpdateKeypressScanning()
            assert.is_not_nil(scanner.keyFrame)
        end)

        it("waits for the end of combat before it hooks the keyboard", function()
            SetInCombat(true)
            scanner = WoWForeverRace.Scanner(core, db, eventbus)
            assert.is_nil(scanner.keyFrame)

            SetInCombat(false)
            scanner.whoFrame:FireEvent("PLAYER_REGEN_ENABLED")
            assert.is_not_nil(scanner.keyFrame)
            assert.is_false(scanner.whoFrame:IsEventRegistered("PLAYER_REGEN_ENABLED"))
        end)
    end)

    it("scans less often once a /who reply was lost", function()
        scanner:TriggerScan()
        -- no reply: the timeout gives up on the scan
        SetTime(time + 60)
        _G.C_Timer.Advance(60)
        assert.is_false(scanner.scanPending)

        scanner:TriggerScan()
        scanner:OnWhoListUpdate()
        ResetWhoQuery()

        SetTime(time + 60 + 9)
        scanner:TriggerScan()
        assert.is_nil(GetWhoQuery())

        SetTime(time + 60 + 10)
        scanner:TriggerScan()
        assert.equals("2-60", GetWhoQuery())
    end)

    it("keeps the scan rate when the reply was lost to somebody else's /who", function()
        scanner:TriggerScan()
        scanner:OnSendWho()
        SetTime(time + 60)
        _G.C_Timer.Advance(60)

        assert.is_false(scanner.scanPending)
        assert.equals(5, scanner.scanCooldown)
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

    it("still scans the classes when the probe saw everybody online", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 7, classIndex = 1, dingedAt = time},
        }
        db.factionrealm.leaderboard[0].highestLevel = 7

        scanner:TriggerScan()
        SetWhoResults({{fullName = "Warr", level = 5, filename = "WARRIOR"}}, 1)
        scanner:OnWhoListUpdate()
        SetTime(time + 16)
        scanner:TriggerScan()

        assert.equals("2-60 c-\"Warrior\"", GetWhoQuery())
    end)

    it("treats a result that fills the row cap as cut off, whatever total the client reports", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }
        scanner.probe = NO_PROBE
        scanner.classScanFloor[1] = 2

        scanner:TriggerScan()
        assert.equals("2-60 c-\"Warrior\"", GetWhoQuery())

        -- the WoW Forever client caps the reported total at the row cap too
        -- ("50 People Found"), so a full result always counts as cut off
        local rows = {}
        for i = 1, 50 do rows[i] = {fullName = "Warr" .. i, level = 60, filename = "WARRIOR"} end
        SetWhoResults(rows, 50)
        scanner:OnWhoListUpdate()

        assert.is_true(scanner.lastResultFull[1])
        assert.is_nil(scanner.classScanComplete[1])
    end)

    it("treats a result under the row cap as complete", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
        }
        scanner.probe = NO_PROBE

        scanner:TriggerScan()
        local rows = {}
        for i = 1, 49 do rows[i] = {fullName = "Warr" .. i, level = 60, filename = "WARRIOR"} end
        SetWhoResults(rows, 49)
        scanner:OnWhoListUpdate()

        assert.is_false(scanner.lastResultFull[1])
        assert.is_not_nil(scanner.classScanComplete[1])
    end)

    it("looks just above the highest level seen after a full result, further when that is full too", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 20, classIndex = 1, dingedAt = time},
        }
        db.factionrealm.leaderboard[0].highestLevel = 20
        db.factionrealm.leaderboard[1].players = {
            {name = "Seed", level = 20, classIndex = 1, dingedAt = time},
        }
        db.factionrealm.leaderboard[1].highestLevel = 20
        scanner.probe = NO_PROBE

        local now = time
        local function nextWarriorScan(count)
            local rows = {}
            for i = 1, count do rows[i] = {fullName = "Warr" .. i, level = 60, filename = "WARRIOR"} end
            SetWhoResults(rows)
            scanner:OnWhoListUpdate()
            now = now + 16
            SetTime(now)
            scanner.nextScanClassIdx = 1
            scanner:TriggerScan()
            return GetWhoQuery()
        end

        scanner:TriggerScan()
        assert.equals("20-60 c-\"Warrior\"", GetWhoQuery())

        -- fifty or more at 20: 21-60, not a jump towards the level cap
        assert.equals("21-60 c-\"Warrior\"", nextWarriorScan(50))
        -- still full, so level 20 was outdated: the step doubles
        assert.equals("23-60 c-\"Warrior\"", nextWarriorScan(50))
        assert.equals("27-60 c-\"Warrior\"", nextWarriorScan(50))
        -- room again: back down one level per visit, and the next full result starts small
        assert.equals("26-60 c-\"Warrior\"", nextWarriorScan(10))
    end)

    it("falls back to the row cap when the server total is unknown", function()
        scanner:TriggerScan()
        assert.equals("2-60", GetWhoQuery())

        local rows = {}
        for i = 1, 50 do rows[i] = {fullName = "Top" .. i, level = 60, filename = "MAGE"} end
        SetWhoResults(rows, false)
        scanner:OnWhoListUpdate()

        -- no match count, no estimate: the class scans start at the bottom
        assert.is_nil(scanner:ProbeFloor("MAGE"))
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

    it("starts a class at the highest level known for it and takes in one more level per visit", function()
        db.factionrealm.leaderboard[0].players = {
            {name = "Seed", level = 20, classIndex = 1, dingedAt = time},
        }
        db.factionrealm.leaderboard[0].highestLevel = 20
        db.factionrealm.leaderboard[1].players = {
            {name = "Seed", level = 20, classIndex = 1, dingedAt = time},
        }
        db.factionrealm.leaderboard[1].highestLevel = 20
        scanner.probe = NO_PROBE

        local function warriors(count, level)
            local rows = {}
            for i = 1, count do rows[i] = {fullName = "Warr" .. i, level = level, filename = "WARRIOR"} end
            return rows
        end
        local now = time
        local function nextWarriorScan(rows)
            SetWhoResults(rows)
            scanner:OnWhoListUpdate()
            now = now + 16
            SetTime(now)
            scanner.nextScanClassIdx = 1
            scanner:TriggerScan()
            return GetWhoQuery()
        end

        scanner:TriggerScan()
        assert.equals("20-60 c-\"Warrior\"", GetWhoQuery())

        -- room left: one level lower on every visit
        assert.equals("19-60 c-\"Warrior\"", nextWarriorScan(warriors(5, 20)))
        assert.equals("18-60 c-\"Warrior\"", nextWarriorScan(warriors(30, 19)))
        -- full: back to the floor that fit, and stay there
        assert.equals("19-60 c-\"Warrior\"", nextWarriorScan(warriors(50, 18)))
        assert.equals("19-60 c-\"Warrior\"", nextWarriorScan(warriors(40, 19)))
        -- the players outgrew that floor: the next level up, not halfway to the top
        db.factionrealm.leaderboard[0].highestLevel = 40
        assert.equals("20-60 c-\"Warrior\"", nextWarriorScan(warriors(50, 19)))
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

    describe("race scans", function()
        -- rests every class, so the rotation reaches the race slots
        local function restClasses()
            for _, classIndex in ipairs(WoWForeverRace.Config.MopClassIndexes) do
                scanner.classScanComplete[classIndex] = time
            end
        end

        before_each(function()
            db.factionrealm.leaderboard[0].players = {
                {name = "Seed", level = 60, classIndex = 1, dingedAt = time},
            }
            scanner.probe = NO_PROBE
        end)

        after_each(function()
            SetRaceNames(nil)
            SetFaction(nil)
        end)

        it("publishes the race of the who rows", function()
            local eventBusSpy = spy.on(eventbus, "PublishEvent")

            scanner:TriggerScan()
            SetWhoResults({
                {fullName = "Warr", level = 45, filename = "WARRIOR", raceStr = "High Order Skyborne"},
                {fullName = "Oddity", level = 40, filename = "WARRIOR", raceStr = "Murloc"},
            })
            scanner:OnWhoListUpdate()

            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus),
                    WoWForeverRace.Config.Events.SlashWhoResult, {
                        {name = "Warr", level = 45, class = "WARRIOR", raceIndex = 95},
                        {name = "Oddity", level = 40, class = "WARRIOR"},
                    })
        end)

        it("scans the classes first and gives a race one turn per round of class scans", function()
            local now = time
            local queries = {}
            for i = 1, 20 do
                scanner:TriggerScan()
                queries[i] = GetWhoQuery()
                -- a full result, so neither the classes nor the races come to rest
                local rows = {}
                for r = 1, 50 do
                    rows[r] = {fullName = "P" .. r, level = 60,
                               filename = string.upper(string.match(queries[i], 'c%-"(%a+)"') or "MAGE"),
                               raceStr = string.match(queries[i], 'r%-"([%a ]+)"')}
                end
                SetWhoResults(rows, 50)
                scanner:OnWhoListUpdate()
                now = now + 16
                SetTime(now)
            end

            for i = 1, 9 do
                assert.is_not_nil(string.find(queries[i], 'c-"', 1, true), queries[i])
            end
            assert.is_not_nil(string.find(queries[10], 'r-"Human"', 1, true), queries[10])
            for i = 11, 19 do
                assert.is_not_nil(string.find(queries[i], 'c-"', 1, true), queries[i])
            end
            assert.is_not_nil(string.find(queries[20], 'r-"Dwarf"', 1, true), queries[20])
        end)

        it("scans the races when no class needs a scan", function()
            restClasses()

            scanner:TriggerScan()
            assert.equals('2-60 r-"Human"', GetWhoQuery())

            scanner:OnWhoListUpdate()
            SetTime(time + 16)
            scanner:TriggerScan()

            -- Human is resting, so the rotation moves on to Dwarf
            assert.equals('2-60 r-"Dwarf"', GetWhoQuery())
        end)

        it("scans the Horde races on a Horde character", function()
            SetFaction("Horde")
            restClasses()
            scanner.nextScanRaceIdx = 5

            scanner:TriggerScan()

            assert.equals('2-60 r-"Windshaper Skyborne"', GetWhoQuery())
        end)

        it("uses the localized race name in race scans", function()
            SetRaceNames({[1] = "Mensch"})
            core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
            scanner = WoWForeverRace.Scanner(core, db, eventbus)
            scanner.probe = NO_PROBE
            restClasses()

            scanner:TriggerScan()

            assert.equals('2-60 r-"Mensch"', GetWhoQuery())
        end)

        it("skips a race whose leaderboard is final", function()
            restClasses()
            local humans = db.factionrealm.leaderboard[WoWForeverRace.Config:RaceBoardIndex(1)]
            for i = 1, WoWForeverRace.Config.MaxLeaderboardSize do
                humans.players[i] = {name = "Human" .. i, level = 60, classIndex = 1, raceIndex = 1, dingedAt = time}
            end
            humans.minLevel = 60

            scanner:TriggerScan()

            assert.equals('2-60 r-"Dwarf"', GetWhoQuery())
        end)

        it("does not attribute a manual /who to a pending race scan", function()
            restClasses()
            scanner:TriggerScan()
            assert.equals('2-60 r-"Human"', GetWhoQuery())

            local eventBusSpy = spy.on(eventbus, "PublishEvent")
            SetWhoResults({{fullName = "Shorty", level = 20, filename = "MAGE", raceStr = "Gnome"}})
            scanner:OnWhoListUpdate()

            assert.spy(eventBusSpy).called_at_most(0)
            assert.is_true(scanner.scanPending)

            -- the real response, with a name the client could not resolve in between
            SetWhoResults({
                {fullName = "Hume", level = 45, filename = "MAGE", raceStr = "Human"},
                {fullName = "Humette", level = 44, filename = "MAGE", raceStr = "Humanette"},
            })
            scanner:OnWhoListUpdate()

            assert.is_false(scanner.scanPending)
            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus),
                    WoWForeverRace.Config.Events.SlashWhoResult, {
                        {name = "Hume", level = 45, class = "MAGE", raceIndex = 1},
                        {name = "Humette", level = 44, class = "MAGE"},
                    })
        end)

        it("bisects the floor of a crowded race like a class floor", function()
            restClasses()
            db.factionrealm.leaderboard[0].highestLevel = 60
            local rows = {}
            for i = 1, 50 do
                rows[i] = {fullName = "Human" .. i, level = 30, filename = "MAGE", raceStr = "Human"}
            end

            scanner:TriggerScan()
            assert.equals('2-60 r-"Human"', GetWhoQuery())
            SetWhoResults(rows, 200)
            scanner:OnWhoListUpdate()

            -- every other race rests, so the rotation comes back to Human
            for _, raceIndex in ipairs({3, 4, 7, 95}) do
                scanner.classScanComplete[WoWForeverRace.Config:RaceBoardIndex(raceIndex)] = time
            end
            SetTime(time + 16)
            scanner:TriggerScan()

            assert.equals('31-60 r-"Human"', GetWhoQuery())
        end)

        it("starts a crowded race where the probe expects it to fit under the cap", function()
            scanner.probe = nil
            db.factionrealm.leaderboard[0].highestLevel = 7
            local rows = {}
            for i = 1, 50 do
                rows[i] = {
                    fullName = "Player" .. i,
                    level    = i <= 4 and 6 or (i <= 12 and 4 or 2),
                    filename = "MAGE",
                    raceStr  = i % 2 == 0 and "Human" or "Gnome",
                }
            end
            scanner:TriggerScan()
            assert.equals("2-60", GetWhoQuery())
            SetWhoResults(rows, 400)
            scanner:OnWhoListUpdate()

            restClasses()
            SetTime(time + 16)
            scanner:TriggerScan()

            -- 50 of ~200 humans fit: the top quarter of the sample starts at level 4
            assert.equals('4-60 r-"Human"', GetWhoQuery())
        end)
    end)
end)
