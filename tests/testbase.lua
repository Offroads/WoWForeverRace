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
