local WoWForeverRace = require("testbase")

describe("Config", function()
    local config = WoWForeverRace.Config

    after_each(function()
        SetTocVersion(nil)
    end)

    it("detects the WoW Forever client line", function()
        SetTocVersion(16001)
        assert.equals("FOREVER", config:DetectExpansion())
    end)

    it("still detects the other classic clients", function()
        SetTocVersion(11509)
        assert.equals("CLASSIC", config:DetectExpansion())
        SetTocVersion(20506)
        assert.equals("TBC", config:DetectExpansion())
        SetTocVersion(50504)
        assert.equals("MOP", config:DetectExpansion())
    end)

    it("races to 60 with Paladin and Shaman on both factions in WoW Forever", function()
        local data = config.ExpansionData.FOREVER

        assert.equals(60, data.maxLevel)
        assert.is_nil(data.hordeOnly)
        assert.is_nil(data.allianceOnly)
        assert.same({1, 2, 3, 4, 5, 7, 8, 9, 11}, data.validClassIndexes)
    end)

    it("rejects class indexes that are not playable", function()
        assert.is_true(config:IsValidClassIndex(config.ClassIndexes.PALADIN))
        assert.is_true(config:IsValidClassIndex(config.ClassIndexes.SHAMAN))
        assert.is_false(config:IsValidClassIndex(config.ClassIndexes.DEATHKNIGHT))
        assert.is_false(config:IsValidClassIndex(config.ClassIndexes.MONK))
    end)
end)
