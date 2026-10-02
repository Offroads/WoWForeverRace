-- load test base
local WoWForeverRace = require("testbase")

local NetEvents = WoWForeverRace.Config.Network.Events

describe("VersionCheck", function()
    local config
    local db
    local core
    local eventbus
    local versionCheck
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
        versionCheck = WoWForeverRace.VersionCheck(config, core, db, eventbus)
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
        -- stub instead of spy so the warnings don't end up in the test output
        printSpy = stub(WoWForeverRace, "PPrint")
        create()
    end)

    after_each(function()
        printSpy:revert()
    end)

    describe("hearing a newer build", function()
        it("waits for a second player before it tells the player", function()
            announce("Dude", NEWER, "v0.1.0-beta14")
            assert.is_nil(versionCheck:NewerVersion())
            assert.spy(printSpy).was_not_called()

            announce("Dudette", NEWER, "v0.1.0-beta14")
            assert.equals("v0.1.0-beta14", versionCheck:NewerVersion())
            assert.same({buildTime = NEWER, version = "v0.1.0-beta14"}, db.global.newerVersion)
            assert.spy(printSpy).was_called(1)
            local message = printSpy.calls[1].vals[2]
            assert.is_truthy(message:find("v0.1.0-beta14", 1, true))
            assert.is_truthy(message:find("v0.1.0-beta13", 1, true))
        end)

        it("counts a player once, however often it announces", function()
            announce("Dude", NEWER, "v0.1.0-beta14")
            announce("Dude", NEWER, "v0.1.0-beta14")
            announce("Dude", NEWEST, "v0.1.0-beta15")

            assert.is_nil(versionCheck:NewerVersion())
            assert.spy(printSpy).was_not_called()
        end)

        it("names the build two players run at least", function()
            announce("Dude", NEWEST, "v0.1.0-beta15")
            announce("Dudette", NEWER, "v0.1.0-beta14")
            assert.equals("v0.1.0-beta14", versionCheck:NewerVersion())

            -- a second player on the newest build: that one is known now ...
            announce("Dudine", NEWEST, "v0.1.0-beta15")
            assert.equals("v0.1.0-beta15", versionCheck:NewerVersion())
            -- ... but the player was told this session already
            assert.spy(printSpy).was_called(1)
        end)

        it("keeps the newest build it knows of", function()
            announce("Dude", NEWEST, "v0.1.0-beta15")
            announce("Dudette", NEWEST, "v0.1.0-beta15")
            announce("Dudine", NEWER, "v0.1.0-beta14")
            announce("Dudon", NEWER, "v0.1.0-beta14")

            assert.equals("v0.1.0-beta15", versionCheck:NewerVersion())
        end)

        it("ignores our own build and older ones", function()
            for _, sender in ipairs({"Dude", "Dudette"}) do
                announce(sender, MINE, "v0.1.0-beta13")
                announce(sender, MINE - DAY, "v0.1.0-beta12")
            end

            assert.is_nil(versionCheck:NewerVersion())
            assert.spy(printSpy).was_not_called()
        end)

        it("ignores a client that says nothing about its build", function()
            assert.has_no.errors(function()
                for _, sender in ipairs({"Dude", "Dudette"}) do
                    eventbus:PublishEvent(NetEvents.ChannelSync, {123, 456}, sender, "CHANNEL")
                    eventbus:PublishEvent(NetEvents.ChannelSync, {123, 456, time}, sender, "CHANNEL")
                    eventbus:PublishEvent(NetEvents.ChannelSync, 42, sender, "CHANNEL")
                    eventbus:PublishEvent(NetEvents.ChannelSync, {123, 456, nil, "junk"}, sender, "CHANNEL")
                    eventbus:PublishEvent(NetEvents.ChannelSync, {123, 456, nil, {}}, sender, "CHANNEL")
                end
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
                announce("Dudette", build[1], build[2])
            end

            assert.is_nil(versionCheck:NewerVersion())
            assert.is_nil(db.global.newerVersion)
            assert.spy(printSpy).was_not_called()
        end)

        it("an unpackaged checkout never warns", function()
            versionCheck = WoWForeverRace.VersionCheck(WoWForeverRace.Config, core, db, WoWForeverRace.EventBus())
            versionCheck:OnNetChannelSync({123, 456, nil, {NEWER, "v0.1.0-beta14"}}, "Dude")
            versionCheck:OnNetChannelSync({123, 456, nil, {NEWER, "v0.1.0-beta14"}}, "Dudette")

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
            announce("Dudette", NEWER, version)
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
            announce("Dudette", NEWEST, "v0.1.0-beta15")
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
