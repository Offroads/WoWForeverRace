local WoWForeverRace = require("testbase")

local Config = WoWForeverRace.Config
local NAME = Config.RaceChannelPrefix .. "Alliance"

describe("Channel", function()
    local db, core, eventbus, channel
    local time
    local joinedEvents, lastMoved

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

        joinedEvents, lastMoved = 0, nil
        eventbus:RegisterCallback(Config.Events.ChannelJoined, {}, function(_, moved)
            joinedEvents = joinedEvents + 1
            lastMoved = moved
        end)
    end)

    after_each(function()
        _G.SetChatChannels(nil)
        _G.SetChatLockdown(false)
        _G.SetFaction(nil)
        _G.issecretvalue = nil
        _G.StaticPopup_Hide = nil
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

        it("stays out when the channel banned us", function()
            _G.SetChannelJoinRefused(true)
            channel:Init()
            advance(Config.ChannelJoinDelay)
            notice("BANNED")
            advance(Config.ChannelJoinRetry * 3)

            assert.equals("refused", channel:Status())
            assert.equals(1, channel:Index())
            assert.equals(1, #_G.GetChannelJoinRequests())
        end)

        describe("a channel that asks for a password", function()
            local function passwordRequest(name)
                channel.Thread:FireEvent("CHANNEL_PASSWORD_REQUEST", name or channel:Name())
            end

            it("is given up for the same name with the next number", function()
                _G.SetChannelJoinRefused({NAME})
                channel:Init()
                advance(Config.ChannelJoinDelay)
                passwordRequest()
                advance(Config.ChannelJoinRetry * 2)

                assert.same({NAME, NAME .. "2"}, _G.GetChannelJoinRequests())
                assert.is_true(channel:IsJoined())
                assert.equals(NAME .. "2", channel:Name())
                assert.equals(2, channel:Index())
                assert.equals(1, joinedEvents)
                assert.is_false(lastMoved)
                -- a fresh join, not a move with everybody: the join sync has its time
                assert.equals(Config.ChannelSettleTime, channel:SettleDelay())
            end)

            it("is also given up on the wrong password notice, once per channel", function()
                _G.SetChannelJoinRefused({NAME})
                channel:Init()
                advance(Config.ChannelJoinDelay)
                -- the server may send both for the one join
                notice("WRONG_PASSWORD")
                notice("WRONG_PASSWORD", NAME)
                passwordRequest(NAME)
                advance(Config.ChannelJoinRetry * 2)

                assert.equals(2, channel:Index())
                assert.is_true(channel:IsJoined())
            end)

            it("hides the password dialog the client opens for our join", function()
                local hidden = {}
                _G.StaticPopup_Hide = function(which, data) hidden[#hidden + 1] = which .. ":" .. tostring(data) end
                _G.SetChannelJoinRefused({NAME})
                channel:Init()
                advance(Config.ChannelJoinDelay)
                passwordRequest()

                assert.same({"CHAT_CHANNEL_PASSWORD:" .. NAME}, hidden)
                -- and once more a frame later, in case the client opened it after our handler ran
                advance(1)
                assert.equals(2, #hidden)
            end)

            it("leaves the dialog and the channel alone when it was not our join", function()
                local hideSpy = spy.new(function() end)
                _G.StaticPopup_Hide = hideSpy

                -- before we tried to join anything, and for some other channel
                passwordRequest(NAME)
                channel:Init()
                advance(Config.ChannelJoinDelay)
                passwordRequest("SomeGuildChannel")

                assert.spy(hideSpy).was_not_called()
                assert.equals(1, channel:Index())
            end)

            it("gives up when every name asks for a password", function()
                _G.SetChannelJoinRefused(true)
                channel:Init()
                advance(Config.ChannelJoinDelay)
                for _ = 1, Config.ChannelMaxIndex do
                    passwordRequest()
                    advance(Config.ChannelJoinRetry)
                end

                assert.equals("refused", channel:Status())
                assert.equals(Config.ChannelMaxIndex, channel:Index())
                assert.equals(Config.ChannelMaxIndex, #_G.GetChannelJoinRequests())
                assert.is_false(channel:IsJoined())
            end)
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

    describe("moving to a higher channel number", function()
        before_each(function()
            channel:Init()
            advance(Config.ChannelJoinDelay + Config.ChannelJoinRetry)
            assert.is_true(channel:IsJoined())
        end)

        it("joins the higher number and leaves the old channel a moment later", function()
            assert.is_true(channel:MoveTo(2))
            assert.equals(NAME .. "2", channel:Name())
            -- still there: what we tell the old channel has to get out
            assert.is_true(_G.GetChannelName(NAME) > 0)

            advance(Config.ChannelJoinRetry)

            assert.is_true(channel:IsJoined())
            assert.equals(0, (_G.GetChannelName(NAME)))
            assert.equals(2, joinedEvents)
            assert.is_true(lastMoved)
        end)

        it("does not hold our dings back again: we know what the channel knows", function()
            advance(Config.ChannelSettleTime)
            channel:MoveTo(2)
            advance(Config.ChannelJoinRetry)

            assert.is_true(channel:IsJoined())
            assert.equals(0, channel:SettleDelay())
        end)

        it("keeps who was heard: the same players move with us", function()
            channel:NoteSender("Dude")
            channel:MoveTo(2)
            advance(Config.ChannelJoinRetry)

            assert.is_true(channel:IsLive())
            assert.equals(1, channel:Size())
        end)

        it("only moves up, to a whole number we would try ourselves", function()
            for _, index in ipairs({1, 0, -3, 2.5, Config.ChannelMaxIndex + 1}) do
                assert.is_false(channel:CanMoveTo(index), tostring(index))
                assert.is_false(channel:MoveTo(index))
            end
            assert.is_false(channel:CanMoveTo("2"))
            assert.is_false(channel:CanMoveTo(nil))
            assert.is_true(channel:CanMoveTo(Config.ChannelMaxIndex))
            assert.equals(1, channel:Index())
        end)

        it("does not move after the player left the channel, or with sharing off", function()
            db.profile.options.networking = false
            assert.is_false(channel:MoveTo(2))
            db.profile.options.networking = true

            _G.LeaveChannelByName(NAME)
            notice("YOU_LEFT")
            assert.is_false(channel:MoveTo(2))
            assert.equals(1, channel:Index())
        end)

        it("starts from scratch when sharing is switched off and on during a move", function()
            advance(Config.ChannelSettleTime)
            -- the channel we move to asks for a password, so the move is still under way
            _G.SetChannelJoinRefused({NAME .. "2"})
            channel:MoveTo(2)
            channel.Thread:FireEvent("CHANNEL_PASSWORD_REQUEST", NAME .. "2")

            db.profile.options.networking = false
            channel:OnNetworkingChanged()
            db.profile.options.networking = true
            channel:OnNetworkingChanged()
            advance(Config.ChannelJoinRetry * 2)

            assert.is_true(channel:IsJoined())
            assert.equals(NAME .. "3", channel:Name())
            -- a fresh join: it runs the join sync and holds our dings back for it
            assert.is_false(lastMoved)
            assert.is_true(channel:SettleDelay() > 0)
        end)

        it("tells whether a join is under way", function()
            assert.is_false(channel:IsJoining())
            channel:MoveTo(2)
            assert.is_true(channel:IsJoining())
            advance(Config.ChannelJoinRetry)
            assert.is_false(channel:IsJoining())
        end)

        it("before the first join, just joins the higher number", function()
            _G.C_Timer.Reset()
            _G.SetChatChannels(nil)
            channel = WoWForeverRace.Channel(Config, core, db, eventbus)
            joinedEvents = 0

            assert.is_true(channel:MoveTo(3))
            advance(Config.ChannelJoinRetry)

            assert.same({NAME .. "3"}, _G.GetChannelJoinRequests())
            assert.is_true(channel:IsJoined())
            assert.equals(1, joinedEvents)
            assert.is_false(lastMoved)
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
