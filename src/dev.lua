--[[
This file contains development-only things that aren't pretty but don't need to be ... xD

It is only loaded from an unpackaged checkout (see the @debug@ block in the .toc),
release builds never ship it.
--]]
-- Addon global
local WoWForeverRace = _G.WoWForeverRace

local HELP = {
    "/wfr show           show the leaderboard window",
    "/wfr debug          show the debug window (message stats, hash log, buddies)",
    "/wfr render         re-render the leaderboard window",
    "/wfr status         scanner / sync / leaderboard / roster state in a copyable window",
    "/wfr scan           trigger a /who scan now (must be typed, needs a hardware event)",
    "/wfr update         re-run the login sync",
    "/wfr roster         read the guild roster and group members into the leaderboards now",
    "/wfr ding NAME LVL [CLASS] [RACEID]   fake a /who result for a player",
    "/wfr whoami NAME    pretend to be another player on this realm",
    "/wfr reset          wipe the leaderboards, pioneers and history for this faction-realm (keeps realmOpenedAt)",
    "/wfr resetall       reset the leaderboards, pioneers and history of EVERY player of your faction (beta only,"
            .. " other clients only accept it from the characters in Config.ResetAuthors)",
    "/wfr probe          dump what the client API returns into a copyable window (do a /who first)",
    "/wfr chprobe        send an addon message on every distribution (say, yell, party, guild, our channel, ...)"
            .. " and report which ones the client takes and which echo back",
    "/wfr yellprobe      send SAY and YELL addon messages right from the command (a hardware event, like"
            .. " the /who scans) to see whether that gets them past the client",
}

--[[
The /wfr handler, overwrites with a more advanced development mode /wfr
--]]
function WoWForeverRace:slashwfr(input)
    local action, arg1, arg2, arg3, arg4 = self:GetArgs(input, 5)

    --[[SCAN]]--
    if action == "scan" then
        self.scanner:TriggerScan()

    --[[RESET]]--
    elseif action == "reset" then
        -- go through our own ResetDB (keeps the realm-opened timestamp and
        -- the db version; the components re-bind through OnDatabaseReset)
        self:ResetDB()
        self:PPrint("Database reset.")

    --[[RESET EVERYBODY]]--
    elseif action == "resetall" then
        if self.Core:HasLaunched() then
            self:PPrint("The realm has launched: the race can no longer be reset for everybody.")
            return
        end
        if not self.DB.profile.options.networking then
            self:PPrint("Sharing is turned off: nobody would hear the reset.")
            return
        end
        self.Tracker:SendReset()
        if self.Core:IsResetAuthor(self.Core:RealMe()) then
            self:PPrint("Leaderboards reset for everybody of your faction, as far as they can be reached.")
        else
            self:PPrint("Leaderboards reset here. Other clients ignore it: " .. tostring(self.Core:RealMe())
                    .. " is not in Config.ResetAuthors.")
        end

    --[[SHOW FRAME]]--
    elseif action == "show" or action == nil or action == "" then
        self.StatusFrame:Show()

    --[[DEBUG FRAME]]--
    elseif action == "debug" then
        self.DebugFrame:Show()

    --[[UPDATE FRAME]]--
    elseif action == "render" then
        self.StatusFrame:Render()

    --[[REQUEST UPDATE]]--
    elseif action == "update" then
        self.Sync:InitSync()

    --[[STATUS]]--
    elseif action == "status" then
        self:ShowDevStatus()

    --[[ROSTER]]--
    elseif action == "roster" then
        self.Roster:Refresh()

    --[[API PROBE]]--
    elseif action == "probe" then
        self:ShowApiProbe()

    --[[DISTRIBUTION PROBE]]--
    elseif action == "chprobe" then
        self:ShowChannelProbe("all")

    --[[YELL PROBE (hardware event)]]--
    elseif action == "yellprobe" then
        self:ShowChannelProbe("yell")

    --[[WHOAMI]]--
    elseif action == "whoami" then
        if arg1 == nil then
            self:PPrint("usage: /wfr whoami NAME")
            return
        end
        self.Core:InitMe(arg1, self.Core:MyRealm())

    --[[DING name level]]--
    elseif action == "ding" then
        if arg1 == nil or tonumber(arg2) == nil then
            self:PPrint("usage: /wfr ding NAME LEVEL [CLASS] [RACEID]")
            return
        end
        self:DebugPrint("Forced Ding [" .. arg1 .. "] lvl" .. arg2 .. ".")
        self.EventBus:PublishEvent(self.Config.Events.SlashWhoResult, {{
            name = arg1,
            level = tonumber(arg2),
            class = arg3 and string.upper(arg3) or "DRUID",
            raceIndex = tonumber(arg4),
        }})

    --[[HELP]]--
    elseif action == "help" then
        for _, line in ipairs(HELP) do
            self:PPrint(line)
        end
    else
        self:PPrint("Unknown action: " .. tostring(action) .. " (try /wfr help)")
    end
end

-- Dumps the in-memory state that is otherwise only visible through debug prints.
function WoWForeverRace:BuildDevStatus()
    local db = self.DB.factionrealm
    local scanner = self.scanner
    local sync = self.Sync
    local lines = {}
    local function add(line) lines[#lines + 1] = line end

    add("version " .. tostring(self.Config.Version) .. ", me: " .. tostring(self.Core:FullRealMe())
            .. ", expansion max level " .. tostring(self.Config.MaxLevel))
    add("db version " .. tostring(db.dbversion) .. ", finished: " .. tostring(db.finished)
            .. ", realm opened " .. tostring(db.realmOpenedAt))
    add("")

    add("== Leaderboards")
    for _, boardIndex in ipairs(self.Core:BoardIndexes()) do
        local lb = db.leaderboard[boardIndex]
        if lb and #lb.players > 0 then
            -- a leaderboard index that is no class index belongs to a race
            local label = self.Config.Classes[boardIndex] or boardIndex == 0 and self.Core:ClassByIndex(0)
                    or self.Core:RaceName(boardIndex - self.Config.RaceBoardOffset)
            add(string.format("board %3d (%s): %d players, min lvl %d, max lvl %d",
                    boardIndex, tostring(label), #lb.players, lb.minLevel, lb.highestLevel))
        end
    end
    add("")

    add("== Scanner / sync")
    add("scanner: pending=" .. tostring(scanner.scanPending)
            .. " pendingMin=" .. tostring(scanner.pendingScanMin)
            .. " lastClass=" .. tostring(scanner.lastScanClassIndex)
            .. " nextClassSlot=" .. tostring(scanner.nextScanClassIdx)
            .. " lastScan=" .. tostring(scanner.lastScanTime))
    add("sync: ready=" .. tostring(sync.isReady) .. " lastSync=" .. tostring(sync.lastSync))
    add("buddies: " .. WoWForeverRace.table.cnt(db.buddies)
            .. ", players with history: " .. WoWForeverRace.table.cnt(db.playerHistory))
    local channel = self.Channel
    add("realm channel: " .. channel:Name() .. " status=" .. channel:Status()
            .. " number=" .. tostring(channel:Number())
            .. " joined=" .. tostring(channel:IsJoined())
            .. " live=" .. tostring(channel:IsLive())
            .. " heard=" .. channel:Size()
            .. " lastHeard=" .. tostring(channel.lastHeardAt)
            .. " settleIn=" .. channel:SettleDelay())
    add("")

    add("== Roster")
    local withRace = 0
    for _, seen in pairs(self.Roster.seen) do
        if seen.raceIndex ~= nil then withRace = withRace + 1 end
    end
    add("forwarded: " .. WoWForeverRace.table.cnt(self.Roster.seen) .. " guild / group members, "
            .. withRace .. " with a race")
    local numGuild, numOnline = _G.GetNumGuildMembers()
    add("guild: inGuild=" .. tostring(_G.IsInGuild()) .. " members=" .. tostring(numGuild)
            .. " online=" .. tostring(numOnline))
    local numGroup = _G.GetNumGroupMembers() or 0
    add("group: members=" .. tostring(numGroup) .. " raid=" .. tostring(_G.IsInRaid()))
    if numGroup > 0 then
        local prefix, first, last = "party", 1, numGroup - 1
        if _G.IsInRaid() then
            prefix, first, last = "raid", 1, numGroup
        end
        for i = first, last do
            local unit = prefix .. i
            local name = _G.GetUnitName(unit, true)
            local _, class = _G.UnitClass(unit)
            local _, raceFile, raceIndex = _G.UnitRace(unit)
            local seen = name and self.Roster.seen[name]
            add(string.format("  %s: %s lvl %s %s %s(%s) %s -> %s", unit, tostring(name),
                    tostring(_G.UnitLevel(unit)), tostring(class), tostring(raceFile), tostring(raceIndex),
                    tostring(_G.UnitFactionGroup(unit)),
                    seen and ("forwarded lvl " .. seen.level .. " race " .. tostring(seen.raceIndex)) or "not forwarded"))
        end
    end

    return lines
end

-- click into the box, Ctrl+A / Ctrl+C to copy
function WoWForeverRace:ShowDevStatus()
    local AceGUI = LibStub("AceGUI-3.0")

    if self.statusDevFrame then
        self.statusDevFrame:Hide()
        self.statusDevFrame:Release()
    end

    local _self = self

    local frame = AceGUI:Create("Window")
    frame:SetTitle(self.Config.Name .. " Status")
    frame:SetWidth(720)
    frame:SetHeight(520)
    frame:SetLayout("Flow")
    frame:SetCallback("OnClose", function(widget)
        widget:Release()
        _self.statusDevFrame = nil
        _self.statusDevBox = nil
    end)
    self.statusDevFrame = frame

    local refreshBtn = AceGUI:Create("Button")
    refreshBtn:SetText("Refresh")
    refreshBtn:SetWidth(150)
    refreshBtn:SetCallback("OnClick", function() _self:RenderDevStatus() end)
    frame:AddChild(refreshBtn)

    local box = AceGUI:Create("MultiLineEditBox")
    box:SetLabel("")
    box:DisableButton(true)
    box:SetFullWidth(true)
    box:SetFullHeight(true)
    frame:AddChild(box)
    self.statusDevBox = box

    self:RenderDevStatus()
end

function WoWForeverRace:RenderDevStatus()
    if not self.statusDevBox then return end
    self.statusDevBox:SetText(table.concat(self:BuildDevStatus(), "\n"))
end

--[[
API probe: evaluates a list of expressions against the live client and shows what came
back in a copyable window. Answers "what does this API return here" without a /dump per call.
--]]
local PROBE_PREFIX = "WFRProbe"

-- expressions, evaluated as `return <expr>`; a failing one reports its error
local PROBES = {
    { "Build", {
        'GetBuildInfo()', 'WOW_PROJECT_ID', 'GetLocale()', 'GetCurrentRegion()', 'GetCurrentRegionName()',
        'GetClassicExpansionLevel()', 'GetMaxPlayerLevel()', 'GetMaxLevelForPlayerExpansion()',
    } },
    { "Player identity", {
        'UnitName("player")', 'UnitFullName("player")', 'UnitNameUnmodified("player")',
        'GetUnitName("player", true)', 'UnitGUID("player")', 'GetPlayerInfoByGUID(UnitGUID("player"))',
        'UnitClass("player")', 'UnitRace("player")', 'UnitFactionGroup("player")', 'UnitLevel("player")',
        'GetRealmName()', 'GetNormalizedRealmName()', 'GetRealmID()', 'RegionalUniqueNamesEnabled()',
        'Constants.CharacterNameSeparatorConsts',
        'Ambiguate(UnitName("player") .. "-" .. GetNormalizedRealmName(), "none")',
        'Ambiguate(UnitName("player") .. "-" .. GetNormalizedRealmName(), "short")',
        'Ambiguate(UnitName("player") .. "-" .. GetNormalizedRealmName(), "guild")',
        'UnitXP("player")', 'UnitXPMax("player")', 'GetXPExhaustion()',
    } },
    { "Addon view", {
        'WoWForeverRace.Config.Version', 'WoWForeverRace.Core:Me()', 'WoWForeverRace.Core:MyRealm()',
        'WoWForeverRace.Core:FullRealMe()', 'WoWForeverRace.DB.keys',
    } },
    { "Who list (do a /who first)", {
        'C_FriendList.GetNumWhoResults()', 'C_FriendList.GetWhoInfo(1)', 'C_FriendList.GetWhoInfo(2)',
        'C_FriendList.GetWhoInfo(3)', 'LFGWhoListFrame ~= nil', 'WhoFrame ~= nil', 'FriendsFrame ~= nil',
        'C_AddOns.IsAddOnLoaded("Blizzard_GroupFinder_VanillaStyle")',
    } },
    { "Target (target another player first)", {
        'UnitName("target")', 'UnitFullName("target")', 'GetUnitName("target", true)', 'UnitGUID("target")',
        'GetPlayerInfoByGUID(UnitGUID("target"))',
    } },
    { "Guild", {
        'C_GameRules.IsGameRuleActive(Enum.GameRule.GuildsDisabled)', 'IsInGuild()', 'GetGuildInfo("player")',
        'GetNumGuildMembers()', 'GetGuildRosterInfo(1)', 'GetGuildRosterInfo(2)',
        'GetPlayerInfoByGUID(select(17, GetGuildRosterInfo(1)))',
    } },
    { "Group", {
        'IsInGroup()', 'IsInRaid()', 'IsInGroup(LE_PARTY_CATEGORY_INSTANCE)', 'GetNumGroupMembers()',
        'UnitName("party1")', 'UnitFullName("party1")', 'GetRaidRosterInfo(1)',
    } },
    { "Friends", {
        'C_FriendList.GetNumFriends()', 'C_FriendList.GetFriendInfoByIndex(1)',
    } },
    { "Chat", {
        'C_ChatInfo.InChatMessagingLockdown()', 'C_ChatInfo.IsAddonMessagePrefixRegistered("TCRace")',
        'GetChannelList()',
    } },
}

-- namespaces whose function names are listed (what /api would show)
local PROBE_NAMESPACES = { "C_FriendList", "C_ChatInfo", "C_GameRules", "C_GuildInfo", "C_PlayerInfo" }

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function serialize(value, depth)
    if type(value) == "string" then
        return string.format("%q", value)
    elseif type(value) ~= "table" then
        return tostring(value)
    elseif (depth or 0) >= 3 then
        return "{...}"
    end

    local parts = {}
    for _, k in ipairs(sortedKeys(value)) do
        parts[#parts + 1] = tostring(k) .. "=" .. serialize(value[k], (depth or 0) + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function serializeResults(ok, ...)
    if not ok then
        return "ERROR " .. tostring((...))
    end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = serialize((select(i, ...)))
    end
    return #parts > 0 and table.concat(parts, ", ") or "(nothing)"
end

local function evaluate(expr)
    local fn, err = _G.loadstring("return " .. expr)
    if not fn then
        return "ERROR " .. tostring(err)
    end
    return serializeResults(pcall(fn))
end

function WoWForeverRace:BuildApiProbe()
    local lines = {}

    for _, section in ipairs(PROBES) do
        lines[#lines + 1] = "== " .. section[1]
        for _, expr in ipairs(section[2]) do
            lines[#lines + 1] = expr .. " -> " .. evaluate(expr)
        end
        lines[#lines + 1] = ""
    end

    lines[#lines + 1] = "== Saved factionrealm keys"
    for _, key in ipairs(sortedKeys(self.DB.sv.factionrealm or {})) do
        lines[#lines + 1] = serialize(key)
    end
    lines[#lines + 1] = ""

    lines[#lines + 1] = "== Active game rules"
    local gameRules, rules = _G.C_GameRules, _G.Enum and _G.Enum.GameRule
    if gameRules and rules then
        for _, name in ipairs(sortedKeys(rules)) do
            local ok, active = pcall(gameRules.IsGameRuleActive, rules[name])
            if not ok or active then
                lines[#lines + 1] = name .. "=" .. tostring(rules[name]) .. " -> " .. tostring(active)
                        .. ", float " .. serializeResults(pcall(gameRules.GetGameRuleAsFloat, rules[name]))
            end
        end
    else
        lines[#lines + 1] = "(missing)"
    end
    lines[#lines + 1] = ""

    for _, namespace in ipairs(PROBE_NAMESPACES) do
        lines[#lines + 1] = "== " .. namespace
        local names = type(_G[namespace]) == "table" and sortedKeys(_G[namespace]) or {"(missing)"}
        lines[#lines + 1] = table.concat(names, " ")
        lines[#lines + 1] = ""
    end

    return lines
end

-- Sends the probe prefix to ourselves in every form a name could take, the
-- CHAT_MSG_ADDON echoes show which forms deliver and what `sender` looks like (the
-- distributions themselves are /wfr chprobe's job).
function WoWForeverRace:SendApiProbeEcho()
    local chatInfo = _G.C_ChatInfo
    local echo = { "== Addon message echo (event args: prefix, text, channel, sender, target, ...)" }
    self.probeEcho = echo

    if chatInfo.InChatMessagingLockdown and chatInfo.InChatMessagingLockdown() then
        echo[#echo + 1] = "skipped, chat messaging lockdown"
        return
    end

    if not self.probeEventFrame then
        local _self = self
        chatInfo.RegisterAddonMessagePrefix(PROBE_PREFIX)
        self.probeEventFrame = CreateFrame("Frame")
        self.probeEventFrame:RegisterEvent("CHAT_MSG_ADDON")
        self.probeEventFrame:SetScript("OnEvent", function(_, _, prefix, ...)
            if prefix == PROBE_PREFIX then
                _self.probeEcho[#_self.probeEcho + 1] = "received: " .. serializeResults(true, prefix, ...)
                _self:RenderApiProbe()
            end
        end)
    end

    local name, realm = _G.UnitName("player"), _G.GetNormalizedRealmName()
    local sends = {
        { "WHISPER", name },
        { "WHISPER", (name:gsub(" ", "-")) },
        { "WHISPER", name .. "-" .. tostring(realm) },
    }
    if _G.IsInGuild() then sends[#sends + 1] = { "GUILD" } end
    if _G.IsInGroup() then sends[#sends + 1] = { _G.IsInRaid() and "RAID" or "PARTY" } end

    for i, send in ipairs(sends) do
        local text = i .. ":" .. send[1] .. ":" .. tostring(send[2])
        echo[#echo + 1] = "sent " .. serialize(text) .. " -> "
                .. serializeResults(pcall(chatInfo.SendAddonMessage, PROBE_PREFIX, text, send[1], send[2]))
    end
end

function WoWForeverRace:RenderApiProbe()
    if not self.probeBox then return end
    self.probeBox:SetText(table.concat(self.probeEcho, "\n") .. "\n\n" .. table.concat(self.probeLines, "\n"))
end

-- click into the box, Ctrl+A / Ctrl+C to copy
function WoWForeverRace:ShowApiProbe()
    local AceGUI = LibStub("AceGUI-3.0")

    if self.probeFrame then
        self.probeFrame:Hide()
        self.probeFrame:Release()
    end

    local _self = self

    local frame = AceGUI:Create("Window")
    frame:SetTitle(self.Config.Name .. " API Probe")
    frame:SetWidth(720)
    frame:SetHeight(520)
    frame:SetLayout("Flow")
    frame:SetCallback("OnClose", function(widget)
        widget:Release()
        _self.probeFrame = nil
        _self.probeBox = nil
    end)
    self.probeFrame = frame

    local rerunBtn = AceGUI:Create("Button")
    rerunBtn:SetText("Run again")
    rerunBtn:SetWidth(150)
    rerunBtn:SetCallback("OnClick", function() _self:RunApiProbe() end)
    frame:AddChild(rerunBtn)

    local box = AceGUI:Create("MultiLineEditBox")
    box:SetLabel("")
    box:DisableButton(true)
    box:SetFullWidth(true)
    box:SetFullHeight(true)
    frame:AddChild(box)
    self.probeBox = box

    self:RunApiProbe()
end

function WoWForeverRace:RunApiProbe()
    self.probeLines = self:BuildApiProbe()
    self:SendApiProbeEcho()
    self:RenderApiProbe()
end

--[[
Distribution probe: sends one addon message on every chat distribution the client knows
(SAY, YELL, PARTY, RAID, GUILD, OFFICER, WHISPER to self in both name forms, CHANNEL
for our realm channel and for every other channel we are in) and reports, per
distribution, what SendAddonMessage answered, whether the message came back through
CHAT_MSG_ADDON (the sender hears its own message on a distribution that carries it), and
any channel notice or system message the server sent meanwhile (a channel that refuses
addon messages answers "success" and sends a NOT_ALLOWED_IN_CHANNEL notice instead).

The "yell" mode sends only SAY and YELL, through SendAddonMessage and SendAddonMessageLogged,
and sends them right away instead of from timers: the slash command (or the button click)
is a hardware event, and plain SAY / YELL chat from addons needs one on modern clients.
--]]
local CHPROBE_PREFIX = "WFRChProbe"
local CHPROBE_SPACING = 0.5   -- seconds between sends: packets handed over in one frame get lost
local CHPROBE_WAIT = 20       -- seconds to wait for echoes after the last send (channel echoes come late)

-- Enum.SendAddonMessageResult value -> "value (Name)", for a readable client answer
local function resultName(result)
    local enum = _G.Enum and _G.Enum.SendAddonMessageResult
    if type(enum) == "table" then
        for name, value in pairs(enum) do
            if value == result then
                return tostring(result) .. " (" .. name .. ")"
            end
        end
    end
    return tostring(result)
end

-- The distributions to try, in the order they are sent: {distribution, target, label}.
-- The channel numbers are read now, the probe starts right after.
function WoWForeverRace:ChannelProbeSends()
    -- UnitName("player") returns only the first name on this client, the addon's own
    -- forms ("First Surname", "First Surname-Realm") are what it whispers buddies with
    local sends = {
        { "SAY" }, { "YELL" }, { "PARTY" }, { "RAID" }, { "GUILD" }, { "OFFICER" },
        { "WHISPER", self.Core:RealMe(), "self" },
        { "WHISPER", self.Core:FullRealMe(), "self with realm" },
    }

    local race = self.Channel:Number()
    if race then
        sends[#sends + 1] = { "CHANNEL", race, self.Channel:Name() }
    else
        sends[#sends + 1] = { "CHANNEL", nil, self.Channel:Name() .. " (not joined)" }
    end

    -- every other channel we are in: GetChannelList() returns id, name, disabled per channel
    local list = { _G.GetChannelList() }
    for i = 1, #list, 3 do
        local id, channelName = list[i], list[i + 1]
        if type(id) == "number" and id ~= race then
            sends[#sends + 1] = { "CHANNEL", id, tostring(channelName) }
        end
    end
    return sends
end

-- SAY and YELL through both send calls: {distribution, target, label, logged}
function WoWForeverRace:YellProbeSends()
    local sends = {}
    for _, distribution in ipairs({ "SAY", "YELL" }) do
        sends[#sends + 1] = { distribution, nil, "SendAddonMessage", false }
        sends[#sends + 1] = { distribution, nil, "SendAddonMessageLogged", true }
    end
    return sends
end

-- mode: "all" sends every distribution from timers, "yell" sends SAY and YELL right now
-- (keep the call inside the hardware event: no timer between the command and the send)
function WoWForeverRace:RunChannelProbe(mode)
    local chatInfo = _G.C_ChatInfo
    local probe = { sends = {}, notices = {}, done = false, mode = mode or "all" }
    self.chprobe = probe

    if chatInfo.InChatMessagingLockdown and chatInfo.InChatMessagingLockdown() then
        probe.error = "skipped, chat messaging lockdown"
        probe.done = true
        self:RenderChannelProbe()
        return
    end

    if not self.chprobeEventFrame then
        local _self = self
        chatInfo.RegisterAddonMessagePrefix(CHPROBE_PREFIX)
        local frame = CreateFrame("Frame")
        frame:RegisterEvent("CHAT_MSG_ADDON")
        frame:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
        frame:RegisterEvent("CHAT_MSG_SYSTEM")
        frame:RegisterEvent("UI_ERROR_MESSAGE")
        frame:SetScript("OnEvent", function(_, event, ...)
            local current = _self.chprobe
            -- echoes keep being recorded after the wait, marked as late
            if not current or current.error then return end
            if event == "CHAT_MSG_ADDON" then
                local prefix, text, distribution, sender = ...
                if prefix ~= CHPROBE_PREFIX then return end
                local index = tonumber(string.match(tostring(text), "^(%d+):"))
                local send = index and current.sends[index]
                if send and send.sentAt then
                    send.echoes[#send.echoes + 1] = "heard on " .. tostring(distribution)
                            .. " from " .. tostring(sender)
                            .. string.format(" at +%.1fs", _G.GetTime() - send.sentAt)
                            .. (current.done and " (LATE, after the wait)" or "")
                else
                    current.notices[#current.notices + 1] = "stray echo: " .. serializeResults(true, prefix, ...)
                end
            else
                current.notices[#current.notices + 1] = event .. ": " .. serializeResults(true, ...)
            end
            _self:RenderChannelProbe()
        end)
        self.chprobeEventFrame = frame
    end

    local immediate = probe.mode == "yell"
    local sends = immediate and self:YellProbeSends() or self:ChannelProbeSends()
    local _self = self
    local function sendOne(i, send, entry)
        local text = i .. ":" .. send[1] .. ":" .. tostring(send[3] or send[2] or "")
        entry.sentAt = _G.GetTime()
        local call = send[4] and chatInfo.SendAddonMessageLogged or chatInfo.SendAddonMessage
        if send[1] == "CHANNEL" and send[2] == nil then
            entry.result = "not sent, no channel number"
        elseif call == nil then
            entry.result = "not sent, the client has no " .. tostring(send[3])
        else
            entry.result = serializeResults(pcall(call, CHPROBE_PREFIX, text, send[1], send[2]))
            local result = tonumber(entry.result)
            if result then
                entry.result = resultName(result)
            end
        end
        _self:RenderChannelProbe()
    end

    for i, send in ipairs(sends) do
        local entry = { distribution = send[1], target = send[2], label = send[3], echoes = {} }
        probe.sends[i] = entry
        if immediate then
            sendOne(i, send, entry)
        else
            _G.C_Timer.After((i - 1) * CHPROBE_SPACING, function()
                if _self.chprobe ~= probe then return end
                sendOne(i, send, entry)
            end)
        end
    end

    local spacing = immediate and 0 or CHPROBE_SPACING
    _G.C_Timer.After(#sends * spacing + CHPROBE_WAIT, function()
        if _self.chprobe ~= probe then return end
        probe.done = true
        _self:RenderChannelProbe()
    end)
end

function WoWForeverRace:BuildChannelProbe()
    local probe = self.chprobe
    local lines = {}
    local function add(line) lines[#lines + 1] = line end

    add("== Addon message distributions, " .. (probe.mode == "yell" and "SAY / YELL from a hardware event"
            or "every distribution from timers") .. " (" .. (probe.done and "finished, still listening for late echoes"
            or "running...") .. ")")
    add("prefix " .. CHPROBE_PREFIX .. ", me " .. tostring(self.Core:FullRealMe())
            .. ", in group " .. tostring(_G.IsInGroup()) .. ", in raid " .. tostring(_G.IsInRaid())
            .. ", in guild " .. tostring(_G.IsInGuild())
            .. ", realm channel " .. self.Channel:Name() .. " number " .. tostring(self.Channel:Number()))
    if probe.error then
        add(probe.error)
    end
    add("")
    add(string.format("%-28s %-30s %s", "distribution", "client answer", "echo"))
    for _, send in ipairs(probe.sends) do
        local what = send.distribution
        if send.target ~= nil then
            what = what .. " " .. tostring(send.target)
        end
        if send.label then
            what = what .. " [" .. send.label .. "]"
        end
        local echo
        if #send.echoes > 0 then
            echo = table.concat(send.echoes, "; ")
        elseif send.sentAt == nil then
            echo = "-"
        elseif probe.done then
            echo = "NO ECHO within " .. CHPROBE_WAIT .. "s"
        else
            echo = "waiting"
        end
        add(string.format("%-28s %-30s %s", what, tostring(send.result or "not sent yet"), echo))
    end
    add("")
    add("== Notices and system messages while the probe ran")
    if #probe.notices == 0 then
        add("(none)")
    end
    for _, notice in ipairs(probe.notices) do
        add(notice)
    end
    add("")
    add("A distribution carries addon messages when the client answered 0 (Success) AND the message echoed back.")
    add("Success without an echo (often with a NOT_ALLOWED_IN_CHANNEL notice) means the server dropped it.")
    add("PARTY / RAID / GUILD / OFFICER only mean something while you are in one.")
    return lines
end

function WoWForeverRace:RenderChannelProbe()
    if not self.chprobeBox or not self.chprobe then return end
    self.chprobeBox:SetText(table.concat(self:BuildChannelProbe(), "\n"))
end

-- click into the box, Ctrl+A / Ctrl+C to copy
function WoWForeverRace:ShowChannelProbe(mode)
    local AceGUI = LibStub("AceGUI-3.0")

    if self.chprobeFrame then
        self.chprobeFrame:Hide()
        self.chprobeFrame:Release()
    end

    local _self = self

    local frame = AceGUI:Create("Window")
    frame:SetTitle(self.Config.Name .. " Distribution Probe")
    frame:SetWidth(900)
    frame:SetHeight(520)
    frame:SetLayout("Flow")
    frame:SetCallback("OnClose", function(widget)
        widget:Release()
        _self.chprobeFrame = nil
        _self.chprobeBox = nil
    end)
    self.chprobeFrame = frame

    local rerunBtn = AceGUI:Create("Button")
    rerunBtn:SetText("Run again")
    rerunBtn:SetWidth(150)
    -- a click is a hardware event too, so "Run again" works for the yell mode
    rerunBtn:SetCallback("OnClick", function() _self:RunChannelProbe(mode) end)
    frame:AddChild(rerunBtn)

    local box = AceGUI:Create("MultiLineEditBox")
    box:SetLabel("")
    box:DisableButton(true)
    box:SetFullWidth(true)
    box:SetFullHeight(true)
    frame:AddChild(box)
    self.chprobeBox = box

    self:RunChannelProbe(mode)
end
