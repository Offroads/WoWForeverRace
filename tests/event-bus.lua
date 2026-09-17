-- load test base
local WoWForeverRace = require("testbase")

describe("EventBus", function()
    local eventbus
    local errors
    local originalErrorHandler

    before_each(function()
        eventbus = WoWForeverRace.EventBus()
        errors = {}
        -- WoW hands listener errors to its script error handler; record them here
        originalErrorHandler = _G.geterrorhandler
        _G.geterrorhandler = function()
            return function(err) errors[#errors + 1] = err end
        end
    end)

    after_each(function()
        _G.geterrorhandler = originalErrorHandler
    end)

    it("calls listeners in registration order with the published arguments", function()
        local calls = {}
        local first = {name = "first"}
        local second = {name = "second"}
        eventbus:RegisterCallback("EV", first, function(self, a, b) calls[#calls + 1] = self.name .. a .. b end)
        eventbus:RegisterCallback("EV", second, function(self, a, b) calls[#calls + 1] = self.name .. a .. b end)

        eventbus:PublishEvent("EV", "x", "y")

        assert.same({"firstxy", "secondxy"}, calls)
    end)

    it("does nothing for an event without listeners", function()
        assert.has_no.errors(function() eventbus:PublishEvent("NOBODY", 1) end)
    end)

    it("keeps delivering to the other listeners when one of them errors", function()
        local delivered = false
        eventbus:RegisterCallback("EV", {}, function() error("boom") end)
        eventbus:RegisterCallback("EV", {}, function() delivered = true end)

        assert.has_no.errors(function() eventbus:PublishEvent("EV") end)

        assert.is_true(delivered)
        assert.equals(1, #errors)
        assert.has_match("boom", errors[1])
    end)
end)
