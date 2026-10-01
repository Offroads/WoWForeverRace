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
local REFUSED = "refused"   -- banned, or every channel name asks for a password
local FAILED = "failed"     -- the joins tried went unanswered

--[[
Channel keeps us in the realm channel: a player-made chat channel per faction that
every addon user joins, so one addon message reaches all of them (Network sends to
it as the virtual "RACE" distribution). The server refuses addon messages on its own
channels (General, Trade, ...), a player-made one carries them.

The channel is joined from a timer with JoinTemporaryChannel: it is not saved with the
player's chat settings and not added to a chat window, so the player never sees it.
Its name is public, so anybody can lock it with a password. A channel that asks for one
is given up for the same name with the next number (WFRaceHorde2, ...). The players who
were in it before the password stay in, so every message carries the number of its
sender's channel (see Network) and the highest number wins: whoever hears a higher one
moves there (MoveTo), and the realm ends up on one channel again. A ban, a kick or a
/leave just leaves us out, and the sync flows from before the channel take over.

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
    self.index = 1            -- which of the channel names we use, see Name
    self.moved = false        -- whether the join in progress moves us up from a channel we were in
    self.attempts = 0         -- joins tried
    self.waited = 0           -- seconds waited for the client's own channels
    self.joinScheduled = false
    self.joinedAt = nil
    self.settleAt = nil       -- from when our own dings may go to the channel, see SettleDelay
    self.senders = {}         -- [name] = when we last heard that player on the channel
    self.lastHeardAt = nil

    self.Thread = CreateFrame("Frame")
    self.Thread:Hide()
    self.Thread:SetScript("OnEvent", function(_, event, ...)
        if event == "CHANNEL_PASSWORD_REQUEST" then
            self:OnPasswordRequest(...)
        else
            self:OnChannelNotice(...)
        end
    end)
    self.Thread:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
    self.Thread:RegisterEvent("CHANNEL_PASSWORD_REQUEST")

    return self
end

-- One channel per faction: the race is per faction, and the other faction's
-- messages would be dropped anyway (see Network:HandleAddonMessage). The number is
-- only part of the name from the second channel on.
function WoWForeverRaceChannel:Name()
    local name = self.Config.RaceChannelPrefix .. tostring(self.Core:MyFaction())
    if self.index > 1 then
        name = name .. self.index
    end
    return name
end

function WoWForeverRaceChannel:Index()
    return self.index
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

-- A join is under way: its next attempt, or the check that confirms it, is scheduled.
function WoWForeverRaceChannel:IsJoining()
    return self.status == IDLE and self.joinScheduled and self:Wanted()
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
    local moved = self.moved
    self.moved = false
    self.joinedAt = self.Core:Now()
    -- after a move we know what the channel knows, like before it
    if not moved then
        self.settleAt = self.joinedAt + self.Config.ChannelSettleTime
    end
    WoWForeverRace:DebugPrint("Channel: joined " .. self:Name() .. " as channel " .. tostring(self:Number()))
    self.EventBus:PublishEvent(self.Config.Events.ChannelJoined, moved)
end

-- The channel we are joining asks for a password: give it up for the next name.
function WoWForeverRaceChannel:OnLocked()
    if self.status ~= IDLE then return end
    if self.index >= self.Config.ChannelMaxIndex then
        WoWForeverRace:DebugPrint("Channel: " .. self:Name() .. " asks for a password, no name left to try")
        self.status = REFUSED
        return
    end

    WoWForeverRace:DebugPrint("Channel: " .. self:Name() .. " asks for a password, trying the next name")
    self.index = self.index + 1
    self.attempts = 0
    -- usually the check after our join is still scheduled, and joins the next name
    self:ScheduleJoin(self.Config.ChannelJoinRetry)
end

-- CHANNEL_PASSWORD_REQUEST: the server wants a password for a channel we are joining.
-- The client answers that with a password dialog, which the player never asked for.
function WoWForeverRaceChannel:OnPasswordRequest(channelName)
    if type(channelName) ~= "string" or string.lower(channelName) ~= string.lower(self:Name()) then return end
    -- a player joining the channel by hand gets the dialog
    if self.status ~= IDLE or self.attempts == 0 then return end

    local function hideDialog()
        if _G.StaticPopup_Hide ~= nil then
            _G.StaticPopup_Hide("CHAT_CHANNEL_PASSWORD", channelName)
        end
    end
    hideDialog()
    -- the client's own handler may run after ours
    C_Timer.After(0, hideDialog)

    self:OnLocked()
end

-- Whether a channel number another player is on is one to move to: a higher one than
-- ours (up to the last one we would try ourselves), unless the player left the channel.
function WoWForeverRaceChannel:CanMoveTo(index)
    return type(index) == "number" and index % 1 == 0
            and index > self.index and index <= self.Config.ChannelMaxIndex
            and self.status ~= LEFT and self:Wanted()
end

-- Another player is on a channel with a higher number: ours asked somebody for a
-- password, so the realm is moving on. Joins that one and leaves ours. Returns
-- whether we moved.
function WoWForeverRaceChannel:MoveTo(index)
    if not self:CanMoveTo(index) then return false end

    local oldName = self:Name()
    local wasOurs = self.status == JOINED or self.attempts > 0
    self.moved = self:IsJoined()
    WoWForeverRace:DebugPrint("Channel: moving from " .. oldName .. " to number " .. index)

    self.index = index
    self.status = IDLE
    self.attempts = 0

    if wasOurs then
        -- not right away: what we still tell the old channel has to get out first
        -- (Network:AnnounceChannelMove)
        C_Timer.After(self.Config.ChannelJoinRetry, function()
            local id = GetChannelName(oldName)
            if type(id) == "number" and id > 0 then
                LeaveChannelByName(oldName)
            end
        end)
    end

    self:TryJoin()
    return true
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
    elseif noticeType == "WRONG_PASSWORD" then
        self:OnLocked()
    elseif noticeType == "BANNED" then
        -- only we are banned, the other players are still there: no other name helps
        if self.status == IDLE then
            WoWForeverRace:DebugPrint("Channel: " .. self:Name() .. " banned us")
            self.status = REFUSED
        end
    end
end

-- The sharing option was switched: leave the channel with it, join when it comes back.
function WoWForeverRaceChannel:OnNetworkingChanged()
    -- whatever join was under way, the next one starts from scratch (not as the move
    -- with everybody that a join interrupted by this may have been)
    self.moved = false
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
