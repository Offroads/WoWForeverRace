local WoWForeverRace = require("testbase")

describe("Config", function()
    local config = WoWForeverRace.Config

    after_each(function()
        SetTocVersion(nil)
        SetMaxPlayerLevel(nil)
        config:ApplyExpansion("FOREVER")
    end)

    it("detects the WoW Forever client line", function()
        SetTocVersion(16001)
        assert.equals("FOREVER", config:DetectExpansion())
    end)

    it("still detects the other classic clients", function()
        SetMaxPlayerLevel(90)
        SetTocVersion(11509)
        assert.equals("CLASSIC", config:DetectExpansion())
        SetTocVersion(20506)
        assert.equals("TBC", config:DetectExpansion())
        SetTocVersion(50504)
        assert.equals("MOP", config:DetectExpansion())
    end)

    it("detects WoW Forever by its level cap should it leave the 1.x numbering", function()
        SetTocVersion(20001)
        assert.equals("FOREVER", config:DetectExpansion())
    end)

    it("races to 60 with Paladin and Shaman on both factions in WoW Forever", function()
        for _, faction in ipairs({"Horde", "Alliance"}) do
            config:ApplyExpansion(nil, faction)

            assert.equals(60, config.MaxLevel)
            assert.is_true(config:IsValidClassIndex(config.ClassIndexes.PALADIN))
            assert.is_true(config:IsValidClassIndex(config.ClassIndexes.SHAMAN))
            assert.equals(9, #config.MopClassIndexes)
        end
    end)

    it("keeps Paladin and Shaman faction-only on Classic Era", function()
        config:ApplyExpansion("CLASSIC", "Horde")
        assert.is_false(config:IsValidClassIndex(config.ClassIndexes.PALADIN))
        assert.is_true(config:IsValidClassIndex(config.ClassIndexes.SHAMAN))

        config:ApplyExpansion("CLASSIC", "Alliance")
        assert.is_true(config:IsValidClassIndex(config.ClassIndexes.PALADIN))
        assert.is_false(config:IsValidClassIndex(config.ClassIndexes.SHAMAN))
    end)

    it("rejects class indexes that are not playable", function()
        assert.is_false(config:IsValidClassIndex(config.ClassIndexes.DEATHKNIGHT))
        assert.is_false(config:IsValidClassIndex(config.ClassIndexes.MONK))
    end)
end)
