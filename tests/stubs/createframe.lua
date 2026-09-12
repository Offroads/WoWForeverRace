-- Bare-bones Frame stub: records scripts and registered events so tests can
-- fire them (see Frame:FireEvent), everything else is a no-op.
local Frame = {}
Frame.__index = Frame

setmetatable(Frame, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function Frame.new()
    local self = setmetatable({}, Frame)
    self.scripts = {}
    self.events = {}
    self.shown = true
    return self
end

function Frame:Show()
    self.shown = true
end

function Frame:Hide()
    self.shown = false
end

function Frame:IsShown()
    return self.shown
end

function Frame:SetScript(handler, callback)
    self.scripts[handler] = callback
end

function Frame:GetScript(handler)
    return self.scripts[handler]
end

function Frame:HookScript(handler, callback)
    local existing = self.scripts[handler]
    if existing then
        self.scripts[handler] = function(...)
            existing(...)
            callback(...)
        end
    else
        self.scripts[handler] = callback
    end
end

function Frame:RegisterEvent(event)
    self.events[event] = true
end

function Frame:UnregisterEvent(event)
    self.events[event] = nil
end

function Frame:UnregisterAllEvents()
    self.events = {}
end

function Frame:IsEventRegistered(event)
    return self.events[event] == true
end

-- test helper: dispatch an event to the OnEvent script as WoW would
function Frame:FireEvent(event, ...)
    local handler = self.scripts["OnEvent"]
    if handler and self.events[event] then
        handler(self, event, ...)
    end
end

function _G.CreateFrame(frameType)
    if frameType ~= "Frame" then
        error("unsupported type arg to CreateFrame(" .. tostring(frameType) .. ")")
    end

    return Frame()
end
