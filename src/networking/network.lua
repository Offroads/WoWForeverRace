-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- WoW API
local IsInRaid, IsInGroup, GetNumGroupMembers = _G.IsInRaid, _G.IsInGroup, _G.GetNumGroupMembers
local LE_PARTY_CATEGORY_INSTANCE = _G.LE_PARTY_CATEGORY_INSTANCE

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
    if event == WoWForeverRace.Config.Network.Events.PlayerInfoBatch then
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
        -- YELL gives "Name", GUILD/WHISPER give "Name-Realm" - split before comparing
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

function WoWForeverRaceNetwork:SendObject(event, object, channel, target, prio)
    if prio == nil then
        prio = "BULK"
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
