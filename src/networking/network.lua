-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- WoW API
local IsInRaid, IsInGroup, GetNumGroupMembers = _G.IsInRaid, _G.IsInGroup, _G.GetNumGroupMembers
local LE_PARTY_CATEGORY_INSTANCE = _G.LE_PARTY_CATEGORY_INSTANCE
local C_ChatInfo, C_Timer, math = _G.C_ChatInfo, _G.C_Timer, _G.math

local OUTBOX_MAX = 100          -- messages held back during a chat messaging lockdown
local OUTBOX_RETRY_INTERVAL = 5 -- seconds between checks whether the lockdown has ended

-- Libs
local LibStub = _G.LibStub
local Serializer = LibStub:GetLibrary("AceSerializer-3.0")
local AceComm = LibStub:GetLibrary("AceComm-3.0")
local LibCompress = LibStub:GetLibrary("LibCompress")
local EncodeTable = LibCompress:GetAddonEncodeTable()

-- AceComm's packet framing: a message of up to 255 bytes is one chat packet (escaped when
-- it starts with a control byte), a longer one travels in parts marked first, next, last
local MSG_MULTI_FIRST, MSG_MULTI_NEXT, MSG_MULTI_LAST, MSG_ESCAPE = "\001", "\002", "\003", "\004"
local PACKET_BYTES = 255

-- The chat packets AceComm:SendCommMessage makes of a message, which every client's
-- AceComm puts together again.
local function splitPackets(text)
    local length = #text
    local control = string.find(text, "^[\001-\009]") ~= nil
    if length <= PACKET_BYTES and not (control and length + 1 > PACKET_BYTES) then
        return {control and MSG_ESCAPE .. text or text}
    end

    local size = PACKET_BYTES - 1
    local packets = {MSG_MULTI_FIRST .. string.sub(text, 1, size)}
    local pos = 1 + size
    while pos + size <= length do
        packets[#packets + 1] = MSG_MULTI_NEXT .. string.sub(text, pos, pos + size - 1)
        pos = pos + size
    end
    packets[#packets + 1] = MSG_MULTI_LAST .. string.sub(text, pos)
    return packets
end

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
        local batchstr, isDiscoveryAnswer, boardIndex = payload[1], payload[2], payload[3]
        local players = WoWForeverRace.Serializer.DeserializePlayerInfoBatch(batchstr)
        WoWForeverRace:DebugPrint("  discovery=" .. tostring(isDiscoveryAnswer) ..
                " board=" .. tostring(boardIndex or 0) .. " count=" .. #players)
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
---@field Channel WoWForeverRaceChannel
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
---@param Channel WoWForeverRaceChannel optional, without it there is no "RACE" distribution
function WoWForeverRaceNetwork.new(Core, EventBus, Channel)
    local self = setmetatable({}, WoWForeverRaceNetwork)

    self.Core = Core
    self.EventBus = EventBus
    self.Channel = Channel

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
    local prefix, message, distribution, sender = ...

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

        -- A message that doesn't decode lost one of its packets on the way (AceComm puts
        -- together whatever arrives). Its sender still holds what it tried to send us:
        -- Sync asks for it again.
        local decoded = EncodeTable:Decode(message)
        local decompressed, decomprErr = LibCompress:Decompress(decoded)
        if not decompressed then
            WoWForeverRace:DebugPrint("Decompress error: " .. tostring(decomprErr))
            self.EventBus:PublishEvent(WoWForeverRace.Config.Events.MessageGarbled, sender, distribution)
            return
        end

        local ok2, object = Serializer:Deserialize(decompressed)
        if not ok2 then
            WoWForeverRace:DebugPrint("Deserialize error: " .. tostring(object))
            self.EventBus:PublishEvent(WoWForeverRace.Config.Events.MessageGarbled, sender, distribution)
            return
        end

        local event, payload, faction, channelIndex = object[1], object[2], object[3], object[4]

        -- Local EventBus events are not part of the addon-wire protocol. Without
        -- this guard, another addon client could invoke local state transitions.
        if type(event) ~= "string" or not NetworkEvents[event] then
            WoWForeverRace:DebugPrint("Ignored unknown network event: " .. tostring(event))
            return
        end

        -- The race is per faction and nothing else on the wire tells the factions
        -- apart, so only messages tagged with our own faction are accepted. An
        -- untagged message comes from an older client, whose faction is unknown.
        if type(faction) ~= "string" or faction ~= self.Core:MyFaction() then
            WoWForeverRace:DebugPrint("Ignored " .. event .. " from another or unknown faction: " .. tostring(faction))
            return
        end

        WoWForeverRace:TracePrint("Received Network Event: " .. event .. " From: " .. sender)
        -- with the path it took: a log then shows whether a player is on the realm channel
        WoWForeverRace:DebugPrint("Recv " .. event .. " <- " .. sender .. " (" .. tostring(distribution) .. ")")
        debugLogPayload(event, payload)

        self:TrackMessage("recv", event)
        if self.Channel ~= nil then
            -- a player of our faction on a chat channel: the realm channel carries traffic
            if distribution == "CHANNEL" then
                self.Channel:NoteSender(senderName)
                self.EventBus:PublishEvent(WoWForeverRace.Config.Events.ChannelHeard, sender)
            end
            self:FollowChannel(channelIndex, distribution)
        end
        self.EventBus:PublishEvent(event, payload, sender, distribution)
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

-- Resolves the virtual "RACE" channel to the number of the realm channel (see
-- Channel) as the "CHANNEL" target, or nil when we are not in it.
function WoWForeverRaceNetwork:ResolveRaceChannel()
    if self.Channel == nil or not self.Channel:IsJoined() then
        return nil
    end
    return tostring(self.Channel:Number())
end

-- The number of the realm channel we use, when it is not the first: the fourth element
-- of every envelope, see FollowChannel. nil on the first channel name, so the envelope
-- only grows once a channel was given up.
function WoWForeverRaceNetwork:ChannelIndexTag()
    local index = self.Channel ~= nil and self.Channel:Index() or 1
    return index > 1 and index or nil
end

-- Every message tells which realm channel its sender uses, and the highest number wins:
-- a higher one than ours means our channel asked somebody for a password (see Channel),
-- so we move as well. That is how the players who were in a channel before it got its
-- password, and the ones who land on an old name after the password is gone, end up
-- with everybody else.
function WoWForeverRaceNetwork:FollowChannel(index, distribution)
    local channel = self.Channel
    if not channel:CanMoveTo(index) then return end

    if distribution == "CHANNEL" or not channel:IsJoined() then
        -- everybody on our channel heard it too, or we are on none
        channel:MoveTo(index)
        return
    end

    -- Heard outside our channel: the players on it don't know yet. We tell them before
    -- we leave, after a random delay so that not everybody who heard it does.
    if self.pendingChannelIndex == nil then
        local _self = self
        C_Timer.After(math.random() * WoWForeverRace.Config.ChannelMoveDelay, function()
            _self:AnnounceChannelMove()
        end)
    end
    if self.pendingChannelIndex == nil or index > self.pendingChannelIndex then
        self.pendingChannelIndex = index
    end
end

function WoWForeverRaceNetwork:AnnounceChannelMove()
    local index = self.pendingChannelIndex
    self.pendingChannelIndex = nil

    -- somebody else told the channel meanwhile, and we moved with it
    if not self.Channel:CanMoveTo(index) then return end

    local target = self:ResolveRaceChannel()
    self.Channel:MoveTo(index)
    if target ~= nil then
        -- to the channel we leave; the envelope carries the new number
        self:SendObject(WoWForeverRace.Config.Network.Events.ChannelMove, index, "CHANNEL", target)
    end
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

-- ChatThrottleLib drops a packet the client refuses for any reason but its addon message
-- throttle, and goes on with the next one: the receiver gets nothing, or a long message
-- with a hole in it. So the whole message goes out again a little later, a few times.
function WoWForeverRaceNetwork:RetrySend(event, object, channel, target, prio, attempt)
    if attempt >= WoWForeverRace.Config.SendRetryMax then
        WoWForeverRace:DebugPrint("Send failed: " .. event .. " -> " .. tostring(channel) .. ", giving up")
        return
    end
    WoWForeverRace:DebugPrint("Send failed: " .. event .. " -> " .. tostring(channel) .. ", sending it again")
    local _self = self
    C_Timer.After(WoWForeverRace.Config.SendRetryDelay, function()
        _self:SendObject(event, object, channel, target, prio, attempt + 1)
    end)
end

-- attempt: set by RetrySend, the number of times this message was sent before
function WoWForeverRaceNetwork:SendObject(event, object, channel, target, prio, attempt)
    if prio == nil then
        prio = "BULK"
    end
    -- as the caller passed them: a retry resolves the group and the realm channel again
    local toChannel, toTarget = channel, target

    -- Modern clients (WoW Forever) reject addon messages while the chat messaging
    -- lockdown is active (it covers whole dungeons and raids); hold them back
    -- with their original arguments and send once the lockdown has ended.
    if self:IsLockedDown() then
        self:HoldMessage(event, object, channel, target, prio)
        return
    end

    -- resolve the channel first so nothing is serialized, logged or counted
    -- for a group or realm channel message that has nowhere to go
    if channel == "GROUP" then
        channel = self:ResolveGroupChannel()
        if channel == nil then
            WoWForeverRace:DebugPrint("Dropped " .. event .. " -> GROUP (not grouped)")
            return
        end
        target = nil
    elseif channel == "RACE" then
        target = self:ResolveRaceChannel()
        if target == nil then
            WoWForeverRace:DebugPrint("Dropped " .. event .. " -> RACE (not in the realm channel)")
            return
        end
        channel = "CHANNEL"
    end

    -- the third element locks the data to our faction, see HandleAddonMessage;
    -- older clients only read the first two. The fourth is our realm channel number
    local payload = Serializer:Serialize({event, object, self.Core:MyFaction(), self:ChannelIndexTag()})
    local compressed = LibCompress:CompressHuffman(payload)
    local encoded = EncodeTable:Encode(compressed)

    WoWForeverRace:TracePrint("Send Network Event: " .. event .. " Channel: " .. channel ..
            " Size: " .. string.len(encoded) .. " / " .. string.len(payload))
    WoWForeverRace:DebugPrint("Send " .. event .. " -> " .. channel)
    debugLogPayload(event, object)
    self:TrackMessage("send", event)

    local _self = self
    self:Transmit(encoded, channel, target, prio, function(refused)
        if refused then
            _self:RetrySend(event, object, toChannel, toTarget, prio, attempt or 0)
        end
    end)
end

-- Hands an encoded message to the client, one chat packet per Config.PacketInterval.
-- ChatThrottleLib sends whatever its allowance covers right away, so the packets of a
-- long message, or of several messages, used to reach the client in the same frame, and
-- packets sent together don't reliably arrive: some are lost, some out of order, and
-- AceComm then puts a message together wrong or not at all. One packet at a time arrives.
-- onDone(refused): called when the last packet was handed over, or one was refused.
function WoWForeverRaceNetwork:Transmit(text, channel, target, prio, onDone)
    local interval = WoWForeverRace.Config.PacketInterval
    if interval == nil or interval <= 0 then
        -- unpaced, AceComm splits and sends: once per packet it reports the bytes handed
        -- over so far and whether the client took that packet (nil when it doesn't tell)
        local refused = false
        AceComm:SendCommMessage(WoWForeverRace.Config.Network.Prefix, text, channel, target, prio,
                function(_, sent, total, didSend)
                    if didSend == false then
                        refused = true
                    end
                    if sent >= total then
                        onDone(refused)
                    end
                end)
        return
    end

    self.sendQueue = self.sendQueue or {}
    table.insert(self.sendQueue, {packets = splitPackets(text), sent = 0, channel = channel,
                                  target = target, prio = prio, onDone = onDone})
    self:PumpPackets()
end

-- Sends the next packet of the message at the head of the queue, unless one is under way.
function WoWForeverRaceNetwork:PumpPackets()
    if self.pumpBusy then return end
    local message = self.sendQueue[1]
    if message == nil then return end

    self.pumpBusy = true
    local _self = self
    -- ChatThrottleLib calls back when the packet went to the client, right away or after
    -- its own queue, with whether the client took it
    _G.ChatThrottleLib:SendAddonMessage(message.prio, WoWForeverRace.Config.Network.Prefix,
            message.packets[message.sent + 1], message.channel, message.target, nil,
            function(_, didSend)
                _self:OnPacketSent(message, didSend)
            end)
end

function WoWForeverRaceNetwork:OnPacketSent(message, didSend)
    message.sent = message.sent + 1
    local refused = didSend == false
    -- the rest of a message with a hole in it is of no use to anybody
    if refused or message.sent >= #message.packets then
        table.remove(self.sendQueue, 1)
        message.onDone(refused)
    end

    local _self = self
    C_Timer.After(WoWForeverRace.Config.PacketInterval, function()
        _self.pumpBusy = false
        _self:PumpPackets()
    end)
end
