-- load test base
local WoWForeverRace = require("testbase")

local NetEvents = WoWForeverRace.Config.Network.Events

describe("VersionCheck", function()
    local config
    local db
    local core
    local eventbus
    local versionCheck
    local network, sent
    local printSpy
    local time = 1000000000
    local DAY = 24 * 60 * 60
    -- the build we run, and two newer ones
    local MINE, NEWER, NEWEST = time - 10 * DAY, time - 2 * DAY, time - DAY

    -- a packaged build of our own, the shared config is an unpackaged checkout
    local function packagedConfig(version, buildTime)
        return setmetatable({Version = version, BuildTime = tostring(buildTime)},
                {__index = WoWForeverRace.Config})
    end

    local function create(version)
        config = packagedConfig(version or "v0.1.0-beta13", MINE)
        versionCheck = WoWForeverRace.VersionCheck(config, core, db, eventbus, network)
    end

    -- a player announces itself on the realm channel
    local function announce(sender, buildTime, version)
        eventbus:PublishEvent(NetEvents.ChannelSync, {123, 456, nil, {buildTime, version}}, sender, "CHANNEL")
    end

    before_each(function()
        _G.C_Timer.Reset()
        db = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
        db:ResetDB()
        core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
        function core:Now() return time end
        eventbus = WoWForeverRace.EventBus()
        sent = {}
        network = {
            SendObject = function(_, event, payload, distribution, target)
                sent[#sent + 1] = {event = event, payload = payload, channel = distribution, target = target}
            end,
        }
        -- stub instead of spy so the warnings don't end up in the test output
        printSpy = stub(WoWForeverRace, "PPrint")
        create()
    end)

    after_each(function()
        printSpy:revert()
        _G.SetIsInGuild(nil)
    end)

    describe("announcing to the guild and the buddies", function()
        -- who a message went to: "GUILD", or the name whispered to
        local function receivers()
            local out = {}
            for _, s in ipairs(sent) do
                assert.equals(NetEvents.Version, s.event)
                assert.same({MINE, "v0.1.0-beta13"}, s.payload)
                out[#out + 1] = s.channel == "WHISPER" and s.target or s.channel
            end
            table.sort(out)
            return out
        end

        before_each(function()
            _G.SetIsInGuild(true)
            db.factionrealm.buddies = {
                ["Dude"] = {lastSeen = time - 60},
                ["Dudette"] = {lastSeen = time - DAY},
                -- about to be dropped
                ["Gone"] = {lastSeen = time - WoWForeverRace.Config.BuddyMaxAge - 1},
                ["Never"] = {},
            }
        end)

        it("tells them which build we run, once after login", function()
            versionCheck:Init()
            assert.equals(0, #sent)

            _G.C_Timer.Advance(config.VersionAnnounceDelay)
            assert.same({"Dude", "Dudette", "GUILD"}, receivers())

            _G.C_Timer.Advance(DAY)
            assert.equals(3, #sent)
        end)

        it("skips the guild when we are in none", function()
            _G.SetIsInGuild(false)
            versionCheck:Announce()
            assert.same({"Dude", "Dudette"}, receivers())
        end)

        it("stays quiet on an unpackaged checkout, with sharing off and after the race", function()
            WoWForeverRace.VersionCheck(WoWForeverRace.Config, core, db, WoWForeverRace.EventBus(), network):Announce()

            db.profile.options.networking = false
            versionCheck:Announce()
            db.profile.options.networking = true
            db.factionrealm.finished = true
            versionCheck:Announce()

            assert.equals(0, #sent)
        end)

        it("waits for a chat messaging lockdown to end", function()
            local lockedDown = true
            function network:IsLockedDown() return lockedDown end

            versionCheck:Announce()
            _G.C_Timer.Advance(config.RetrySyncWait)
            assert.equals(0, #sent)

            lockedDown = false
            _G.C_Timer.Advance(config.RetrySyncWait)
            assert.same({"Dude", "Dudette", "GUILD"}, receivers())
        end)

        it("warns the player when a guild member or a buddy runs a newer build", function()
            eventbus:PublishEvent(NetEvents.Version, {NEWER, "v0.1.0-beta14"}, "Dude", "GUILD")

            assert.equals("v0.1.0-beta14", versionCheck:NewerVersion())
            assert.spy(printSpy).was_called(1)
        end)

        it("ignores a build that is no build", function()
            assert.has_no.errors(function()
                eventbus:PublishEvent(NetEvents.Version, nil, "Dude", "WHISPER")
                eventbus:PublishEvent(NetEvents.Version, "v9.9.9", "Dude", "WHISPER")
                eventbus:PublishEvent(NetEvents.Version, {MINE, "v0.1.0-beta13"}, "Dude", "WHISPER")
                eventbus:PublishEvent(NetEvents.Version, {NEWER, "|cFFFF0000x|r"}, "Dude", "WHISPER")
            end)

            assert.is_nil(versionCheck:NewerVersion())
            assert.spy(printSpy).was_not_called()
        end)
    end)

    describe("hearing a newer build", function()
        it("tells the player as soon as one player runs a newer build", function()
            announce("Dude", NEWER, "v0.1.0-beta14")

            assert.equals("v0.1.0-beta14", versionCheck:NewerVersion())
            assert.same({buildTime = NEWER, version = "v0.1.0-beta14"}, db.global.newerVersion)
            assert.spy(printSpy).was_called(1)
            local message = printSpy.calls[1].vals[2]
            assert.is_truthy(message:find("v0.1.0-beta14", 1, true))
            assert.is_truthy(message:find("v0.1.0-beta13", 1, true))
        end)

        it("tells the player once per session", function()
            announce("Dude", NEWER, "v0.1.0-beta14")
            announce("Dude", NEWER, "v0.1.0-beta14")
            announce("Dudette", NEWER, "v0.1.0-beta14")
            -- a still newer build is known from now on, without another chat line
            announce("Dudine", NEWEST, "v0.1.0-beta15")

            assert.equals("v0.1.0-beta15", versionCheck:NewerVersion())
            assert.spy(printSpy).was_called(1)
        end)

        it("keeps the newest build it knows of", function()
            announce("Dude", NEWEST, "v0.1.0-beta15")
            announce("Dudette", NEWER, "v0.1.0-beta14")

            assert.equals("v0.1.0-beta15", versionCheck:NewerVersion())
        end)

        it("ignores our own build and older ones", function()
            announce("Dude", MINE, "v0.1.0-beta13")
            announce("Dudette", MINE - DAY, "v0.1.0-beta12")

            assert.is_nil(versionCheck:NewerVersion())
            assert.spy(printSpy).was_not_called()
        end)

        it("ignores a client that says nothing about its build", function()
            assert.has_no.errors(function()
                eventbus:PublishEvent(NetEvents.ChannelSync, {123, 456}, "Dude", "CHANNEL")
                eventbus:PublishEvent(NetEvents.ChannelSync, {123, 456, time}, "Dude", "CHANNEL")
                eventbus:PublishEvent(NetEvents.ChannelSync, 42, "Dude", "CHANNEL")
                eventbus:PublishEvent(NetEvents.ChannelSync, {123, 456, nil, "junk"}, "Dude", "CHANNEL")
                eventbus:PublishEvent(NetEvents.ChannelSync, {123, 456, nil, {}}, "Dude", "CHANNEL")
            end)

            assert.is_nil(versionCheck:NewerVersion())
        end)

        it("ignores a build that can't be real", function()
            local forged = {
                {time + 2 * DAY, "v9.9.9"},                   -- from the future
                {NEWER + 0.5, "v0.1.0-beta14"},               -- no timestamp
                {tostring(NEWER), "v0.1.0-beta14"},
                {0 / 0, "v0.1.0-beta14"},
                {math.huge, "v0.1.0-beta14"},
                {NEWER, nil},
                {NEWER, 14},
                {NEWER, ""},
                {NEWER, "|cFFFF0000v0.1.0-beta14|r"},         -- escape codes
                {NEWER, "|Hplayer:Dude|h[click]|h"},
                {NEWER, "v0.1.0 beta14"},
                {NEWER, string.rep("1", WoWForeverRace.Config.VersionMaxLength + 1)},
            }
            for _, build in ipairs(forged) do
                announce("Dude", build[1], build[2])
            end

            assert.is_nil(versionCheck:NewerVersion())
            assert.is_nil(db.global.newerVersion)
            assert.spy(printSpy).was_not_called()
        end)

        it("an unpackaged checkout never warns", function()
            versionCheck = WoWForeverRace.VersionCheck(WoWForeverRace.Config, core, db, WoWForeverRace.EventBus())
            versionCheck:OnNetChannelSync({123, 456, nil, {NEWER, "v0.1.0-beta14"}}, "Dude")

            assert.is_nil(versionCheck:NewerVersion())
            assert.spy(printSpy).was_not_called()
        end)
    end)

    describe("release types", function()
        -- whether a client on version `own` tells its player about the newer build `version`
        local function warnsAbout(own, version)
            eventbus = WoWForeverRace.EventBus()
            db.global.newerVersion = nil
            create(own)
            announce("Dude", NEWER, version)
            return versionCheck:NewerVersion() ~= nil
        end

        it("a player on a release is only told about releases", function()
            assert.is_true(warnsAbout("v1.0.0", "v1.0.1"))
            assert.is_false(warnsAbout("v1.0.0", "v1.1.0-beta1"))
            assert.is_false(warnsAbout("v1.0.0", "v1.1.0-alpha1"))
        end)

        it("a player on a beta is told about betas and releases", function()
            assert.is_true(warnsAbout("v0.1.0-beta13", "v0.1.0-beta14"))
            assert.is_true(warnsAbout("v0.1.0-beta13", "v0.1.0-BETA14"))
            assert.is_true(warnsAbout("v0.1.0-beta13", "v0.1.0"))
            assert.is_false(warnsAbout("v0.1.0-beta13", "v0.2.0-alpha1"))
        end)

        it("nobody on a tagged build is told about the build of an untagged commit", function()
            assert.is_false(warnsAbout("v1.0.0", "v1.0.0-3-g1a2b3c4"))
            assert.is_false(warnsAbout("v0.1.0-beta13", "v0.1.0-beta13-3-g1a2b3c4"))
            assert.is_true(warnsAbout("v0.1.0-beta13-3-g7654321", "v0.1.0-beta13-4-g1a2b3c4"))
        end)
    end)

    describe("at login", function()
        it("tells about the build an earlier session heard of, after the login chatter", function()
            db.global.newerVersion = {buildTime = NEWER, version = "v0.1.0-beta14"}

            versionCheck:Init()
            assert.spy(printSpy).was_not_called()
            _G.C_Timer.Advance(config.VersionWarnDelay)
            assert.spy(printSpy).was_called(1)

            -- once per session
            announce("Dude", NEWEST, "v0.1.0-beta15")
            assert.equals("v0.1.0-beta15", versionCheck:NewerVersion())
            assert.spy(printSpy).was_called(1)
        end)

        it("forgets that build once we run it", function()
            db.global.newerVersion = {buildTime = MINE, version = "v0.1.0-beta13"}

            versionCheck:Init()
            _G.C_Timer.Advance(config.VersionWarnDelay)

            assert.is_nil(db.global.newerVersion)
            assert.spy(printSpy).was_not_called()
        end)

        it("forgets a build the saved variables can't have got from us", function()
            for _, saved in ipairs({"junk", {}, {buildTime = NEWER}, {buildTime = NEWER, version = "|cFFFF0000x|r"}}) do
                db.global.newerVersion = saved
                versionCheck:Init()
                assert.is_nil(db.global.newerVersion)
            end
            _G.C_Timer.Advance(config.VersionWarnDelay)
            assert.spy(printSpy).was_not_called()
        end)

        it("stays quiet when nothing newer is known", function()
            versionCheck:Init()
            _G.C_Timer.Advance(config.VersionWarnDelay)
            assert.spy(printSpy).was_not_called()
        end)
    end)
end)
