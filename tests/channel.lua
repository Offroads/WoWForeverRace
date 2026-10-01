local WoWForeverRace = require("testbase")

local Config = WoWForeverRace.Config
local NAME = Config.RaceChannelPrefix .. "Alliance"

describe("Channel", function()
    local db, core, eventbus, channel
    local time
    local joinedEvents

    -- moves the mocked server time and the timers together
    local function advance(seconds)
        for _ = 1, seconds do
            time = time + 1
            _G.C_Timer.Advance(1)
        end
    end

    -- the client's channel notice, as the server sends it for our channel
    local function notice(noticeType, baseName)
        channel.Thread:FireEvent("CHAT_MSG_CHANNEL_NOTICE", noticeType, "", "", "3. " .. (baseName or NAME), "", "",
                0, 3, baseName or NAME)
    end

    before_each(function()
        _G.C_Timer.Reset()
        _G.SetChatChannels(nil)
        time = 1000000000

        db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
        db:ResetDB()
        core = WoWForeverRace.Core(Config, "Nub", "NubVille")
        function core:Now() return time end
        eventbus = WoWForeverRace.EventBus()
        channel = WoWForeverRace.Channel(Config, core, db, eventbus)

        joinedEvents = 0
        eventbus:RegisterCallback(Config.Events.ChannelJoined, {}, function() joinedEvents = joinedEvents + 1 end)
    end)

    after_each(function()
        _G.SetChatChannels(nil)
        _G.SetChatLockdown(false)
        _G.SetFaction(nil)
        _G.issecretvalue = nil
    end)

    it("is named after the faction", function()
        assert.equals("WFRaceAlliance", channel:Name())
        _G.SetFaction("Horde")
        assert.equals("WFRaceHorde", channel:Name())
    end)

    describe("joining", function()
        it("waits for a while after login, then joins without a chat frame", function()
            channel:Init()
            advance(Config.ChannelJoinDelay - 1)
            assert.same({}, _G.GetChannelJoinRequests())

            advance(1)
            assert.same({NAME}, _G.GetChannelJoinRequests())
            assert.is_false(channel:IsJoined())

            -- the next check finds the channel number
            advance(Config.ChannelJoinRetry)
            assert.is_true(channel:IsJoined())
            assert.equals(3, channel:Number())
            assert.equals(1, joinedEvents)
            assert.same({NAME}, _G.GetChannelJoinRequests())
        end)

        it("is confirmed by the channel notice before the next check", function()
            channel:Init()
            advance(Config.ChannelJoinDelay)
            notice("YOU_CHANGED")

            assert.is_true(channel:IsJoined())
            assert.equals(1, joinedEvents)

            -- the pending check changes nothing
            advance(Config.ChannelJoinRetry)
            assert.equals(1, joinedEvents)
            assert.same({NAME}, _G.GetChannelJoinRequests())
        end)

        it("waits for the client's own channels to show up first", function()
            _G.SetChatChannels({})
            channel:Init()
            advance(Config.ChannelJoinDelay + Config.ChannelJoinRetry)
            assert.same({}, _G.GetChannelJoinRequests())

            _G.SetChatChannels({"General"})
            advance(Config.ChannelJoinRetry)
            assert.same({NAME}, _G.GetChannelJoinRequests())
        end)

        it("joins anyway when the player has no other channels", function()
            _G.SetChatChannels({})
            channel:Init()
            advance(Config.ChannelJoinDelay + Config.ChannelJoinMaxWait + Config.ChannelJoinRetry)

            assert.is_true(channel:IsJoined())
            assert.equals(1, channel:Number())
        end)

        it("takes over a channel it is already in, after a /reload", function()
            _G.SetChatChannels({"General", NAME})
            channel:Init()
            advance(Config.ChannelJoinDelay)

            assert.is_true(channel:IsJoined())
            assert.equals(2, channel:Number())
            assert.same({}, _G.GetChannelJoinRequests())
        end)

        it("gives up after a few unanswered joins", function()
            _G.SetChannelJoinRefused(true)
            channel:Init()
            advance(Config.ChannelJoinDelay + Config.ChannelJoinRetry * (Config.ChannelJoinAttempts + 3))

            assert.equals(Config.ChannelJoinAttempts, #_G.GetChannelJoinRequests())
            assert.equals("failed", channel:Status())
            assert.is_false(channel:IsJoined())
            assert.equals(0, joinedEvents)
        end)

        it("stays out when the channel has a password or banned us", function()
            for _, noticeType in ipairs({"WRONG_PASSWORD", "BANNED"}) do
                _G.C_Timer.Reset()
                _G.SetChatChannels(nil)
                _G.SetChannelJoinRefused(true)
                channel = WoWForeverRace.Channel(Config, core, db, eventbus)

                channel:Init()
                advance(Config.ChannelJoinDelay)
                notice(noticeType)
                advance(Config.ChannelJoinRetry * 3)

                assert.equals("refused", channel:Status())
                assert.equals(1, #_G.GetChannelJoinRequests())
            end
        end)

        it("waits out a chat messaging lockdown", function()
            _G.SetChatLockdown(true)
            channel:Init()
            advance(Config.ChannelJoinDelay + Config.ChannelJoinRetry * 10)
            assert.same({}, _G.GetChannelJoinRequests())

            _G.SetChatLockdown(false)
            advance(Config.ChannelJoinRetry * 2)
            assert.is_true(channel:IsJoined())
        end)

        it("does not join with sharing turned off or after the race", function()
            db.profile.options.networking = false
            channel:Init()
            advance(Config.ChannelJoinDelay + Config.ChannelJoinRetry)
            assert.same({}, _G.GetChannelJoinRequests())

            db.profile.options.networking = true
            db.factionrealm.finished = true
            channel = WoWForeverRace.Channel(Config, core, db, eventbus)
            channel:Init()
            advance(Config.ChannelJoinDelay + Config.ChannelJoinRetry)
            assert.same({}, _G.GetChannelJoinRequests())
        end)
    end)

    describe("once joined", function()
        before_each(function()
            channel:Init()
            advance(Config.ChannelJoinDelay + Config.ChannelJoinRetry)
            assert.is_true(channel:IsJoined())
        end)

        it("looks the number up on every use", function()
            assert.equals(3, channel:Number())
            -- the player joined another channel before ours in the list
            _G.SetChatChannels({"General", "Trade", "LocalDefense", NAME})
            assert.equals(4, channel:Number())
        end)

        it("does not rejoin after the player left it", function()
            _G.LeaveChannelByName(NAME)
            notice("YOU_LEFT")

            assert.equals("left", channel:Status())
            assert.is_false(channel:IsJoined())
            advance(Config.ChannelJoinRetry * 5)
            assert.equals(1, #_G.GetChannelJoinRequests())
        end)

        it("is not joined anymore when the channel is gone without a notice", function()
            _G.LeaveChannelByName(NAME)
            assert.is_false(channel:IsJoined())
            assert.is_nil(channel:Number())
        end)

        it("picks it up again when the player joins it by hand", function()
            _G.LeaveChannelByName(NAME)
            notice("YOU_LEFT")

            _G.JoinTemporaryChannel(NAME)
            notice("YOU_CHANGED")

            assert.is_true(channel:IsJoined())
            assert.equals(2, joinedEvents)
        end)

        it("ignores notices of other channels", function()
            notice("YOU_LEFT", "Trade")
            assert.is_true(channel:IsJoined())
        end)

        it("matches the channel name without regard to case", function()
            notice("YOU_LEFT", string.lower(NAME))
            assert.equals("left", channel:Status())
        end)

        it("leaves a secret notice alone", function()
            -- during a chat messaging lockdown the notice type is a secret value
            _G.issecretvalue = function(value) return value == "YOU_LEFT" end
            assert.has_no.errors(function() notice("YOU_LEFT") end)
            assert.is_true(channel:IsJoined())
        end)

        it("leaves with sharing turned off and joins again when it comes back", function()
            db.profile.options.networking = false
            channel:OnNetworkingChanged()
            assert.equals(0, (_G.GetChannelName(NAME)))
            -- our own leave is not the player leaving
            notice("YOU_LEFT")
            assert.equals("idle", channel:Status())

            db.profile.options.networking = true
            channel:OnNetworkingChanged()
            -- the join right away, then the check that finds the number
            advance(1 + Config.ChannelJoinRetry)
            assert.is_true(channel:IsJoined())
            assert.equals(2, joinedEvents)
        end)

        it("holds our own dings back for a while after joining", function()
            assert.equals(Config.ChannelSettleTime, channel:SettleDelay())
            advance(Config.ChannelSettleTime - 10)
            assert.equals(10, channel:SettleDelay())
            advance(20)
            assert.equals(0, channel:SettleDelay())
        end)
    end)

    describe("traffic", function()
        before_each(function()
            _G.SetChatChannels({"General", NAME})
            channel:TryJoin()
        end)

        it("is not live until another player is heard", function()
            assert.is_true(channel:IsJoined())
            assert.is_false(channel:IsLive())

            channel:NoteSender("Dude")
            assert.is_true(channel:IsLive())
        end)

        it("stops being live when nobody was heard for a while", function()
            channel:NoteSender("Dude")
            advance(Config.ChannelLiveTTL)
            assert.is_true(channel:IsLive())
            advance(1)
            assert.is_false(channel:IsLive())
        end)

        it("is not live after leaving the channel", function()
            channel:NoteSender("Dude")
            _G.LeaveChannelByName(NAME)
            assert.is_false(channel:IsLive())
        end)

        it("counts the players heard within a sync interval", function()
            assert.equals(0, channel:Size())
            channel:NoteSender("Dude")
            channel:NoteSender("Dude")
            channel:NoteSender("Dudette")
            assert.equals(2, channel:Size())

            advance(Config.ChannelSyncInterval - 10)
            channel:NoteSender("Dudette")
            advance(20)
            assert.equals(1, channel:Size())
        end)

        it("ignores a sender without a name", function()
            channel:NoteSender(nil)
            assert.is_false(channel:IsLive())
            assert.equals(0, channel:Size())
        end)
    end)
end)
