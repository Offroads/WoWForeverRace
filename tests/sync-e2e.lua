-- End-to-end sync check: two complete addon stacks (Core, EventBus, Network, Tracker,
-- Sync) talk to each other through the real network envelope, one of them seeded
-- with real WoW Forever data (tests/fixtures/horde-pve-factionrealm.lua). Every
-- sync flow must leave the peers with identical data and then go quiet.
local WoWForeverRace = require("testbase")

local Config = WoWForeverRace.Config
local Events = Config.Events
local NetEvents = Config.Network.Events
local AceComm = LibStub("AceComm-3.0")
local AceDB = LibStub("AceDB-3.0")
local AceSerializer = LibStub("AceSerializer-3.0")
local LibCompress = LibStub("LibCompress")
local EncodeTable = LibCompress:GetAddonEncodeTable()

local FIXTURE = "tests/fixtures/horde-pve-factionrealm.lua"
local REALM = "PvE"
local FACTION = "Horde"
-- 2026-09-25: after the fixture's dings (2026-09-21), before Config.RealmLaunchAt
local START = 1790400000

-- AceDB fixes its factionrealm key when the library loads (from the stubs: "Alliance - PvE"),
-- so the fixture is stored under that key; the addon itself sees the Horde faction through
-- UnitFactionGroup and tracks the Horde race leaderboards
local aceDBKey = AceDB:New({}, WoWForeverRace.DefaultDB, true).keys.factionrealm

-- a fresh copy of the fixture as a SavedVariables table
local function realSavedVariables()
    return {factionrealm = {[aceDBKey] = dofile(FIXTURE)}}
end

local function decodeEnvelope(text)
    local ok, envelope = AceSerializer:Deserialize(LibCompress:Decompress(EncodeTable:Decode(text)))
    assert(ok, "envelope did not decode")
    return envelope
end

-- ---------------------------------------------------------------------------
-- the wire: every stack sends through AceComm:SendCommMessage, which is routed
-- to the other stacks' Network:HandleAddonMessage like the addon channel would
-- ---------------------------------------------------------------------------
local stacks, queue, activeStack, log, undelivered, now

local function resetWorld()
    stacks, queue, log, undelivered = {}, {}, {}, {}
    activeStack = nil
    now = START
    _G.SetTime(now)
    _G.C_Timer.Reset()
    _G.SetFaction(FACTION)
end

local originalSendCommMessage = AceComm.SendCommMessage
local function installWire()
    AceComm.SendCommMessage = function(_, prefix, text, channel, target)
        assert(activeStack ~= nil, "send outside of a stack")
        local envelope = decodeEnvelope(text)
        log[#log + 1] = {from = activeStack.name, event = envelope[1], channel = channel, target = target}
        queue[#queue + 1] = {from = activeStack, prefix = prefix, text = text, channel = channel, target = target}
    end
end
local function removeWire()
    AceComm.SendCommMessage = originalSendCommMessage
end

-- delivers every queued message; a message sent while delivering is queued behind the rest
local function pump()
    while #queue > 0 do
        local msg = table.remove(queue, 1)
        local delivered = false
        for _, stack in ipairs(stacks) do
            if stack ~= msg.from then
                local wanted = true
                if msg.channel == "WHISPER" then
                    wanted = stack.name == msg.target
                elseif msg.channel == "GUILD" then
                    wanted = _G.IsInGuild()
                end
                if wanted then
                    delivered = true
                    stack.network:HandleAddonMessage(msg.prefix, msg.text, msg.channel, msg.from.name)
                end
            end
        end
        if not delivered and msg.channel == "WHISPER" then
            undelivered[#undelivered + 1] = msg.from.name .. " -> " .. tostring(msg.target)
        end
    end
end

-- moves the clock and the timers one second at a time, delivering in between
local function advance(seconds)
    pump()
    for _ = 1, seconds do
        now = now + 1
        _G.SetTime(now)
        _G.C_Timer.Advance(1)
        pump()
    end
end

local function stack(name, savedVariables)
    local db = AceDB:New(savedVariables or {}, WoWForeverRace.DefaultDB, true)
    local core = WoWForeverRace.Core(Config, name, REALM)
    local eventbus = WoWForeverRace.EventBus()
    local network = WoWForeverRace.Network(core, eventbus)
    local tracker = WoWForeverRace.Tracker(Config, core, db, eventbus, network)
    local sync = WoWForeverRace.Sync(Config, core, db, eventbus, network)
    local s = {name = name, db = db, core = core, eventbus = eventbus, network = network,
               tracker = tracker, sync = sync}
    -- tag outgoing messages with their stack
    network.SendObject = function(self, ...)
        local previous = activeStack
        activeStack = s
        WoWForeverRace.Network.SendObject(self, ...)
        activeStack = previous
    end
    stacks[#stacks + 1] = s
    return s
end

-- ---------------------------------------------------------------------------
-- comparison helpers
-- ---------------------------------------------------------------------------
local BOARDS = Config:BoardIndexes(FACTION)

local function boardPlayers(s, boardIndex)
    local lb = s.db.factionrealm.leaderboard[boardIndex]
    local out = {}
    for i, p in ipairs(lb and lb.players or {}) do
        out[i] = {name = p.name, level = p.level, dingedAt = p.dingedAt,
                  classIndex = p.classIndex, raceIndex = p.raceIndex}
    end
    return out
end

local function hashes(s)
    return {
        full = WoWForeverRace.Sync.ComputeFullHash(s.db, Config, nil, FACTION),
        ftl = WoWForeverRace.Sync.ComputeFTLHash(s.db, Config),
        ph = WoWForeverRace.Sync.ComputePHHash(s.db, Config, FACTION),
    }
end

local function assertBoardEqual(a, b, boardIndex)
    assert.same(boardPlayers(a, boardIndex), boardPlayers(b, boardIndex),
            "leaderboard " .. boardIndex .. " differs between " .. a.name .. " and " .. b.name)
    assert.equals(WoWForeverRace.Leaderboard.ComputeHash(a.db.factionrealm.leaderboard[boardIndex]),
            WoWForeverRace.Leaderboard.ComputeHash(b.db.factionrealm.leaderboard[boardIndex]),
            "hash of leaderboard " .. boardIndex .. " differs")
end

local function assertAllBoardsEqual(a, b)
    for _, boardIndex in ipairs(BOARDS) do
        assertBoardEqual(a, b, boardIndex)
    end
    assert.equals(hashes(a).full, hashes(b).full, "full hash differs")
end

local function assertFTLEqual(a, b)
    assert.same(a.db.factionrealm.firstToLevel, b.db.factionrealm.firstToLevel, "firstToLevel differs")
    assert.equals(hashes(a).ftl, hashes(b).ftl, "FTL hash differs")
    assert.equals(a.db.factionrealm.realmOpenedAt, b.db.factionrealm.realmOpenedAt, "realmOpenedAt differs")
    assert.equals(a.db.factionrealm.raceStartedAt, b.db.factionrealm.raceStartedAt, "raceStartedAt differs")
end

-- the history of everybody on b's leaderboards must match a's (the race is local only)
local function assertHistoryCovered(a, b)
    local checked = 0
    for _, boardIndex in ipairs(BOARDS) do
        for _, p in ipairs(boardPlayers(b, boardIndex)) do
            local mine, theirs = b.db.factionrealm.playerHistory[p.name], a.db.factionrealm.playerHistory[p.name]
            assert.is_table(theirs, "source has no history for " .. p.name)
            assert.is_table(mine, "receiver has no history for " .. p.name)
            assert.same(theirs.levels, mine.levels, "history levels differ for " .. p.name)
            assert.equals(theirs.classIndex, mine.classIndex, "history class differs for " .. p.name)
            checked = checked + 1
        end
    end
    assert.is_true(checked > 0, "no leaderboard member to check the history of")
end

-- {[event] = number of messages} sent since log entry `since`
local function countEvents(since)
    local counts = {}
    for i = since or 1, #log do
        counts[log[i].event] = (counts[log[i].event] or 0) + 1
    end
    return counts
end

-- number of distinct players on any leaderboard of s (the history sync covers exactly those)
local function playersOnBoards(s)
    local names = {}
    for _, boardIndex in ipairs(BOARDS) do
        for _, p in ipairs(boardPlayers(s, boardIndex)) do names[p.name] = true end
    end
    local n = 0
    for _ in pairs(names) do n = n + 1 end
    return n
end

-- seconds until the last history chunk for s's leaderboard members has been sent
local function historyPullTime(s)
    return Config.PlayerHistoryChunkDelay * math.ceil(playersOnBoards(s) / Config.PlayerHistoryChunkSize) + 1
end

-- ---------------------------------------------------------------------------
describe("Sync end to end with real data", function()
    setup(function() installWire() end)
    teardown(function() removeWire() end)

    before_each(function()
        resetWorld()
        _G.SetIsInGuild(false)
    end)
    after_each(function()
        assert.same({}, undelivered, "whispers that reached nobody")
        _G.SetIsInGuild(nil)
        _G.SetFaction(nil)
        _G.SetGroupState(nil)
    end)

    it("loads the fixture into the right factionrealm without normalizing anything", function()
        local template = dofile(FIXTURE)
        local a = stack("Alpha Tester", realSavedVariables())

        assert.is_false(a.core:HasLaunched())
        for _, boardIndex in ipairs(BOARDS) do
            assert.equals(50, #a.db.factionrealm.leaderboard[boardIndex].players, "board " .. boardIndex)
            -- NormalizeDB must leave data saved by this build untouched, else a client
            -- that just logged in would hash differently from one holding the same file
            assert.same(template.leaderboard[boardIndex].players, a.db.factionrealm.leaderboard[boardIndex].players,
                    "NormalizeDB changed board " .. boardIndex)
        end
        assert.same(template.firstToLevel, a.db.factionrealm.firstToLevel)
        assert.same(template.playerHistory, a.db.factionrealm.playerHistory)
    end)

    it("login zone sync: a fresh client pulls overall, own class, pioneers and history", function()
        local a = stack("Alpha Tester", realSavedVariables())
        a.sync.isReady = true
        local before = hashes(a)
        local b = stack("Beta Tester", {})

        b.sync:InitSync()
        pump()
        assert.equals(1, countEvents()[NetEvents.RequestSync])
        assert.equals(1, countEvents()[NetEvents.OfferSync], "source should offer")

        advance(Config.RequestSyncWait)
        assert.equals(1, countEvents()[NetEvents.StartSync])
        advance(historyPullTime(a))

        assert.is_true(b.sync.isReady)
        assertBoardEqual(a, b, 0)
        assertBoardEqual(a, b, a.sync.classIndex)
        assertFTLEqual(a, b)
        assertHistoryCovered(a, b)
        -- the source is untouched by handing out its data
        assert.same(before, hashes(a))
        -- no retry: the partner answered
        advance(Config.RetrySyncWait)
        assert.equals(1, countEvents()[NetEvents.StartSync])
    end)

    it("login zone sync: a client with identical data gets no offer", function()
        local a = stack("Alpha Tester", realSavedVariables())
        a.sync.isReady = true
        local b = stack("Beta Tester", realSavedVariables())

        b.sync:InitSync()
        pump()
        advance(Config.RequestSyncWait)

        assert.is_nil(countEvents()[NetEvents.OfferSync])
        assert.is_nil(countEvents()[NetEvents.SyncPayload])
        assert.is_true(b.sync.isReady)
    end)

    it("guild login sync: a fresh guild member ends up with every leaderboard", function()
        _G.SetIsInGuild(true)
        local a = stack("Alpha Tester", realSavedVariables())
        a.sync.isReady = true
        local b = stack("Beta Tester", {})

        b.sync:SendGuildSync(true)
        pump()
        advance(Config.GuildSyncWait + 1)
        assert.equals(1, countEvents()[NetEvents.GuildOffer])
        assert.equals(1, countEvents()[NetEvents.StartSync])
        advance(historyPullTime(a))

        assert.equals(#BOARDS, countEvents()[NetEvents.SyncPayload], "one SYNC per leaderboard")
        assertAllBoardsEqual(a, b)
        assertFTLEqual(a, b)
        assert.equals(hashes(a).ph, hashes(b).ph, "history hash differs after the login pull")
        assertHistoryCovered(a, b)

        -- the periodic ticker round afterwards is silent in both directions
        local mark = #log + 1
        b.sync.isReady = true
        b.sync:SendGuildSync()
        advance(Config.GuildSyncWait + 1)
        a.sync:SendGuildSync()
        advance(Config.GuildSyncWait + 1)
        local after = countEvents(mark)
        assert.equals(2, after[NetEvents.GuildSync])
        assert.is_nil(after[NetEvents.GuildOffer], "nobody should offer when in sync")
        assert.is_nil(after[NetEvents.StartSync])
        assert.is_nil(after[NetEvents.SyncPayload])
    end)

    it("buddy ping: both sides push what the other lacks, then go quiet", function()
        local a = stack("Alpha Tester", realSavedVariables())
        local b = stack("Beta Tester", realSavedVariables())
        a.sync.isReady, b.sync.isReady = true, true

        -- b saw a new top player (touches the overall, warrior and orc boards) ...
        b.tracker:ProcessPlayerInfo({name = "Zed Tester", level = 21, classIndex = 1, raceIndex = 2, dingedAt = now - 100})
        assert.equals("Zed Tester", b.db.factionrealm.leaderboard[0].players[1].name)
        -- ... and never scanned the mages properly
        local mage = Config.ClassIndexes.MAGE
        local mageBoard = b.db.factionrealm.leaderboard[mage]
        for i = #mageBoard.players, 11, -1 do table.remove(mageBoard.players, i) end
        assert.not_equals(hashes(a).full, hashes(b).full)

        b.db.factionrealm.buddies["Alpha Tester"] = {lastSeen = now}
        b.sync:SendBuddyPings()
        pump()

        local counts = countEvents()
        assert.equals(1, counts[NetEvents.BuddyPing])
        assert.equals(1, counts[NetEvents.BuddyPong])
        assertAllBoardsEqual(a, b)
        assertFTLEqual(a, b)
        assert.equals("Zed Tester", a.db.factionrealm.leaderboard[0].players[1].name)
        assert.equals(50, #b.db.factionrealm.leaderboard[mage].players)
        -- the buddies remember each other
        assert.is_table(a.db.factionrealm.buddies["Beta Tester"])

        -- a second ping exchanges hashes only
        local mark = #log + 1
        b.sync:SendBuddyPings()
        pump()
        local after = countEvents(mark)
        assert.equals(1, after[NetEvents.BuddyPing])
        assert.equals(1, after[NetEvents.BuddyPong])
        assert.is_nil(after[NetEvents.SyncPayload], "converged peers must not resend leaderboards")
        assert.is_nil(after[NetEvents.FTLSync], "converged peers must not resend pioneers")
    end)

    it("group sync: a BPING to the party converges the members", function()
        _G.SetGroupState(2, false, false)
        local a = stack("Alpha Tester", realSavedVariables())
        local b = stack("Beta Tester", {})
        a.sync.isReady, b.sync.isReady = true, true

        b.sync:OnGroupRosterUpdate()
        advance(3)

        assertAllBoardsEqual(a, b)
        assertFTLEqual(a, b)
    end)

    it("discovery beacon: a zone listener with a different hash gets the missing boards", function()
        local a = stack("Alpha Tester", realSavedVariables())
        local b = stack("Beta Tester", {})

        a.tracker:SendDiscoveryBeacon()
        pump()
        assert.equals(1, countEvents()[NetEvents.DataRequest])
        advance(Config.RequestSyncWait)

        assert.is_true((countEvents()[NetEvents.PlayerInfoBatch] or 0) >= 1)
        assertAllBoardsEqual(a, b)

        -- once equal the next beacon draws no request
        local mark = #log + 1
        a.tracker:SendDiscoveryBeacon()
        advance(Config.RequestSyncWait)
        assert.is_nil(countEvents(mark)[NetEvents.DataRequest])
    end)

    it("ding push: a scan result reaches the zone by YELL and the guild after the delay", function()
        _G.SetIsInGuild(true)
        local a = stack("Alpha Tester", realSavedVariables())
        local b = stack("Beta Tester", realSavedVariables())
        a.sync.isReady, b.sync.isReady = true, true

        b.eventbus:PublishEvent(Events.SlashWhoResult, {
            {name = "Yell Tester", level = 21, classIndex = 4, raceIndex = 8},
        })
        pump()

        assert.equals(1, countEvents()[NetEvents.PlayerInfoBatch])
        assert.equals("Yell Tester", a.db.factionrealm.leaderboard[0].players[1].name)
        assert.equals(8, a.db.factionrealm.leaderboard[0].players[1].raceIndex)
        assertAllBoardsEqual(a, b)

        advance(Config.DingPushDelay)
        assert.equals(2, countEvents()[NetEvents.PlayerInfoBatch], "guild push after DingPushDelay")
        assertAllBoardsEqual(a, b)
    end)

    it("faction lock: an Alliance client ignores the Horde data", function()
        local a = stack("Alpha Tester", realSavedVariables())
        a.sync.isReady = true
        local b = stack("Beta Tester", {})
        -- b's messages carry "Alliance", a's carry "Horde"
        a.core.MyFaction = function() return "Horde" end
        b.core.MyFaction = function() return "Alliance" end

        b.sync:InitSync()
        advance(Config.RequestSyncWait)

        assert.is_nil(countEvents()[NetEvents.OfferSync])
        assert.equals(0, #b.db.factionrealm.leaderboard[0].players)
    end)
end)
