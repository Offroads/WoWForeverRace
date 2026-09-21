-- Addon global
local WoWForeverRace = _G.WoWForeverRace

--[[
ChatNotifier is responsible for notifying the user about events through the chat window
based on events from the EventBus
]]--
---@class WoWForeverRaceChatNotifier
---@field Config WoWForeverRaceConfig
---@field Core WoWForeverRaceCore
---@field EventBus WoWForeverRaceEventBus
local WoWForeverRaceChatNotifier = {}
WoWForeverRaceChatNotifier.__index = WoWForeverRaceChatNotifier
WoWForeverRace.ChatNotifier = WoWForeverRaceChatNotifier
setmetatable(WoWForeverRaceChatNotifier, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function WoWForeverRaceChatNotifier.new(Config, Core, DB, EventBus)
    local self = setmetatable({}, WoWForeverRaceChatNotifier)

    self.Config = Config
    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus

    -- subscribe to local events
    EventBus:RegisterCallback(self.Config.Events.Ding, self, self.OnDing)
    EventBus:RegisterCallback(self.Config.Events.RaceFinished, self, self.OnRaceFinished)

    return self
end

function WoWForeverRaceChatNotifier:OnDing(playerInfo, globalRank, classRank, raceRank)
    -- check if we should report on this ding
    if not self:ShouldReport(playerInfo, globalRank, classRank, raceRank) then
        return
    end

    if playerInfo.name == self.Core:Me() then
        self:OnSelfDing(playerInfo, globalRank, classRank, raceRank)
    else
        self:OnStrangerDing(playerInfo, globalRank, classRank, raceRank)
    end
end

-- the global / class gates: the top N sliders and the max level toggle
function WoWForeverRaceChatNotifier:PassesRankGate(playerInfo, globalRank, classRank)
    -- sliders are the primary gate
    if classRank ~= nil and classRank <= self.DB.profile.options.classTopN then
        return true
    end

    if globalRank ~= nil and globalRank <= self.DB.profile.options.globalTopN then
        return true
    end

    -- maxLevelNotify only fires for rank-1 (first to max level globally or per class),
    -- so it doesn't spam when many players are already at max level. The first of a
    -- race is up to the race gate alone: race top N at 0 silences every race rank.
    if self.DB.profile.options.maxLevelNotify
            and playerInfo.level >= self.Config.MaxLevel
            and (globalRank == 1 or classRank == 1) then
        return true
    end

    return false
end

-- the race gate: the race top N slider
function WoWForeverRaceChatNotifier:PassesRaceGate(raceRank)
    return raceRank ~= nil and raceRank <= self.DB.profile.options.raceTopN
end

function WoWForeverRaceChatNotifier:ShouldReport(playerInfo, globalRank, classRank, raceRank)
    -- ignore stale detections (>10 min old) unless rank 1
    if playerInfo.dingedAt < self.Core:Now() - 600
            and (globalRank == nil or globalRank > 1)
            and (classRank == nil or classRank > 1)
            and (raceRank == nil or raceRank > 1) then
        return false
    end

    return self:PassesRankGate(playerInfo, globalRank, classRank)
            or self:PassesRaceGate(raceRank)
end

function WoWForeverRaceChatNotifier:OnSelfDing(playerInfo, globalRank, classRank, raceRank)
    self:DingNotification(playerInfo, globalRank, classRank, true, raceRank)
end

function WoWForeverRaceChatNotifier:OnStrangerDing(playerInfo, globalRank, classRank, raceRank)
    self:DingNotification(playerInfo, globalRank, classRank, false, raceRank)
end

-- A ding is one chat line. The global / class message also names the race rank when
-- the race gate lets it; a ding only the race gate lets through gets the race message.
function WoWForeverRaceChatNotifier:DingNotification(playerInfo, globalRank, classRank, isSelf, raceRank)
    local className = self.Core:ClassByIndex(playerInfo.classIndex)
    local chatLink
    local addressPerson
    if isSelf then
        chatLink = WoWForeverRace:PlayerChatLink(playerInfo.name, "You", className)
        addressPerson = chatLink .. " are"
    else
        chatLink = WoWForeverRace:PlayerChatLink(playerInfo.name, nil, className)
        addressPerson = chatLink .. " is"
    end

    local message = nil
    if self:PassesRankGate(playerInfo, globalRank, classRank) then
        message = self:RankMessage(playerInfo, globalRank, classRank, chatLink, addressPerson)
    end

    if self:PassesRaceGate(raceRank) then
        local raceName = self.Core:RaceName(playerInfo.raceIndex) or "unknown race"
        if message ~= nil then
            -- keep the closing exclamation marks at the end
            local body, marks = string.match(message, "^(.-)(!*)$")
            message = body .. ", and #" .. raceRank .. " of all " .. raceName .. marks
        else
            message = self:RaceMessage(playerInfo, raceRank, raceName, chatLink, addressPerson)
        end
    end

    if message ~= nil then
        WoWForeverRace:PPrint(message)
    end
end

function WoWForeverRaceChatNotifier:RaceMessage(playerInfo, raceRank, raceName, chatLink, addressPerson)
    local isMaxLevel = playerInfo.level == self.Config.MaxLevel
    if raceRank == 1 then
        if isMaxLevel then
            return "Gratz! " .. addressPerson .. " the first to reach max level of all " .. raceName .. "!!"
        end
        return "Gratz! " .. addressPerson .. " first to reach level " .. playerInfo.level .. " of all " .. raceName .. "!"
    end

    if isMaxLevel then
        return "Gratz! " .. chatLink .. " reached max level as #" .. raceRank .. " of all " .. raceName .. "!"
    end
    return "Gratz! " .. chatLink .. " reached level " .. playerInfo.level .. " as #" .. raceRank
            .. " of all " .. raceName .. "!"
end

function WoWForeverRaceChatNotifier:RankMessage(playerInfo, globalRank, classRank, chatLink, addressPerson)
    local className = self.Core:ClassByIndex(playerInfo.classIndex)
    -- players with an unknown class (old clients, missing /who data) have no
    -- class leaderboard, so classRank is nil and there is no pretty name either
    local prettyClassName = self.Config.PrettyClassNames[className] or "unknown class"

    if globalRank == 1 then
        if playerInfo.level == self.Config.MaxLevel then
            return "Gratz! The race is over! " .. addressPerson .. " the first to reach max level!!"
        else
            return "Gratz! " .. addressPerson .. " first to reach level " .. playerInfo.level .. "!"
        end
    elseif classRank == 1 and globalRank ~= nil then
        if playerInfo.level == self.Config.MaxLevel then
            return "Gratz! " .. addressPerson .. " the first to reach max level of all " ..
                    prettyClassName .. ", and #" .. globalRank .. " for all classes!!"
        else
            return "Gratz! " .. addressPerson .. " first to reach level " .. playerInfo.level .. " of all " ..
                    prettyClassName .. ", and #" .. globalRank .. " for all classes!"
        end
    elseif classRank == 1 then
        if playerInfo.level == self.Config.MaxLevel then
            return "Gratz! " .. addressPerson .. " the first to reach max level of all " ..
                    prettyClassName .. "!!"
        else
            return "Gratz! " .. addressPerson .. " first to reach level " .. playerInfo.level .. " of all " ..
                    prettyClassName .. "!!"
        end
    elseif globalRank ~= nil and classRank ~= nil then
        if playerInfo.level == self.Config.MaxLevel then
            return "Gratz!  " .. chatLink .. " reached max level as #" .. classRank .. " of all " .. prettyClassName .. ", " ..
                    "and #" .. globalRank .. " for all classes!!"
        else
            return "Gratz! " .. chatLink .. " reached level " .. playerInfo.level .. "! " ..
                    "Currently rank #" .. classRank .. " of all " .. prettyClassName .. " and #" .. globalRank .. " for all classes in the race!"
        end
    elseif globalRank ~= nil then
        if playerInfo.level == self.Config.MaxLevel then
            return "Gratz!  " .. chatLink .. " reached max level as #" .. globalRank .. " for all classes!!"
        else
            return "Gratz! " .. chatLink .. " reached level " .. playerInfo.level .. "! " ..
                    "Currently rank #" .. globalRank .. " for all classes in the race!"
        end
    elseif classRank ~= nil then
        if playerInfo.level == self.Config.MaxLevel then
            return "Gratz!  " .. chatLink .. " reached max level as #" .. classRank .. " of all " .. prettyClassName .. "!"
        else
            return "Gratz! " .. chatLink .. " reached level " .. playerInfo.level .. " as #" .. classRank
                    .. " of all " .. prettyClassName .. "!"
        end
    end

    return nil
end

function WoWForeverRaceChatNotifier:OnRaceFinished()
    WoWForeverRace:PPrint("Every class and race leaderboard is full with " .. self.Config.MaxLeaderboardSize ..
            " players at max level, the race is over!")
end
