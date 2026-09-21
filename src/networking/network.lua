-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- WoW API
local IsInRaid, IsInGroup, GetNumGroupMembers = _G.IsInRaid, _G.IsInGroup, _G.GetNumGroupMembers
local LE_PARTY_CATEGORY_INSTANCE = _G.LE_PARTY_CATEGORY_INSTANCE
local C_ChatInfo, C_Timer = _G.C_ChatInfo, _G.C_Timer

local OUTBOX_MAX = 100          -- messages held back during a chat messaging lockdown
local OUTBOX_RETRY_INTERVAL = 5 -- seconds between checks whether the lockdown has ended

-- Libs
local LibStub = _G.LibStub
local Serializer = LibStub:GetLibrary("AceSerializer-3.0")
local AceComm = LibStub:GetLibrary("AceComm-3.0")
local LibCompress = LibStub:GetLibrary("LibCompress")
local EncodeTable = LibCompress:GetAddonEncodeTable()

local NetworkEvents = {}
for _, event in pairs(WoWForeverRace.Config.Network.Events) do
    NetworkEvents[event] = true
end

local function debugLogPayload(event, payload)
    -- runs on every message before the consumers do, so it must neither cost
    -- anything when debug is off nor throw on a malformed payload
    if not (WoWForeverRace.DB and WoWForeverRace.DB.profile.options.debug) then return end
    if event == WoWForeverRace.Config.Network.Events.PlayerInfoBatch then
        if type(payload) ~= "table" then
            WoWForeverRace:DebugPrint("  malformed payload: " .. tostring(payload))
            return
        end
        local batchstr, isRebroadcast, classIndex = payload[1], payload[2], payload[3]
        local players = WoWForeverRace.Serializer.DeserializePlayerInfoBatch(batchstr)
        WoWForeverRace:DebugPrint("  rebroadcast=" .. tostring(isRebroadcast) ..
                " class=" .. tostring(classIndex or 0) .. " count=" .. #players)
        for _, p in ipairs(players) do
            WoWForeverRace:DebugPrint("  " .. p.name .. " lvl" .. p.level .. " [" .. tostring(p.classIndex) .. "]")
        end
    elseif type(payload) == "table" then
        WoWForeverRace:DebugPrintTable(payload)
    else
        WoWForeverRace:DebugPrint("  payload: " .. tostring(payload))
    end
end

--[[
WoWForeverRaceNetwork uses AceComm to send and receive messages over Addon channels
and broadcast them as events once received fully over our EventBus.
--]]
---@class WoWForeverRaceNetwork
---@field Core WoWForeverRaceCore
---@field EventBus WoWForeverRaceEventBus
local WoWForeverRaceNetwork = {}
WoWForeverRaceNetwork.__index = WoWForeverRaceNetwork
WoWForeverRace.Network = WoWForeverRaceNetwork

setmetatable(WoWForeverRaceNetwork, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

---@param Core WoWForeverRaceCore
---@param EventBus WoWForeverRaceEventBus
function WoWForeverRaceNetwork.new(Core, EventBus)
    local self = setmetatable({}, WoWForeverRaceNetwork)

    self.Core = Core
    self.EventBus = EventBus

    AceComm:RegisterComm(WoWForeverRace.Config.Network.Prefix, function(...)
        self:HandleAddonMessage(...)
    end)

    return self
end

function WoWForeverRaceNetwork:Init()
    self.EventBus:PublishEvent(WoWForeverRace.Config.Events.NetworkReady)
end

function WoWForeverRaceNetwork:TrackMessage(direction, event)
    if not WoWForeverRace.DB or not WoWForeverRace.DB.profile.options.debug then return end
    local stats = WoWForeverRace.MsgStats
    if not stats then return end
    stats[direction][event] = (stats[direction][event] or 0) + 1
    self.EventBus:PublishEvent(WoWForeverRace.Config.Events.MsgStats)
end

function WoWForeverRaceNetwork:HandleAddonMessage(...)
    local prefix, message, _, sender = ...

    -- check if it's our prefix
    if prefix ~= WoWForeverRace.Config.Network.Prefix then
        return
    end

    WoWForeverRace:DebugPrint("Recv raw <- " .. tostring(sender))

    local ok, err = pcall(function()
        -- WoW Forever senders are "First Surname" without a realm on every channel,
        -- a "Name-Realm" form is still split off in case a cross-realm sender shows up
        local senderName, senderRealm = self.Core:SplitFullPlayer(sender)

        -- completely ignore anything from other realms
        if not self.Core:IsMyRealm(senderRealm) then
            return
        end

        -- ignore our own messages regardless of whether realm is included in sender
        if senderName == self.Core:RealMe() then
            return
        end

        local decoded = EncodeTable:Decode(message)
        local decompressed, decomprErr = LibCompress:Decompress(decoded)
        if not decompressed then
            WoWForeverRace:DebugPrint("Decompress error: " .. tostring(decomprErr))
            return
        end

        local ok2, object = Serializer:Deserialize(decompressed)
        if not ok2 then
            WoWForeverRace:DebugPrint("Deserialize error: " .. tostring(object))
            return
        end

        local event, payload = object[1], object[2]

        -- Local EventBus events are not part of the addon-wire protocol. Without
        -- this guard, another addon client could invoke local state transitions.
        if type(event) ~= "string" or not NetworkEvents[event] then
            WoWForeverRace:DebugPrint("Ignored unknown network event: " .. tostring(event))
            return
        end

        WoWForeverRace:TracePrint("Received Network Event: " .. event .. " From: " .. sender)
        WoWForeverRace:DebugPrint("Recv " .. event .. " <- " .. sender)
        debugLogPayload(event, payload)

        self:TrackMessage("recv", event)
        self.EventBus:PublishEvent(event, payload, sender)
    end)

    if not ok then
        WoWForeverRace:PPrint("Network receive error: " .. tostring(err))
    end
end

-- Resolves the virtual "GROUP" channel to the addon channel that actually
-- reaches the player's current group, or nil when not grouped.
-- PARTY/RAID addon messages are silently dropped while in an instance group
-- (dungeon finder, battleground); those must use INSTANCE_CHAT.
function WoWForeverRaceNetwork:ResolveGroupChannel()
    if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif GetNumGroupMembers() > 0 then
        return "PARTY"
    end
    return nil
end

function WoWForeverRaceNetwork:IsLockedDown()
    return C_ChatInfo ~= nil and C_ChatInfo.InChatMessagingLockdown ~= nil
            and C_ChatInfo.InChatMessagingLockdown() == true
end

-- Payload events are kept in full, every other event only matters in its latest
-- version (beacons, pings, sync negotiation), so a long lockdown can't pile them up.
local function outboxKey(event, channel, target)
    local events = WoWForeverRace.Config.Network.Events
    if event == events.PlayerInfoBatch or event == events.SyncPayload
            or event == events.FTLSync or event == events.PlayerHistorySync then
        return nil
    end
    return event .. "/" .. tostring(channel) .. "/" .. tostring(target)
end

function WoWForeverRaceNetwork:HoldMessage(event, object, channel, target, prio)
    WoWForeverRace:DebugPrint("Hold " .. event .. " -> " .. tostring(channel) .. " (chat messaging lockdown)")
    self.outbox = self.outbox or {}

    local key = outboxKey(event, channel, target)
    if key ~= nil then
        for i, held in ipairs(self.outbox) do
            if held.key == key then
                table.remove(self.outbox, i)
                break
            end
        end
    end
    table.insert(self.outbox, {key = key, args = {event, object, channel, target, prio}})
    while #self.outbox > OUTBOX_MAX do
        table.remove(self.outbox, 1)
    end

    if not self.outboxTicker then
        local _self = self
        self.outboxTicker = C_Timer.NewTicker(OUTBOX_RETRY_INTERVAL, function() _self:FlushOutbox() end)
    end
end

function WoWForeverRaceNetwork:FlushOutbox()
    if self:IsLockedDown() then return end

    if self.outboxTicker then
        self.outboxTicker:Cancel()
        self.outboxTicker = nil
    end
    local outbox = self.outbox or {}
    self.outbox = {}
    for _, held in ipairs(outbox) do
        self:SendObject(held.args[1], held.args[2], held.args[3], held.args[4], held.args[5])
    end
end

function WoWForeverRaceNetwork:SendObject(event, object, channel, target, prio)
    if prio == nil then
        prio = "BULK"
    end

    -- Modern clients (WoW Forever) reject addon messages while the chat messaging
    -- lockdown is active (it covers whole dungeons and raids); hold them back
    -- with their original arguments and send once the lockdown has ended.
    if self:IsLockedDown() then
        self:HoldMessage(event, object, channel, target, prio)
        return
    end

    -- resolve the channel first so nothing is serialized, logged or counted
    -- for a group message that has nowhere to go
    if channel == "GROUP" then
        channel = self:ResolveGroupChannel()
        if channel == nil then
            WoWForeverRace:DebugPrint("Dropped " .. event .. " -> GROUP (not grouped)")
            return
        end
        target = nil
    end

    local payload = Serializer:Serialize({event, object})
    local compressed = LibCompress:CompressHuffman(payload)
    local encoded = EncodeTable:Encode(compressed)

    WoWForeverRace:TracePrint("Send Network Event: " .. event .. " Channel: " .. channel ..
            " Size: " .. string.len(encoded) .. " / " .. string.len(payload))
    WoWForeverRace:DebugPrint("Send " .. event .. " -> " .. channel)
    debugLogPayload(event, object)
    self:TrackMessage("send", event)

    AceComm:SendCommMessage(
            WoWForeverRace.Config.Network.Prefix,
            encoded,
            channel,
            target,
            prio)
end
