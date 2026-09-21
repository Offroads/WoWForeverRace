local WoWForeverRace = require("testbase")

describe("Core", function()
    local config
    local core

    before_each(function()
        config = setmetatable({RealmLaunchAt = 2000}, {__index = WoWForeverRace.Config})
        core = WoWForeverRace.Core(config, "Nub", "NubVille")
    end)

    after_each(function()
        SetTime(1000000000)
    end)

    describe("RaceStartTime", function()
        it("uses the fallback before the realm launch", function()
            SetTime(1999)
            assert.equals(1500, core:RaceStartTime(1500))
            assert.is_nil(core:RaceStartTime(nil))
        end)

        it("uses the realm launch once it has passed", function()
            SetTime(2000)
            assert.equals(2000, core:RaceStartTime(1500))
            assert.equals(2000, core:RaceStartTime(nil))
        end)

        it("uses the fallback when no launch is configured", function()
            SetTime(5000)
            -- a plain nil would let the real Config value shine through, so shadow it explicitly
            config = setmetatable({}, {__index = function(_, key)
                if key == "RealmLaunchAt" then return nil end
                return WoWForeverRace.Config[key]
            end})
            core = WoWForeverRace.Core(config, "Nub", "NubVille")
            assert.equals(1500, core:RaceStartTime(1500))
        end)
    end)
end)
