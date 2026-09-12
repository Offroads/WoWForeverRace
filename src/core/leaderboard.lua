-- Addon global
local WoWForeverRace = _G.WoWForeverRace

--[[
Leaderboard is responsible for maintaining our leaderboard data based on data provided by other parts of the system
to us through the EventBus.
]]--
---@class WoWForeverRaceLeaderboard
---@field Config WoWForeverRaceConfig
---@field leaderboard table<string, table>
local WoWForeverRaceLeaderboard = {}
WoWForeverRaceLeaderboard.__index = WoWForeverRaceLeaderboard
WoWForeverRace.Leaderboard = WoWForeverRaceLeaderboard
setmetatable(WoWForeverRaceLeaderboard, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

-- Canonical ranking order: level desc, then dingedAt asc (nil sorts last), then name asc.
-- This is a strict total order so every client arrives at the exact same array,
-- which is required for ComputeHash to agree between clients with identical data.
local function ranksBefore(a, b)
    if a.level ~= b.level then
        return a.level > b.level
    end
    if a.dingedAt ~= b.dingedAt then
        if a.dingedAt == nil then return false end
        if b.dingedAt == nil then return true end
        return a.dingedAt < b.dingedAt
    end
    return a.name < b.name
end

-- Re-sorts a players array into the canonical order.
-- Used to heal DBs persisted by versions with different ordering rules.
function WoWForeverRaceLeaderboard.SortPlayers(players)
    table.sort(players, ranksBefore)
end

-- djb2 hash over all player entries in sorted order
-- fields are ':'-separated so different data can't concatenate to the same entry string
function WoWForeverRaceLeaderboard.ComputeHash(lbdb)
    local hash = 5381
    for _, player in ipairs(lbdb.players) do
        local entry = player.name .. ":" .. player.level .. ":" .. (player.classIndex or 0)
                .. ":" .. math.floor(player.dingedAt or 0)
        for i = 1, #entry do
            hash = ((hash * 33) + string.byte(entry, i)) % 2147483647
        end
    end
    return hash
end

function WoWForeverRaceLeaderboard.new(Config, leaderboardDB)
    local self = setmetatable({}, WoWForeverRaceLeaderboard)

    self.Config = Config
    self.lbdb = leaderboardDB

    return self
end

--[[
ProcessPlayerInfo updates the leaderboard and triggers notifications accordingly
]]--
function WoWForeverRaceLeaderboard:ProcessPlayerInfo(playerInfo)
    WoWForeverRace:DebugPrint("[LB] ProcessPlayerInfo: " .. playerInfo.name .. " lvl" .. playerInfo.level)

    -- ignore players below our lower bound threshold
    if playerInfo.level < self.lbdb.minLevel then
        WoWForeverRace:DebugPrint("Ignored player info < lvl" .. self.lbdb.minLevel)
        return
    end

    -- determine where to insert the player and his previous rank
    -- doing this O(n) isn't very efficient, but considering the small size of the leaderboard this is more than fine
    local insertAtRank = nil
    local previousRank = nil
    for rank, player in ipairs(self.lbdb.players) do
        -- find the place where to insert the new player using the canonical order,
        -- which ensures deterministic ordering across clients when multiple players
        -- share the same level and second-precision timestamp
        if insertAtRank == nil and ranksBefore(playerInfo, player) then
            insertAtRank = rank
        end

        -- find a possibly previous entry of this player
        if previousRank == nil and playerInfo.name == player.name then
            previousRank = rank
        end
    end

    local previousPlayer = previousRank ~= nil and self.lbdb.players[previousRank] or nil

    local isNew = previousRank == nil
    local isDing = not isNew and playerInfo.level > previousPlayer.level
    -- only accept an earlier dingedAt for the level we already have the player at;
    -- info about a lower level is stale and must not downgrade the entry, otherwise
    -- two clients holding different (level, dingedAt) snapshots swap states forever
    local isDingedAtUpdate = not isNew and not isDing
            and playerInfo.level == previousPlayer.level
            and playerInfo.dingedAt ~= nil
            and (previousPlayer.dingedAt == nil or playerInfo.dingedAt < previousPlayer.dingedAt)

    -- no change in rank; still fill in a previously unknown classIndex in place, so
    -- clients holding the same player with and without class info converge on the
    -- same hash instead of mismatching forever
    if not isNew and not isDing and not isDingedAtUpdate then
        if (previousPlayer.classIndex == nil or previousPlayer.classIndex == 0)
                and playerInfo.classIndex ~= nil and playerInfo.classIndex ~= 0 then
            previousPlayer.classIndex = playerInfo.classIndex
        end
        return
    end

    -- grow the leaderboard up until the max size
    if insertAtRank == nil and #self.lbdb.players < self.Config.MaxLeaderboardSize then
        insertAtRank = #self.lbdb.players + 1
    end

    -- not high enough for leaderboard
    if insertAtRank == nil then
        return
    end

    -- keep a known classIndex over an unknown incoming one
    local classIndex = playerInfo.classIndex
    if (classIndex == nil or classIndex == 0) and previousPlayer ~= nil
            and previousPlayer.classIndex ~= nil and previousPlayer.classIndex ~= 0 then
        classIndex = previousPlayer.classIndex
    end

    -- remove from previous rank
    if previousRank ~= nil then
        table.remove(self.lbdb.players, previousRank)
    end

    -- add at new rank
    table.insert(self.lbdb.players, insertAtRank, {
        name = playerInfo.name,
        level = playerInfo.level,
        dingedAt = playerInfo.dingedAt,
        classIndex = classIndex,
    })

    -- truncate when leaderboard reached max size
    while #self.lbdb.players > self.Config.MaxLeaderboardSize do
        table.remove(self.lbdb.players)
    end

    -- we only care about levels >= our bottom ranked on the leaderboard
    local lowestLevel = self.lbdb.players[#self.lbdb.players].level
    if #self.lbdb.players >= self.Config.MaxLeaderboardSize then
        self.lbdb.minLevel = lowestLevel
    end

    -- update highest level
    self.lbdb.highestLevel = math.max(self.lbdb.highestLevel, playerInfo.level)

    return insertAtRank, isNew or isDing, lowestLevel
end