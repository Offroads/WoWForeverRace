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
        SetFaction(nil)
    end)

    describe("MyFaction", function()
        it("returns the player's faction", function()
            assert.equals("Alliance", core:MyFaction())
        end)

        it("follows the faction of the character that is logged in", function()
            SetFaction("Horde")
            assert.equals("Horde", core:MyFaction())
        end)
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

    describe("Races", function()
        after_each(function()
            SetRaceNames(nil)
        end)

        it("tracks the races of the faction of the player", function()
            assert.same({1, 3, 4, 7, 95}, core:MyRaceIndexes())
            assert.is_true(core:IsValidRaceIndex(95))
            assert.is_false(core:IsValidRaceIndex(96))

            SetFaction("Horde")
            assert.same({2, 5, 6, 8, 96}, core:MyRaceIndexes())
            assert.is_true(core:IsValidRaceIndex(96))
            assert.is_false(core:IsValidRaceIndex(95))
        end)

        it("resolves the race name of a /who row", function()
            assert.equals(4, core:RaceIndexByName("Night Elf"))
            assert.equals(95, core:RaceIndexByName("High Order Skyborne"))
            -- the races of the other faction never show up in our /who
            assert.is_nil(core:RaceIndexByName("Windshaper Skyborne"))
            assert.is_nil(core:RaceIndexByName("Orc"))
            assert.is_nil(core:RaceIndexByName("Murloc"))
            assert.is_nil(core:RaceIndexByName(nil))
            assert.is_nil(core:RaceIndexByName(4))
        end)

        it("resolves the Horde Skyborne on a Horde character", function()
            SetFaction("Horde")
            core = WoWForeverRace.Core(config, "Nub", "NubVille")
            assert.equals(96, core:RaceIndexByName("Windshaper Skyborne"))
            assert.is_nil(core:RaceIndexByName("High Order Skyborne"))
        end)

        it("uses the localized race names of the client", function()
            SetRaceNames({[4] = "Nachtelf"})
            core = WoWForeverRace.Core(config, "Nub", "NubVille")
            assert.equals("Nachtelf", core:RaceName(4))
            assert.equals(4, core:RaceIndexByName("Nachtelf"))
            assert.is_nil(core:RaceIndexByName("Night Elf"))
        end)

        it("falls back to the English race names without the client API", function()
            local creatureInfo = _G.C_CreatureInfo
            _G.C_CreatureInfo = nil
            assert.equals("Night Elf", core:RaceName(4))
            _G.C_CreatureInfo = creatureInfo
        end)

        it("has no name for a race that is not tracked", function()
            assert.is_nil(core:RaceName(10))
            assert.is_nil(core:RaceName(nil))
        end)
    end)
end)
