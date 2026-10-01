-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- WoW API
local CreateFrame, C_Timer, C_ChatInfo, math = _G.CreateFrame, _G.C_Timer, _G.C_ChatInfo, _G.math
local JoinTemporaryChannel, LeaveChannelByName = _G.JoinTemporaryChannel, _G.LeaveChannelByName
local GetChannelName, GetChannelList = _G.GetChannelName, _G.GetChannelList

-- status values
local IDLE = "idle"         -- not in the channel (yet): waiting to join, joining, or sharing is turned off
local JOINED = "joined"
local LEFT = "left"         -- the player left it or was kicked: not rejoined this session
local REFUSED = "refused"   -- wrong password or banned: somebody else controls the channel
local FAILED = "failed"     -- the joins tried went unanswered

--[[
Channel keeps us in the realm channel: a player-made chat channel per faction that
every addon user joins, so one addon message reaches all of them (Network sends to
it as the virtual "RACE" distribution). The server refuses addon messages on its own
channels (General, Trade, ...), a player-made one carries them.

The channel is joined from a timer with JoinTemporaryChannel: it is not saved with the
player's chat settings and not added to a chat window, so the player never sees it.
Its name is public, so anybody can take it over (password, ban) or leave it: then we
are simply not in it, and the sync flows from before the channel take over again.

It also keeps track of who was heard on the channel: that tells whether the channel
carries traffic at all (IsLive) and how many players are on it (Size).
]]--
---@class WoWForeverRaceChannel
---@field Config WoWForeverRaceConfig
---@field Core WoWForeverRaceCore
---@field DB table<string, table>
---@field EventBus WoWForeverRaceEventBus
local WoWForeverRaceChannel = {}
WoWForeverRaceChannel.__index = WoWForeverRaceChannel
WoWForeverRace.Channel = WoWForeverRaceChannel
setmetatable(WoWForeverRaceChannel, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function WoWForeverRaceChannel.new(Config, Core, DB, EventBus)
    local self = setmetatable({}, WoWForeverRaceChannel)

    self.Config = Config
    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus

    self.status = IDLE
    self.attempts = 0         -- joins tried
    self.waited = 0           -- seconds waited for the client's own channels
    self.joinScheduled = false
    self.joinedAt = nil
    self.settleAt = nil       -- from when our own dings may go to the channel, see SettleDelay
    self.senders = {}         -- [name] = when we last heard that player on the channel
    self.lastHeardAt = nil

    self.Thread = CreateFrame("Frame")
    self.Thread:Hide()
    self.Thread:SetScript("OnEvent", function(_, _, ...)
        self:OnChannelNotice(...)
    end)
    self.Thread:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")

    return self
end

-- One channel per faction: the race is per faction, and the other faction's
-- messages would be dropped anyway (see Network:HandleAddonMessage).
function WoWForeverRaceChannel:Name()
    return self.Config.RaceChannelPrefix .. tostring(self.Core:MyFaction())
end

-- The channel's number in the player's channel list, nil when we are not in it. It
-- changes when the player joins or leaves other channels, so it is looked up per send.
function WoWForeverRaceChannel:Number()
    local id = GetChannelName(self:Name())
    if type(id) == "number" and id > 0 then
        return id
    end
    return nil
end

function WoWForeverRaceChannel:Status()
    return self.status
end

-- no point in the channel when we share nothing, or when the race is over
function WoWForeverRaceChannel:Wanted()
    return self.DB.profile.options.networking == true and not self.DB.factionrealm.finished
end

function WoWForeverRaceChannel:IsJoined()
    return self.status == JOINED and self:Number() ~= nil
end

-- Whether the channel carries traffic: we are in it and heard another player on it
-- lately (see NoteSender). Only then does it replace the other sync flows; an empty
-- or broken channel leaves them running.
function WoWForeverRaceChannel:IsLive()
    return self:IsJoined() and self.lastHeardAt ~= nil
            and self.Core:Now() - self.lastHeardAt <= self.Config.ChannelLiveTTL
end

-- Another player was heard on the channel, or answered what we sent there.
function WoWForeverRaceChannel:NoteSender(name)
    if type(name) ~= "string" then return end
    local now = self.Core:Now()
    self.senders[name] = now
    self.lastHeardAt = now
end

-- The number of players heard on the channel within a sync interval. Everybody
-- announces itself once per interval, so this approaches the players on the channel.
function WoWForeverRaceChannel:Size()
    local oldest = self.Core:Now() - self.Config.ChannelSyncInterval
    local size = 0
    for name, at in pairs(self.senders) do
        if at < oldest then
            self.senders[name] = nil
        else
            size = size + 1
        end
    end
    return size
end

-- Seconds until our own dings may go to the channel. Right after joining we may be
-- behind the realm, and what looks new to us is old news there; the sync that runs
-- at the join (Sync:OnChannelJoined) settles that.
function WoWForeverRaceChannel:SettleDelay()
    if self.settleAt == nil then return 0 end
    return math.max(0, self.settleAt - self.Core:Now())
end

-- The join sync found a partner only now: give its data the full time to arrive.
function WoWForeverRaceChannel:Settle()
    self.settleAt = self.Core:Now() + self.Config.ChannelSettleTime
end

local function isLockedDown()
    return C_ChatInfo ~= nil and C_ChatInfo.InChatMessagingLockdown ~= nil
            and C_ChatInfo.InChatMessagingLockdown() == true
end

-- Starts joining a while after login: a channel joined before the client's own
-- (General, Trade, ...) can take a low number and push those around.
function WoWForeverRaceChannel:Init()
    self:ScheduleJoin(self.Config.ChannelJoinDelay)
end

function WoWForeverRaceChannel:ScheduleJoin(delay)
    if self.joinScheduled then return end
    self.joinScheduled = true
    local _self = self
    C_Timer.After(delay, function()
        _self.joinScheduled = false
        _self:TryJoin()
    end)
end

function WoWForeverRaceChannel:TryJoin()
    if self.status ~= IDLE or not self:Wanted() then return end

    -- already in it: the server answered our join, or a /reload kept the channel
    if self:Number() ~= nil then
        self:OnJoined()
        return
    end

    local retry = self.Config.ChannelJoinRetry
    -- nothing gets through during a chat messaging lockdown: wait it out
    if isLockedDown() then
        self:ScheduleJoin(retry)
        return
    end
    -- wait for the client's own channels (a player who left them all has none)
    if self.attempts == 0 and select("#", GetChannelList()) == 0 and self.waited < self.Config.ChannelJoinMaxWait then
        self.waited = self.waited + retry
        self:ScheduleJoin(retry)
        return
    end
    if self.attempts >= self.Config.ChannelJoinAttempts then
        WoWForeverRace:DebugPrint("Channel: could not join " .. self:Name())
        self.status = FAILED
        return
    end

    self.attempts = self.attempts + 1
    WoWForeverRace:DebugPrint("Channel: joining " .. self:Name())
    -- no chat frame argument: the channel is not added to any chat window
    JoinTemporaryChannel(self:Name())
    -- the join is confirmed by a channel notice, or by the next check finding the number
    self:ScheduleJoin(retry)
end

function WoWForeverRaceChannel:OnJoined()
    if self.status == JOINED then return end
    self.status = JOINED
    self.joinedAt = self.Core:Now()
    self.settleAt = self.joinedAt + self.Config.ChannelSettleTime
    WoWForeverRace:DebugPrint("Channel: joined " .. self:Name() .. " as channel " .. tostring(self:Number()))
    self.EventBus:PublishEvent(self.Config.Events.ChannelJoined)
end

-- CHAT_MSG_CHANNEL_NOTICE: text (the notice type), playerName, languageName, channelName,
-- playerName2, specialFlags, zoneChannelID, channelIndex, channelBaseName
function WoWForeverRaceChannel:OnChannelNotice(noticeType, _, _, _, _, _, _, _, baseName)
    -- the notice type is a secret value during a chat messaging lockdown
    if _G.issecretvalue ~= nil and _G.issecretvalue(noticeType) then return end
    if type(noticeType) ~= "string" or type(baseName) ~= "string" then return end
    if string.lower(baseName) ~= string.lower(self:Name()) then return end

    if noticeType == "YOU_CHANGED" or noticeType == "YOU_JOINED" then
        -- also when the player joins it by hand after leaving it
        if self.status ~= JOINED and self:Wanted() then
            self:OnJoined()
        end
    elseif noticeType == "YOU_LEFT" then
        -- a /leave or a kick: don't fight it, the next login joins again
        if self.status == JOINED then
            WoWForeverRace:DebugPrint("Channel: left " .. self:Name())
            self.status = LEFT
        end
    elseif noticeType == "WRONG_PASSWORD" or noticeType == "BANNED" then
        if self.status == IDLE then
            WoWForeverRace:DebugPrint("Channel: " .. self:Name() .. " refused us (" .. noticeType .. ")")
            self.status = REFUSED
        end
    end
end

-- The sharing option was switched: leave the channel with it, join when it comes back.
function WoWForeverRaceChannel:OnNetworkingChanged()
    if self:Wanted() then
        if self.status == IDLE or self.status == FAILED then
            self.status = IDLE
            self.attempts = 0
            self:ScheduleJoin(0)
        end
    elseif self.status == JOINED or self.status == IDLE then
        local wasIn = self:Number() ~= nil
        -- back to idle first, so our own YOU_LEFT notice is not taken for the player leaving
        self.status = IDLE
        if wasIn then
            LeaveChannelByName(self:Name())
        end
    end
end
