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

function WoWForeverRaceChatNotifier:OnDing(playerInfo, globalRank, classRank)
    -- check if we should report on this ding
    if not self:ShouldReport(playerInfo, globalRank, classRank) then
        return
    end

    if playerInfo.name == self.Core:Me() then
        self:OnSelfDing(playerInfo, globalRank, classRank)
    else
        self:OnStrangerDing(playerInfo, globalRank, classRank)
    end
end


function WoWForeverRaceChatNotifier:ShouldReport(playerInfo, globalRank, classRank)
    -- ignore stale detections (>10 min old) unless rank 1
    if playerInfo.dingedAt < self.Core:Now() - 600
            and (globalRank == nil or globalRank > 1)
            and (classRank == nil or classRank > 1) then
        return false
    end

    -- sliders are the primary gate
    if classRank ~= nil and classRank <= self.DB.profile.options.classTopN then
        return true
    end

    if globalRank ~= nil and globalRank <= self.DB.profile.options.globalTopN then
        return true
    end

    -- maxLevelNotify only fires for rank-1 (first to max level globally or per class),
    -- so it doesn't spam when many players are already at max level
    if self.DB.profile.options.maxLevelNotify
            and playerInfo.level >= self.Config.MaxLevel
            and (globalRank == 1 or classRank == 1) then
        return true
    end

    return false
end

function WoWForeverRaceChatNotifier:OnSelfDing(playerInfo, globalRank, classRank)
    self:DingNotification(playerInfo, globalRank, classRank, true)
end

function WoWForeverRaceChatNotifier:OnStrangerDing(playerInfo, globalRank, classRank)
    self:DingNotification(playerInfo, globalRank, classRank, false)
end

function WoWForeverRaceChatNotifier:DingNotification(playerInfo, globalRank, classRank, isSelf)
    local className = self.Core:ClassByIndex(playerInfo.classIndex)
    local prettyClassName = self.Config.PrettyClassNames[className]
    local chatLink
    local addressPerson
    if isSelf then
        chatLink = WoWForeverRace:PlayerChatLink(playerInfo.name, "You", className)
        addressPerson = chatLink .. " are"
    else
        chatLink = WoWForeverRace:PlayerChatLink(playerInfo.name, nil, className)
        addressPerson = chatLink .. " is"
    end

    if globalRank == 1 then
        if playerInfo.level == self.Config.MaxLevel then
            WoWForeverRace:PPrint("Gratz! The race is over! " .. addressPerson .. " the first to reach max level!!")
        else
            WoWForeverRace:PPrint("Gratz! " .. addressPerson .. " first to reach level " .. playerInfo.level .. "!")
        end
    elseif classRank == 1 and globalRank ~= nil then
        if playerInfo.level == self.Config.MaxLevel then
            WoWForeverRace:PPrint("Gratz! The race is over! " .. addressPerson .. " the first to reach max level of all " ..
                    prettyClassName .. ", and #" .. globalRank .. " for all classes!!")
        else
            WoWForeverRace:PPrint("Gratz! " .. addressPerson .. " first to reach level " .. playerInfo.level .. " of all " ..
                    prettyClassName .. ", and #" .. globalRank .. " for all classes!")
        end
    elseif classRank == 1 then
        if playerInfo.level == self.Config.MaxLevel then
            WoWForeverRace:PPrint("Gratz! The race is over! " .. addressPerson .. " the first to reach max level of all " ..
                    prettyClassName .. "!!")
        else
            WoWForeverRace:PPrint("Gratz! " .. addressPerson .. " first to reach level " .. playerInfo.level .. " of all " ..
                    prettyClassName .. "!!")
        end
    elseif globalRank ~= nil then
        if playerInfo.level == self.Config.MaxLevel then
            WoWForeverRace:PPrint("Gratz!  " .. chatLink .. " reached max level as #" .. classRank .. " of all " .. prettyClassName .. ", " ..
                    "and #" .. globalRank .. " for all classes!!")
        else
            WoWForeverRace:PPrint("Gratz! " .. chatLink .. " reached level " .. playerInfo.level .. "! " ..
                    "Currently rank #" .. classRank .. " of all " .. prettyClassName .. " and #" .. globalRank .. " for all classes in the race!")
        end
    else
        if playerInfo.level == self.Config.MaxLevel then
            WoWForeverRace:PPrint("Gratz!  " .. chatLink .. " reached max level as #" .. classRank .. " of all " .. prettyClassName .. "!")
        else
            WoWForeverRace:PPrint("Gratz! " .. chatLink .. " reached level " .. playerInfo.level .. " as #" .. classRank
                    .. " of all " .. prettyClassName .. "!")
        end
    end
end

function WoWForeverRaceChatNotifier:OnRaceFinished()
    WoWForeverRace:PPrint("More than " .. self.Config.MaxLeaderboardSize .. " players have reached max level, the race is over!")
end
