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

    it("tracks the four classic races and its own Skyborne per faction", function()
        assert.same({1, 3, 4, 7, 95}, config:RaceIndexes("Alliance"))
        assert.same({2, 5, 6, 8, 96}, config:RaceIndexes("Horde"))
        assert.same({}, config:RaceIndexes("Neutral"))
        assert.same({}, config:RaceIndexes(nil))
    end)

    it("only accepts the race indexes of the given faction", function()
        assert.is_true(config:IsValidRaceIndex(95, "Alliance"))
        assert.is_true(config:IsValidRaceIndex(8, "Horde"))
        for _, raceIndex in ipairs({0, 2, 96, 9, "1", {}}) do
            assert.is_false(config:IsValidRaceIndex(raceIndex, "Alliance"))
        end
        assert.is_false(config:IsValidRaceIndex(nil, "Alliance"))
    end)

    it("names and draws every tracked race", function()
        for _, faction in ipairs({"Alliance", "Horde"}) do
            for _, raceIndex in ipairs(config:RaceIndexes(faction)) do
                assert.is_string(config.Races[raceIndex])
                assert.is_string(config.RaceNames[raceIndex])
                assert.is_string(config.RaceIconAtlas[raceIndex])
            end
        end
    end)

    it("keeps the race leaderboards clear of the overall and class leaderboards", function()
        assert.same({0, 1, 2, 3, 4, 5, 7, 8, 9, 11, 101, 103, 104, 107, 195},
                config:BoardIndexes("Alliance"))
        assert.same({0, 1, 2, 3, 4, 5, 7, 8, 9, 11, 102, 105, 106, 108, 196},
                config:BoardIndexes("Horde"))
    end)

    it("only lists the leaderboards a peer reported", function()
        -- index i+1 = leaderboard[i]: overall, warrior and the Human race board
        local peerHashes = {[1] = 1, [2] = 2, [102] = 3}
        assert.same({0, 1, 101}, config:BoardIndexes("Alliance", peerHashes))
        -- a peer that reports no race board at all does not track races
        assert.same({0, 1}, config:BoardIndexes("Alliance", {[1] = 1, [2] = 2}))
    end)
end)
