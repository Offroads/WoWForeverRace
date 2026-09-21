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

    describe("PredatesLaunch", function()
        it("is false for everything while the launch is still ahead", function()
            SetTime(1999)
            assert.is_false(core:PredatesLaunch(1500))
        end)

        it("is true only for timestamps before the launch once it has passed", function()
            SetTime(3000)
            assert.is_true(core:PredatesLaunch(1999))
            assert.is_false(core:PredatesLaunch(2000))
            assert.is_false(core:PredatesLaunch(nil))
        end)

        it("is false when no launch is configured", function()
            SetTime(3000)
            config = setmetatable({}, {__index = function(_, key)
                if key == "RealmLaunchAt" then return nil end
                return WoWForeverRace.Config[key]
            end})
            core = WoWForeverRace.Core(config, "Nub", "NubVille")
            assert.is_false(core:HasLaunched())
            assert.is_false(core:PredatesLaunch(1999))
        end)
    end)

    describe("RaceStartTime", function()
        it("uses the fallback before the realm launch", function()
            SetTime(1999)
            assert.equals(1500, core:RaceStartTime(1500))
            assert.is_nil(core:RaceStartTime(nil))
        end)

        it("uses the realm launch once it has passed", function()
            SetTime(2000)
            assert.equals(2000, core:RaceStartTime(nil))
            SetTime(3000)
            assert.equals(2000, core:RaceStartTime(1500))
            assert.equals(2000, core:RaceStartTime(1500, 2000))
            assert.equals(2000, core:RaceStartTime(1500, 2500))
        end)

        it("keeps the fallback for a ding from before the realm launch", function()
            SetTime(3000)
            assert.equals(1500, core:RaceStartTime(1500, 1999))
            assert.is_nil(core:RaceStartTime(nil, 1999))
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
