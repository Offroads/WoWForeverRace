-- Message sizes of a full update: every leaderboard, the pioneers (first to level)
-- and the login player history pull, each sent the way the addon sends it
-- (Sync:Sync, Sync:SyncFTL, Sync:SyncPlayerHistory) through the real pipeline of
-- Network:SendObject: AceSerializer, the real LibCompress Huffman coder and addon
-- channel encode table, then AceComm's chunking into chat packets. The ChatThrottleLib
-- cost is what the bundled ChatThrottleLib charges: each packet's length plus
-- MSG_OVERHEAD. Run it again whenever the wire format changes.
--
-- Run from the repo root (in the dev container: `make netsize`):
--   lua scripts/netsize.lua [savedvariables]
--     savedvariables  optional SavedVariables file (a path inside the checkout) to
--                     measure instead of tests/fixtures/horde-pve-factionrealm.lua;
--                     its "Horde - PvE" factionrealm block is used (FACTION and REALM below)
--
-- Needs WoW's `bit` library (LuaBitOp, in the dev image) for the real LibCompress.
package.path = "./src/?.lua;./src/?/?.lua;./libs/?.lua;./libs/?/?.lua;./tests/?.lua;./tests/?/?.lua;"
        .. package.path

-- the real LibCompress instead of the tests' pass-through, see tests/testbase.lua
_G.WFR_REAL_LIBCOMPRESS = true
local WoWForeverRace = require("testbase")
local Config = WoWForeverRace.Config
local noop = function() end
Config.Debug, Config.Trace = false, false
WoWForeverRace.DebugPrint, WoWForeverRace.TracePrint = noop, noop
WoWForeverRace.PPrint, WoWForeverRace.AddHashLog = noop, noop

local AceComm = LibStub("AceComm-3.0")
local AceDB = LibStub("AceDB-3.0")
local CTL = _G.ChatThrottleLib

local SAVED_VARIABLES = arg[1]
local REALM, FACTION = "PvE", "Horde"
local TARGET = "Netsize Target"

-- the factionrealm block to measure
local function loadFactionRealm()
    if SAVED_VARIABLES == nil then
        return dofile("tests/fixtures/horde-pve-factionrealm.lua")
    end
    local env = {}
    setfenv(assert(loadfile(SAVED_VARIABLES)), env)()
    local blocks = env.WoWForeverRace_DB and env.WoWForeverRace_DB.factionrealm or {}
    local key = FACTION .. " - " .. REALM
    if blocks[key] ~= nil then return blocks[key] end

    local found = {}
    for name in pairs(blocks) do found[#found + 1] = "\"" .. name .. "\"" end
    table.sort(found)
    error(string.format("no factionrealm block \"%s\" in %s (found: %s)", key, SAVED_VARIABLES,
            #found > 0 and table.concat(found, ", ") or "none"))
end

local function version()
    local pipe = io.popen("git rev-parse --short HEAD 2>/dev/null")
    local rev = pipe and pipe:read("*l")
    if pipe then pipe:close() end
    return rev or "?"
end

-- ---------------------------------------------------------------------------
-- capture: AceComm counts the messages and their encoded bytes, then chunks them
-- exactly like the client and hands every packet to ChatThrottleLib, which counts
-- the packets and their cost instead of sending them
-- ---------------------------------------------------------------------------
local current
local sendCommMessage = AceComm.SendCommMessage
AceComm.SendCommMessage = function(self, prefix, text, ...)
    current.messages = current.messages + 1
    current.bytes = current.bytes + #text
    return sendCommMessage(self, prefix, text, ...)
end
CTL.SendAddonMessage = function(ctl, _, _, text)
    current.packets = current.packets + 1
    current.cost = current.cost + #text + ctl.MSG_OVERHEAD
end

local function measure(fn)
    current = {messages = 0, bytes = 0, packets = 0, cost = 0}
    fn()
    -- the history chunks are spaced out by timers
    _G.C_Timer.Advance(3600)
    return current
end

local function add(a, b)
    return {messages = a.messages + b.messages, bytes = a.bytes + b.bytes,
            packets = a.packets + b.packets, cost = a.cost + b.cost}
end

-- ---------------------------------------------------------------------------
-- one client holding the data
-- ---------------------------------------------------------------------------
_G.C_Timer.Reset()
_G.SetFaction(FACTION)
local aceDBKey = AceDB:New({}, WoWForeverRace.DefaultDB, true).keys.factionrealm
local db = AceDB:New({factionrealm = {[aceDBKey] = loadFactionRealm()}}, WoWForeverRace.DefaultDB, true)
local core = WoWForeverRace.Core(Config, "Netsize Sender", REALM)
local eventbus = WoWForeverRace.EventBus()
local network = WoWForeverRace.Network(core, eventbus)
local sync = WoWForeverRace.Sync(Config, core, db, eventbus, network)

local boards = {}
local allBoards = {messages = 0, bytes = 0, packets = 0, cost = 0}
for _, boardIndex in ipairs(core:BoardIndexes()) do
    local lb = db.factionrealm.leaderboard[boardIndex]
    if lb and #lb.players > 0 then
        local size = measure(function() sync:Sync(TARGET, boardIndex) end)
        size.players = #lb.players
        boards[#boards + 1] = size
        allBoards = add(allBoards, size)
    end
end
local ftl = measure(function() sync:SyncFTL(TARGET) end)
local history = measure(function() sync:SyncPlayerHistory(TARGET) end)

-- ---------------------------------------------------------------------------
-- report
-- ---------------------------------------------------------------------------
local function thousands(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function range(key)
    local low, high
    for _, b in ipairs(boards) do
        low = low and math.min(low, b[key]) or b[key]
        high = high and math.max(high, b[key]) or b[key]
    end
    if low == nil then return "-" end
    if low == high then return thousands(low) end
    return thousands(low) .. "-" .. thousands(high)
end

local rows = {
    {"One full leaderboard (" .. range("players") .. " players)", "1", range("bytes"), range("packets"), range("cost")},
}
local function row(label, size)
    rows[#rows + 1] = {label, thousands(size.messages), thousands(size.bytes), thousands(size.packets),
                       thousands(size.cost)}
end
row("All " .. #boards .. " leaderboards", allBoards)
row("First-to-level records", ftl)
row("Full update (boards + first-to-level)", add(allBoards, ftl))
row("Login player history pull", history)

print(string.format("Message sizes through the real pipeline [%s], data: %s",
        version(), SAVED_VARIABLES or "tests/fixtures/horde-pve-factionrealm.lua"))
local header = {"What", "Messages", "Bytes sent", "Chat packets", "ChatThrottleLib cost"}
local widths = {}
for i, title in ipairs(header) do widths[i] = #title end
for _, r in ipairs(rows) do
    for i, cell in ipairs(r) do widths[i] = math.max(widths[i], #cell) end
end
local function printRow(r)
    local cells = {string.format("%-" .. widths[1] .. "s", r[1])}
    for i = 2, #r do cells[i] = string.format("%" .. widths[i] .. "s", r[i]) end
    print("  " .. table.concat(cells, "  "))
end
printRow(header)
for _, r in ipairs(rows) do printRow(r) end
print(string.format("  ChatThrottleLib lets a client send %d bytes/s (%d burst): a full update costs %.0f seconds of it",
        CTL.MAX_CPS, CTL.BURST, add(allBoards, ftl).cost / CTL.MAX_CPS))
