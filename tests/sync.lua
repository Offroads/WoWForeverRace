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
        myFullHash = WoWForeverRace.Sync.ComputeFullHash(db, WoWForeverRace.Config)
        myPHHash = WoWForeverRace.Sync.ComputePHHash(db, WoWForeverRace.Config)
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
            local phHash = WoWForeverRace.Sync.ComputePHHash(db, WoWForeverRace.Config)

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
            local phHash = WoWForeverRace.Sync.ComputePHHash(db, WoWForeverRace.Config)

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
            for _, classIndex in ipairs(leaderboardClassIndexes()) do
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
            for _, classIndex in ipairs(leaderboardClassIndexes()) do
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

        it("never adds ourselves as buddy", function()
            sync:AddBuddy("Nub")
            sync:AddBuddy("Nub-NubVille")

            local count = 0
            for _ in pairs(db.factionrealm.buddies) do
                count = count + 1
            end
            assert.equals(0, count)
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
end)
