-- load test base
local WoWForeverRace = require("testbase")

-- aliases
local Events = WoWForeverRace.Config.Events
local DRUIDIDX, WARRIORIDX, PALADINIDX, PRIESTIDX =
WoWForeverRace.Config.ClassIndexes["DRUID"], WoWForeverRace.Config.ClassIndexes["WARRIOR"],
WoWForeverRace.Config.ClassIndexes["PALADIN"],WoWForeverRace.Config.ClassIndexes["PRIEST"]

local function merge(...)
    local config = {}
    for _, c in pairs({...}) do
        for k, v in pairs(c) do
            config[k] = v
        end
    end

    return config
end

local function leaderboardSpies(tracker, config)
    local spies = {}

    spies[0] = spy.on(tracker.lbGlobal, "ProcessPlayerInfo")

    for _, classIndex in ipairs(config.MopClassIndexes) do
        spies[classIndex] = spy.on(tracker.lbPerClass[classIndex], "ProcessPlayerInfo")
    end

    return spies
end

describe("Tracker", function()
    ---@type WoWForeverRaceConfig
    local config
    local db
    ---@type WoWForeverRaceCore
    local core
    ---@type WoWForeverRaceEventBus
    local eventbus
    ---@type WoWForeverRaceNetwork
    local network
    ---@type WoWForeverRaceTracker
    local tracker
    local time = 1000000000

    local function playerInfo(name, level, classIndex, dingedAt)
        if classIndex == nil then
            classIndex = 11
        end
        if dingedAt == nil then
            dingedAt = time
        end

        return {
            name = name,
            level = level,
            classIndex = classIndex,
            dingedAt = dingedAt,
        }
    end



    before_each(function()
        _G.C_Timer.Reset()
        config = merge(WoWForeverRace.Config, {MaxLeaderboardSize = 5})
        db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
        db:ResetDB()
        core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
        -- mock core:Now() to return our mocked time
        function core:Now() return time end
        eventbus = WoWForeverRace.EventBus()
        network = {SendObject = function() end}
        tracker = WoWForeverRace.Tracker(config, core, db, eventbus, network)
    end)

    after_each(function()
        -- reset any mocking of IsInGuild we did
        _G.SetIsInGuild(nil)
    end)

    describe("leaderboard", function()
        it("adds players to global and class board", function()
            local lbSpies = leaderboardSpies(tracker, config)

            local pInfo

            pInfo = playerInfo("Nubone", 5, DRUIDIDX)
            tracker:ProcessPlayerInfoBatch({ pInfo, })
            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), pInfo)
            assert.spy(lbSpies[DRUIDIDX]).was_called_with(match.is_ref(tracker.lbPerClass[DRUIDIDX]), pInfo)

            pInfo = playerInfo("Nub2", 5, WARRIORIDX)
            tracker:ProcessPlayerInfoBatch({ pInfo, })
            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), pInfo)
            assert.spy(lbSpies[WARRIORIDX]).was_called_with(match.is_ref(tracker.lbPerClass[WARRIORIDX]), pInfo)

            pInfo = playerInfo("Nubthree", 5, PALADINIDX)
            tracker:ProcessPlayerInfoBatch({ pInfo, })
            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), pInfo)
            assert.spy(lbSpies[PALADINIDX]).was_called_with(match.is_ref(tracker.lbPerClass[PALADINIDX]), pInfo)

            pInfo = playerInfo("Nubfour", 5, PRIESTIDX)
            tracker:ProcessPlayerInfoBatch({ pInfo, })
            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), pInfo)
            assert.spy(lbSpies[PRIESTIDX]).was_called_with(match.is_ref(tracker.lbPerClass[PRIESTIDX]), pInfo)
        end)

        it("fixes missing dingedAt", function()
            local lbSpies = leaderboardSpies(tracker, config)

            tracker:ProcessPlayerInfo({name = "Nubone", level = 5, classIndex = DRUIDIDX})

            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal),
                    playerInfo("Nubone", 5, DRUIDIDX, time))
        end)

        it("fixes class to classIndex", function()
            local lbSpies = leaderboardSpies(tracker, config)

            tracker:ProcessPlayerInfo({name = "Nubone", level = 5, class = "DRUID"})

            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal),
                    playerInfo("Nubone", 5, DRUIDIDX, time))
        end)

        it("should broadcast internal event", function()
            local eventBusSpy = spy.on(eventbus, "PublishEvent")

            tracker:ProcessPlayerInfoBatch({ playerInfo("Nubone", 5), })
            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), config.Events.Ding,
                    match.is_table(), 1, 1)

            tracker:ProcessPlayerInfoBatch({ playerInfo("Nubone", 6), })
            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), config.Events.Ding,
                    match.is_table(), 1, 1)

            tracker:ProcessPlayerInfoBatch({ playerInfo("Nub2", 7), })
            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), config.Events.Ding,
                    match.is_table(), 1, 1)

            eventBusSpy:clear()
            tracker:ProcessPlayerInfoBatch({ playerInfo("Nubone", 6), })
            assert.spy(eventBusSpy).was_not_called()

            tracker:ProcessPlayerInfoBatch({ playerInfo("Nubone", 7), })
            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), config.Events.Ding,
                    match.is_table(), 2, 2)
        end)

        it("shouldn't broadcast to network OnNetPlayerInfo", function()
            local networkSpy = spy.on(network, "SendObject")

            tracker:OnNetPlayerInfoBatch({
                WoWForeverRace.Serializer.SerializePlayerInfoBatch({
                    {name = "Nubone", level = 7, classIndex = 11, dingedAt = 1000000100},
                }),
                false
            })
            assert.spy(networkSpy).was_not_called()
        end)

        it("should publish Ding on OnNetPlayerInfo", function()
            local eventBusSpy = spy.on(eventbus, "PublishEvent")

            tracker:OnNetPlayerInfoBatch({
                WoWForeverRace.Serializer.SerializePlayerInfoBatch({
                    {name = "Nubone", level = 7, classIndex = DRUIDIDX, dingedAt = 1000000100},
                }), false, DRUIDIDX
            })

            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), config.Events.Ding,
                    match.is_table(), 1, 1)

            assert.spy(eventBusSpy).called_at_most(1)
        end)

        it("handles unknown classIndex (0) in a batch without error", function()
            tracker:OnNetPlayerInfoBatch({
                WoWForeverRace.Serializer.SerializePlayerInfoBatch({
                    {name = "Nubone", level = 7, classIndex = 0, dingedAt = 1000000100},
                }), false, 0
            })

            assert.equals(1, #db.factionrealm.leaderboard[0].players)
            assert.equals(0, db.factionrealm.leaderboard[0].players[1].classIndex)
        end)

        it("ignores player info without a name", function()
            local eventBusSpy = spy.on(eventbus, "PublishEvent")

            tracker:ProcessPlayerInfo({level = 7, classIndex = DRUIDIDX})
            tracker:ProcessPlayerInfo({name = "", level = 7, classIndex = DRUIDIDX})

            assert.equals(0, #db.factionrealm.leaderboard[0].players)
            assert.is_nil(next(db.factionrealm.playerHistory))
            assert.spy(eventBusSpy).was_not_called()
        end)

        it("ignores player info with an invalid level", function()
            tracker:ProcessPlayerInfo(playerInfo("Nubone", 0))
            tracker:ProcessPlayerInfo(playerInfo("Nubtwo", "7"))
            tracker:ProcessPlayerInfo(playerInfo("Nubthree", config.MaxLevel + 1))

            assert.equals(0, #db.factionrealm.leaderboard[0].players)
        end)

        it("ignores player info with a non-integer level", function()
            tracker:ProcessPlayerInfo(playerInfo("Nubone", 42.5))

            assert.equals(0, #db.factionrealm.leaderboard[0].players)
        end)

        it("ignores player info with a forged or corrupt dingedAt", function()
            local eventBusSpy = spy.on(eventbus, "PublishEvent")

            tracker:ProcessPlayerInfo(playerInfo("Zero", 60, DRUIDIDX, 0))
            tracker:ProcessPlayerInfo(playerInfo("Negative", 60, DRUIDIDX, -5))
            tracker:ProcessPlayerInfo(playerInfo("Ancient", 60, DRUIDIDX, 1))
            tracker:ProcessPlayerInfo(playerInfo("Future", 60, DRUIDIDX, time + 3600))
            tracker:ProcessPlayerInfo(playerInfo("Infinite", 60, DRUIDIDX, math.huge))
            tracker:ProcessPlayerInfo({name = "Text", level = 60, classIndex = DRUIDIDX, dingedAt = "soon"})

            assert.equals(0, #db.factionrealm.leaderboard[0].players)
            assert.is_nil(db.factionrealm.raceStartedAt)
            assert.is_nil(db.factionrealm.firstToLevel[0])
            assert.spy(eventBusSpy).was_not_called()
        end)

        it("accepts a dingedAt slightly ahead of our clock", function()
            tracker:ProcessPlayerInfo(playerInfo("Ahead", 60, DRUIDIDX, time + 60))

            assert.equals(1, #db.factionrealm.leaderboard[0].players)
        end)

        it("ignores malformed network batches", function()
            assert.has_no.errors(function()
                tracker:OnNetPlayerInfoBatch("not a table")
                tracker:OnNetPlayerInfoBatch({})
                tracker:OnNetPlayerInfoBatch({42})
                tracker:OnNetPlayerInfoBatch({{}})
            end)
            assert.equals(0, #db.factionrealm.leaderboard[0].players)
        end)

        it("should broadcast to network OnSlashWhoResult", function()
            local networkSpy = spy.on(network, "SendObject")

            tracker:OnSlashWhoResult({ playerInfo("Nubone", 5), })
            -- yells immediately for real-time zone updates
            assert.spy(networkSpy).was_called_with(match.is_ref(network), config.Network.Events.PlayerInfoBatch,
                    match.is_table(), "YELL")
            assert.spy(networkSpy).called_at_most(1)

            -- guild push is batched behind DingPushDelay
            _G.C_Timer.Advance(config.DingPushDelay)
            assert.spy(networkSpy).was_called_with(match.is_ref(network), config.Network.Events.PlayerInfoBatch,
                    match.is_table(), "GUILD")
            assert.spy(networkSpy).called_at_most(2)
        end)

        it("should broadcast to network OnSlashWhoResult, not to guild when not in guild", function()
            local networkSpy = spy.on(network, "SendObject")

            _G.SetIsInGuild(false)

            tracker:OnSlashWhoResult({ playerInfo("Nubone", 5), })
            assert.spy(networkSpy).was_called_with(match.is_ref(network), config.Network.Events.PlayerInfoBatch,
                    match.is_table(), "YELL")
            assert.spy(networkSpy).called_at_most(1)

            _G.C_Timer.Advance(config.DingPushDelay)
            assert.spy(networkSpy).called_at_most(1)
        end)
    end)

    describe("Pioneers", function()
        it("UpdatePioneers sets raceStartedAt on first player", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            assert.equals(time, db.factionrealm.raceStartedAt)
        end)

        it("UpdatePioneers updates raceStartedAt to the minimum seen", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            tracker:ProcessPlayerInfo(playerInfo("Bob", 16, WARRIORIDX, time - 100))
            assert.equals(time - 100, db.factionrealm.raceStartedAt)
        end)

        it("UpdatePioneers does not lower raceStartedAt for a later timestamp", function()
            tracker:ProcessPlayerInfo(playerInfo("Bob", 16, WARRIORIDX, time - 100))
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            assert.equals(time - 100, db.factionrealm.raceStartedAt)
        end)

        it("UpdatePioneers records first player to reach each level (overall)", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            local ftl0 = db.factionrealm.firstToLevel[0]
            assert.equals("Alice",   ftl0[15].name)
            assert.equals(DRUIDIDX,  ftl0[15].classIndex)
            assert.equals(time,      ftl0[15].dingedAt)
        end)

        it("UpdatePioneers records first player to reach each level (per class)", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            local ftlDruid = db.factionrealm.firstToLevel[DRUIDIDX]
            assert.equals("Alice", ftlDruid[15].name)
            assert.equals(time,    ftlDruid[15].dingedAt)
        end)

        it("UpdatePioneers keeps earliest record per level (overall)", function()
            tracker:ProcessPlayerInfo(playerInfo("Bob",   15, WARRIORIDX, time))
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX,   time - 100))
            assert.equals("Alice", db.factionrealm.firstToLevel[0][15].name)
        end)

        it("UpdatePioneers does not overwrite an earlier record with a later one", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX,   time - 100))
            tracker:ProcessPlayerInfo(playerInfo("Bob",   15, WARRIORIDX, time))
            assert.equals("Alice", db.factionrealm.firstToLevel[0][15].name)
        end)

        it("UpdatePioneers uses name as tiebreaker when dingedAt is equal", function()
            tracker:ProcessPlayerInfo(playerInfo("Zebra",    15, WARRIORIDX, time))
            tracker:ProcessPlayerInfo(playerInfo("Aardvark", 15, DRUIDIDX,   time))
            assert.equals("Aardvark", db.factionrealm.firstToLevel[0][15].name)
        end)

        it("UpdatePlayerHistory records dingedAt per level", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            local hist = db.factionrealm.playerHistory["Alice"]
            assert.equals(time,     hist.levels[15])
            assert.equals(DRUIDIDX, hist.classIndex)
        end)

        it("UpdatePlayerHistory keeps earliest dingedAt per level", function()
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time))
            tracker:ProcessPlayerInfo(playerInfo("Alice", 15, DRUIDIDX, time - 50))
            assert.equals(time - 50, db.factionrealm.playerHistory["Alice"].levels[15])
        end)

        it("OnFTLSyncResult merges remote firstToLevel into local DB", function()
            local ftldb = {
                [0] = {[10] = {name = "Remote", classIndex = WARRIORIDX, dingedAt = time - 200}},
            }
            tracker:OnFTLSyncResult(ftldb)
            assert.equals("Remote",  db.factionrealm.firstToLevel[0][10].name)
            assert.equals(time - 200, db.factionrealm.raceStartedAt)
        end)

        it("OnFTLSyncResult keeps local record when it is earlier", function()
            tracker:ProcessPlayerInfo(playerInfo("Local", 10, DRUIDIDX, time - 500))
            local ftldb = {
                [0] = {[10] = {name = "Remote", classIndex = WARRIORIDX, dingedAt = time - 200}},
            }
            tracker:OnFTLSyncResult(ftldb)
            assert.equals("Local", db.factionrealm.firstToLevel[0][10].name)
        end)

        it("OnFTLSyncResult overwrites local record when remote is earlier", function()
            tracker:ProcessPlayerInfo(playerInfo("Local", 10, DRUIDIDX, time - 100))
            local ftldb = {
                [0] = {[10] = {name = "Remote", classIndex = WARRIORIDX, dingedAt = time - 500}},
            }
            tracker:OnFTLSyncResult(ftldb)
            assert.equals("Remote", db.factionrealm.firstToLevel[0][10].name)
        end)
    end)

    describe("Realm launch", function()
        local launchAt = time - 1000

        before_each(function()
            -- the launch has passed; shadow the real (future) Config value
            core.Config = setmetatable({RealmLaunchAt = launchAt}, {__index = WoWForeverRace.Config})
        end)

        it("ignores player info from before the launch", function()
            tracker:ProcessPlayerInfo(playerInfo("Beta", 10, DRUIDIDX, launchAt - 1))
            tracker:ProcessPlayerInfo(playerInfo("Live", 5, DRUIDIDX, launchAt))

            assert.equals(1, #db.factionrealm.leaderboard[0].players)
            assert.equals("Live", db.factionrealm.leaderboard[0].players[1].name)
            assert.is_nil(db.factionrealm.playerHistory["Beta"])
            assert.equals(launchAt, db.factionrealm.raceStartedAt)
        end)

        it("OnFTLSyncResult ignores records and realmOpenedAt from before the launch", function()
            tracker:OnFTLSyncResult({
                [0] = {
                    [10] = {name = "Beta", classIndex = WARRIORIDX, dingedAt = launchAt - 1},
                    [9] = {name = "Live", classIndex = WARRIORIDX, dingedAt = launchAt + 1},
                },
            }, launchAt - 500)

            assert.is_nil(db.factionrealm.firstToLevel[0][10])
            assert.equals("Live", db.factionrealm.firstToLevel[0][9].name)
            assert.is_nil(db.factionrealm.realmOpenedAt)
            assert.equals(launchAt + 1, db.factionrealm.raceStartedAt)
        end)

        it("OnPHSyncResult ignores levels from before the launch", function()
            tracker:OnPHSyncResult({
                ["Remote"] = {classIndex = WARRIORIDX, levels = {[5] = launchAt - 1, [6] = launchAt + 1}},
            })

            assert.is_nil(db.factionrealm.playerHistory["Remote"].levels[5])
            assert.equals(launchAt + 1, db.factionrealm.playerHistory["Remote"].levels[6])
        end)

        describe("PurgePreLaunchData", function()
            local launched

            before_each(function()
                -- collect beta data while the launch is still ahead, then let it pass
                launched = core.Config
                core.Config = setmetatable({RealmLaunchAt = time + 1000}, {__index = WoWForeverRace.Config})
                db.factionrealm.realmOpenedAt = launchAt - 5000
                db.factionrealm.buddies["BetaBuddy"] = {lastSeen = launchAt - 10}
                db.factionrealm.buddies["LiveBuddy"] = {lastSeen = launchAt + 10}
                db.profile.options.networking = false
                tracker:ProcessPlayerInfo(playerInfo("Beta", 10, DRUIDIDX, launchAt - 100))
                tracker:ProcessPlayerInfo(playerInfo("Both", 4, WARRIORIDX, launchAt - 50))
                tracker:ProcessPlayerInfo(playerInfo("Both", 5, WARRIORIDX, launchAt + 50))
                tracker:ProcessPlayerInfo(playerInfo("Live", 3, DRUIDIDX, launchAt + 10))
            end)

            it("does nothing while the launch is still ahead", function()
                tracker:PurgePreLaunchData()

                assert.equals(3, #db.factionrealm.leaderboard[0].players)
                assert.equals(launchAt - 5000, db.factionrealm.realmOpenedAt)
            end)

            it("drops only the race data from before the launch", function()
                db.factionrealm.finished = true
                core.Config = launched
                tracker:PurgePreLaunchData()

                local players = db.factionrealm.leaderboard[0].players
                assert.equals(2, #players)
                assert.equals("Both", players[1].name)
                assert.equals("Live", players[2].name)
                assert.equals(5, db.factionrealm.leaderboard[0].highestLevel)
                assert.equals(2, db.factionrealm.leaderboard[0].minLevel)
                assert.equals(1, #db.factionrealm.leaderboard[DRUIDIDX].players)

                assert.is_nil(db.factionrealm.firstToLevel[0][10])
                assert.is_nil(db.factionrealm.firstToLevel[0][4])
                assert.equals("Both", db.factionrealm.firstToLevel[0][5].name)
                assert.is_nil(db.factionrealm.playerHistory["Beta"])
                assert.is_nil(db.factionrealm.playerHistory["Both"].levels[4])
                assert.equals(launchAt + 50, db.factionrealm.playerHistory["Both"].levels[5])

                assert.equals(launchAt + 10, db.factionrealm.raceStartedAt)
                assert.equals(launchAt, db.factionrealm.realmOpenedAt)
                assert.is_false(db.factionrealm.finished)

                assert.is_nil(db.factionrealm.buddies["BetaBuddy"])
                assert.is_not_nil(db.factionrealm.buddies["LiveBuddy"])

                -- settings stay
                assert.is_false(db.profile.options.networking)
            end)

            it("runs from the discovery beacon when the launch passes mid-session", function()
                core.Config = launched
                tracker:SendDiscoveryBeacon()

                assert.equals(2, #db.factionrealm.leaderboard[0].players)
            end)

            it("publishes BuddyUpdate when buddies were dropped", function()
                local eventBusSpy = spy.on(eventbus, "PublishEvent")
                core.Config = launched
                tracker:PurgePreLaunchData()

                assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), config.Events.BuddyUpdate)
            end)

            it("survives a pioneer record without dingedAt", function()
                -- array part, so the valid record is visited first and the broken one gets compared
                db.factionrealm.firstToLevel[0] = {
                    {name = "Live", classIndex = DRUIDIDX, dingedAt = launchAt + 10},
                    {name = "Broken", classIndex = DRUIDIDX},
                }
                core.Config = launched
                tracker:PurgePreLaunchData()

                assert.equals(launchAt + 10, db.factionrealm.raceStartedAt)
            end)

            it("runs before a ding is processed, so a beta record cannot hold its slot", function()
                core.Config = launched
                tracker:ProcessPlayerInfo(playerInfo("First", 10, WARRIORIDX, launchAt + 60))

                assert.equals("First", db.factionrealm.firstToLevel[0][10].name)
            end)

            it("runs before a sync result is merged, so a beta record cannot hold its slot", function()
                core.Config = launched
                tracker:OnFTLSyncResult({
                    [0] = {[10] = {name = "First", classIndex = WARRIORIDX, dingedAt = launchAt + 60}},
                })
                assert.equals("First", db.factionrealm.firstToLevel[0][10].name)
            end)

            it("runs before a history chunk is merged, so a beta level cannot hold its slot", function()
                core.Config = launched
                tracker:OnPHSyncResult({
                    ["Both"] = {classIndex = WARRIORIDX, levels = {[4] = launchAt + 20}},
                })
                assert.equals(launchAt + 20, db.factionrealm.playerHistory["Both"].levels[4])
            end)

            it("runs at login", function()
                core.Config = launched
                WoWForeverRace.Tracker(config, core, db, eventbus, network)

                assert.equals(2, #db.factionrealm.leaderboard[0].players)
            end)
        end)

        it("accepts data from before the launch while the launch is still ahead", function()
            core.Config = setmetatable({RealmLaunchAt = time + 1000}, {__index = WoWForeverRace.Config})
            tracker:ProcessPlayerInfo(playerInfo("Beta", 10, DRUIDIDX, time - 500))

            assert.equals("Beta", db.factionrealm.leaderboard[0].players[1].name)
        end)
    end)

    describe("RaceFinished", function()
        -- fills the class leaderboards with max-level players, optionally
        -- leaving some class boards one player short
        local function fillClassLeaderboards(missing)
            missing = missing or {}
            for _, classIndex in ipairs(WoWForeverRace.Config.MopClassIndexes) do
                local size = config.MaxLeaderboardSize
                if missing[classIndex] then size = size - 1 end

                local players = {}
                for i = 1, size do
                    players[i] = {name = "C" .. classIndex .. "Racer" .. i, level = config.MaxLevel,
                                  dingedAt = time + i, classIndex = classIndex}
                end
                db.factionrealm.leaderboard[classIndex].players = players
                if size >= config.MaxLeaderboardSize then
                    db.factionrealm.leaderboard[classIndex].minLevel = config.MaxLevel
                end
            end
            tracker:ReinitLeaderboards()
        end

        it("produces RaceFinished event once", function()
            fillClassLeaderboards()
            local eventBusSpy = spy.on(eventbus, "PublishEvent")

            tracker:OnScanFinished(false)
            assert.spy(eventBusSpy).called_at_most(0)

            tracker:OnScanFinished(true)
            tracker:OnScanFinished(true)
            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), Events.RaceFinished)
            assert.spy(eventBusSpy).called_at_most(1)
        end)

        it("finishes when every class leaderboard is full at max level", function()
            fillClassLeaderboards()

            tracker:CheckRaceFinished()

            assert.is_true(db.factionrealm.finished)
        end)

        it("does not finish while a class leaderboard is unfilled", function()
            fillClassLeaderboards({[PALADINIDX] = true})
            -- a full global leaderboard at max level is not sufficient
            local players = {}
            for i = 1, config.MaxLeaderboardSize do
                players[i] = {name = "Racer" .. i, level = config.MaxLevel,
                              dingedAt = time + i, classIndex = WARRIORIDX}
            end
            db.factionrealm.leaderboard[0].players = players
            db.factionrealm.leaderboard[0].minLevel = config.MaxLevel

            tracker:CheckRaceFinished()
            tracker:OnScanFinished(true)

            assert.is_false(db.factionrealm.finished)
        end)

        it("finishes via ProcessPlayerInfo when the final ding fills the last class leaderboard", function()
            fillClassLeaderboards({[WARRIORIDX] = true})

            tracker:ProcessPlayerInfo(playerInfo("Lastracer", config.MaxLevel, WARRIORIDX))

            assert.is_true(db.factionrealm.finished)
        end)

        it("rejects player info with a level above max level", function()
            tracker:ProcessPlayerInfo(playerInfo("Cheater", 999, WARRIORIDX))

            assert.equals(0, #db.factionrealm.leaderboard[0].players)
            assert.is_nil(db.factionrealm.playerHistory["Cheater"])
        end)
    end)

    describe("Sync", function()
        it("adds players", function()
            local lbSpies = leaderboardSpies(tracker, config)

            local nub3 = playerInfo("Nubthree", 5)
            local nub4 = playerInfo("Nubfour", 5, PALADINIDX)
            local nub5 = playerInfo("Nubfive", 5, PRIESTIDX, time - 100)
            tracker:OnSyncResult({
                nub3, nub4, nub5,
            })

            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), nub3)
            assert.spy(lbSpies[DRUIDIDX]).was_called_with(match.is_ref(tracker.lbPerClass[DRUIDIDX]), nub3)

            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), nub4)
            assert.spy(lbSpies[PALADINIDX]).was_called_with(match.is_ref(tracker.lbPerClass[PALADINIDX]), nub4)

            assert.spy(lbSpies[0]).was_called_with(match.is_ref(tracker.lbGlobal), nub5)
            assert.spy(lbSpies[PRIESTIDX]).was_called_with(match.is_ref(tracker.lbPerClass[PRIESTIDX]), nub5)

            assert.equals(3, #db.factionrealm.leaderboard[0].players)
            -- canonical order: level desc, dingedAt asc, name asc
            assert.same({
                {name = "Nubfive", level = 5, dingedAt = time - 100, classIndex = PRIESTIDX},
                {name = "Nubfour", level = 5, dingedAt = time, classIndex = PALADINIDX},
                {name = "Nubthree", level = 5, dingedAt = time, classIndex = DRUIDIDX},
            }, db.factionrealm.leaderboard[0].players)
        end)
    end)

    describe("Convergence", function()
        it("NormalizeDB re-sorts legacy leaderboard order and floors timestamps", function()
            db.factionrealm.leaderboard[0].players = {
                {name = "Zebra", level = 5, dingedAt = time + 0.7, classIndex = DRUIDIDX},
                {name = "Aardvark", level = 5, dingedAt = time, classIndex = WARRIORIDX},
                {name = "Top", level = 7, dingedAt = time, classIndex = PRIESTIDX},
            }

            -- constructing a tracker normalizes the persisted data
            WoWForeverRace.Tracker(config, core, db, WoWForeverRace.EventBus(), network)

            assert.same({
                {name = "Top", level = 7, dingedAt = time, classIndex = PRIESTIDX},
                {name = "Aardvark", level = 5, dingedAt = time, classIndex = WARRIORIDX},
                {name = "Zebra", level = 5, dingedAt = time, classIndex = DRUIDIDX},
            }, db.factionrealm.leaderboard[0].players)
        end)

        it("clients converge on identical hashes after one bidirectional sync", function()
            -- regression for issue #16: A knows the player's class at a stale lower
            -- level, B has the newer level but doesn't know the class
            local dbB = LibStub("AceDB-3.0"):New("WoWForeverRace_DB_B", WoWForeverRace.DefaultDB, true)
            dbB:ResetDB()
            local trackerB = WoWForeverRace.Tracker(config, core, dbB, WoWForeverRace.EventBus(), network)

            tracker:ProcessPlayerInfo({name = "Racer", level = 20, classIndex = DRUIDIDX, dingedAt = time - 100})
            trackerB:ProcessPlayerInfo({name = "Racer", level = 25, classIndex = 0, dingedAt = time})
            assert.not_equals(tracker:ComputeFullHash(), trackerB:ComputeFullHash())

            -- exchange all leaderboards both ways through the wire format,
            -- snapshotting both sides first like the real sync exchange does
            local wire = function(t)
                local strs = {}
                for _, b in ipairs(t:CollectBatches(nil) or {}) do
                    strs[#strs + 1] = WoWForeverRace.Serializer.SerializePlayerInfoBatch(b.players)
                end
                return strs
            end
            local batchesA, batchesB = wire(tracker), wire(trackerB)
            for _, str in ipairs(batchesB) do
                tracker:OnSyncResult(WoWForeverRace.Serializer.DeserializePlayerInfoBatch(str))
            end
            for _, str in ipairs(batchesA) do
                trackerB:OnSyncResult(WoWForeverRace.Serializer.DeserializePlayerInfoBatch(str))
            end

            assert.equals(tracker:ComputeFullHash(), trackerB:ComputeFullHash())
            -- both ended up with the latest level and the known class
            assert.same({name = "Racer", level = 25, dingedAt = time, classIndex = DRUIDIDX},
                    db.factionrealm.leaderboard[0].players[1])
            assert.same({name = "Racer", level = 25, dingedAt = time, classIndex = DRUIDIDX},
                    dbB.factionrealm.leaderboard[0].players[1])
        end)

        it("UpdatePioneers ignores level 1", function()
            tracker:ProcessPlayerInfo(playerInfo("Fresh", 1, DRUIDIDX, time))
            assert.is_nil(db.factionrealm.firstToLevel[0])
        end)

        it("OnFTLSyncResult fills in a missing classIndex on otherwise identical records", function()
            tracker:ProcessPlayerInfo({name = "Racer", level = 10, classIndex = 0, dingedAt = time})
            assert.equals(0, db.factionrealm.firstToLevel[0][10].classIndex)

            tracker:OnFTLSyncResult({
                [0] = {[10] = {name = "Racer", classIndex = DRUIDIDX, dingedAt = time}},
            })

            assert.equals(DRUIDIDX, db.factionrealm.firstToLevel[0][10].classIndex)
        end)

        it("OnPHSyncResult merges new players into playerHistory", function()
            tracker:OnPHSyncResult({
                Racer = {classIndex = WARRIORIDX, levels = {[10] = time - 100, [11] = time}},
            })

            local hist = db.factionrealm.playerHistory["Racer"]
            assert.equals(WARRIORIDX, hist.classIndex)
            assert.equals(time - 100, hist.levels[10])
            assert.equals(time, hist.levels[11])
        end)

        it("OnPHSyncResult keeps the earliest dingedAt per level", function()
            tracker:ProcessPlayerInfo(playerInfo("Racer", 10, DRUIDIDX, time - 100))

            tracker:OnPHSyncResult({
                Racer = {classIndex = DRUIDIDX, levels = {[10] = time, [11] = time + 50}},
            })

            local hist = db.factionrealm.playerHistory["Racer"]
            -- local level-10 record was earlier, remote level-11 record is new
            assert.equals(time - 100, hist.levels[10])
            assert.equals(time + 50, hist.levels[11])
        end)

        it("OnPHSyncResult fills in a missing classIndex", function()
            tracker:ProcessPlayerInfo({name = "Racer", level = 10, classIndex = 0, dingedAt = time})
            assert.equals(0, db.factionrealm.playerHistory["Racer"].classIndex)

            tracker:OnPHSyncResult({
                Racer = {classIndex = DRUIDIDX, levels = {[10] = time}},
            })

            assert.equals(DRUIDIDX, db.factionrealm.playerHistory["Racer"].classIndex)
        end)

        it("OnPHSyncResult ignores levels that don't fit the wire format", function()
            tracker:OnPHSyncResult({
                Racer = {classIndex = DRUIDIDX, levels = {[1] = time, [100] = time, [10] = time}},
            })

            local hist = db.factionrealm.playerHistory["Racer"]
            assert.is_nil(hist.levels[1])
            assert.is_nil(hist.levels[100])
            assert.equals(time, hist.levels[10])
        end)

        it("PrunePlayerHistory keeps everyone while the race is still live", function()
            db.factionrealm.leaderboard[0].players = {
                {name = "OnBoard", level = 30, dingedAt = time, classIndex = DRUIDIDX},
            }
            db.factionrealm.playerHistory = {
                OnBoard = {classIndex = DRUIDIDX, levels = {[30] = time}},
                Rando = {classIndex = WARRIORIDX, levels = {[10] = time}},
            }

            -- constructing a tracker runs NormalizeDB, which prunes
            WoWForeverRace.Tracker(config, core, db, WoWForeverRace.EventBus(), network)

            -- no leaderboard is final yet: Rando may still enter the race
            assert.is_table(db.factionrealm.playerHistory["OnBoard"])
            assert.is_table(db.factionrealm.playerHistory["Rando"])
        end)

        it("PrunePlayerHistory drops non-members once their class leaderboard is final", function()
            local players = {}
            for i = 1, config.MaxLeaderboardSize do
                players[i] = {name = "Warrior" .. i, level = config.MaxLevel, dingedAt = time + i,
                              classIndex = WARRIORIDX}
            end
            db.factionrealm.leaderboard[WARRIORIDX].players = players
            db.factionrealm.leaderboard[WARRIORIDX].minLevel = config.MaxLevel

            db.factionrealm.playerHistory = {
                Warrior1 = {classIndex = WARRIORIDX, levels = {[config.MaxLevel] = time}},
                Rando = {classIndex = WARRIORIDX, levels = {[10] = time}},
                Druid = {classIndex = DRUIDIDX, levels = {[10] = time}},
                Unknown = {classIndex = 0, levels = {[10] = time}},
                -- ourselves, same class as the final board but never pruned
                Nub = {classIndex = WARRIORIDX, levels = {[5] = time}},
            }

            WoWForeverRace.Tracker(config, core, db, WoWForeverRace.EventBus(), network)

            -- warriors not on the final warrior board are out of that race
            assert.is_nil(db.factionrealm.playerHistory["Rando"])
            -- board members, other classes (their boards are still live), unknown-class
            -- players (global board still live) and ourselves are all kept
            assert.is_table(db.factionrealm.playerHistory["Warrior1"])
            assert.is_table(db.factionrealm.playerHistory["Druid"])
            assert.is_table(db.factionrealm.playerHistory["Unknown"])
            assert.is_table(db.factionrealm.playerHistory["Nub"])
        end)

        it("PrunePlayerHistory drops unknown-class non-members once the global leaderboard is final", function()
            local players = {}
            for i = 1, config.MaxLeaderboardSize do
                players[i] = {name = "Racer" .. i, level = config.MaxLevel, dingedAt = time + i,
                              classIndex = DRUIDIDX}
            end
            db.factionrealm.leaderboard[0].players = players
            db.factionrealm.leaderboard[0].minLevel = config.MaxLevel

            db.factionrealm.playerHistory = {
                Unknown = {classIndex = 0, levels = {[10] = time}},
            }

            WoWForeverRace.Tracker(config, core, db, WoWForeverRace.EventBus(), network)

            assert.is_nil(db.factionrealm.playerHistory["Unknown"])
        end)

        it("PrunePlayerHistory drops all non-members when the race is finished", function()
            db.factionrealm.finished = true
            db.factionrealm.leaderboard[0].players = {
                {name = "OnBoard", level = 30, dingedAt = time, classIndex = DRUIDIDX},
            }
            db.factionrealm.playerHistory = {
                OnBoard = {classIndex = DRUIDIDX, levels = {[30] = time}},
                Rando = {classIndex = WARRIORIDX, levels = {[10] = time}},
                Nub = {classIndex = DRUIDIDX, levels = {[5] = time}},
            }

            WoWForeverRace.Tracker(config, core, db, WoWForeverRace.EventBus(), network)

            assert.is_nil(db.factionrealm.playerHistory["Rando"])
            assert.is_table(db.factionrealm.playerHistory["OnBoard"])
            assert.is_table(db.factionrealm.playerHistory["Nub"])
        end)

        it("OnFTLSyncResult ignores records that don't fit the wire format", function()
            tracker:OnFTLSyncResult({
                [0] = {
                    [1] = {name = "Fresh", classIndex = DRUIDIDX, dingedAt = time},
                    [100] = {name = "Impossible", classIndex = DRUIDIDX, dingedAt = time},
                    [10] = {name = "Racer", classIndex = DRUIDIDX, dingedAt = time},
                },
            })

            assert.is_nil(db.factionrealm.firstToLevel[0][1])
            assert.is_nil(db.factionrealm.firstToLevel[0][100])
            assert.equals("Racer", db.factionrealm.firstToLevel[0][10].name)
        end)
    end)

    describe("ComputeNeedSet", function()
        it("skips classes the requester's build does not track", function()
            tracker:ProcessPlayerInfo(playerInfo("Pally", 30, PALADINIDX))

            -- requester reports every board except Paladin (index + 1), all empty
            local requesterHashes = {}
            for _, classIndex in ipairs({0, 1, 3, 4, 5, 7, 8, 9, 11}) do
                requesterHashes[classIndex + 1] = 5381
            end
            local needSet = tracker:ComputeNeedSet(requesterHashes)

            assert.is_true(needSet[0])
            assert.is_nil(needSet[PALADINIDX])
        end)

        it("includes a class the requester tracks with a different hash", function()
            tracker:ProcessPlayerInfo(playerInfo("Pally", 30, PALADINIDX))

            local requesterHashes = {}
            for _, classIndex in ipairs({0, 1, 2, 3, 4, 5, 7, 8, 9, 11}) do
                requesterHashes[classIndex + 1] = 5381
            end

            assert.is_true(tracker:ComputeNeedSet(requesterHashes)[PALADINIDX])
        end)
    end)
end)
