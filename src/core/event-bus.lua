local WoWForeverRace = _G.WoWForeverRace

---@class WoWForeverRaceEventBus
local WoWForeverRaceEventBus = {}
WoWForeverRaceEventBus.__index = WoWForeverRaceEventBus

WoWForeverRace.EventBus = WoWForeverRaceEventBus

setmetatable(WoWForeverRaceEventBus, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function WoWForeverRaceEventBus.new()
    local self = setmetatable({}, WoWForeverRaceEventBus)
    self.Listeners = {}
    return self
end

function WoWForeverRaceEventBus:RegisterCallback(event, object, callback)
    if (self.Listeners[event] == nil) then
        self.Listeners[event] = {}
    end
    table.insert(self.Listeners[event], { Object = object, Callback = callback })
end

function WoWForeverRaceEventBus:PublishEvent(event, ...)
    WoWForeverRace:TracePrint("Event published: " .. event)
    if (self.Listeners[event] ~= nil) then
        for key in pairs(self.Listeners[event]) do
            self.Listeners[event][key].Callback(self.Listeners[event][key].Object, ...)
        end
    end
end
