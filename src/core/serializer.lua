-- Addon global
local WoWForeverRace = _G.WoWForeverRace

--[[
]]--
---@class WoWForeverRaceSerializer
---@field Config WoWForeverRaceConfig
local WoWForeverRaceSerializer = {}
WoWForeverRace.Serializer = WoWForeverRaceSerializer

function WoWForeverRaceSerializer.SerializePlayerInfo(playerInfo, dingedAtOffset)
    local level = math.floor(playerInfo.level)
    local classIndex = math.floor(playerInfo.classIndex or 0)
    local dingedAt = math.floor(playerInfo.dingedAt - (dingedAtOffset or 0))

    if level <= 99 then
        return string.format("%02d", level) .. classIndex .. playerInfo.name .. dingedAt
    end

    -- The legacy format has an unframed two-digit level. Use a tagged,
    -- delimiter-based record for later expansions without changing old data.
    return "!" .. level .. ":" .. classIndex .. ":" .. playerInfo.name .. ":" .. dingedAt
end

function WoWForeverRaceSerializer.DeserializePlayerInfo(str, dingedAtOffset)
    local level, classIndex, name, dingedAt = string.match(
            str, "^!(%d+):(%d+):([^:]+):(%-?%d+)")

    if level == nil then
        -- Legacy format: level is two digits, followed by a one- or two-digit class index.
        local lvlandClass
        lvlandClass, name, dingedAt = string.match(str, "^(%d+)([^%d-]+)(%-?%d+)")
        if lvlandClass == nil then return nil end
        level = string.sub(lvlandClass, 1, 2)
        classIndex = string.sub(lvlandClass, 3)
    end

    return {
        name = name,
        level = tonumber(level),
        classIndex = tonumber(classIndex) or 0,
        dingedAt = tonumber(dingedAt) + (dingedAtOffset or 0),
    }
end

function WoWForeverRaceSerializer.SerializePlayerInfoBatch(playerInfoBatch)
    if #playerInfoBatch == 0 then
        return ""
    end

    -- determine offset by finding lowest dingedAt
    local dingedAtOffset = nil
    for _, playerInfo in ipairs(playerInfoBatch) do
        if dingedAtOffset == nil then
            dingedAtOffset = playerInfo.dingedAt
        else
            dingedAtOffset = math.min(dingedAtOffset, playerInfo.dingedAt)
        end
    end

    dingedAtOffset = math.floor(dingedAtOffset)

    -- build payload
    -- zero pad offset (for tests with low timestamps)
    local res = string.sub("0000000000" .. dingedAtOffset, -10) .. "$"
    for _, playerInfo in ipairs(playerInfoBatch) do
        res = res .. WoWForeverRaceSerializer.SerializePlayerInfo(playerInfo, dingedAtOffset) .. "$"
    end

    return res
end

function WoWForeverRaceSerializer.DeserializePlayerInfoBatch(str)
    if str == "" then return {} end

    local dingedAtOffset = tonumber(string.sub(str, 1, 10))
    if dingedAtOffset == nil then return {} end
    str = string.sub(str, 12)

    local res = {}
    for substr in string.gmatch(str, "([^$]+$)") do
        local playerInfo = WoWForeverRaceSerializer.DeserializePlayerInfo(substr, dingedAtOffset)
        if playerInfo ~= nil then res[#res + 1] = playerInfo end
    end

    return res
end

-- Serializes firstToLevel into a compact string.
-- firstToLevel[classFilter][level] = {name, classIndex, dingedAt}
-- Legacy entry format: CF(2) LV(2) CI(2) name dingedAtDelta $. Extended entries use !CF:LV:CI:name:delta$
function WoWForeverRaceSerializer.SerializeFTLBatch(firstToLevel)
    local entries = {}
    for classFilter, levels in pairs(firstToLevel) do
        for level, record in pairs(levels) do
            if record.dingedAt ~= nil and level >= 2 and level <= 999
                    and classFilter >= 0 and classFilter <= 999 then
                entries[#entries + 1] = {
                    classFilter = classFilter,
                    level = level,
                    name = record.name,
                    classIndex = record.classIndex or 0,
                    dingedAt = record.dingedAt,
                }
            end
        end
    end

    if #entries == 0 then return "" end

    local offset = entries[1].dingedAt
    for _, e in ipairs(entries) do
        if e.dingedAt < offset then offset = e.dingedAt end
    end
    offset = math.floor(offset)

    local res = string.sub("0000000000" .. offset, -10) .. "$"
    for _, e in ipairs(entries) do
        local delta = math.floor(e.dingedAt) - offset
        if e.classFilter <= 99 and e.level <= 99 and e.classIndex <= 99 then
            res = res .. string.format("%02d", e.classFilter)
                    .. string.format("%02d", e.level)
                    .. string.format("%02d", e.classIndex)
                    .. e.name .. delta .. "$"
        else
            res = res .. "!" .. e.classFilter .. ":" .. e.level .. ":"
                    .. e.classIndex .. ":" .. e.name .. ":" .. delta .. "$"
        end
    end

    return res
end

-- Serializes playerHistory for the given player names into chunk strings of at most
-- chunkSize players each. Each chunk is independently parseable (own offset header)
-- so partial delivery of a multi-chunk sync still merges cleanly.
-- Chunk format: offset(10) $ record $ record $ ...
-- Record format: classIndex(2) name plus legacy :level(2)delta or extended :!level,delta groups.
-- playerHistory[name] = {classIndex = ci, levels = {[level] = dingedAt}}
function WoWForeverRaceSerializer.SerializePlayerHistoryChunks(playerHistory, names, chunkSize)
    local records = {}
    for _, name in ipairs(names) do
        local hist = playerHistory[name]
        if hist ~= nil and hist.levels ~= nil then
            local levels = {}
            for level, dingedAt in pairs(hist.levels) do
                if level >= 2 and level <= 999 and dingedAt ~= nil then
                    levels[#levels + 1] = {level = level, dingedAt = math.floor(dingedAt)}
                end
            end
            if #levels > 0 then
                table.sort(levels, function(a, b) return a.level < b.level end)
                records[#records + 1] = {name = name, classIndex = hist.classIndex or 0, levels = levels}
            end
        end
    end

    local chunks = {}
    for chunkStart = 1, #records, chunkSize do
        local chunkEnd = math.min(chunkStart + chunkSize - 1, #records)

        local offset = nil
        for i = chunkStart, chunkEnd do
            for _, entry in ipairs(records[i].levels) do
                if offset == nil or entry.dingedAt < offset then offset = entry.dingedAt end
            end
        end

        local res = string.sub("0000000000" .. offset, -10) .. "$"
        for i = chunkStart, chunkEnd do
            local record = records[i]
            local str = string.format("%02d", record.classIndex) .. record.name
            for _, entry in ipairs(record.levels) do
                local delta = entry.dingedAt - offset
                if entry.level <= 99 then
                    str = str .. ":" .. string.format("%02d", entry.level) .. delta
                else
                    str = str .. ":!" .. entry.level .. "," .. delta
                end
            end
            res = res .. str .. "$"
        end
        chunks[#chunks + 1] = res
    end

    return chunks
end

-- Deserializes a single playerHistory chunk produced by SerializePlayerHistoryChunks.
-- Returns {[name] = {classIndex = ci, levels = {[level] = dingedAt}}}.
function WoWForeverRaceSerializer.DeserializePlayerHistoryBatch(str)
    if str == "" then return {} end

    local offset = tonumber(string.sub(str, 1, 10))
    if offset == nil then return {} end
    str = string.sub(str, 12)

    local batch = {}
    for substr in string.gmatch(str, "([^$]+)") do
        local ci, name, levelstr = string.match(substr, "^(%d%d)([^:]+)(:.+)$")
        if ci and name and levelstr then
            local levels = {}
            local count = 0
            local function addLevel(level, delta)
                local dingedAt = tonumber(delta) + offset
                if level >= 2 and (levels[level] == nil or dingedAt < levels[level]) then
                    if levels[level] == nil then count = count + 1 end
                    levels[level] = dingedAt
                end
            end
            for lv, delta in string.gmatch(levelstr, ":(%d%d)(%d+)") do
                addLevel(tonumber(lv), delta)
            end
            for lv, delta in string.gmatch(levelstr, ":!(%d+),(%d+)") do
                addLevel(tonumber(lv), delta)
            end
            if count > 0 then
                batch[name] = {classIndex = tonumber(ci), levels = levels}
            end
        end
    end

    return batch
end

-- Deserializes a firstToLevel batch string produced by SerializeFTLBatch.
-- When duplicate (classFilter, level) entries appear, keeps the one with the earlier dingedAt.
function WoWForeverRaceSerializer.DeserializeFTLBatch(str)
    if str == "" then return {} end
    local offset = tonumber(string.sub(str, 1, 10))
    if offset == nil then return {} end
    str = string.sub(str, 12)

    local ftldb = {}
    for substr in string.gmatch(str, "([^$]+)") do
        local cf, lv, ci, name, delta
        if string.sub(substr, 1, 1) == "!" then
            cf, lv, ci, name, delta = string.match(substr, "^!(%d+):(%d+):(%d+):([^:]+):(%-?%d+)$")
        else
            cf, lv, ci, name, delta = string.match(substr, "^(%d%d)(%d%d)(%d%d)([^%d-]+)(%-?%d+)$")
        end
        if cf and lv and ci and name and delta then
            local classFilter = tonumber(cf)
            local level = tonumber(lv)
            local classIndex = tonumber(ci)
            local dingedAt = tonumber(delta) + offset
            if level >= 2 then
                if ftldb[classFilter] == nil then ftldb[classFilter] = {} end
                local existing = ftldb[classFilter][level]
                if existing == nil or dingedAt < existing.dingedAt
                        or (dingedAt == existing.dingedAt and name < existing.name) then
                    ftldb[classFilter][level] = {
                        name = name,
                        classIndex = classIndex,
                        dingedAt = dingedAt,
                    }
                end
            end
        end
    end

    return ftldb
end