-- load test base
local WoWForeverRace = require("testbase")

-- libs
local AceSerializer = LibStub:GetLibrary("AceSerializer-3.0")

-- aliases
local SerPInfo = WoWForeverRace.Serializer.SerializePlayerInfo
local DeserPInfo = WoWForeverRace.Serializer.DeserializePlayerInfo
local SerPInfoBatch = WoWForeverRace.Serializer.SerializePlayerInfoBatch
local DeserPInfoBatch = WoWForeverRace.Serializer.DeserializePlayerInfoBatch
local SerFTLBatch = WoWForeverRace.Serializer.SerializeFTLBatch
local DeserFTLBatch = WoWForeverRace.Serializer.DeserializeFTLBatch

function mergeConfigs(...)
    local config = {}
    for _, c in pairs({...}) do
        for k, v in pairs(c) do
            config[k] = v
        end
    end

    return config
end

local time = 1000000000

describe("Serializer", function()
    describe("PlayerInfo", function()
        it("serializes and deserializes", function()
            local nub1 = {name = "Nubone", level = 5, dingedAt = time, classIndex = 11}
            local nub2 = {name = "Nubtwo", level = 5, dingedAt = time, classIndex = 1}
            local nub3 = {name = "Nubthree", level = 5, dingedAt = 0, classIndex = 2}
            local nub4 = {name = "Nubfour", level = 11, dingedAt = time, classIndex = 11}
            local nub5 = {name = "Nubfive", level = 1, dingedAt = time, classIndex = 1}

            local nub1str = SerPInfo(nub1)
            assert.same("0511Nubone1000000000", nub1str)
            assert.same(nub1, DeserPInfo(nub1str))

            local nub2str = SerPInfo(nub2)
            assert.same("051Nubtwo1000000000", nub2str)
            assert.same(nub2, DeserPInfo(nub2str))

            local nub3str = SerPInfo(nub3)
            assert.same("052Nubthree0", nub3str)
            assert.same(nub3, DeserPInfo(nub3str))

            local nub4str = SerPInfo(nub4)
            assert.same("1111Nubfour1000000000", nub4str)
            assert.same(nub4, DeserPInfo(nub4str))

            local nub5str = SerPInfo(nub5)
            assert.same("011Nubfive1000000000", nub5str)
            assert.same(nub5, DeserPInfo(nub5str))
        end)

        it("round-trips levels above 99 using the extended format", function()
            local playerInfo = {name = "Nubone", level = 100, dingedAt = time, classIndex = 12}

            assert.equals("!100:12:Nubone:1000000000", SerPInfo(playerInfo))
            assert.same(playerInfo, DeserPInfo(SerPInfo(playerInfo)))
        end)
        it("it more compact than AceSerializer", function()
            local nub1 = {name = "Nubone", level = 5, dingedAt = time, classIndex = 11}

            assert.same("0511Nubone1000000000", SerPInfo(nub1))
            assert.same(20, string.len(SerPInfo(nub1)))

            -- ^1^T^SclassIndex^N11^Slevel^N5^SdingedAt^N1000000000^Sname^SNubone^t^^
            assert.same(70, string.len(AceSerializer:Serialize(nub1)))

            assert.same("^1^T^N1^SNubone^N2^N5^N3^N1000000000^N4^N11^t^^",
                    AceSerializer:Serialize({nub1.name, nub1.level, nub1.dingedAt, nub1.classIndex}))
            assert.same(47,
                    string.len(AceSerializer:Serialize({nub1.name, nub1.level, nub1.dingedAt, nub1.classIndex})))
        end)
    end)

    describe("FTLBatch", function()
        it("empty batch serializes to empty string", function()
            assert.equals("", SerFTLBatch({}))
            assert.same({}, DeserFTLBatch(""))
        end)

        it("round-trips firstToLevel data", function()
            local t = 1000000000
            local ftl = {
                [0] = {
                    [15] = {name = "Alice", classIndex = 3, dingedAt = t + 100},
                    [16] = {name = "Bob",   classIndex = 1, dingedAt = t},
                },
                [3] = {
                    [15] = {name = "Alice", classIndex = 3, dingedAt = t + 100},
                },
            }

            local str = SerFTLBatch(ftl)
            local result = DeserFTLBatch(str)

            assert.equals(t + 100, result[0][15].dingedAt)
            assert.equals("Alice", result[0][15].name)
            assert.equals(3,       result[0][15].classIndex)

            assert.equals(t,     result[0][16].dingedAt)
            assert.equals("Bob", result[0][16].name)
            assert.equals(1,     result[0][16].classIndex)

            assert.equals(t + 100, result[3][15].dingedAt)
            assert.equals("Alice", result[3][15].name)
        end)

        it("deduplicates on deserialize keeping earliest dingedAt", function()
            -- manually craft a string with two entries for (classFilter=0, level=5)
            local t = 1000000000
            -- format: offset$ CF(2) LV(2) CI(2) name delta $
            local str = string.sub("0000000000" .. t, -10)
                    .. "$"
                    .. "000501Early0$"        -- dingedAt = t+0  (Earlier)
                    .. "000502Late1000$"      -- dingedAt = t+1000 (Later)
            local result = DeserFTLBatch(str)
            -- Earlier record should win
            assert.equals("Early", result[0][5].name)
            assert.equals(1,       result[0][5].classIndex)
            assert.equals(t,       result[0][5].dingedAt)
        end)

        it("deduplicates on deserialize keeping alphabetically earlier name when dingedAt is equal", function()
            local t = 1000000000
            local str = string.sub("0000000000" .. t, -10)
                    .. "$"
                    .. "000501Zebra0$"   -- dingedAt = t, name "Zebra"
                    .. "000502Aardvark0$" -- dingedAt = t, name "Aardvark" (should win)
            local result = DeserFTLBatch(str)
            assert.equals("Aardvark", result[0][5].name)
        end)

        it("round-trips levels above 99 using the extended format", function()
            local t = 1000000000
            local ftl = {
                [0] = {
                    [1] = {name = "Fresh", classIndex = 1, dingedAt = t},
                    [100] = {name = "Impossible", classIndex = 1, dingedAt = t},
                    [10] = {name = "Racer", classIndex = 1, dingedAt = t},
                },
            }
            local result = DeserFTLBatch(SerFTLBatch(ftl))
            assert.is_nil(result[0][1])
            assert.equals("Impossible", result[0][100].name)
            assert.equals("Racer", result[0][10].name)
        end)

        it("ignores level-1 entries on deserialize", function()
            local t = 1000000000
            local str = string.sub("0000000000" .. t, -10)
                    .. "$"
                    .. "000101Fresh0$"   -- level 1 entry, invalid
                    .. "000501Racer0$"   -- level 5 entry, valid
            local result = DeserFTLBatch(str)
            assert.is_nil(result[0][1])
            assert.equals("Racer", result[0][5].name)
        end)

        it("handles single-digit class indexes correctly", function()
            local t = 1000000000
            local ftl = {
                [0] = {[2] = {name = "Nub", classIndex = 1, dingedAt = t}},
            }
            local str = SerFTLBatch(ftl)
            local result = DeserFTLBatch(str)
            assert.equals("Nub", result[0][2].name)
            assert.equals(1,     result[0][2].classIndex)
            assert.equals(t,     result[0][2].dingedAt)
        end)
    end)

    describe("PlayerHistoryChunks", function()
        local SerPHChunks = WoWForeverRace.Serializer.SerializePlayerHistoryChunks
        local DeserPHBatch = WoWForeverRace.Serializer.DeserializePlayerHistoryBatch

        it("empty history serializes to no chunks", function()
            assert.same({}, SerPHChunks({}, {}, 20))
            assert.same({}, DeserPHBatch(""))
        end)

        it("round-trips player history", function()
            local t = 1000000000
            local playerHistory = {
                Alice = {classIndex = 3, levels = {[15] = t + 100, [16] = t + 200}},
                Bob = {classIndex = 1, levels = {[10] = t}},
            }

            local chunks = SerPHChunks(playerHistory, {"Alice", "Bob"}, 20)
            assert.equals(1, #chunks)

            local result = DeserPHBatch(chunks[1])
            assert.same(playerHistory, result)
        end)

        it("splits into chunks of at most chunkSize players, each independently parseable", function()
            local t = 1000000000
            local playerHistory = {
                Alice = {classIndex = 3, levels = {[15] = t + 100}},
                Bob = {classIndex = 1, levels = {[10] = t}},
                Carol = {classIndex = 5, levels = {[20] = t + 500}},
            }

            local chunks = SerPHChunks(playerHistory, {"Alice", "Bob", "Carol"}, 2)
            assert.equals(2, #chunks)

            -- merging all chunks yields the full data set
            local merged = {}
            for _, chunk in ipairs(chunks) do
                for name, hist in pairs(DeserPHBatch(chunk)) do
                    merged[name] = hist
                end
            end
            assert.same(playerHistory, merged)
        end)

        it("keeps valid levels and skips players without a ding", function()
            local t = 1000000000
            local playerHistory = {
                Alice = {classIndex = 3, levels = {[1] = t, [15] = t + 100, [100] = t}},
                Fresh = {classIndex = 1, levels = {[1] = t}},
            }

            local chunks = SerPHChunks(playerHistory, {"Alice", "Fresh"}, 20)
            assert.equals(1, #chunks)

            local result = DeserPHBatch(chunks[1])
            assert.same({Alice = {classIndex = 3, levels = {[15] = t + 100, [100] = t}}}, result)
        end)

        it("round-trips names containing a dash", function()
            local t = 1000000000
            local playerHistory = {
                ["Nub-Ville"] = {classIndex = 2, levels = {[12] = t}},
            }

            local chunks = SerPHChunks(playerHistory, {"Nub-Ville"}, 20)
            local result = DeserPHBatch(chunks[1])
            assert.same(playerHistory, result)
        end)

        it("floors fractional timestamps", function()
            local t = 1000000000
            local playerHistory = {
                Alice = {classIndex = 3, levels = {[15] = t + 100.9}},
            }

            local chunks = SerPHChunks(playerHistory, {"Alice"}, 20)
            local result = DeserPHBatch(chunks[1])
            assert.equals(t + 100, result["Alice"].levels[15])
        end)
    end)

    describe("PlayerInfoBatch", function()
        it("serializes and deserializes", function()
            local nub1 = {name = "Nubone", level = 5, dingedAt = time + 10, classIndex = 11}
            local nub2 = {name = "Nubtwo", level = 5, dingedAt = time - 10, classIndex = 1}
            local nub3 = {name = "Nubthree", level = 5, dingedAt = time, classIndex = 2}
            local nub4 = {name = "Nubfour", level = 11, dingedAt = time , classIndex = 11}
            local nub5 = {name = "Nubfive", level = 1, dingedAt = time, classIndex = 1}
            local batch = {nub1, nub2, nub3, nub4, nub5}

            local batchstr = SerPInfoBatch(batch)
            assert.same("0999999990$0511Nubone20$051Nubtwo0$052Nubthree10$1111Nubfour10$011Nubfive10$",
                    batchstr)
            assert.same(batch, DeserPInfoBatch(batchstr))
        end)

        it("dingedAt offset 0", function()
            local nub1 = {name = "Nubone", level = 5, dingedAt = time, classIndex = 11}
            local nub2 = {name = "Nubtwo", level = 5, dingedAt = time, classIndex = 1}
            local nub3 = {name = "Nubthree", level = 5, dingedAt = 0, classIndex = 2}
            local nub4 = {name = "Nubfour", level = 11, dingedAt = time, classIndex = 11}
            local nub5 = {name = "Nubfive", level = 1, dingedAt = time, classIndex = 1}
            local batch = {nub1, nub2, nub3, nub4, nub5}

            local batchstr = SerPInfoBatch(batch)
            assert.same("0000000000$0511Nubone1000000000$051Nubtwo1000000000$052Nubthree0$1111Nubfour1000000000$011Nubfive1000000000$",
                    batchstr)
            assert.same(batch, DeserPInfoBatch(batchstr))
        end)


        it("it more compact than AceSerializer", function()
            local nub1 = {name = "Nubone", level = 5, dingedAt = time, classIndex = 11}
            local batch = {nub1, nub1, nub1, nub1, nub1}

            local batchstr = SerPInfoBatch(batch)
            assert.same("1000000000$0511Nubone0$0511Nubone0$0511Nubone0$0511Nubone0$0511Nubone0$",
                    batchstr)
            assert.same(71, string.len(batchstr))

            assert.same(238, string.len(
                    AceSerializer:Serialize({
                        {nub1.name, nub1.level, nub1.dingedAt, nub1.classIndex},
                        {nub1.name, nub1.level, nub1.dingedAt, nub1.classIndex},
                        {nub1.name, nub1.level, nub1.dingedAt, nub1.classIndex},
                        {nub1.name, nub1.level, nub1.dingedAt, nub1.classIndex},
                        {nub1.name, nub1.level, nub1.dingedAt, nub1.classIndex},
                    })
            ))
        end)
    end)
end)
