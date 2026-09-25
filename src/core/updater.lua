-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- WoW API
local CreateFrame, UnitRace = _G.CreateFrame, _G.UnitRace

--[[
Updater is responsible for when we level up ourselves
]]--
---@class WoWForeverRaceUpdater
---@field Core WoWForeverRaceCore
---@field EventBus WoWForeverRaceEventBus
local WoWForeverRaceUpdater = {}
WoWForeverRaceUpdater.__index = WoWForeverRaceUpdater
WoWForeverRace.Updater = WoWForeverRaceUpdater
setmetatable(WoWForeverRaceUpdater, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function WoWForeverRaceUpdater.new(Core, EventBus)
    local self = setmetatable({}, WoWForeverRaceUpdater)

    self.Core = Core
    self.EventBus = EventBus

    -- create a Frame to use as thread to receive events on
    self.Thread = CreateFrame("Frame")
    self.Thread:Hide()
    self.Thread:SetScript("OnEvent", function(_, event, ...)
        if (event == "PLAYER_LEVEL_UP") then
            self:OnPlayerLevelUp(...)
        end
    end)

    -- register for level up events
    self.Thread:RegisterEvent("PLAYER_LEVEL_UP")

    return self
end

function WoWForeverRaceUpdater:OnPlayerLevelUp(level)
    WoWForeverRace:DebugPrint("OnPlayerLevelUp(" .. tostring(level) .. ")")

    local classIndex = self.Core:MyClass()
    local _, _, raceIndex = UnitRace("player")

    -- we fake an /who result
    self.EventBus:PublishEvent(WoWForeverRace.Config.Events.SlashWhoResult, {{
        name = self.Core:Me(),
        level = level,
        classIndex = classIndex,
        raceIndex = self.Core:IsValidRaceIndex(raceIndex) and raceIndex or nil,
    }, })
end
