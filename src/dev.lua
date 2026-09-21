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
    "/wfr status         print scanner / sync / leaderboard state",
    "/wfr scan           trigger a /who scan now (must be typed, needs a hardware event)",
    "/wfr update         re-run the login sync",
    "/wfr ding NAME LVL [CLASS] [RACEID]   fake a /who result for a player",
    "/wfr whoami NAME    pretend to be another player on this realm",
    "/wfr reset          wipe the leaderboards, pioneers and history for this faction-realm (keeps realmOpenedAt)",
    "/wfr probe          dump what the client API returns into a copyable window (do a /who first)",
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
        self:PrintDevStatus()

    --[[API PROBE]]--
    elseif action == "probe" then
        self:ShowApiProbe()

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
function WoWForeverRace:PrintDevStatus()
    local db = self.DB.factionrealm
    local scanner = self.scanner
    local sync = self.Sync

    self:PPrint("version " .. tostring(self.Config.Version) .. ", me: " .. tostring(self.Core:FullRealMe())
            .. ", expansion max level " .. tostring(self.Config.MaxLevel))
    self:PPrint("db version " .. tostring(db.dbversion) .. ", finished: " .. tostring(db.finished)
            .. ", realm opened " .. tostring(db.realmOpenedAt))

    for _, boardIndex in ipairs(self.Core:BoardIndexes()) do
        local lb = db.leaderboard[boardIndex]
        if lb and #lb.players > 0 then
            -- a leaderboard index that is no class index belongs to a race
            local label = self.Config.Classes[boardIndex] or boardIndex == 0 and self.Core:ClassByIndex(0)
                    or self.Core:RaceName(boardIndex - self.Config.RaceBoardOffset)
            self:PPrint(string.format("  board %3d (%s): %d players, min lvl %d, max lvl %d",
                    boardIndex, tostring(label), #lb.players, lb.minLevel, lb.highestLevel))
        end
    end

    self:PPrint("scanner: pending=" .. tostring(scanner.scanPending)
            .. " pendingMin=" .. tostring(scanner.pendingScanMin)
            .. " lastClass=" .. tostring(scanner.lastScanClassIndex)
            .. " nextClassSlot=" .. tostring(scanner.nextScanClassIdx)
            .. " lastScan=" .. tostring(scanner.lastScanTime))
    self:PPrint("sync: ready=" .. tostring(sync.isReady)
            .. " offers=" .. tostring(#sync.offers)
            .. " partner=" .. tostring(sync.syncPartner and sync.syncPartner.name)
            .. " lastSync=" .. tostring(sync.lastSync))

    self:PPrint("buddies: " .. WoWForeverRace.table.cnt(db.buddies)
            .. ", players with history: " .. WoWForeverRace.table.cnt(db.playerHistory))
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
-- CHAT_MSG_ADDON echoes show which forms deliver and what `sender` looks like.
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
