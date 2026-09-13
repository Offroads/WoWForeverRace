-- load test base
require("testbase")

-- The C_Timer stub drives most of the sync and tracker tests, so its own
-- semantics are pinned here.
describe("C_Timer stub", function()
    before_each(function()
        _G.C_Timer.Reset()
    end)

    it("fires due one-shot timers in due-time order", function()
        local order = {}
        _G.C_Timer.After(5, function() order[#order + 1] = "late" end)
        _G.C_Timer.After(2, function() order[#order + 1] = "early" end)

        _G.C_Timer.Advance(10)

        assert.same({"early", "late"}, order)
    end)

    it("does not fire timers that are not due yet", function()
        local fired = false
        _G.C_Timer.After(5, function() fired = true end)

        _G.C_Timer.Advance(4)
        assert.is_false(fired)

        _G.C_Timer.Advance(1)
        assert.is_true(fired)
    end)

    it("runs a zero-delay timer scheduled from a fired callback", function()
        local chained = false
        _G.C_Timer.After(5, function()
            _G.C_Timer.After(0, function() chained = true end)
        end)

        _G.C_Timer.Advance(5)

        assert.is_true(chained)
    end)

    it("keeps a timer scheduled from a callback for later", function()
        local chained = false
        _G.C_Timer.After(5, function()
            _G.C_Timer.After(3, function() chained = true end)
        end)

        _G.C_Timer.Advance(5)
        assert.is_false(chained)

        _G.C_Timer.Advance(3)
        assert.is_true(chained)
    end)

    it("ticks repeating timers once per interval and honours Cancel", function()
        local ticks = 0
        local ticker = _G.C_Timer.NewTicker(10, function() ticks = ticks + 1 end)

        _G.C_Timer.Advance(25)
        assert.equals(2, ticks)

        ticker:Cancel()
        _G.C_Timer.Advance(20)
        assert.equals(2, ticks)
    end)

    it("stops a limited ticker after its iterations", function()
        local ticks = 0
        _G.C_Timer.NewTicker(1, function() ticks = ticks + 1 end, 3)

        _G.C_Timer.Advance(10)

        assert.equals(3, ticks)
    end)
end)
