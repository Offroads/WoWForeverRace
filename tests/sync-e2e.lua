-- End-to-end sync check: two complete addon stacks (Core, EventBus, Network, Tracker,
-- Sync, Channel) talk to each other through the real network envelope, one of them seeded
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
-- false: the stacks are out of yell range of each other
local yellReaches

local function resetWorld()
    stacks, queue, log, undelivered = {}, {}, {}, {}
    yellReaches = true
    activeStack = nil
    now = START
    _G.SetTime(now)
    _G.C_Timer.Reset()
    _G.SetFaction(FACTION)
    _G.SetChatChannels(nil)
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
                elseif msg.channel == "YELL" then
                    wanted = yellReaches
                elseif msg.channel == "CHANNEL" then
                    -- the realm channel: every stack that joined it
                    wanted = stack.channel:IsJoined()
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
    -- not joined until a test calls joinChannel
    local channel = WoWForeverRace.Channel(Config, core, db, eventbus)
    local network = WoWForeverRace.Network(core, eventbus, channel)
    local tracker = WoWForeverRace.Tracker(Config, core, db, eventbus, network, channel)
    local sync = WoWForeverRace.Sync(Config, core, db, eventbus, network, channel)
    local s = {name = name, db = db, core = core, eventbus = eventbus, network = network,
               tracker = tracker, sync = sync, channel = channel}
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
        _G.SetChatChannels(nil)
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

    -- the SYNC / FTLSYNC messages sent since log entry `since`
    local function dataMessages(since)
        local out = {}
        for i = since or 1, #log do
            local e = log[i]
            if e.event == NetEvents.SyncPayload or e.event == NetEvents.FTLSync then out[#out + 1] = e end
        end
        return out
    end

    -- a player only s knows, high enough for the overall, class and race boards
    local function addOwnPlayer(s, name, level)
        s.tracker:ProcessPlayerInfo({name = name, level = level, classIndex = 1, raceIndex = 2, dingedAt = now - 100})
        assert.equals(name, s.db.factionrealm.leaderboard[0].players[1].name)
    end

    it("group sync: a BPING to the party converges the members", function()
        _G.SetGroupState(2, false, false)
        local a = stack("Alpha Tester", realSavedVariables())
        local b = stack("Beta Tester", {})
        a.sync.isReady, b.sync.isReady = true, true

        b.sync:OnGroupRosterUpdate()
        -- debounce, the pinger's round, then the picked member's answer
        advance(2 + Config.GroupSyncWait + 2)

        assertAllBoardsEqual(a, b)
        assertFTLEqual(a, b)
        for _, e in ipairs(dataMessages()) do
            assert.equals("PARTY", e.channel, "group sync data goes to the group, never by whisper")
        end
    end)

    it("group sync: one ping, only one member answers with data, over the group channel", function()
        _G.SetGroupState(3, true, false)
        local a = stack("Alpha Tester", realSavedVariables())
        local b = stack("Beta Tester", realSavedVariables())
        local c = stack("Gamma Tester", {})
        a.sync.isReady, b.sync.isReady, c.sync.isReady = true, true, true
        addOwnPlayer(b, "Zed Tester", 22)
        local mark = #log + 1

        c.sync:SendGroupSync()
        advance(Config.GroupSyncWait + 5)

        local senders = {}
        for _, e in ipairs(dataMessages(mark)) do
            assert.equals("RAID", e.channel, "group sync data goes to the group, never by whisper")
            senders[e.from] = true
        end
        senders["Gamma Tester"] = nil
        local answering = {}
        for name in pairs(senders) do answering[#answering + 1] = name end
        assert.equals(1, #answering, "exactly one member answers the ping with data")

        -- the empty pinger now holds what the member that answered holds
        local responder = answering[1] == "Alpha Tester" and a or b
        assertAllBoardsEqual(responder, c)
        assertFTLEqual(responder, c)
    end)

    it("group sync: members out of yell range converge through the group alone", function()
        yellReaches = false
        _G.SetGroupState(3, true, false)
        local a = stack("Alpha Tester", realSavedVariables())
        local b = stack("Beta Tester", realSavedVariables())
        local c = stack("Gamma Tester", realSavedVariables())
        a.sync.isReady, b.sync.isReady, c.sync.isReady = true, true, true
        addOwnPlayer(a, "Ann Only", 22)
        addOwnPlayer(b, "Bob Only", 23)
        addOwnPlayer(c, "Cid Only", 24)

        -- a roster change reaches every member, and every member pings the group
        for _, s in ipairs(stacks) do s.sync:OnGroupRosterUpdate() end
        advance(60)

        assertAllBoardsEqual(a, b)
        assertAllBoardsEqual(b, c)
        assertFTLEqual(a, b)
        assertFTLEqual(b, c)
        assert.equals("Cid Only", a.db.factionrealm.leaderboard[0].players[1].name)

        -- in step now: a further ping draws no answer at all
        local mark = #log + 1
        a.sync:SendGroupSync()
        advance(Config.GroupSyncWait + 2)
        local after = countEvents(mark)
        assert.equals(1, after[NetEvents.BuddyPing])
        assert.is_nil(after[NetEvents.BuddyPong], "members in sync stay silent")
        assert.is_nil(after[NetEvents.SyncPayload])
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

    -- ---------------------------------------------------------------------------
    -- the realm channel: the stacks are out of yell range, in no guild and not grouped
    -- ---------------------------------------------------------------------------
    local RACE_CHANNEL = Config.RaceChannelPrefix .. FACTION

    -- puts the stack in the realm channel (the channel list is shared by all stacks),
    -- which runs its join sync
    local function joinChannel(s)
        _G.JoinTemporaryChannel(RACE_CHANNEL)
        s.channel:TryJoin()
        assert.is_true(s.channel:IsJoined())
    end

    -- the messages sent since log entry `since`, per channel
    local function countChannels(since)
        local counts = {}
        for i = since or 1, #log do
            counts[log[i].channel] = (counts[log[i].channel] or 0) + 1
        end
        return counts
    end

    -- both stacks joined a while ago and heard each other on the channel
    local function settledOnChannel(a, b)
        a.sync.isReady, b.sync.isReady = true, true
        joinChannel(a)
        joinChannel(b)
        advance(Config.ChannelSettleTime)
        a.channel:NoteSender(b.name)
        b.channel:NoteSender(a.name)
    end

    it("realm channel: joining pulls every leaderboard, the pioneers and the history from one partner", function()
        yellReaches = false
        local a = stack("Alpha Tester", realSavedVariables())
        a.sync.isReady = true
        joinChannel(a)
        advance(Config.ChannelSyncWait + 1)
        local before = hashes(a)
        local b = stack("Beta Tester", {})

        joinChannel(b)
        pump()
        -- a announced itself to an empty channel, b to a
        assert.equals(2, countEvents()[NetEvents.ChannelSync])
        advance(Config.ChannelSyncWait + 1)
        assert.equals(1, countEvents()[NetEvents.ChannelOffer])
        assert.equals(1, countEvents()[NetEvents.BuddyPing])
        advance(historyPullTime(a))

        assert.equals(#BOARDS, countEvents()[NetEvents.SyncPayload], "one SYNC per leaderboard")
        assertAllBoardsEqual(a, b)
        assertFTLEqual(a, b)
        assertHistoryCovered(a, b)
        assert.same(before, hashes(a))
        -- only the hashes went over the channel, the data by whisper
        assert.equals(2, countChannels()["CHANNEL"])
        -- both know now that the channel carries traffic
        assert.is_true(a.channel:IsLive())
        assert.is_true(b.channel:IsLive())
    end)

    it("realm channel: a ding reaches a player out of yell range in one message", function()
        yellReaches = false
        local a = stack("Alpha Tester", realSavedVariables())
        local b = stack("Beta Tester", realSavedVariables())
        settledOnChannel(a, b)
        local mark = #log + 1

        b.eventbus:PublishEvent(Events.SlashWhoResult, {
            {name = "Far Tester", level = 21, classIndex = 4, raceIndex = 8},
        })
        advance(Config.ChannelDingDelayMax)

        assert.equals("Far Tester", a.db.factionrealm.leaderboard[0].players[1].name)
        assertAllBoardsEqual(a, b)
        assert.same({CHANNEL = 1}, countChannels(mark))
    end)

    it("realm channel: of the clients that spot the same ding, one sends it", function()
        yellReaches = false
        local a = stack("Alpha Tester", realSavedVariables())
        local b = stack("Beta Tester", realSavedVariables())
        local c = stack("Gamma Tester", realSavedVariables())
        settledOnChannel(a, b)
        c.sync.isReady = true
        joinChannel(c)
        advance(Config.ChannelSettleTime)
        c.channel:NoteSender(a.name)
        local mark = #log + 1

        -- three delays, seconds apart
        local draws = {0, 0.5, 0.99}
        local originalRandom = _G.math.random
        _G.math.random = function() return table.remove(draws, 1) end
        for _, s in ipairs(stacks) do
            s.eventbus:PublishEvent(Events.SlashWhoResult, {
                {name = "Seen Tester", level = 21, classIndex = 4, raceIndex = 8},
            })
        end
        _G.math.random = originalRandom
        advance(Config.ChannelDingDelayMax)

        assert.same({CHANNEL = 1}, countChannels(mark))
        assertAllBoardsEqual(a, b)
        assertAllBoardsEqual(b, c)
    end)

    it("realm channel: the hourly sync trades what each side lacks, then goes quiet", function()
        yellReaches = false
        local a = stack("Alpha Tester", realSavedVariables())
        local b = stack("Beta Tester", realSavedVariables())
        a.sync.isReady, b.sync.isReady = true, true
        joinChannel(a)
        joinChannel(b)
        advance(Config.ChannelSyncWait + 1)
        -- each learned of a player while the other was not listening
        a.tracker:ProcessPlayerInfo({name = "Ann Only", level = 22, classIndex = 1, raceIndex = 2, dingedAt = now - 100})
        b.tracker:ProcessPlayerInfo({name = "Bob Only", level = 23, classIndex = 4, raceIndex = 8, dingedAt = now - 50})
        local mark = #log + 1

        b.sync:SendChannelSync()
        advance(Config.ChannelSyncWait + 2)

        local counts = countEvents(mark)
        assert.equals(1, counts[NetEvents.ChannelSync])
        assert.equals(1, counts[NetEvents.ChannelOffer])
        assert.equals(1, counts[NetEvents.BuddyPing])
        assert.equals(1, counts[NetEvents.BuddyPong])
        assertAllBoardsEqual(a, b)
        assertFTLEqual(a, b)
        assert.equals("Bob Only", a.db.factionrealm.leaderboard[0].players[1].name)
        assert.equals("Ann Only", b.db.factionrealm.leaderboard[0].players[2].name)
        assert.equals(1, countChannels(mark)["CHANNEL"], "only the announce goes over the channel")

        -- in step: the next announce draws no offer
        mark = #log + 1
        a.sync:SendChannelSync()
        advance(Config.ChannelSyncWait + 2)
        assert.same({[NetEvents.ChannelSync] = 1}, countEvents(mark))
    end)

    it("realm channel: what one player alone knows reaches everyone through a single trade", function()
        yellReaches = false
        local a = stack("Alpha Tester", realSavedVariables())
        local b = stack("Beta Tester", realSavedVariables())
        local c = stack("Gamma Tester", realSavedVariables())
        settledOnChannel(a, b)
        c.sync.isReady = true
        joinChannel(c)
        advance(Config.ChannelSettleTime)
        -- c saw this while nobody was listening
        c.tracker:ProcessPlayerInfo({name = "Cid Only", level = 24, classIndex = 1, raceIndex = 2, dingedAt = now - 100})
        local mark = #log + 1

        c.sync:SendChannelSync()
        -- the offers, the trade with one of them, and that partner passing it on
        advance(Config.ChannelSyncWait + 2 + Config.ChannelDingDelayMax)

        assert.equals(1, countEvents(mark)[NetEvents.BuddyPing], "c trades with one partner")
        assertAllBoardsEqual(a, c)
        assertAllBoardsEqual(b, c)
        assert.equals("Cid Only", a.db.factionrealm.leaderboard[0].players[1].name)
        assert.equals("Cid Only", b.db.factionrealm.leaderboard[0].players[1].name)
        -- c's announce, and the partner's relay of the one player it gained
        assert.equals(2, countChannels(mark)["CHANNEL"])
    end)

    it("realm channel: while it is live, the yells, guild, group and buddy sync stay quiet", function()
        _G.SetIsInGuild(true)
        _G.SetGroupState(2, false, false)
        local a = stack("Alpha Tester", realSavedVariables())
        local b = stack("Beta Tester", realSavedVariables())
        settledOnChannel(a, b)
        a.db.factionrealm.buddies[b.name] = {lastSeen = now}
        b.db.factionrealm.buddies[a.name] = {lastSeen = now}
        local mark = #log + 1

        for _, s in ipairs(stacks) do
            s.tracker:SendDiscoveryBeacon()
            s.sync:SendBuddyPings()
            s.sync:ScheduleGroupSync()
        end
        b.eventbus:PublishEvent(Events.SlashWhoResult, {
            {name = "Live Tester", level = 21, classIndex = 4, raceIndex = 8},
        })
        advance(Config.DingPushDelay + Config.GroupSyncWait)

        assert.same({CHANNEL = 1}, countChannels(mark))
        assertAllBoardsEqual(a, b)
    end)

    it("realm channel: a player outside the channel is still served by whisper", function()
        yellReaches = false
        local a = stack("Alpha Tester", realSavedVariables())
        local b = stack("Beta Tester", realSavedVariables())
        settledOnChannel(a, b)
        -- c never joined (an older version, or it left the channel) and knows b from before
        local c = stack("Gamma Tester", {})
        c.sync.isReady = true
        c.db.factionrealm.buddies[b.name] = {lastSeen = now}
        local mark = #log + 1

        c.sync:SendBuddyPings()
        advance(2)

        assertAllBoardsEqual(b, c)
        assertFTLEqual(b, c)
        assert.is_nil(countChannels(mark)["CHANNEL"])
    end)

    it("realm-wide reset: an author empties everybody's leaderboards, also for a player who comes later", function()
        yellReaches = false
        local printStub = stub(WoWForeverRace, "PPrint")
        local a = stack("Offroad Dverg", realSavedVariables())
        local b = stack("Beta Tester", realSavedVariables())
        settledOnChannel(a, b)
        assert.equals(50, #b.db.factionrealm.leaderboard[0].players)

        a.tracker:SendReset()
        pump()

        for _, s in ipairs({a, b}) do
            assert.equals(now, s.db.factionrealm.resetAt)
            for _, boardIndex in ipairs(BOARDS) do
                assert.equals(0, #s.db.factionrealm.leaderboard[boardIndex].players, s.name .. " board " .. boardIndex)
            end
            assert.is_nil(next(s.db.factionrealm.playerHistory))
        end

        -- a player who was offline joins later with the old data: the author tells it
        advance(60)
        local c = stack("Gamma Tester", realSavedVariables())
        c.sync.isReady = true
        joinChannel(c)
        advance(Config.ChannelSyncWait + 5)

        assert.equals(a.db.factionrealm.resetAt, c.db.factionrealm.resetAt)
        assert.equals(0, #c.db.factionrealm.leaderboard[0].players)
        assert.equals(0, #b.db.factionrealm.leaderboard[0].players, "the old data did not come back")
        printStub:revert()
    end)

    it("realm-wide reset: old data from a player who missed it is not taken back", function()
        yellReaches = false
        local printStub = stub(WoWForeverRace, "PPrint")
        local a = stack("Offroad Dverg", realSavedVariables())
        local b = stack("Beta Tester", realSavedVariables())
        settledOnChannel(a, b)
        a.tracker:SendReset()
        pump()
        -- the author logs off; a player with the old data trades with b by whisper
        table.remove(stacks, 1)
        local c = stack("Gamma Tester", realSavedVariables())
        c.sync.isReady = true
        c.db.factionrealm.buddies[b.name] = {lastSeen = now}

        c.sync:SendBuddyPings()
        advance(5)

        assert.is_true((countEvents()[NetEvents.SyncPayload] or 0) > 0, "c pushed its old leaderboards")
        assert.equals(0, #b.db.factionrealm.leaderboard[0].players)
        -- and a stranger can't reset anybody
        c.tracker:SendReset()
        b.tracker:ProcessPlayerInfo({name = "Fresh Tester", level = 3, classIndex = 1, raceIndex = 2, dingedAt = now})
        pump()
        assert.equals(1, #b.db.factionrealm.leaderboard[0].players)
        printStub:revert()
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
