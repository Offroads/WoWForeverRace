-- Group / raid / guild / zone / realm traffic simulation: N complete addon stacks (Core,
-- EventBus, Network, Tracker, Sync, Roster, Channel) talking through the real network envelope.
-- Each client's outgoing traffic is paced by a ChatThrottleLib model (800 B/s, 4 KB
-- burst), so the report shows queueing and time to get back in sync, not just counts.
--
-- Run from the repo root (in the dev container: `make sim`):
--   lua scripts/groupsim.lua [scenario] [sizes] [savedvariables] [nochannel]
--     scenario        all (default), steady, reload, levelup, scan, diverge, drift, guild, zone,
--                     realm, realmlogin, realmnews, realmdiverge
--     sizes           comma separated numbers of clients, default 5,40
--     savedvariables  optional SavedVariables file (a path inside the checkout) to
--                     seed every client with, instead of tests/fixtures/horde-pve-factionrealm.lua;
--                     its "Horde - PvE" factionrealm block is used (FACTION and REALM below).
--                     Pass - to keep the fixture and still give a fourth argument
--     nochannel       nobody is in the realm channel, to measure the backup flows alone
--
-- The model: every client stays online. In the group scenarios (all but guild, zone and
-- the realm ones) they are in yell range of each other and in the same group, with no guild;
-- guild puts them in one guild, out of yell range and not grouped, each logged in at a
-- different time; zone puts them in yell range, not grouped and in no guild; the realm
-- scenarios put them out of yell range, not grouped and in no guild, so only the realm
-- channel connects them. On a checkout with the realm channel every client is in it
-- (joined a while ago) in every scenario, unless nochannel is given. Message
-- sizes are the serialized envelope times the compression ratio measured on real beta
-- leaderboards (not a real Huffman run per message, see scripts/netsize.lua for that),
-- each client sends its queue in order, and the server's own addon message limit is
-- not modelled. Older checkouts without the group ticker run as well, so the same
-- script compares two versions: copy it into a checkout of the older version and run it there.
package.path = "./src/?.lua;./src/?/?.lua;./libs/?.lua;./libs/?/?.lua;./tests/?.lua;./tests/?/?.lua;"
        .. package.path

local WoWForeverRace = require("testbase")
local Config = WoWForeverRace.Config
local noop = function() end
Config.Debug, Config.Trace = false, false
WoWForeverRace.DebugPrint, WoWForeverRace.TracePrint = noop, noop
WoWForeverRace.PPrint, WoWForeverRace.AddHashLog = noop, noop

local AceComm = LibStub("AceComm-3.0")
local AceDB = LibStub("AceDB-3.0")
local AceSerializer = LibStub("AceSerializer-3.0")

local SCENARIO = arg[1] or "all"
local SIZES = {}
for size in string.gmatch(arg[2] or "5,40", "%d+") do SIZES[#SIZES + 1] = tonumber(size) end
local SAVED_VARIABLES = arg[3] ~= "-" and arg[3] ~= "" and arg[3] or nil

local REALM, FACTION = "PvE", "Horde"
-- Huffman plus the addon channel encode table sends 0.80 of the raw bytes on real
-- beta leaderboards (all 15 boards: 18,672 raw, 14,948 sent)
local COMPRESSION = 0.80
local CTL_CPS, CTL_BURST, CTL_OVERHEAD = 800, 4000, #Config.Network.Prefix + 40

local aceDBKey = AceDB:New({}, WoWForeverRace.DefaultDB, true).keys.factionrealm
local HAS_GROUP_TICKER = WoWForeverRace.Sync.InitGroupTicker ~= nil
-- older checkouts have no realm channel
local USE_CHANNEL = WoWForeverRace.Channel ~= nil and arg[4] ~= "nochannel"
local RACE_CHANNEL = USE_CHANNEL and (Config.RaceChannelPrefix .. FACTION) or nil

-- ---------------------------------------------------------------------------
-- seed data
-- ---------------------------------------------------------------------------
-- a fresh copy of the factionrealm block every client starts from
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

-- the clock starts right after the newest ding in the data: a record from the
-- future would be rejected and the clients could never agree
local function startTime()
    local newest = 0
    local fr = loadFactionRealm()
    for _, lb in pairs(fr.leaderboard) do
        if type(lb) == "table" then
            for _, p in ipairs(lb.players) do newest = math.max(newest, p.dingedAt or 0) end
        end
    end
    assert(newest + 60 < Config.RealmLaunchAt, "the data is from after the realm launch, it would be purged")
    return newest + 60
end
local START = startTime()

local function version()
    local pipe = io.popen("git rev-parse --short HEAD 2>/dev/null")
    local rev = pipe and pipe:read("*l")
    if pipe then pipe:close() end
    return rev or "?"
end
local VERSION = version()

-- ---------------------------------------------------------------------------
-- world: every client queues its messages, the throttle model releases them
-- ---------------------------------------------------------------------------
local stacks, now, activeStack, log
-- who hears whom: {group = bool, yell = bool, guild = bool}, set per scenario
local world

local function wireSize(text)
    local bytes = math.ceil(#text * COMPRESSION)
    -- AceComm: one message up to 255 bytes, else 254 byte chunks plus a part marker
    local packets = bytes <= 255 and 1 or math.ceil(bytes / 254)
    return bytes, packets, bytes + packets * CTL_OVERHEAD
end

AceComm.SendCommMessage = function(_, prefix, text, channel, target)
    -- the test stubs replace LibCompress with a pass-through, so the envelope is plain
    local ok, envelope = AceSerializer:Deserialize(text)
    assert(ok, "envelope did not decode")
    local bytes, packets, cost = wireSize(text)
    local s = activeStack
    s.outbox[#s.outbox + 1] = {from = s, prefix = prefix, text = text, channel = channel, target = target,
                               event = envelope[1], bytes = bytes, packets = packets, cost = cost,
                               queuedAt = now}
end

local function resetWorld(flags)
    stacks, log = {}, {}
    world = flags
    now = START
    _G.SetTime(now)
    _G.C_Timer.Reset()
    _G.SetFaction(FACTION)
    _G.SetIsInGuild(flags.guild)
    if USE_CHANNEL then _G.SetChatChannels(nil) end
end

local function deliver(msg)
    log[#log + 1] = msg
    local s = msg.from
    s.sentBytes = s.sentBytes + msg.bytes
    s.maxDelay = math.max(s.maxDelay, now - msg.queuedAt)
    for _, other in ipairs(stacks) do
        if other ~= s then
            local wanted
            if msg.channel == "WHISPER" then
                wanted = other.name == msg.target
            elseif msg.channel == "GUILD" then
                wanted = world.guild
            elseif msg.channel == "YELL" then
                wanted = world.yell
            elseif msg.channel == "CHANNEL" then
                -- the realm channel reaches every client that is in it, wherever it is
                wanted = other.channel:IsJoined()
            else
                -- RAID, PARTY, INSTANCE_CHAT
                wanted = world.group
            end
            if wanted then
                other.network:HandleAddonMessage(msg.prefix, msg.text, msg.channel, s.name)
            end
        end
    end
end

-- sends what every client's throttle allows, delivering right away; repeats until
-- nothing more fits (a delivery can queue replies)
local function pump()
    local progress = true
    while progress do
        progress = false
        for _, s in ipairs(stacks) do
            while #s.outbox > 0 and s.avail >= s.outbox[1].cost do
                local msg = table.remove(s.outbox, 1)
                s.avail = s.avail - msg.cost
                deliver(msg)
                progress = true
            end
        end
    end
end

local function tick(seconds)
    for _ = 1, seconds do
        now = now + 1
        _G.SetTime(now)
        for _, s in ipairs(stacks) do
            s.avail = math.min(s.avail + CTL_CPS, CTL_BURST)
            -- a message bigger than the burst still goes out once the bucket is full
            if #s.outbox > 0 and s.outbox[1].cost > CTL_BURST and s.avail >= CTL_BURST then
                s.avail = s.outbox[1].cost
            end
        end
        _G.C_Timer.Advance(1)
        pump()
    end
end

local function newStack(name, savedVariables)
    local db = AceDB:New(savedVariables, WoWForeverRace.DefaultDB, true)
    local core = WoWForeverRace.Core(Config, name, REALM)
    local eventbus = WoWForeverRace.EventBus()
    local channel = USE_CHANNEL and WoWForeverRace.Channel(Config, core, db, eventbus) or nil
    local network = WoWForeverRace.Network(core, eventbus, channel)
    local s = {name = name, db = db, core = core, network = network, channel = channel, outbox = {},
               avail = CTL_BURST, sentBytes = 0, maxDelay = 0}
    s.tracker = WoWForeverRace.Tracker(Config, core, db, eventbus, network, channel)
    s.sync = WoWForeverRace.Sync(Config, core, db, eventbus, network, channel)
    s.roster = WoWForeverRace.Roster(core, db, eventbus)
    -- tag outgoing messages with their client
    network.SendObject = function(self, ...)
        local previous = activeStack
        activeStack = s
        WoWForeverRace.Network.SendObject(self, ...)
        activeStack = previous
    end
    stacks[#stacks + 1] = s
    return s
end

-- puts a client in the realm channel (the channel list of the stubs is shared by all
-- clients), which runs its join sync
local function joinChannel(s)
    if not USE_CHANNEL then return end
    _G.JoinTemporaryChannel(RACE_CHANNEL)
    s.channel:TryJoin()
end

-- Every client joined the realm channel a while ago: runs the join syncs and lets them
-- settle, so a scenario starts with clients that hear each other there. Clients that
-- know different things have traded with one partner each by then, like after a login.
local function settleOnChannel()
    if not USE_CHANNEL then return end
    for _, s in ipairs(stacks) do joinChannel(s) end
    tick(Config.ChannelSyncWait + 1 + Config.ChannelSettleTime)
    for _, s in ipairs(stacks) do s.sync:InitChannelTicker() end
end

local function memberName(i)
    local letter = string.char(64 + ((i - 1) % 26) + 1)
    return "Member" .. letter .. " Raider" .. string.rep("x", math.floor((i - 1) / 26))
end

-- the group as the unit stubs see it: every client is a raid member (the stubs are
-- shared by all clients, and raid tokens look the same from every member)
local memberLevels
local function setGroup()
    local members = {}
    for _, s in ipairs(stacks) do
        members[#members + 1] = {name = s.name, level = memberLevels[s.name] or 20, class = "WARRIOR", raceIndex = 2}
    end
    _G.SetGroupMembers(members, true)
end

-- drops each player from every board of fr with chance 1 - keep (consistently across boards)
local function forget(fr, keep)
    local kept = {}
    for _, lb in pairs(fr.leaderboard) do
        if type(lb) == "table" then
            local players = {}
            for _, p in ipairs(lb.players) do
                if kept[p.name] == nil then kept[p.name] = math.random() < keep end
                if kept[p.name] then players[#players + 1] = p end
            end
            lb.players = players
            -- a board that isn't full takes anyone again
            if #players < Config.MaxLeaderboardSize then lb.minLevel = 1 end
        end
    end
end

-- n clients online for a while (ready, tickers at random phases), just grouped up;
-- keep < 1 gives each client only part of the boards
local function makeGroup(n, keep, seed)
    resetWorld({group = true, yell = true, guild = false})
    math.randomseed(seed)
    memberLevels = {}
    for i = 1, n do
        local fr = loadFactionRealm()
        if keep < 1 then forget(fr, keep) end
        local s = newStack(memberName(i), {factionrealm = {[aceDBKey] = fr}})
        s.sync.isReady = true
    end
    _G.SetGroupMembers(nil)
    settleOnChannel()
    setGroup()
    -- everyone just joined: the group change runs the join-time group sync on every
    -- version (and makes the members each other's buddies)
    for _, s in ipairs(stacks) do s.sync:OnGroupRosterUpdate() end
    for _, s in ipairs(stacks) do
        _G.C_Timer.After(math.random(0, 300), function()
            s.tracker:InitDiscoveryTicker()
            s.sync:InitBuddyTicker()
            if HAS_GROUP_TICKER then s.sync:InitGroupTicker() end
        end)
    end
end

-- n clients online for a while, not grouped (flags: the guild and yell range), each
-- keeping part of the boards. Everyone logged in at a different time: the guild sync
-- of older versions picks the member online the longest.
local function makeCrowd(n, keep, seed, flags)
    resetWorld(flags)
    math.randomseed(seed)
    _G.SetGroupMembers(nil)
    for i = 1, n do
        local fr = loadFactionRealm()
        if keep < 1 then forget(fr, keep) end
        local s = newStack(memberName(i), {factionrealm = {[aceDBKey] = fr}})
        s.sync.isReady = true
        s.core.loginTime = START - i * 60
    end
    settleOnChannel()
    for _, s in ipairs(stacks) do
        _G.C_Timer.After(math.random(0, 300), function()
            s.tracker:InitDiscoveryTicker()
            s.sync:InitBuddyTicker()
            if flags.guild then
                -- the first guild round, then one every GuildSyncInterval
                s.sync:SendGuildSync()
                s.sync:InitGuildTicker()
            end
        end)
    end
end

local function fullHash(s)
    return WoWForeverRace.Sync.ComputeFullHash(s.db, Config, nil, FACTION)
end

-- the number of clients holding the most common data
local function largestAgreement()
    local counts, best = {}, 0
    for _, s in ipairs(stacks) do
        local h = fullHash(s)
        counts[h] = (counts[h] or 0) + 1
        best = math.max(best, counts[h])
    end
    return best
end

-- ---------------------------------------------------------------------------
-- reporting
-- ---------------------------------------------------------------------------
local function resetCounters()
    for _, s in ipairs(stacks) do s.sentBytes, s.maxDelay = 0, 0 end
    return #log + 1
end

local function summarize(title, since, seconds)
    local byEvent, msgs, bytes, packets = {}, 0, 0, 0
    for i = since, #log do
        local m = log[i]
        local key = m.event .. " " .. (m.channel == "WHISPER" and "whisper" or m.channel:lower())
        local e = byEvent[key] or {msgs = 0, bytes = 0}
        e.msgs, e.bytes = e.msgs + 1, e.bytes + m.bytes
        byEvent[key] = e
        msgs, bytes, packets = msgs + 1, bytes + m.bytes, packets + m.packets
    end
    local maxSent, maxDelay, backlog = 0, 0, 0
    for _, s in ipairs(stacks) do
        maxSent = math.max(maxSent, s.sentBytes)
        maxDelay = math.max(maxDelay, s.maxDelay)
        local queued = 0
        for _, m in ipairs(s.outbox) do queued = queued + m.bytes end
        backlog = math.max(backlog, queued)
    end
    print(string.format("  %s  [%s]", title, VERSION))
    print(string.format("    %d messages, %.1f KB, %d packets over %ds (%.1f msgs/min for the group)",
            msgs, bytes / 1024, packets, seconds, msgs / seconds * 60))
    print(string.format("    busiest client sent %.1f KB (%.1f%% of its throttle budget); "
            .. "longest queue wait %ds; largest backlog left %.1f KB",
            maxSent / 1024, 100 * maxSent / (CTL_CPS * seconds + CTL_BURST), maxDelay, backlog / 1024))
    local keys = {}
    for k in pairs(byEvent) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return byEvent[a].bytes > byEvent[b].bytes end)
    for _, k in ipairs(keys) do
        print(string.format("      %-22s %6d msgs %9.1f KB", k, byEvent[k].msgs, byEvent[k].bytes / 1024))
    end
end

-- ticks until every client holds the same data (at most two hours) and reports it
local function untilInSync(title, since)
    local convergedAt
    local agreement = {}
    for t = 1, 7200 do
        tick(1)
        if t % 60 == 0 then agreement[#agreement + 1] = largestAgreement() end
        -- hashing every client's boards is the slow part: every second at first, then every 10
        if (t <= 600 or t % 10 == 0) and largestAgreement() == #stacks then convergedAt = t break end
    end
    summarize(title, since, convergedAt or 7200)
    print(string.format("    in sync after: %s; clients holding the most common data, per minute: %s",
            convergedAt and (convergedAt .. "s") or "NOT within 120 min", table.concat(agreement, " ")))
end

-- ---------------------------------------------------------------------------
-- scenarios
-- ---------------------------------------------------------------------------
local scenarios = {}

scenarios.steady = function(n)
    makeGroup(n, 1, 1)
    tick(300) -- let every ticker start
    local since = resetCounters()
    tick(1800)
    summarize(string.format("%d players, all in sync, 30 min of normal ticking", n), since, 1800)
end

scenarios.reload = function(n)
    makeGroup(n, 1, 2)
    tick(600)
    local since = resetCounters()
    -- one member reloads: it isn't ready until its login sync ran
    local s = stacks[1]
    s.sync.isReady = false
    s.sync.offers = {}
    s.sync:InitSync()
    tick(60)
    summarize(string.format("%d players, one member /reloads (first 60s)", n), since, 60)
end

scenarios.levelup = function(n)
    makeGroup(n, 1, 4)
    -- the roster has read everyone once
    for _, s in ipairs(stacks) do s.roster.Thread:FireEvent("GROUP_ROSTER_UPDATE") end
    tick(600)
    local since = resetCounters()
    memberLevels[stacks[1].name] = 21
    setGroup()
    for _, s in ipairs(stacks) do s.roster.Thread:FireEvent("UNIT_LEVEL", "raid2") end
    tick(30)
    summarize(string.format("%d players, one member levels 20 -> 21 (first 30s)", n), since, 30)
end

scenarios.scan = function(n)
    makeGroup(n, 1, 5)
    tick(600)
    local since = resetCounters()
    stacks[1].tracker:OnSlashWhoResult({{name = "Somebody Else", level = 21, classIndex = 1, raceIndex = 2}})
    tick(30)
    summarize(string.format("%d players, one member's /who finds a new level 21 (first 30s)", n), since, 30)
end

scenarios.diverge = function(n)
    makeGroup(n, 0.6, 3)
    local since = resetCounters()
    untilInSync(string.format("%d players group up, each knowing 60%% of the boards, until in sync", n), since)
end

scenarios.drift = function(n)
    makeGroup(n, 1, 6)
    tick(600)
    for _, s in ipairs(stacks) do forget(s.db.factionrealm, 0.6) end
    local since = resetCounters()
    untilInSync(string.format("%d players online for 10 min, then each drops to 60%% of the boards, until in sync", n),
            since)
end

scenarios.guild = function(n)
    makeCrowd(n, 0.6, 8, {group = false, yell = false, guild = true})
    local since = resetCounters()
    untilInSync(string.format("%d guild members out of yell range, each knowing 60%% of the boards, until in sync",
            n), since)
end

scenarios.zone = function(n)
    makeCrowd(n, 0.6, 7, {group = false, yell = true, guild = false})
    local since = resetCounters()
    untilInSync(string.format("%d players in yell range, not grouped, no guild, each knowing 60%% of the boards, "
            .. "until in sync", n), since)
end

-- ---------------------------------------------------------------------------
-- realm scenarios: only the realm channel connects the clients
-- ---------------------------------------------------------------------------
local REALM_WORLD = {group = false, yell = false, guild = false}

-- a character name: letters only, the serializer keeps digits out of names
local function runnerName(i)
    local letters = ""
    repeat
        letters = string.char(97 + i % 26) .. letters
        i = math.floor(i / 26)
    until i == 0
    return "Runner " .. letters
end

local function inSyncNote()
    return string.format("    clients holding the most common data at the end: %d of %d", largestAgreement(), #stacks)
end

-- everyone in sync on the channel; a level-up every 20s, spotted by three clients within
-- a few seconds of each other (three /who scans that hit the same class)
scenarios.realm = function(n)
    if not USE_CHANNEL then return end
    makeCrowd(n, 1, 9, REALM_WORLD)
    tick(300)
    local since = resetCounters()
    local dings = 0
    for t = 1, 3600 do
        if t % 20 == 0 then
            dings = dings + 1
            local info = {name = runnerName(dings), level = 21 + math.floor(dings / 60), classIndex = 1, raceIndex = 2}
            for _, delay in ipairs({0, 1, 3}) do
                local s = stacks[math.random(1, #stacks)]
                _G.C_Timer.After(delay, function()
                    s.tracker:OnSlashWhoResult({{name = info.name, level = info.level, classIndex = 1, raceIndex = 2}})
                end)
            end
        end
        tick(1)
    end
    tick(30)
    summarize(string.format("%d players on the realm channel, in sync, 60 min with %d level-ups each spotted by 3 "
            .. "clients", n, dings), since, 3630)
    print(inSyncNote())
end

-- everyone in sync on the channel, then a client that was offline (knows 60%) logs in
scenarios.realmlogin = function(n)
    if not USE_CHANNEL then return end
    makeCrowd(n, 1, 10, REALM_WORLD)
    tick(300)
    local since = resetCounters()
    local fr = loadFactionRealm()
    forget(fr, 0.6)
    local s = newStack("Late Comer", {factionrealm = {[aceDBKey] = fr}})
    s.sync:InitSync()
    _G.C_Timer.After(Config.ChannelJoinDelay, function() joinChannel(s) end)
    untilInSync(string.format("%d players on the realm channel, in sync; one more logs in knowing 60%% of the "
            .. "boards, until in sync", n), since)
end

-- everyone in sync on the channel, and one client holds a player nobody else knows (seen
-- while nobody was listening): it spreads with that client's next full sync
scenarios.realmnews = function(n)
    if not USE_CHANNEL then return end
    makeCrowd(n, 1, 11, REALM_WORLD)
    tick(300)
    stacks[1].tracker:ProcessPlayerInfo({name = "Night Owl", level = 25, classIndex = 1, raceIndex = 2,
                                         dingedAt = now - 100})
    local since = resetCounters()
    untilInSync(string.format("%d players on the realm channel, one of them holds a player nobody else knows, "
            .. "until in sync", n), since)
end

-- the worst case: every client knows a different 60% of the boards
scenarios.realmdiverge = function(n)
    if not USE_CHANNEL then return end
    makeCrowd(n, 0.6, 12, REALM_WORLD)
    local since = resetCounters()
    untilInSync(string.format("%d players on the realm channel, each knowing 60%% of the boards, until in sync "
            .. "(after the join sync with one partner each)", n), since)
end

local ORDER = {"steady", "reload", "levelup", "scan", "diverge", "drift", "guild", "zone",
               "realm", "realmlogin", "realmnews", "realmdiverge"}
if SCENARIO ~= "all" and scenarios[SCENARIO] == nil then
    error("unknown scenario " .. SCENARIO .. ", expected all or one of: " .. table.concat(ORDER, ", "))
end
for _, n in ipairs(SIZES) do
    print(string.rep("=", 100))
    for _, name in ipairs(ORDER) do
        if SCENARIO == "all" or SCENARIO == name then scenarios[name](n) end
    end
end
