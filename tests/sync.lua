-- load test base
local WoWForeverRace = require("testbase")

-- aliases
local Events = WoWForeverRace.Config.Events
local NetEvents = WoWForeverRace.Config.Network.Events
local function leaderboardClassIndexes()
    local indexes = {0}
    for _, classIndex in ipairs(WoWForeverRace.Config.MopClassIndexes) do
        indexes[#indexes + 1] = classIndex
    end
    return indexes
end
-- every leaderboard we track ourselves: overall, classes and our faction's races
local function boardIndexes()
    return WoWForeverRace.Config:BoardIndexes("Alliance")
end

describe("Sync", function()
    local db
    ---@type WoWForeverRaceConfig
    local core
    ---@type WoWForeverRaceEventBus
    local eventbus
    ---@type WoWForeverRaceNetwork
    local network
    ---@type WoWForeverRaceSync
    local sync
    local time = 1000000000

    local AdvanceClock

    -- shorthands for the hashes of our (empty) DB
    local myGlobalHash, myClassHash, myFTLHash, myFullHash, myPHHash

    before_each(function()
        -- easier to only test channel
        _G.SetIsInGuild(false)
        -- reset
        _G.C_Timer.Reset()

        -- stubs
        AdvanceClock = function(seconds)
            time = time + seconds
            _G.C_Timer.Advance(seconds)
        end

        db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
        db:ResetDB()
        core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
        -- mock core:Now() to return our mocked time
        function core:Now() return time end
        eventbus = WoWForeverRace.EventBus()
        network = {SendObject = function() end}
        sync = WoWForeverRace.Sync(WoWForeverRace.Config, core, db, eventbus, network)

        myGlobalHash = WoWForeverRace.Leaderboard.ComputeHash(db.factionrealm.leaderboard[0])
        myClassHash = WoWForeverRace.Leaderboard.ComputeHash(db.factionrealm.leaderboard[11])
        myFTLHash = WoWForeverRace.Sync.ComputeFTLHash(db, WoWForeverRace.Config)
        myFullHash = WoWForeverRace.Sync.ComputeFullHash(db, WoWForeverRace.Config, nil, core:MyFaction())
        myPHHash = WoWForeverRace.Sync.ComputePHHash(db, WoWForeverRace.Config, core:MyFaction())
    end)

    after_each(function()
        -- reset any mocking of IsInGuild we did
        _G.SetIsInGuild(nil)
    end)

    it("waits with the login sync until a chat messaging lockdown has ended", function()
        local lockedDown = true
        network.IsLockedDown = function() return lockedDown end
        local networkSpy = spy.on(network, "SendObject")

        sync:InitSync()
        AdvanceClock(WoWForeverRace.Config.RetrySyncWait)
        assert.spy(networkSpy).was_not_called()

        lockedDown = false
        AdvanceClock(WoWForeverRace.Config.RetrySyncWait)

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.RequestSync,
                {11, myGlobalHash, myClassHash, myFTLHash, myPHHash}, "YELL")
    end)

    it("can request sync, marks ready when no partner", function()
        local networkSpy = spy.on(network, "SendObject")

        sync:InitSync()

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.RequestSync,
                {11, myGlobalHash, myClassHash, myFTLHash, myPHHash}, "YELL")
        assert.spy(networkSpy).called_at_most(1)
        networkSpy:clear()

        -- advance our clock so the sync happens
        AdvanceClock(WoWForeverRace.Config.RequestSyncWait)

        assert.equals(true, sync.isReady)
    end)

    it("can request sync, announces to guild too", function()
        local networkSpy = spy.on(network, "SendObject")

        _G.SetIsInGuild(true)

        sync:InitSync()

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.RequestSync,
                {11, myGlobalHash, myClassHash, myFTLHash, myPHHash}, "YELL")
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.GuildSync,
                {11, myFullHash, core:LoginTime(), myFTLHash, myPHHash}, "GUILD")
        assert.spy(networkSpy).called_at_most(2)
    end)

    it("can init and start sync with partner that offers no hashes (old client)", function()
        local networkSpy = spy.on(network, "SendObject")

        sync:InitSync()
        networkSpy:clear()

        eventbus:PublishEvent(NetEvents.OfferSync, {11, nil}, "Dude")

        -- advance our clock so the sync happens
        AdvanceClock(WoWForeverRace.Config.RequestSyncWait)

        -- no hashes known -> sends global + class leaderboards and FTL data
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.StartSync,
                {11, myGlobalHash, myClassHash, myFTLHash, myPHHash}, "WHISPER", "Dude")
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.SyncPayload, "", "WHISPER", "Dude")
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.FTLSync, {""}, "WHISPER", "Dude")
        assert.spy(networkSpy).called_at_most(4)
    end)

    it("skips syncing entirely when partner hashes all match", function()
        local networkSpy = spy.on(network, "SendObject")

        sync:InitSync()
        networkSpy:clear()

        eventbus:PublishEvent(NetEvents.OfferSync,
                {11, nil, myGlobalHash, myClassHash, myFTLHash}, "Dude")

        AdvanceClock(WoWForeverRace.Config.RequestSyncWait)

        -- no sync exchange needed; the only traffic is the buddy ping on becoming ready
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.BuddyPing,
                match.is_table(), "WHISPER", "Dude")
        assert.spy(networkSpy).called_at_most(1)
        assert.equals(true, sync.isReady)
    end)

    it("syncs only FTL when only the FTL hash differs", function()
        local networkSpy = spy.on(network, "SendObject")

        sync:InitSync()
        networkSpy:clear()

        eventbus:PublishEvent(NetEvents.OfferSync,
                {11, nil, myGlobalHash, myClassHash, myFTLHash + 1}, "Dude")

        AdvanceClock(WoWForeverRace.Config.RequestSyncWait)

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.StartSync,
                {11, myGlobalHash, myClassHash, myFTLHash, myPHHash}, "WHISPER", "Dude")
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.FTLSync, {""}, "WHISPER", "Dude")
        assert.spy(networkSpy).called_at_most(2)
    end)

    it("can init and chooses preferred partner", function()
        local networkSpy = spy.on(network, "SendObject")

        sync:InitSync()
        networkSpy:clear()

        -- Dude was synced recently (throttled), Chick was not
        eventbus:PublishEvent(NetEvents.OfferSync, {11, time}, "Dude")
        eventbus:PublishEvent(NetEvents.OfferSync, {11, nil}, "Chick")

        -- overload SelectPartnerFromList to avoid randomness, hacky but works...
        sync.SelectPartnerFromList = function(self, offers)
            return table.remove(offers, 1)
        end

        -- advance our clock so the sync happens
        AdvanceClock(WoWForeverRace.Config.RequestSyncWait)

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.StartSync,
                match.is_table(), "WHISPER", "Chick")
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.SyncPayload, "", "WHISPER", "Chick")
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.FTLSync, {""}, "WHISPER", "Chick")
        assert.spy(networkSpy).called_at_most(4)
        networkSpy:clear()

        -- advance our clock so the retry happens
        AdvanceClock(WoWForeverRace.Config.RetrySyncWait)

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.StartSync,
                match.is_table(), "WHISPER", "Dude")
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.SyncPayload, "", "WHISPER", "Dude")
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.FTLSync, {""}, "WHISPER", "Dude")
        assert.spy(networkSpy).called_at_most(4)
    end)

    it("can init and sync with partner, won't (re)try other partners", function()
        local networkSpy = spy.on(network, "SendObject")

        sync:InitSync()
        networkSpy:clear()

        eventbus:PublishEvent(NetEvents.OfferSync, {11, nil}, "Dude")
        eventbus:PublishEvent(NetEvents.OfferSync, {11, nil}, "Chick")

        -- overload SelectPartnerFromList to avoid randomness, hacky but works...
        sync.SelectPartnerFromList = function(self, offers)
            return table.remove(offers, 1)
        end

        -- advance our clock so the sync happens
        AdvanceClock(WoWForeverRace.Config.RequestSyncWait)

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.StartSync,
                match.is_table(), "WHISPER", "Dude")

        -- receive payload from Dude (also triggers buddy pings on becoming ready)
        eventbus:PublishEvent(NetEvents.SyncPayload, "", "Dude")
        assert.equals(true, sync.isReady)
        networkSpy:clear()

        -- advance our clock so the retry would happen
        AdvanceClock(WoWForeverRace.Config.RetrySyncWait)

        assert.spy(networkSpy).called_at_most(0)
    end)

    it("marks ready when receiving only an FTL payload", function()
        sync:InitSync()

        eventbus:PublishEvent(NetEvents.OfferSync, {11, nil}, "Dude")

        AdvanceClock(WoWForeverRace.Config.RequestSyncWait)
        assert.equals(false, sync.isReady)

        -- partner only had FTL differences to offer
        eventbus:PublishEvent(NetEvents.FTLSync, {""}, "Dude")

        assert.equals(true, sync.isReady)
    end)

    it("can init and retry sync with unresponsive partner", function()
        local networkSpy = spy.on(network, "SendObject")

        sync:InitSync()
        networkSpy:clear()

        eventbus:PublishEvent(NetEvents.OfferSync, {11, nil}, "Dude")
        eventbus:PublishEvent(NetEvents.OfferSync, {11, nil}, "Chick")

        -- overload SelectPartnerFromList to avoid randomness, hacky but works...
        sync.SelectPartnerFromList = function(self, offers)
            return table.remove(offers, 1)
        end

        -- advance our clock so the sync happens
        AdvanceClock(WoWForeverRace.Config.RequestSyncWait)

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.StartSync,
                match.is_table(), "WHISPER", "Dude")
        networkSpy:clear()

        -- advance our clock so the retry happens
        AdvanceClock(WoWForeverRace.Config.RetrySyncWait)

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.StartSync,
                match.is_table(), "WHISPER", "Chick")
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.SyncPayload, "", "WHISPER", "Chick")
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.FTLSync, {""}, "WHISPER", "Chick")
        assert.spy(networkSpy).called_at_most(4)
    end)

    it("can offer and sync with old client that sends no hashes", function()
        local networkSpy = spy.on(network, "SendObject")

        -- mark as ready
        sync.isReady = true

        eventbus:PublishEvent(NetEvents.RequestSync, 11, "Dude")

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.OfferSync,
                {11, nil, myGlobalHash, myClassHash, myFTLHash, myPHHash}, "WHISPER", "Dude")
        assert.spy(networkSpy).called_at_most(1)
        networkSpy:clear()

        eventbus:PublishEvent(NetEvents.StartSync, 11, "Dude")

        -- old client provided no hashes -> send global + class leaderboards and FTL
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.SyncPayload, "", "WHISPER", "Dude")
        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.FTLSync, {""}, "WHISPER", "Dude")
        assert.spy(networkSpy).called_at_most(3)
    end)

    it("won't offer to a requester whose hashes match ours", function()
        local networkSpy = spy.on(network, "SendObject")

        -- mark as ready
        sync.isReady = true

        eventbus:PublishEvent(NetEvents.RequestSync,
                {11, myGlobalHash, myClassHash, myFTLHash}, "Dude")

        assert.spy(networkSpy).called_at_most(0)
    end)

    it("offers when the requester's class leaderboard differs", function()
        local networkSpy = spy.on(network, "SendObject")

        -- mark as ready
        sync.isReady = true

        eventbus:PublishEvent(NetEvents.RequestSync,
                {11, myGlobalHash, myClassHash + 1, myFTLHash}, "Dude")

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.OfferSync,
                {11, nil, myGlobalHash, myClassHash, myFTLHash, myPHHash}, "WHISPER", "Dude")
        assert.spy(networkSpy).called_at_most(1)
    end)

    it("sends nothing on StartSync when the requester's hashes match", function()
        local networkSpy = spy.on(network, "SendObject")

        eventbus:PublishEvent(NetEvents.StartSync,
                {11, myGlobalHash, myClassHash, myFTLHash}, "Dude")

        assert.spy(networkSpy).called_at_most(0)
    end)

    it("sends only the differing leaderboard on StartSync", function()
        local networkSpy = spy.on(network, "SendObject")

        eventbus:PublishEvent(NetEvents.StartSync,
                {11, myGlobalHash + 1, myClassHash, myFTLHash}, "Dude")

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.SyncPayload, "", "WHISPER", "Dude")
        assert.spy(networkSpy).called_at_most(1)
    end)

    it("won't offer when not ready offer and sync", function()
        local networkSpy = spy.on(network, "SendObject")

        eventbus:PublishEvent(NetEvents.RequestSync, 11, "Dude")

        assert.spy(networkSpy).called_at_most(0)
    end)

    it("won't offer when networking is disabled", function()
        local networkSpy = spy.on(network, "SendObject")

        -- disable networking in options
        db.profile.options.networking = false

        -- mark as ready
        sync.isReady = true

        eventbus:PublishEvent(NetEvents.RequestSync, 11, "Dude")

        assert.spy(networkSpy).called_at_most(0)
    end)

    it("won't request sync when networking is disabled", function()
        local networkSpy = spy.on(network, "SendObject")

        -- disable networking in options
        db.profile.options.networking = false

        sync:InitSync()

        assert.spy(networkSpy).called_at_most(0)
    end)

    it("won't request sync when networking race is finished", function()
        local networkSpy = spy.on(network, "SendObject")

        -- mark race finished
        db.factionrealm.finished = true

        sync:InitSync()

        assert.spy(networkSpy).called_at_most(0)
    end)

    describe("guild sync", function()
        it("won't offer when the announcer's hashes match ours", function()
            local networkSpy = spy.on(network, "SendObject")
            sync.isReady = true

            eventbus:PublishEvent(NetEvents.GuildSync, {11, myFullHash, time, myFTLHash}, "Dude")
            AdvanceClock(WoWForeverRace.Config.GuildSyncWait)

            assert.spy(networkSpy).called_at_most(0)
        end)

        it("offers when only the announcer's FTL hash differs", function()
            local networkSpy = spy.on(network, "SendObject")
            sync.isReady = true

            eventbus:PublishEvent(NetEvents.GuildSync, {11, myFullHash, time, myFTLHash + 1}, "Dude")
            AdvanceClock(WoWForeverRace.Config.GuildSyncWait)

            assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.GuildOffer,
                    {11, nil, myFullHash, myGlobalHash, myClassHash, core:LoginTime(), myFTLHash, myPHHash},
                    "WHISPER", "Dude")
            assert.spy(networkSpy).called_at_most(1)
        end)

        it("offers to an old client that announces a differing full hash without FTL", function()
            local networkSpy = spy.on(network, "SendObject")
            sync.isReady = true

            eventbus:PublishEvent(NetEvents.GuildSync, {11, myFullHash + 1, time}, "Dude")
            AdvanceClock(WoWForeverRace.Config.GuildSyncWait)

            assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.GuildOffer,
                    match.is_table(), "WHISPER", "Dude")
            assert.spy(networkSpy).called_at_most(1)
        end)

        it("starts guild sync with the best partner only when hashes differ", function()
            local networkSpy = spy.on(network, "SendObject")
            _G.SetIsInGuild(true)

            sync:SendGuildSync()
            networkSpy:clear()

            -- partner fully in sync with us -> nothing to do
            eventbus:PublishEvent(NetEvents.GuildOffer,
                    {11, nil, myFullHash, myGlobalHash, myClassHash, time - 100, myFTLHash}, "Dude")
            AdvanceClock(WoWForeverRace.Config.GuildSyncWait + 1)

            assert.spy(networkSpy).called_at_most(0)
        end)

        it("starts guild sync when the best partner's FTL differs", function()
            local networkSpy = spy.on(network, "SendObject")
            _G.SetIsInGuild(true)

            sync:SendGuildSync()
            networkSpy:clear()

            eventbus:PublishEvent(NetEvents.GuildOffer,
                    {11, nil, myFullHash, myGlobalHash, myClassHash, time - 100, myFTLHash + 1}, "Dude")
            AdvanceClock(WoWForeverRace.Config.GuildSyncWait + 1)

            assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.StartSync,
                    match.is_table(), "WHISPER", "Dude")
            assert.spy(networkSpy).called_at_most(1)
        end)

        it("picks the guild partner at random, not the member online the longest", function()
            local networkSpy = spy.on(network, "SendObject")
            _G.SetIsInGuild(true)

            sync:SendGuildSync()
            networkSpy:clear()

            -- First has been online the longest (lowest loginTime)
            for _, offer in ipairs({{"First", 100}, {"Second", 300}, {"Third", 200}}) do
                eventbus:PublishEvent(NetEvents.GuildOffer,
                        {11, nil, myFullHash + 1, myGlobalHash, myClassHash, offer[2], myFTLHash}, offer[1])
            end
            local random = stub(math, "random", 2)
            AdvanceClock(WoWForeverRace.Config.GuildSyncWait + 1)
            random:revert()

            assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.StartSync,
                    match.is_table(), "WHISPER", "Second")
            assert.spy(networkSpy).called_at_most(1)
        end)

        it("skips the FTL payload when a guild STARTSYNC carries a matching FTL hash", function()
            local networkSpy = spy.on(network, "SendObject")

            local perClassHashes = {}
            for _, classIndex in ipairs(leaderboardClassIndexes()) do
                perClassHashes[classIndex + 1] = WoWForeverRace.Leaderboard.ComputeHash(
                        db.factionrealm.leaderboard[classIndex])
            end

            eventbus:PublishEvent(NetEvents.StartSync, {11, perClassHashes, myFTLHash}, "Dude")
            assert.spy(networkSpy).called_at_most(0)

            eventbus:PublishEvent(NetEvents.StartSync, {11, perClassHashes, myFTLHash + 1}, "Dude")
            assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.FTLSync,
                    {""}, "WHISPER", "Dude")
            assert.spy(networkSpy).called_at_most(1)
        end)

        it("always sends the FTL payload to an old client guild STARTSYNC", function()
            local networkSpy = spy.on(network, "SendObject")

            local perClassHashes = {}
            for _, classIndex in ipairs(leaderboardClassIndexes()) do
                perClassHashes[classIndex + 1] = WoWForeverRace.Leaderboard.ComputeHash(
                        db.factionrealm.leaderboard[classIndex])
            end

            eventbus:PublishEvent(NetEvents.StartSync, {11, perClassHashes}, "Dude")
            assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.FTLSync,
                    {""}, "WHISPER", "Dude")
            assert.spy(networkSpy).called_at_most(1)
        end)
    end)

    describe("player history sync", function()
        local seedHistory

        before_each(function()
            -- seed a leaderboard member with history so the sync subset is non-empty
            seedHistory = function()
                db.factionrealm.leaderboard[0].players = {
                    {name = "Racer", level = 30, dingedAt = time, classIndex = 4},
                }
                db.factionrealm.playerHistory = {
                    Racer = {classIndex = 4, levels = {[29] = time - 50, [30] = time}},
                }
            end
        end)

        it("pushes player history when the requester announces a differing hash", function()
            local networkSpy = spy.on(network, "SendObject")
            seedHistory()

            local globalHash = WoWForeverRace.Leaderboard.ComputeHash(db.factionrealm.leaderboard[0])
            local phHash = WoWForeverRace.Sync.ComputePHHash(db, WoWForeverRace.Config, core:MyFaction())

            eventbus:PublishEvent(NetEvents.StartSync,
                    {11, globalHash, myClassHash, myFTLHash, phHash + 1}, "Dude")

            -- chunks are sent via timers
            AdvanceClock(WoWForeverRace.Config.PlayerHistoryChunkDelay)

            local expectedChunk = WoWForeverRace.Serializer.SerializePlayerHistoryChunks(
                    db.factionrealm.playerHistory, {"Racer"}, WoWForeverRace.Config.PlayerHistoryChunkSize)[1]
            assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.PlayerHistorySync,
                    expectedChunk, "WHISPER", "Dude")
            assert.spy(networkSpy).called_at_most(1)
        end)

        it("doesn't push player history when the requester's hash matches", function()
            local networkSpy = spy.on(network, "SendObject")
            seedHistory()

            local globalHash = WoWForeverRace.Leaderboard.ComputeHash(db.factionrealm.leaderboard[0])
            local phHash = WoWForeverRace.Sync.ComputePHHash(db, WoWForeverRace.Config, core:MyFaction())

            eventbus:PublishEvent(NetEvents.StartSync,
                    {11, globalHash, myClassHash, myFTLHash, phHash}, "Dude")
            AdvanceClock(WoWForeverRace.Config.PlayerHistoryChunkDelay)

            assert.spy(networkSpy).called_at_most(0)
        end)

        it("never pushes player history to old clients that sent no hash", function()
            local networkSpy = spy.on(network, "SendObject")
            seedHistory()

            -- old client StartSync: differing global hash but no history hash
            eventbus:PublishEvent(NetEvents.StartSync,
                    {11, myGlobalHash + 1, myClassHash, myFTLHash}, "Dude")
            AdvanceClock(WoWForeverRace.Config.PlayerHistoryChunkDelay)

            assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.SyncPayload,
                    match.is_string(), "WHISPER", "Dude")
            assert.spy(networkSpy).called_at_most(1)
        end)

        it("marks ready when receiving a player history payload", function()
            assert.equals(false, sync.isReady)

            eventbus:PublishEvent(NetEvents.PlayerHistorySync, "", "Dude")

            assert.equals(true, sync.isReady)
        end)

        it("forwards received player history chunks to the tracker", function()
            local eventBusSpy = spy.on(eventbus, "PublishEvent")
            seedHistory()

            local chunk = WoWForeverRace.Serializer.SerializePlayerHistoryChunks(
                    db.factionrealm.playerHistory, {"Racer"}, WoWForeverRace.Config.PlayerHistoryChunkSize)[1]
            sync:OnNetPHSync(chunk, "Dude")

            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), Events.PHSyncResult,
                    match.is_same({
                        Racer = {classIndex = 4, levels = {[29] = time - 50, [30] = time}},
                    }))
        end)

        it("guild ticker sync doesn't negotiate player history", function()
            local networkSpy = spy.on(network, "SendObject")
            _G.SetIsInGuild(true)

            -- ticker-style call, no withPlayerHistory flag
            sync:SendGuildSync()

            assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.GuildSync,
                    {11, myFullHash, core:LoginTime(), myFTLHash}, "GUILD")
            assert.spy(networkSpy).called_at_most(1)
            networkSpy:clear()

            -- even a partner whose history hash differs doesn't trigger a history pull
            eventbus:PublishEvent(NetEvents.GuildOffer,
                    {11, nil, myFullHash + 1, myGlobalHash, myClassHash, time - 100, myFTLHash, myPHHash + 1},
                    "Dude")
            AdvanceClock(WoWForeverRace.Config.GuildSyncWait + 1)

            local perClassHashes = {}
            for _, classIndex in ipairs(boardIndexes()) do
                perClassHashes[classIndex + 1] = WoWForeverRace.Leaderboard.ComputeHash(
                        db.factionrealm.leaderboard[classIndex])
            end
            assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.StartSync,
                    {11, perClassHashes, myFTLHash}, "WHISPER", "Dude")
            assert.spy(networkSpy).called_at_most(1)
        end)

        it("login guild sync pulls player history when it differs", function()
            local networkSpy = spy.on(network, "SendObject")
            _G.SetIsInGuild(true)

            -- login-style call: negotiate player history too
            sync:SendGuildSync(true)
            networkSpy:clear()

            -- partner matches everything except player history
            eventbus:PublishEvent(NetEvents.GuildOffer,
                    {11, nil, myFullHash, myGlobalHash, myClassHash, time - 100, myFTLHash, myPHHash + 1},
                    "Dude")
            AdvanceClock(WoWForeverRace.Config.GuildSyncWait + 1)

            local perClassHashes = {}
            for _, classIndex in ipairs(boardIndexes()) do
                perClassHashes[classIndex + 1] = WoWForeverRace.Leaderboard.ComputeHash(
                        db.factionrealm.leaderboard[classIndex])
            end
            assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.StartSync,
                    {11, perClassHashes, myFTLHash, myPHHash}, "WHISPER", "Dude")
            assert.spy(networkSpy).called_at_most(1)
        end)
    end)

    describe("buddies", function()
        it("normalizes same-realm buddy names to their short form", function()
            sync:AddBuddy("Dude-NubVille")
            sync:AddBuddy("Dude")

            local count = 0
            for name, _ in pairs(db.factionrealm.buddies) do
                assert.equals("Dude", name)
                count = count + 1
            end
            assert.equals(1, count)
        end)

        it("does not push a class the pinging peer does not track", function()
            local SHAMANIDX = WoWForeverRace.Config.ClassIndexes.SHAMAN
            db.factionrealm.leaderboard[SHAMANIDX].players = {
                {name = "Totem", level = 40, classIndex = SHAMANIDX, dingedAt = time},
            }
            sync.isReady = true
            local syncSpy = spy.on(sync, "Sync")

            -- a Classic Era style Alliance peer: identical data, but no Shaman board.
            -- Its full hash chains only the boards it tracks.
            local peerHashes = {}
            local peerFullHash = 5381
            for _, classIndex in ipairs({0, 1, 2, 3, 4, 5, 8, 9, 11}) do
                local hash = WoWForeverRace.Leaderboard.ComputeHash(db.factionrealm.leaderboard[classIndex])
                peerHashes[classIndex + 1] = hash
                peerFullHash = ((peerFullHash * 33) + hash) % 2147483647
            end

            sync:OnNetBuddyPing({peerFullHash, peerHashes, myFTLHash}, "Dude")

            assert.spy(syncSpy).was_not_called()
        end)

        it("still pushes a class the pinging peer tracks but lacks", function()
            local SHAMANIDX = WoWForeverRace.Config.ClassIndexes.SHAMAN
            db.factionrealm.leaderboard[SHAMANIDX].players = {
                {name = "Totem", level = 40, classIndex = SHAMANIDX, dingedAt = time},
            }
            sync.isReady = true
            local syncSpy = spy.on(sync, "Sync")

            local peerHashes = {}
            for _, classIndex in ipairs({0, 1, 2, 3, 4, 5, 7, 8, 9, 11}) do
                peerHashes[classIndex + 1] = 5381
            end

            sync:OnNetBuddyPing({myFullHash, peerHashes, myFTLHash}, "Dude")

            assert.spy(syncSpy).was_called_with(match.is_ref(sync), "Dude", SHAMANIDX)
        end)

        it("never adds ourselves as buddy", function()
            sync:AddBuddy("Nub")
            sync:AddBuddy("Nub-NubVille")

            local count = 0
            for _ in pairs(db.factionrealm.buddies) do
                count = count + 1
            end
            assert.equals(0, count)
        end)

        it("drops buddies not seen for BuddyMaxAge a while after the login sync, not at login", function()
            local maxAge = WoWForeverRace.Config.BuddyMaxAge
            local syncWait = WoWForeverRace.Config.RequestSyncWait
            local pruneDelay = WoWForeverRace.Config.BuddyPruneDelay
            db.factionrealm.buddies = {
                ["Stale Buddy"] = {lastSeen = time - maxAge - 1},
                ["Unseen Buddy"] = {},
                ["Fresh Buddy"] = {lastSeen = time - 60},
                ["Edge Buddy"] = {lastSeen = time - maxAge + syncWait + pruneDelay},
            }
            local updates = 0
            eventbus:RegisterCallback(Events.BuddyUpdate, {}, function() updates = updates + 1 end)

            -- a login builds the addon anew: nothing is dropped yet
            WoWForeverRace.Sync(WoWForeverRace.Config, core, db, eventbus, network)
            assert.is_table(db.factionrealm.buddies["Stale Buddy"])

            -- nor when the login sync is done
            sync:InitSync()
            AdvanceClock(syncWait)
            assert.is_true(sync.isReady)
            assert.is_table(db.factionrealm.buddies["Stale Buddy"])
            assert.is_table(db.factionrealm.buddies["Unseen Buddy"])
            assert.equals(0, updates)

            AdvanceClock(pruneDelay)

            assert.is_nil(db.factionrealm.buddies["Stale Buddy"])
            assert.is_nil(db.factionrealm.buddies["Unseen Buddy"])
            assert.is_table(db.factionrealm.buddies["Fresh Buddy"])
            assert.is_table(db.factionrealm.buddies["Edge Buddy"])
            assert.equals(1, updates)
        end)

        it("keeps the buddies who are online when we were away for longer than BuddyMaxAge", function()
            local stale = time - WoWForeverRace.Config.BuddyMaxAge - 1
            db.factionrealm.buddies = {
                ["Offline Buddy"] = {lastSeen = stale},
                ["Online Buddy"] = {lastSeen = stale},
                ["Channel Buddy"] = {lastSeen = stale},
            }
            local pinged = {}
            network.SendObject = function(_, event, _, channel, target)
                if event == NetEvents.BuddyPing and channel == "WHISPER" then
                    pinged[target] = true
                end
            end

            -- the login sync ends with a ping to the buddies, stale or not
            sync:InitSync()
            AdvanceClock(WoWForeverRace.Config.RequestSyncWait)
            assert.same({["Offline Buddy"] = true, ["Online Buddy"] = true, ["Channel Buddy"] = true}, pinged)

            -- one answers it, another is heard on the realm channel
            sync:OnNetBuddyPong({}, "Online Buddy")
            eventbus:PublishEvent(Events.ChannelHeard, "Channel Buddy")

            AdvanceClock(WoWForeverRace.Config.BuddyPruneDelay)

            assert.is_nil(db.factionrealm.buddies["Offline Buddy"])
            assert.is_table(db.factionrealm.buddies["Online Buddy"])
            assert.is_table(db.factionrealm.buddies["Channel Buddy"])
        end)

        it("keeps any number of recent buddies and stays quiet when nothing is stale", function()
            db.factionrealm.buddies = {}
            for i = 1, 400 do
                db.factionrealm.buddies["Buddy " .. i] = {lastSeen = time - i}
            end
            local updates = 0
            eventbus:RegisterCallback(Events.BuddyUpdate, {}, function() updates = updates + 1 end)

            sync:InitSync()
            AdvanceClock(WoWForeverRace.Config.RequestSyncWait + WoWForeverRace.Config.BuddyPruneDelay)

            local count = 0
            for _ in pairs(db.factionrealm.buddies) do count = count + 1 end
            assert.equals(400, count)
            assert.equals(0, updates)
        end)
    end)

    describe("group sync", function()
        local groupPings

        before_each(function()
            groupPings = {}
            network.SendObject = function(_, event, _, channel)
                if event == NetEvents.BuddyPing and channel == "GROUP" then
                    groupPings[#groupPings + 1] = event
                end
            end
        end)

        after_each(function()
            _G.SetGroupState(nil)
        end)

        it("pings the group once the login sync is done when already grouped", function()
            _G.SetGroupState(2, false, false)

            sync:SetReady()
            assert.equals(0, #groupPings, "debounced")
            AdvanceClock(2)

            assert.equals(1, #groupPings)
        end)

        it("does not ping a group after the login sync when not grouped", function()
            sync:SetReady()
            AdvanceClock(2)

            assert.equals(0, #groupPings)
        end)

        it("does not ping the group on a roster change before the login sync is done", function()
            _G.SetGroupState(2, false, false)

            sync:OnGroupRosterUpdate()
            AdvanceClock(2)

            assert.equals(0, #groupPings)
        end)

        it("pings the group again every GroupSyncInterval while grouped", function()
            _G.SetGroupState(2, false, false)
            sync.isReady = true
            sync:InitGroupTicker()

            -- each tick schedules the debounced ping 2s later
            local interval = WoWForeverRace.Config.GroupSyncInterval
            AdvanceClock(interval)
            AdvanceClock(2)
            assert.equals(1, #groupPings)

            AdvanceClock(interval - 2)
            AdvanceClock(2)
            assert.equals(2, #groupPings)

            -- left the group: the ticker keeps running but has nobody to ping
            _G.SetGroupState(nil)
            AdvanceClock(interval - 2)
            AdvanceClock(2)
            assert.equals(2, #groupPings)
        end)

        it("merges the login sync and a roster change close together into one ping", function()
            _G.SetGroupState(2, false, false)

            sync:SetReady()
            sync:OnGroupRosterUpdate()
            AdvanceClock(2)

            assert.equals(1, #groupPings)
        end)

        it("does not ping the group from the ticker once the race is finished", function()
            _G.SetGroupState(2, false, false)
            sync.isReady = true
            db.factionrealm.finished = true
            sync:InitGroupTicker()

            AdvanceClock(WoWForeverRace.Config.GroupSyncInterval)
            AdvanceClock(2)

            assert.equals(0, #groupPings)
        end)

        it("does not whisper a buddy ping to group members, who get the group ping", function()
            local whispered = {}
            network.SendObject = function(_, event, _, channel, target)
                if event == NetEvents.BuddyPing and channel == "WHISPER" then
                    whispered[#whispered + 1] = target
                end
            end
            db.factionrealm.buddies = {["Alice Wanderer"] = {lastSeen = time}, ["Bob Faraway"] = {lastSeen = time}}
            _G.SetGroupMembers({{name = "Alice Wanderer", level = 22, class = "WARRIOR", raceIndex = 1}})

            sync.isReady = true
            sync:SendBuddyPings()
            _G.SetGroupMembers(nil)

            assert.same({"Bob Faraway"}, whispered)
        end)

        it("does not whisper a buddy ping to raid members either", function()
            local whispered = {}
            network.SendObject = function(_, event, _, channel, target)
                if event == NetEvents.BuddyPing and channel == "WHISPER" then
                    whispered[#whispered + 1] = target
                end
            end
            db.factionrealm.buddies = {
                ["Alice Wanderer"] = {lastSeen = time},
                ["Carl Raider"] = {lastSeen = time},
                ["Bob Faraway"] = {lastSeen = time},
            }
            _G.SetGroupMembers({
                {name = "Alice Wanderer", level = 22, class = "WARRIOR", raceIndex = 1},
                {name = "Carl Raider", level = 23, class = "MAGE", raceIndex = 1},
            }, true)

            sync.isReady = true
            sync:SendBuddyPings()
            _G.SetGroupMembers(nil)

            assert.same({"Bob Faraway"}, whispered)
        end)

        it("does not pong a group ping when already in sync", function()
            local pongs = 0
            network.SendObject = function(_, event)
                if event == NetEvents.BuddyPong then pongs = pongs + 1 end
            end
            local myHashes = {}
            for _, boardIndex in ipairs(boardIndexes()) do
                myHashes[boardIndex + 1] = WoWForeverRace.Leaderboard.ComputeHash(db.factionrealm.leaderboard[boardIndex])
            end
            sync.isReady = true

            sync:OnNetBuddyPing({myFullHash, myHashes, myFTLHash}, "Dude", "PARTY")
            sync:OnNetBuddyPing({myFullHash, myHashes, myFTLHash}, "Dude", "RAID")
            sync:OnNetBuddyPing({myFullHash, myHashes, myFTLHash}, "Dude", "INSTANCE_CHAT")
            assert.equals(0, pongs)

            -- a whispered buddy ping is always answered: the pong is how the sender
            -- learns we're online
            sync:OnNetBuddyPing({myFullHash, myHashes, myFTLHash}, "Dude", "WHISPER")
            assert.equals(1, pongs)
        end)

        it("pongs a group ping when the data differs, flagged so the pinger runs its round", function()
            local pongs = {}
            network.SendObject = function(_, event, payload)
                if event == NetEvents.BuddyPong then pongs[#pongs + 1] = payload end
            end
            sync.isReady = true

            sync:OnNetBuddyPing({myFullHash + 1, {}, myFTLHash}, "Dude", "PARTY")

            assert.equals(1, #pongs)
            assert.is_true(pongs[1][4])
        end)

        it("pongs a group ping before the login sync is done", function()
            local pongs = 0
            network.SendObject = function(_, event)
                if event == NetEvents.BuddyPong then pongs = pongs + 1 end
            end

            sync:OnNetBuddyPing({myFullHash, {}, myFTLHash}, "Dude", "PARTY")

            assert.equals(1, pongs)
        end)

        it("does not ping the group from the ticker with networking disabled", function()
            _G.SetGroupState(2, false, false)
            sync.isReady = true
            db.profile.options.networking = false
            sync:InitGroupTicker()

            AdvanceClock(WoWForeverRace.Config.GroupSyncInterval)
            AdvanceClock(2)

            assert.equals(0, #groupPings)
        end)

        describe("one data responder per ping", function()
            local CLASS = 11
            local sent, fullHash

            local function sentOf(event)
                local out = {}
                for _, s in ipairs(sent) do
                    if s.event == event then out[#out + 1] = s end
                end
                return out
            end

            -- our per-board hashes with some boards made to differ
            local function hashesDiffering(boards)
                local hashes = sync:MyBoardHashes()
                for _, boardIndex in ipairs(boards) do hashes[boardIndex + 1] = 1 end
                return hashes
            end

            local function groupPong(name, boards, ftlHash)
                eventbus:PublishEvent(NetEvents.BuddyPong, {fullHash + 1, hashesDiffering(boards), ftlHash or myFTLHash, true}, name)
            end

            before_each(function()
                sent = {}
                network.SendObject = function(_, event, payload, channel, target)
                    sent[#sent + 1] = {event = event, payload = payload, channel = channel, target = target}
                end
                db.factionrealm.leaderboard[0].players = {
                    {name = "Nub One", level = 12, classIndex = CLASS, dingedAt = time},
                }
                db.factionrealm.leaderboard[CLASS].players = {
                    {name = "Nub One", level = 12, classIndex = CLASS, dingedAt = time},
                }
                fullHash = WoWForeverRace.Sync.ComputeFullHash(db, WoWForeverRace.Config, nil, core:MyFaction())
                sync.isReady = true
                _G.SetGroupState(3, true, false)
            end)

            it("answers a differing group ping with its hashes only, no data", function()
                sync:OnNetBuddyPing({fullHash + 1, hashesDiffering({0}), myFTLHash + 1}, "Dude", "RAID")

                assert.equals(1, #sent)
                assert.equals(NetEvents.BuddyPong, sent[1].event)
                assert.equals("WHISPER", sent[1].channel)
                assert.equals("Dude", sent[1].target)
                assert.is_true(sent[1].payload[4])
            end)

            it("sends what the answering members lack to the group once, then picks one of them", function()
                sync:SendGroupSync()
                assert.equals(1, #sentOf(NetEvents.BuddyPing))
                assert.equals("GROUP", sentOf(NetEvents.BuddyPing)[1].channel)

                groupPong("Ann Wanderer", {0})
                groupPong("Bob Faraway", {0}, myFTLHash + 1)
                assert.equals(0, #sentOf(NetEvents.SyncPayload), "nothing before the window closes")

                AdvanceClock(WoWForeverRace.Config.GroupSyncWait)

                local syncs = sentOf(NetEvents.SyncPayload)
                assert.equals(1, #syncs, "board 0 once, although both lack it")
                assert.equals("GROUP", syncs[1].channel)
                local ftls = sentOf(NetEvents.FTLSync)
                assert.equals(1, #ftls)
                assert.equals("GROUP", ftls[1].channel)

                local starts = sentOf(NetEvents.StartSync)
                assert.equals(1, #starts)
                assert.equals("WHISPER", starts[1].channel)
                assert.is_true(starts[1].target == "Ann Wanderer" or starts[1].target == "Bob Faraway")
                assert.is_true(starts[1].payload[5])
                assert.is_nil(starts[1].payload[4], "no player history in group sync")
                assert.same(sync:MyBoardHashes(), starts[1].payload[2])
            end)

            it("sends nothing when nobody answers", function()
                sync:SendGroupSync()
                AdvanceClock(WoWForeverRace.Config.GroupSyncWait)

                assert.equals(1, #sent)
                assert.equals(NetEvents.BuddyPing, sent[1].event)
            end)

            it("serves a late answer with only what nobody sent yet this round", function()
                local syncSpy = spy.on(sync, "Sync")
                sync:SendGroupSync()
                groupPong("Ann Wanderer", {0})
                AdvanceClock(WoWForeverRace.Config.GroupSyncWait)
                assert.spy(syncSpy).was_called_with(match.is_ref(sync), nil, 0, "GROUP")
                sent = {}
                syncSpy:clear()

                -- needs board 0 too: already sent to the whole group
                groupPong("Bob Faraway", {0})
                assert.equals(0, #sent)

                -- needs the class board: sent now, and nobody else is asked to answer
                groupPong("Cid Late", {CLASS})
                assert.spy(syncSpy).was_called_with(match.is_ref(sync), nil, CLASS, "GROUP")
                assert.spy(syncSpy).called_at_most(1)
                assert.equals(0, #sentOf(NetEvents.StartSync))
            end)

            it("lets a late answer respond when nobody answered in time", function()
                sync:SendGroupSync()
                AdvanceClock(WoWForeverRace.Config.GroupSyncWait)
                sent = {}

                groupPong("Ann Wanderer", {0})

                assert.equals(1, #sentOf(NetEvents.SyncPayload))
                local starts = sentOf(NetEvents.StartSync)
                assert.equals(1, #starts)
                assert.equals("Ann Wanderer", starts[1].target)
            end)

            it("drops a round a newer ping replaced", function()
                sync:SendGroupSync()
                groupPong("Ann Wanderer", {0})
                AdvanceClock(1)
                sync:SendGroupSync()
                sent = {}

                -- the first round's window ends first: it was replaced, so nothing
                AdvanceClock(WoWForeverRace.Config.GroupSyncWait - 1)
                assert.equals(0, #sent)
                -- the second round heard no answer
                AdvanceClock(1)
                assert.equals(0, #sent)
            end)

            it("answers a STARTSYNC with the toGroup flag to the group", function()
                eventbus:PublishEvent(NetEvents.StartSync, {CLASS, hashesDiffering({0}), myFTLHash + 1, nil, true}, "Pinger")

                local syncs = sentOf(NetEvents.SyncPayload)
                assert.equals(1, #syncs)
                assert.equals("GROUP", syncs[1].channel)
                local ftls = sentOf(NetEvents.FTLSync)
                assert.equals(1, #ftls)
                assert.equals("GROUP", ftls[1].channel)
                assert.equals(2, #sent)
            end)

            it("ignores a STARTSYNC with the toGroup flag when not grouped", function()
                _G.SetGroupState(nil)

                eventbus:PublishEvent(NetEvents.StartSync, {CLASS, hashesDiffering({0}), myFTLHash + 1, nil, true}, "Pinger")

                assert.equals(0, #sent)
            end)
        end)
    end)

    it("produces proper payload for global leaderboard", function()
        local networkSpy = spy.on(network, "SendObject")

        db.factionrealm.leaderboard[0].players = {
            {name = "Nub1", level = 5, dingedAt = time, classIndex = 8},
            {name = "Nub2", level = 5, dingedAt = time, classIndex = 7},
            {name = "Nub3", level = 5, dingedAt = time, classIndex = 6},
            {name = "Nub4", level = 5, dingedAt = time, classIndex = 5},
            {name = "Nub5", level = 5, dingedAt = time + 10, classIndex = 4},
        }

        sync:Sync("Dude", 0)

        local expectedPayload = WoWForeverRace.Serializer.SerializePlayerInfoBatch(db.factionrealm.leaderboard[0].players)

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.SyncPayload, expectedPayload, "WHISPER", "Dude")
        assert.spy(networkSpy).called_at_most(1)
    end)

    it("produces proper payload for class leaderboard", function()
        local networkSpy = spy.on(network, "SendObject")

        db.factionrealm.leaderboard[8].players = {
            {name = "Nub1", level = 5, dingedAt = time, classIndex = 8},
        }

        sync:Sync("Dude", 8)

        local expectedPayload = WoWForeverRace.Serializer.SerializePlayerInfoBatch(db.factionrealm.leaderboard[8].players)

        assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.SyncPayload, expectedPayload, "WHISPER", "Dude")
        assert.spy(networkSpy).called_at_most(1)
    end)

    it("consumes proper payload", function()
        local eventBusSpy = spy.on(eventbus, "PublishEvent")

        sync:OnNetSyncPayload(WoWForeverRace.Serializer.SerializePlayerInfoBatch({
            {name = "Nubone", level = 5, dingedAt = time, classIndex = 8},
            {name = "Nubtwo", level = 5, dingedAt = time, classIndex = 7},
            {name = "Nubthree", level = 5, dingedAt = time, classIndex = 6},
            {name = "Nubfour", level = 5, dingedAt = time + 10, classIndex = 5},
            {name = "Nubfive", level = 5, dingedAt = time - 11, classIndex = 4},
        }), "Dude")

        assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus), Events.SyncResult,
                match.is_same({
                    {name = "Nubone", level = 5, dingedAt = time, classIndex = 8},
                    {name = "Nubtwo", level = 5, dingedAt = time, classIndex = 7},
                    {name = "Nubthree", level = 5, dingedAt = time, classIndex = 6},
                    {name = "Nubfour", level = 5, dingedAt = time + 10, classIndex = 5},
                    {name = "Nubfive", level = 5, dingedAt = time - 11, classIndex = 4},
                }))
        assert.spy(eventBusSpy).called_at_most(1)
    end)

    describe("channel sync", function()
        local Config = WoWForeverRace.Config
        local RACE_CHANNEL = Config.RaceChannelPrefix .. "Alliance"
        local channel, sent, originalRandom

        local function sentOf(event)
            local out = {}
            for _, s in ipairs(sent) do
                if s.event == event then out[#out + 1] = s end
            end
            return out
        end

        -- our hashes after a change to our data
        local function fullHash()
            return WoWForeverRace.Sync.ComputeFullHash(db, Config, nil, core:MyFaction())
        end

        before_each(function()
            originalRandom = _G.math.random
            _G.SetChatChannels({"General", RACE_CHANNEL})

            sent = {}
            network.SendObject = function(_, event, payload, distribution, target)
                sent[#sent + 1] = {event = event, payload = payload, channel = distribution, target = target}
            end
            eventbus = WoWForeverRace.EventBus()
            channel = WoWForeverRace.Channel(Config, core, db, eventbus)
            sync = WoWForeverRace.Sync(Config, core, db, eventbus, network, channel)
        end)

        after_each(function()
            _G.math.random = originalRandom
            _G.SetChatChannels(nil)
            _G.SetGroupState(nil)
        end)

        describe("announcing", function()
            it("announces our hashes on the channel when we join it", function()
                channel:TryJoin()

                assert.equals(1, #sent)
                assert.equals(NetEvents.ChannelSync, sent[1].event)
                assert.same({myFullHash, myFTLHash}, sent[1].payload)
                assert.equals("RACE", sent[1].channel)
            end)

            it("after moving up with the whole channel, compares again at a random moment soon", function()
                channel:TryJoin()
                sent = {}
                sync.isReady = true

                eventbus:PublishEvent(Config.Events.ChannelJoined, true)
                assert.equals(0, #sent, "not everybody at once")

                AdvanceClock(Config.ChannelFollowUp)
                assert.equals(1, #sentOf(NetEvents.ChannelSync))

                -- a regular round: the trade asks for no player history
                eventbus:PublishEvent(NetEvents.ChannelOffer, {12345, 678}, "Dude", "WHISPER")
                AdvanceClock(Config.ChannelSyncWait + 1)
                assert.is_nil(sentOf(NetEvents.BuddyPing)[1].payload[4])
            end)

            it("tells which realm-wide reset we know", function()
                db.factionrealm.resetAt = time - 100
                channel:TryJoin()

                assert.same({myFullHash, myFTLHash, time - 100}, sent[1].payload)
            end)

            it("stays quiet outside the channel, with sharing off and after the race", function()
                sync:SendChannelSync()
                assert.equals(0, #sent)

                channel:TryJoin()
                sent = {}
                db.profile.options.networking = false
                sync:SendChannelSync()
                db.profile.options.networking = true
                db.factionrealm.finished = true
                sync:SendChannelSync()

                assert.equals(0, #sent)
            end)

            it("announces again about once per ChannelSyncInterval once ready", function()
                channel:TryJoin()
                sent = {}
                sync.isReady = true
                sync:InitChannelTicker()

                AdvanceClock(Config.ChannelSyncInterval * 0.75 - 1)
                assert.equals(0, #sentOf(NetEvents.ChannelSync))
                AdvanceClock(Config.ChannelSyncInterval * 0.5 + 1)
                assert.equals(1, #sentOf(NetEvents.ChannelSync))
                -- and keeps going
                AdvanceClock(Config.ChannelSyncInterval * 1.25)
                assert.equals(2, #sentOf(NetEvents.ChannelSync))
            end)

            it("waits with the announce until a chat messaging lockdown has ended", function()
                local lockedDown = true
                network.IsLockedDown = function() return lockedDown end
                channel:TryJoin()
                AdvanceClock(Config.RetrySyncWait * 3)
                assert.equals(0, #sent)

                lockedDown = false
                AdvanceClock(Config.RetrySyncWait)
                assert.equals(1, #sentOf(NetEvents.ChannelSync))
            end)
        end)

        describe("offering", function()
            before_each(function()
                sync.isReady = true
            end)

            it("whispers an offer with our hashes when the announcer's data differs", function()
                eventbus:PublishEvent(NetEvents.ChannelSync, {12345, myFTLHash}, "Dude", "CHANNEL")
                assert.equals(0, #sent, "after a random delay")
                AdvanceClock(Config.ChannelSyncWait)

                assert.equals(1, #sent)
                assert.equals(NetEvents.ChannelOffer, sent[1].event)
                assert.same({myFullHash, myFTLHash}, sent[1].payload)
                assert.equals("WHISPER", sent[1].channel)
                assert.equals("Dude", sent[1].target)
            end)

            it("offers when only the pioneers differ", function()
                eventbus:PublishEvent(NetEvents.ChannelSync, {myFullHash, 12345}, "Dude", "CHANNEL")
                AdvanceClock(Config.ChannelSyncWait)

                assert.equals(1, #sentOf(NetEvents.ChannelOffer))
            end)

            it("won't offer when the announcer's hashes match ours", function()
                eventbus:PublishEvent(NetEvents.ChannelSync, {myFullHash, myFTLHash}, "Dude", "CHANNEL")
                AdvanceClock(Config.ChannelSyncWait)

                assert.equals(0, #sent)
            end)

            it("won't offer before our own login sync is done, or with sharing off", function()
                sync.isReady = false
                eventbus:PublishEvent(NetEvents.ChannelSync, {12345, myFTLHash}, "Dude", "CHANNEL")
                sync.isReady = true
                db.profile.options.networking = false
                eventbus:PublishEvent(NetEvents.ChannelSync, {12345, myFTLHash}, "Dude", "CHANNEL")
                AdvanceClock(Config.ChannelSyncWait)

                assert.equals(0, #sent)
            end)

            it("ignores a malformed announce", function()
                assert.has_no.errors(function()
                    eventbus:PublishEvent(NetEvents.ChannelSync, 42, "Dude", "CHANNEL")
                    eventbus:PublishEvent(NetEvents.ChannelSync, "junk", "Dude", "CHANNEL")
                end)
                AdvanceClock(Config.ChannelSyncWait)
                assert.equals(0, #sent)
            end)

            it("always offers on a small channel", function()
                for i = 1, Config.ChannelOfferTarget do
                    channel:NoteSender("Player " .. i)
                end
                _G.math.random = function() return 0.999 end

                eventbus:PublishEvent(NetEvents.ChannelSync, {12345, myFTLHash}, "Dude", "CHANNEL")
                AdvanceClock(Config.ChannelSyncWait)

                assert.equals(1, #sentOf(NetEvents.ChannelOffer))
            end)

            it("offers with a chance that shrinks with the players heard on the channel", function()
                -- 100 players: the chance is ChannelOfferTarget in 100
                for i = 1, 100 do
                    channel:NoteSender("Player " .. i)
                end
                local chance = Config.ChannelOfferTarget / 100

                _G.math.random = function() return chance + 0.001 end
                eventbus:PublishEvent(NetEvents.ChannelSync, {12345, myFTLHash}, "Dude", "CHANNEL")
                AdvanceClock(Config.ChannelSyncWait)
                assert.equals(0, #sent)

                _G.math.random = function() return chance - 0.001 end
                eventbus:PublishEvent(NetEvents.ChannelSync, {12345, myFTLHash}, "Dude", "CHANNEL")
                AdvanceClock(Config.ChannelSyncWait)
                assert.equals(1, #sentOf(NetEvents.ChannelOffer))
            end)
        end)

        describe("picking a partner", function()
            local function boardHashes()
                local hashes = {}
                for _, boardIndex in ipairs(boardIndexes()) do
                    hashes[boardIndex + 1] = WoWForeverRace.Leaderboard.ComputeHash(db.factionrealm.leaderboard[boardIndex])
                end
                return hashes
            end

            before_each(function()
                channel:TryJoin()
                sent = {}
            end)

            it("trades with one partner like a buddy ping", function()
                AdvanceClock(Config.ChannelSyncWait + 1)
                sync.isReady = true
                sync:SendChannelSync()
                sent = {}
                local settleAt = channel.settleAt

                eventbus:PublishEvent(NetEvents.ChannelOffer, {12345, 678}, "Dude", "WHISPER")
                AdvanceClock(Config.ChannelSyncWait + 1)

                assert.equals(1, #sent)
                assert.equals(NetEvents.BuddyPing, sent[1].event)
                assert.same({myFullHash, boardHashes(), myFTLHash}, sent[1].payload)
                assert.equals("WHISPER", sent[1].channel)
                assert.equals("Dude", sent[1].target)
                assert.equals(settleAt, channel.settleAt, "an hourly trade does not hold our dings back")
            end)

            it("at the join, also asks for the player history and gives the partner's data time to arrive", function()
                AdvanceClock(Config.ChannelSyncWait - 1)
                eventbus:PublishEvent(NetEvents.ChannelOffer, {12345, 678}, "Dude", "WHISPER")
                AdvanceClock(2)

                assert.equals(1, #sent)
                assert.equals(NetEvents.BuddyPing, sent[1].event)
                assert.same({myFullHash, boardHashes(), myFTLHash, myPHHash}, sent[1].payload)
                assert.equals("Dude", sent[1].target)
                -- joined ChannelSyncWait + 1 seconds ago, and the full settle time starts over
                assert.equals(Config.ChannelSettleTime, channel:SettleDelay())
            end)

            it("at the join, leaves the player history out when a login sync brought it already", function()
                sync:OnNetPHSync("", "Zone Partner")
                eventbus:PublishEvent(NetEvents.ChannelOffer, {12345, 678}, "Dude", "WHISPER")
                AdvanceClock(Config.ChannelSyncWait + 1)

                assert.same({myFullHash, boardHashes(), myFTLHash}, sentOf(NetEvents.BuddyPing)[1].payload)
            end)

            describe("follow-up", function()
                local function syncPayload(name)
                    return WoWForeverRace.Serializer.SerializePlayerInfoBatch({
                        {name = name, level = 5, classIndex = 11, dingedAt = time},
                    })
                end

                before_each(function()
                    -- merges the leaderboards a partner sends
                    WoWForeverRace.Tracker(Config, core, db, eventbus, network, channel)
                    eventbus:PublishEvent(NetEvents.ChannelOffer, {12345, 678}, "Dude", "WHISPER")
                    AdvanceClock(Config.ChannelSyncWait + 1)
                    assert.equals(1, #sentOf(NetEvents.BuddyPing))
                    sent = {}
                end)

                it("compares with the channel again soon after a trade that brought new players", function()
                    eventbus:PublishEvent(NetEvents.SyncPayload, syncPayload("Nubone"), "Dude", "WHISPER")

                    AdvanceClock(Config.ChannelFollowUp - 1)
                    assert.equals(0, #sentOf(NetEvents.ChannelSync))
                    AdvanceClock(1)
                    assert.equals(1, #sentOf(NetEvents.ChannelSync))

                    -- that round found nobody who differs: back to the full sync interval
                    AdvanceClock(Config.ChannelFollowUp * 2)
                    assert.equals(1, #sentOf(NetEvents.ChannelSync))
                end)

                it("leaves it at that after a trade that brought nothing", function()
                    -- we know that player already
                    eventbus:PublishEvent(NetEvents.SyncPayload, syncPayload("Nubone"), "Ann Wanderer", "WHISPER")
                    eventbus:PublishEvent(NetEvents.SyncPayload, syncPayload("Nubone"), "Dude", "WHISPER")
                    AdvanceClock(Config.ChannelFollowUp)

                    assert.equals(0, #sentOf(NetEvents.ChannelSync))
                end)

                it("does not count what somebody else sent", function()
                    eventbus:PublishEvent(NetEvents.SyncPayload, syncPayload("Nubone"), "Ann Wanderer", "WHISPER")
                    AdvanceClock(Config.ChannelFollowUp)

                    assert.equals(0, #sentOf(NetEvents.ChannelSync))
                end)
            end)

            it("asks only one of the players who offered", function()
                for _, name in ipairs({"Dude", "Dudette", "Dudester"}) do
                    eventbus:PublishEvent(NetEvents.ChannelOffer, {12345, 678}, name, "WHISPER")
                end
                AdvanceClock(Config.ChannelSyncWait + 1)

                assert.equals(1, #sent)
            end)

            it("does nothing when the partner's data matches ours by then", function()
                eventbus:PublishEvent(NetEvents.ChannelOffer, {myFullHash, myFTLHash}, "Dude", "WHISPER")
                AdvanceClock(Config.ChannelSyncWait + 1)

                assert.equals(0, #sent)
            end)

            it("does nothing without offers", function()
                AdvanceClock(Config.ChannelSyncWait + 1)
                assert.equals(0, #sent)
            end)

            it("takes an offer as proof that the channel carries our messages", function()
                assert.is_false(channel:IsLive())

                eventbus:PublishEvent(NetEvents.ChannelOffer, {12345, 678}, "Dude-NubVille", "WHISPER")

                assert.is_true(channel:IsLive())
                assert.equals(1, channel:Size())
                assert.is_table(db.factionrealm.buddies["Dude"])
            end)

            it("ignores an offer nobody asked for", function()
                AdvanceClock(Config.ChannelSyncWait + 1)

                assert.has_no.errors(function()
                    eventbus:PublishEvent(NetEvents.ChannelOffer, {12345, 678}, "Dude", "WHISPER")
                    eventbus:PublishEvent(NetEvents.ChannelOffer, "junk", "Dude", "WHISPER")
                end)
                AdvanceClock(Config.ChannelSyncWait + 1)

                assert.is_false(channel:IsLive())
                assert.is_nil(db.factionrealm.buddies["Dude"])
                assert.equals(0, #sent)
            end)
        end)

        describe("answering a channel partner's ping", function()
            local historySpy

            before_each(function()
                sync.isReady = true
                historySpy = spy.on(sync, "SyncPlayerHistory")
            end)

            it("sends the player history to a whispered ping that asks for it", function()
                eventbus:PublishEvent(NetEvents.BuddyPing, {myFullHash, {}, myFTLHash, 12345}, "Dude", "WHISPER")

                assert.spy(historySpy).was_called_with(match.is_ref(sync), "Dude")
                assert.equals(1, #sentOf(NetEvents.BuddyPong))
            end)

            it("sends no player history when the hash matches, or when nobody asked", function()
                eventbus:PublishEvent(NetEvents.BuddyPing, {myFullHash, {}, myFTLHash, myPHHash}, "Dude", "WHISPER")
                eventbus:PublishEvent(NetEvents.BuddyPing, {myFullHash, {}, myFTLHash}, "Dude", "WHISPER")
                eventbus:PublishEvent(NetEvents.BuddyPing, {myFullHash, {}, myFTLHash, "junk"}, "Dude", "WHISPER")

                assert.spy(historySpy).was_not_called()
            end)

            it("sends no player history to a group ping, or before our own login sync is done", function()
                _G.SetGroupState(2, false, false)
                eventbus:PublishEvent(NetEvents.BuddyPing, {12345, {}, myFTLHash, 12345}, "Dude", "PARTY")
                sync.isReady = false
                eventbus:PublishEvent(NetEvents.BuddyPing, {12345, {}, myFTLHash, 12345}, "Dude", "WHISPER")

                assert.spy(historySpy).was_not_called()
            end)
        end)

        describe("players heard on the channel", function()
            local updates

            before_each(function()
                updates = 0
                eventbus:RegisterCallback(Events.BuddyUpdate, {}, function() updates = updates + 1 end)
            end)

            it("become buddies, to whisper when the channel is locked or quiet later", function()
                eventbus:PublishEvent(Events.ChannelHeard, "Dude")
                eventbus:PublishEvent(Events.ChannelHeard, "Dudette-NubVille")

                assert.equals(time, db.factionrealm.buddies["Dude"].lastSeen)
                assert.is_table(db.factionrealm.buddies["Dudette"])
                assert.equals(2, updates)
            end)

            it("are kept up to date without announcing them again", function()
                eventbus:PublishEvent(Events.ChannelHeard, "Dude")
                AdvanceClock(60)
                eventbus:PublishEvent(Events.ChannelHeard, "Dude")
                eventbus:PublishEvent(Events.ChannelHeard, "Dude")

                assert.equals(time, db.factionrealm.buddies["Dude"].lastSeen)
                assert.equals(1, updates)
            end)

            it("are not added with sharing off, and never ourselves", function()
                eventbus:PublishEvent(Events.ChannelHeard, "Nub")
                db.profile.options.networking = false
                eventbus:PublishEvent(Events.ChannelHeard, "Dude")

                assert.is_nil(next(db.factionrealm.buddies))
                assert.equals(0, updates)
            end)

            it("are pinged once the channel is gone", function()
                channel:TryJoin()
                AdvanceClock(Config.ChannelSyncWait + 1)
                sync.isReady = true
                channel:NoteSender("Dude")
                eventbus:PublishEvent(Events.ChannelHeard, "Dude")
                sent = {}

                sync:SendBuddyPings()
                assert.equals(0, #sent, "the channel is live")

                -- somebody locked the channel and we are out of it
                _G.SetChatChannels({"General"})
                sync:SendBuddyPings()

                local pings = sentOf(NetEvents.BuddyPing)
                assert.equals(1, #pings)
                assert.equals("WHISPER", pings[1].channel)
                assert.equals("Dude", pings[1].target)
            end)
        end)

        describe("the other flows as backup", function()
            before_each(function()
                _G.SetIsInGuild(true)
                channel:TryJoin()
                AdvanceClock(Config.ChannelSyncWait + 1)
                sync.isReady = true
                db.factionrealm.buddies = {["Bob Faraway"] = {lastSeen = time}}
                sent = {}
            end)

            it("keeps pinging buddies, the group and the guild while nobody is heard on the channel", function()
                _G.SetGroupState(2, false, false)
                sync:InitGuildTicker()

                sync:SendBuddyPings()
                sync:ScheduleGroupSync()
                AdvanceClock(Config.GuildSyncInterval)

                assert.equals(1, #sentOf(NetEvents.GuildSync))
                local pings = sentOf(NetEvents.BuddyPing)
                assert.equals(2, #pings)
                assert.equals("WHISPER", pings[1].channel)
                assert.equals("GROUP", pings[2].channel)
            end)

            it("starts none of them while the channel is live", function()
                _G.SetGroupState(2, false, false)
                sync:InitGuildTicker()
                channel:NoteSender("Dude")

                sync:SendBuddyPings()
                sync:ScheduleGroupSync()
                AdvanceClock(Config.GuildSyncInterval)

                assert.equals(0, #sent)
            end)

            it("picks them up again when the channel went quiet", function()
                channel:NoteSender("Dude")
                AdvanceClock(Config.ChannelLiveTTL + 1)

                sync:SendBuddyPings()

                assert.equals(1, #sentOf(NetEvents.BuddyPing))
            end)

            it("still answers a buddy, the guild and the group while the channel is live", function()
                _G.SetGroupState(2, false, false)
                channel:NoteSender("Dude")
                db.factionrealm.leaderboard[0].players = {
                    {name = "Nubone", level = 5, dingedAt = time, classIndex = 11},
                }
                local peerHashes = {}
                for _, boardIndex in ipairs(boardIndexes()) do peerHashes[boardIndex + 1] = 5381 end

                -- players who are not in the channel start these
                eventbus:PublishEvent(NetEvents.BuddyPing, {12345, peerHashes, myFTLHash}, "Ann Wanderer", "WHISPER")
                assert.equals(1, #sentOf(NetEvents.BuddyPong))
                assert.equals(1, #sentOf(NetEvents.SyncPayload))

                eventbus:PublishEvent(NetEvents.BuddyPing, {12345, peerHashes, myFTLHash}, "Cid Member", "PARTY")
                assert.equals(2, #sentOf(NetEvents.BuddyPong))

                eventbus:PublishEvent(NetEvents.GuildSync, {11, 12345, time, myFTLHash}, "Bea Guildie", "GUILD")
                AdvanceClock(Config.GuildSyncWait)
                assert.equals(1, #sentOf(NetEvents.GuildOffer))
                assert.not_equals(myFullHash, fullHash())
            end)
        end)
    end)

    describe("race leaderboards", function()
        local HUMAN_BOARD = WoWForeverRace.Config:RaceBoardIndex(1)

        local function myHashes()
            local hashes = {}
            for _, boardIndex in ipairs(boardIndexes()) do
                hashes[boardIndex + 1] = WoWForeverRace.Leaderboard.ComputeHash(db.factionrealm.leaderboard[boardIndex])
            end
            return hashes
        end

        before_each(function()
            db.factionrealm.leaderboard[HUMAN_BOARD].players = {
                {name = "Nub One", level = 12, classIndex = 11, raceIndex = 1, dingedAt = time},
            }
            sync.isReady = true
        end)

        it("pushes a race leaderboard that differs to a buddy", function()
            local networkSpy = spy.on(network, "SendObject")
            local theirs = myHashes()
            theirs[HUMAN_BOARD + 1] = 1
            local theirFull = WoWForeverRace.Sync.ComputeFullHash(db, WoWForeverRace.Config, nil, core:MyFaction()) + 1

            eventbus:PublishEvent(NetEvents.BuddyPong, {theirFull, theirs, myFTLHash}, "Dude")

            assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.SyncPayload,
                    WoWForeverRace.Serializer.SerializePlayerInfoBatch(db.factionrealm.leaderboard[HUMAN_BOARD].players),
                    "WHISPER", "Dude")
            assert.spy(networkSpy).called_at_most(1)
        end)

        it("sends no race leaderboard to a peer that does not track races", function()
            local networkSpy = spy.on(network, "SendObject")
            local theirs = {}
            for _, classIndex in ipairs(leaderboardClassIndexes()) do
                theirs[classIndex + 1] = WoWForeverRace.Leaderboard.ComputeHash(db.factionrealm.leaderboard[classIndex])
            end
            local theirFull = WoWForeverRace.Sync.ComputeFullHash(db, WoWForeverRace.Config, theirs, core:MyFaction())

            eventbus:PublishEvent(NetEvents.BuddyPong, {theirFull, theirs, myFTLHash}, "Dude")

            assert.spy(networkSpy).was_not_called()
        end)

        it("reports the race leaderboards in a buddy ping", function()
            local networkSpy = spy.on(network, "SendObject")
            db.factionrealm.buddies = {Dude = {lastSeen = time}}

            sync:SendBuddyPings()

            local fullHash = WoWForeverRace.Sync.ComputeFullHash(db, WoWForeverRace.Config, nil, core:MyFaction())
            assert.spy(networkSpy).was_called_with(match.is_ref(network), NetEvents.BuddyPing,
                    {fullHash, myHashes(), myFTLHash}, "WHISPER", "Dude")
        end)

        it("syncs the history of race leaderboard members", function()
            db.factionrealm.playerHistory = {
                ["Nub One"] = {classIndex = 11, levels = {[12] = time}},
                ["Nobody"] = {classIndex = 11, levels = {[3] = time}},
            }

            local withRaces = WoWForeverRace.Sync.ComputePHHash(db, WoWForeverRace.Config, core:MyFaction())
            local withoutRaces = WoWForeverRace.Sync.ComputePHHash(db, WoWForeverRace.Config, nil)

            assert.not_equals(withoutRaces, withRaces)
        end)
    end)
end)
