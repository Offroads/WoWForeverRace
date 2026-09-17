local WoWForeverRace = require("testbase")

describe("Config", function()
    local config = WoWForeverRace.Config

    it("races to level 60", function()
        assert.equals(60, config.MaxLevel)
    end)

    it("tracks exactly the 9 WoW Forever classes", function()
        local names = {}
        for _, classIndex in ipairs(config.MopClassIndexes) do
            names[#names + 1] = config.Classes[classIndex]
        end

        assert.same({"WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
                     "SHAMAN", "MAGE", "WARLOCK", "DRUID"}, names)
    end)

    it("keeps the class indexes of the wire format", function()
        assert.equals(7, config.ClassIndexes.SHAMAN)
        assert.equals(11, config.ClassIndexes.DRUID)
        for className, classIndex in pairs(config.ClassIndexes) do
            assert.equals(className, config.Classes[classIndex])
        end
    end)

    it("rejects the class indexes of classes that don't exist in WoW Forever", function()
        for _, classIndex in ipairs({0, 6, 10, 12, 13}) do
            assert.is_false(config:IsValidClassIndex(classIndex))
        end
    end)
end)
