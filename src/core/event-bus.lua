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
    local listeners = self.Listeners[event]
    if listeners == nil then return end

    for _, listener in ipairs(listeners) do
        -- one failing listener must neither silence the listeners after it nor
        -- abort the publisher (the rest of a /who batch, a network message);
        -- the error is handed to WoW's script error handler instead
        local ok, err = pcall(listener.Callback, listener.Object, ...)
        if not ok then
            geterrorhandler()(err)
        end
    end
end
