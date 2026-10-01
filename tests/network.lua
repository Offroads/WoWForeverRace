local WoWForeverRace = require("testbase")

local Events = WoWForeverRace.Config.Events
local NetworkEvents = WoWForeverRace.Config.Network.Events
local Serializer = LibStub("AceSerializer-3.0")
local AceComm = LibStub("AceComm-3.0")
local LibCompress = LibStub("LibCompress")
local EncodeTable = LibCompress:GetAddonEncodeTable()

-- envelope {event, payload, faction} -> message as it travels over the addon channel
local function encodeEnvelope(envelope)
    return EncodeTable:Encode(LibCompress:CompressHuffman(Serializer:Serialize(envelope)))
end

-- message captured from AceComm:SendCommMessage -> envelope
local function decodeMessage(message)
    local ok, envelope = Serializer:Deserialize(LibCompress:Decompress(EncodeTable:Decode(message)))
    assert.is_true(ok)
    return envelope
end

describe("Network", function()
    after_each(function()
        SetGroupState(nil)
    end)

    describe("GROUP channel", function()
        local function sendToGroup()
            local core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
            local network = WoWForeverRace.Network(core, WoWForeverRace.EventBus())
            local commSpy = spy.on(AceComm, "SendCommMessage")
            network:SendObject(NetworkEvents.BuddyPing, {1}, "GROUP")
            commSpy:revert()
            return commSpy
        end

        it("is dropped when not grouped", function()
            SetGroupState(0)
            assert.spy(sendToGroup()).was_not_called()
        end)

        it("does not count a dropped GROUP send in the message stats", function()
            SetGroupState(0)
            local db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
            db:ResetDB()
            db.profile.options.debug = true
            WoWForeverRace.DB = db
            WoWForeverRace.MsgStats = { send = {}, recv = {} }
            local debugStub = stub(WoWForeverRace, "DebugPrint")

            sendToGroup()

            assert.is_nil(WoWForeverRace.MsgStats.send[NetworkEvents.BuddyPing])
            debugStub:revert()
            WoWForeverRace.DB = nil
            WoWForeverRace.MsgStats = nil
        end)

        it("goes to PARTY in a party", function()
            SetGroupState(3, false, false)
            assert.spy(sendToGroup()).was_called_with(match.is_ref(AceComm),
                    WoWForeverRace.Config.Network.Prefix, match.is_string(), "PARTY", nil, "BULK")
        end)

        it("goes to RAID in a raid", function()
            SetGroupState(25, true, false)
            assert.spy(sendToGroup()).was_called_with(match.is_ref(AceComm),
                    WoWForeverRace.Config.Network.Prefix, match.is_string(), "RAID", nil, "BULK")
        end)

        it("goes to INSTANCE_CHAT in an instance group", function()
            SetGroupState(5, false, true)
            assert.spy(sendToGroup()).was_called_with(match.is_ref(AceComm),
                    WoWForeverRace.Config.Network.Prefix, match.is_string(), "INSTANCE_CHAT", nil, "BULK")
        end)
    end)

    describe("RACE channel", function()
        local RACE_CHANNEL = WoWForeverRace.Config.RaceChannelPrefix .. "Alliance"
        local core, eventbus, channel, network, commSpy, sent

        local function receive(envelope, distribution, sender)
            network:HandleAddonMessage(WoWForeverRace.Config.Network.Prefix, encodeEnvelope(envelope),
                    distribution, sender or "Dude")
        end

        before_each(function()
            _G.C_Timer.Reset()
            SetChatChannels({"General", "Trade", RACE_CHANNEL})
            local db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
            db:ResetDB()
            core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
            eventbus = WoWForeverRace.EventBus()
            channel = WoWForeverRace.Channel(WoWForeverRace.Config, core, db, eventbus)
            network = WoWForeverRace.Network(core, eventbus, channel)
            sent = {}
            commSpy = stub(AceComm, "SendCommMessage", function(_, _, message, distribution, target)
                sent[#sent + 1] = {envelope = decodeMessage(message), distribution = distribution, target = target}
            end)
        end)

        after_each(function()
            commSpy:revert()
            SetChatChannels(nil)
            SetChatLockdown(false)
        end)

        it("goes to the realm channel by its current number", function()
            channel:TryJoin()
            network:SendObject(NetworkEvents.ChannelSync, {1}, "RACE")
            assert.spy(commSpy).was_called_with(match.is_ref(AceComm),
                    WoWForeverRace.Config.Network.Prefix, match.is_string(), "CHANNEL", "3", "BULK")

            -- the number moves when the player's channel list changes
            SetChatChannels({"General", RACE_CHANNEL})
            network:SendObject(NetworkEvents.ChannelSync, {1}, "RACE")
            assert.spy(commSpy).was_called_with(match.is_ref(AceComm),
                    WoWForeverRace.Config.Network.Prefix, match.is_string(), "CHANNEL", "2", "BULK")
        end)

        it("is dropped when we are not in the realm channel", function()
            -- the channel exists in the player's list, but our join was never confirmed
            network:SendObject(NetworkEvents.ChannelSync, {1}, "RACE")
            assert.spy(commSpy).was_not_called()

            channel:TryJoin()
            SetChatChannels({"General", "Trade"})
            network:SendObject(NetworkEvents.ChannelSync, {1}, "RACE")
            assert.spy(commSpy).was_not_called()
        end)

        it("is dropped without a channel component", function()
            network = WoWForeverRace.Network(core, eventbus)
            network:SendObject(NetworkEvents.ChannelSync, {1}, "RACE")
            assert.spy(commSpy).was_not_called()
        end)

        it("is resolved when a lockdown ends, not when the message was held", function()
            channel:TryJoin()
            SetChatLockdown(true)
            network:SendObject(NetworkEvents.PlayerInfoBatch, {"a", false, 0}, "RACE")
            SetChatChannels({"General", RACE_CHANNEL})
            SetChatLockdown(false)
            _G.C_Timer.Advance(6)

            assert.spy(commSpy).was_called_with(match.is_ref(AceComm),
                    WoWForeverRace.Config.Network.Prefix, match.is_string(), "CHANNEL", "2", "BULK")
        end)

        it("notes who was heard on a chat channel", function()
            channel:TryJoin()
            assert.is_false(channel:IsLive())

            -- a whisper says nothing about the channel, and neither does the other faction
            receive({NetworkEvents.ChannelSync, {1}, "Alliance"}, "WHISPER")
            receive({NetworkEvents.ChannelSync, {1}, "Horde"}, "CHANNEL")
            -- our own messages come back to us on a channel
            receive({NetworkEvents.ChannelSync, {1}, "Alliance"}, "CHANNEL", "Nub")
            assert.is_false(channel:IsLive())
            assert.equals(0, channel:Size())

            receive({NetworkEvents.ChannelSync, {1}, "Alliance"}, "CHANNEL")
            assert.is_true(channel:IsLive())
            assert.equals(1, channel:Size())
        end)

        it("tells the other components who was heard on a chat channel", function()
            channel:TryJoin()
            local heard = {}
            eventbus:RegisterCallback(Events.ChannelHeard, {}, function(_, sender) heard[#heard + 1] = sender end)

            receive({NetworkEvents.ChannelSync, {1}, "Alliance"}, "WHISPER")
            receive({NetworkEvents.ChannelSync, {1}, "Horde"}, "CHANNEL")
            receive({NetworkEvents.ChannelSync, {1}, "Alliance"}, "CHANNEL", "Nub")
            assert.same({}, heard)

            receive({NetworkEvents.PlayerInfoBatch, {"", false, 0}, "Alliance"}, "CHANNEL", "Dude")
            receive({NetworkEvents.ChannelSync, {1}, "Alliance"}, "CHANNEL", "Dudette")
            assert.same({"Dude", "Dudette"}, heard)
        end)
    end)

    describe("realm channel number", function()
        local Config = WoWForeverRace.Config
        local RACE_CHANNEL = Config.RaceChannelPrefix .. "Alliance"
        local core, eventbus, channel, network, commStub, sent

        local function receive(envelope, distribution, sender)
            network:HandleAddonMessage(Config.Network.Prefix, encodeEnvelope(envelope), distribution, sender or "Dude")
        end

        local function sentOf(event)
            local out = {}
            for _, s in ipairs(sent) do
                if s.envelope[1] == event then out[#out + 1] = s end
            end
            return out
        end

        before_each(function()
            _G.C_Timer.Reset()
            SetChatChannels({"General", "Trade", RACE_CHANNEL})
            local db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
            db:ResetDB()
            core = WoWForeverRace.Core(Config, "Nub", "NubVille")
            eventbus = WoWForeverRace.EventBus()
            channel = WoWForeverRace.Channel(Config, core, db, eventbus)
            network = WoWForeverRace.Network(core, eventbus, channel)
            sent = {}
            commStub = stub(AceComm, "SendCommMessage", function(_, _, message, distribution, target)
                sent[#sent + 1] = {envelope = decodeMessage(message), distribution = distribution, target = target}
            end)
        end)

        after_each(function()
            commStub:revert()
            SetChatChannels(nil)
        end)

        it("is left out of the envelope on the first channel name", function()
            channel:TryJoin()
            network:SendObject(NetworkEvents.BuddyPing, {1}, "WHISPER", "Dude")

            assert.same({NetworkEvents.BuddyPing, {1}, "Alliance"}, sent[1].envelope)
        end)

        it("travels in every envelope from the second name on", function()
            channel:MoveTo(2)
            network:SendObject(NetworkEvents.BuddyPing, {1}, "WHISPER", "Dude")

            assert.same({NetworkEvents.BuddyPing, {1}, "Alliance", 2}, sent[1].envelope)
        end)

        it("moves us when a higher one is heard on our channel, without telling the channel again", function()
            channel:TryJoin()
            receive({NetworkEvents.ChannelMove, 2, "Alliance", 2}, "CHANNEL")

            assert.equals(2, channel:Index())
            _G.C_Timer.Advance(Config.ChannelMoveDelay)
            assert.equals(0, #sentOf(NetworkEvents.ChannelMove))
        end)

        it("is passed on to our channel when heard outside of it, then we move", function()
            channel:TryJoin()
            -- a player our channel refused whispers us from the next one
            receive({NetworkEvents.BuddyPing, {0, {}, 0}, "Alliance", 2}, "WHISPER")
            assert.equals(1, channel:Index(), "after a random delay")

            _G.C_Timer.Advance(Config.ChannelMoveDelay)

            assert.equals(2, channel:Index())
            local moves = sentOf(NetworkEvents.ChannelMove)
            assert.equals(1, #moves)
            -- to the channel we leave (number 3 in our list), telling the new number
            assert.equals("CHANNEL", moves[1].distribution)
            assert.equals("3", moves[1].target)
            assert.same({NetworkEvents.ChannelMove, 2, "Alliance", 2}, moves[1].envelope)
        end)

        it("is not passed on when another player told the channel first", function()
            channel:TryJoin()
            receive({NetworkEvents.BuddyPing, {0, {}, 0}, "Alliance", 2}, "YELL")
            receive({NetworkEvents.ChannelMove, 2, "Alliance", 2}, "CHANNEL", "Dudette")
            assert.equals(2, channel:Index())

            _G.C_Timer.Advance(Config.ChannelMoveDelay)
            assert.equals(0, #sentOf(NetworkEvents.ChannelMove))
        end)

        it("is taken before the first join, with nobody to tell", function()
            receive({NetworkEvents.OfferSync, {11}, "Alliance", 3}, "WHISPER")
            _G.C_Timer.Advance(Config.ChannelMoveDelay)

            assert.equals(3, channel:Index())
            assert.equals(RACE_CHANNEL .. "3", channel:Name())
            assert.equals(0, #sentOf(NetworkEvents.ChannelMove))
        end)

        it("is ignored when lower, not a channel number, or from the other faction", function()
            channel:MoveTo(2)
            for _, index in ipairs({1, 2, 2.5, "3", {}, Config.ChannelMaxIndex + 1}) do
                receive({NetworkEvents.ChannelMove, 2, "Alliance", index}, "CHANNEL")
            end
            receive({NetworkEvents.ChannelMove, 3, "Horde", 3}, "CHANNEL")
            _G.C_Timer.Advance(Config.ChannelMoveDelay)

            assert.equals(2, channel:Index())
        end)
    end)

    it("drops malformed payloads without raising a receive error", function()
        local core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
        local eventbus = WoWForeverRace.EventBus()
        local network = WoWForeverRace.Network(core, eventbus)
        local db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
        db:ResetDB()
        db.profile.options.debug = true
        WoWForeverRace.DB = db
        local printStub = stub(WoWForeverRace, "PPrint")
        local debugStub = stub(WoWForeverRace, "DebugPrint")

        for _, payload in ipairs({42, "junk", {}, {42}}) do
            local message = encodeEnvelope({NetworkEvents.PlayerInfoBatch, payload, "Alliance"})
            network:HandleAddonMessage(WoWForeverRace.Config.Network.Prefix, message,
                    "WHISPER", "Dude-NubVille")
        end

        assert.stub(printStub).was_not_called()
        printStub:revert()
        debugStub:revert()
        WoWForeverRace.DB = nil
    end)

    describe("chat messaging lockdown", function()
        local network, commSpy

        before_each(function()
            _G.C_Timer.Reset()
            local core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
            network = WoWForeverRace.Network(core, WoWForeverRace.EventBus())
            commSpy = spy.on(AceComm, "SendCommMessage")
        end)

        after_each(function()
            SetChatLockdown(false)
            commSpy:revert()
        end)

        it("holds messages back and sends them when the lockdown ends", function()
            SetChatLockdown(true)
            network:SendObject(NetworkEvents.PlayerInfoBatch, {"a", false, 0}, "GUILD")
            network:SendObject(NetworkEvents.PlayerInfoBatch, {"b", false, 0}, "GUILD")
            _G.C_Timer.Advance(6)
            assert.spy(commSpy).was_not_called()

            SetChatLockdown(false)
            _G.C_Timer.Advance(6)

            assert.spy(commSpy).was_called(2)
        end)

        it("keeps only the latest of a repeated non-payload message", function()
            SetChatLockdown(true)
            network:SendObject(NetworkEvents.BuddyPing, {1}, "WHISPER", "Dude")
            network:SendObject(NetworkEvents.BuddyPing, {2}, "WHISPER", "Dude")

            SetChatLockdown(false)
            _G.C_Timer.Advance(6)

            assert.spy(commSpy).was_called(1)
        end)
    end)

    it("does not publish local events received over the wire", function()
        local core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
        local eventbus = WoWForeverRace.EventBus()
        local network = WoWForeverRace.Network(core, eventbus)
        local eventBusSpy = spy.on(eventbus, "PublishEvent")
        local message = encodeEnvelope({Events.ScanFinished, {true}, "Alliance"})

        network:HandleAddonMessage(WoWForeverRace.Config.Network.Prefix, message,
                "WHISPER", "Dude-NubVille")

        assert.spy(eventBusSpy).called_at_most(0)
    end)

    it("accepts configured network events", function()
        local core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
        local eventbus = WoWForeverRace.EventBus()
        local network = WoWForeverRace.Network(core, eventbus)
        local eventBusSpy = spy.on(eventbus, "PublishEvent")
        local message = encodeEnvelope({NetworkEvents.SyncPayload, {"data"}, "Alliance"})

        network:HandleAddonMessage(WoWForeverRace.Config.Network.Prefix, message,
                "WHISPER", "Dude-NubVille")

        assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus),
                NetworkEvents.SyncPayload, {"data"}, "Dude-NubVille", "WHISPER")
    end)

    describe("faction lock", function()
        local Prefix = WoWForeverRace.Config.Network.Prefix
        local core, eventbus, network, eventBusSpy

        before_each(function()
            _G.C_Timer.Reset()
            core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
            eventbus = WoWForeverRace.EventBus()
            network = WoWForeverRace.Network(core, eventbus)
            eventBusSpy = spy.on(eventbus, "PublishEvent")
        end)

        after_each(function()
            SetFaction(nil)
            SetChatLockdown(false)
            SetIsInGuild(nil)
            WoWForeverRace.DB = nil
            WoWForeverRace.MsgStats = nil
        end)

        local function receive(envelope, sender)
            network:HandleAddonMessage(Prefix, encodeEnvelope(envelope), "WHISPER", sender or "Dude")
        end

        -- messages handed to AceComm while fn runs
        local function sentMessages(fn)
            local messages = {}
            local commStub = stub(AceComm, "SendCommMessage", function(_, _, message)
                messages[#messages + 1] = message
            end)
            fn()
            commStub:revert()
            return messages
        end

        local function debugDB()
            local db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
            db:ResetDB()
            db.profile.options.debug = true
            WoWForeverRace.DB = db
            return db
        end

        it("tags every outgoing event with the player's faction", function()
            for _, event in pairs(NetworkEvents) do
                local messages = sentMessages(function()
                    network:SendObject(event, {1}, "WHISPER", "Dude")
                end)
                assert.equals(1, #messages)
                assert.same({event, {1}, "Alliance"}, decodeMessage(messages[1]))
            end

            SetFaction("Horde")
            local messages = sentMessages(function()
                network:SendObject(NetworkEvents.BuddyPing, {1}, "WHISPER", "Dude")
            end)
            assert.equals("Horde", decodeMessage(messages[1])[3])
        end)

        it("tags a message that was held back during a lockdown", function()
            local messages = sentMessages(function()
                SetChatLockdown(true)
                network:SendObject(NetworkEvents.PlayerInfoBatch, {"a", false, 0}, "GUILD")
                SetChatLockdown(false)
                _G.C_Timer.Advance(6)
            end)

            assert.equals(1, #messages)
            assert.equals("Alliance", decodeMessage(messages[1])[3])
        end)

        it("publishes a message from the own faction", function()
            receive({NetworkEvents.SyncPayload, {"data"}, "Alliance"})

            assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus),
                    NetworkEvents.SyncPayload, {"data"}, "Dude", "WHISPER")
        end)

        it("drops a message from the other faction", function()
            receive({NetworkEvents.SyncPayload, {"data"}, "Horde"})

            assert.spy(eventBusSpy).called_at_most(0)
        end)

        it("drops a message without a faction", function()
            receive({NetworkEvents.SyncPayload, {"data"}})

            assert.spy(eventBusSpy).called_at_most(0)
        end)

        it("drops a malformed faction without raising a receive error", function()
            debugDB()
            local printStub = stub(WoWForeverRace, "PPrint")
            local debugStub = stub(WoWForeverRace, "DebugPrint")

            for _, faction in ipairs({42, {}, true, ""}) do
                receive({NetworkEvents.SyncPayload, {"data"}, faction})
            end

            assert.spy(eventBusSpy).called_at_most(0)
            assert.stub(printStub).was_not_called()
            printStub:revert()
            debugStub:revert()
        end)

        it("does not count a dropped message in the message stats", function()
            debugDB()
            WoWForeverRace.MsgStats = { send = {}, recv = {} }
            local debugStub = stub(WoWForeverRace, "DebugPrint")

            receive({NetworkEvents.SyncPayload, {"data"}, "Horde"})
            assert.is_nil(WoWForeverRace.MsgStats.recv[NetworkEvents.SyncPayload])

            eventBusSpy:revert()
            receive({NetworkEvents.SyncPayload, {"data"}, "Alliance"})
            assert.equals(1, WoWForeverRace.MsgStats.recv[NetworkEvents.SyncPayload])
            debugStub:revert()
        end)

        it("accepts what the own faction sent, and nothing after switching faction", function()
            local messages = sentMessages(function()
                network:SendObject(NetworkEvents.SyncPayload, {"data"}, "WHISPER", "Dude")
            end)

            network:HandleAddonMessage(Prefix, messages[1], "WHISPER", "Dude")
            assert.spy(eventBusSpy).was_called(1)

            SetFaction("Horde")
            network:HandleAddonMessage(Prefix, messages[1], "WHISPER", "Dude")
            assert.spy(eventBusSpy).was_called(1)
        end)

        it("leaves the data alone and sends no reply for the other faction", function()
            SetIsInGuild(false)
            eventBusSpy:revert()
            local db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
            db:ResetDB()
            WoWForeverRace.Sync(WoWForeverRace.Config, core, db, eventbus, network)
            WoWForeverRace.Tracker(WoWForeverRace.Config, core, db, eventbus, network)
            local batchstr = WoWForeverRace.Serializer.SerializePlayerInfoBatch({
                {name = "Dinger", level = 5, classIndex = 11, dingedAt = core:Now()},
            })

            local messages = sentMessages(function()
                receive({NetworkEvents.BuddyPing, {0, {}, 0}, "Horde"})
                receive({NetworkEvents.PlayerInfoBatch, {batchstr, false, 0}, "Horde"})
            end)

            assert.is_nil(next(db.factionrealm.buddies))
            assert.equals(0, #db.factionrealm.leaderboard[0].players)
            assert.equals(0, #messages)

            -- the same messages from our own faction do get through
            messages = sentMessages(function()
                receive({NetworkEvents.BuddyPing, {0, {}, 0}, "Alliance"})
                receive({NetworkEvents.PlayerInfoBatch, {batchstr, false, 0}, "Alliance"})
            end)

            assert.is_not_nil(db.factionrealm.buddies["Dude"])
            assert.equals(1, #db.factionrealm.leaderboard[0].players)
            assert.is_true(#messages > 0)
        end)
    end)
end)
