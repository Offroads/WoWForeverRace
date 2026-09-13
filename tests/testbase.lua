-- Shared bootstrap for every test file: installs the WoW API stubs, loads the
-- Ace3 libraries the addon depends on and finally the addon sources under test.
-- Usage at the top of a test file: local WoWForeverRace = require("testbase")

-- stubs
require("stubs.misc")
require("stubs.player")
require("stubs.createframe")
require("stubs.chatinfo")

-- libs loaded with dofile() because dots in the names ...
dofile("libs/LibStub/LibStub.lua")
dofile("libs/CallbackHandler/CallbackHandler-1.0.lua")
dofile("libs/AceDB/AceDB-3.0.lua")
dofile("libs/AceSerializer/AceSerializer-3.0.lua")
dofile("libs/AceComm/ChatThrottleLib.lua")
dofile("libs/AceComm/AceComm-3.0.lua")
dofile("tests/stubs/libcompressmock.lua")

-- addon
WoWForeverRace = {}
_G.WoWForeverRace = WoWForeverRace

require("config")

-- The unpackaged config (the @debug@ block in config.lua) turns debug prints on,
-- which drowns the test output. Opt back in with WFR_TEST_DEBUG=1 when needed.
local testDebug = os.getenv("WFR_TEST_DEBUG")
if testDebug == nil or testDebug == "" or testDebug == "0" or testDebug == "false" then
    WoWForeverRace.Config.Debug = false
    WoWForeverRace.Config.Trace = false
end

require("defaultdb")
require("util.chat")
require("util.util")
require("util.list-helpers")
require("util.table-helpers")
require("core.core")
require("core.scanner")
require("core.event-bus")
require("core.tracker")
require("core.leaderboard")
require("core.sync")
require("core.serializer")
require("networking.network")

return WoWForeverRace
