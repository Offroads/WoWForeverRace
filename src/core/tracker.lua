-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- WoW API
local C_Timer, IsInGuild, math = _G.C_Timer, _G.IsInGuild, _G.math

--[[
Tracker is responsible for maintaining our leaderboard data based on data provided by other parts of the system
to us through the EventBus.
]]--
---@class WoWForeverRaceTracker
---@field DB table<string, table>
---@field Config WoWForeverRaceConfig
---@field Core WoWForeverRaceCore
---@field EventBus WoWForeverRaceEventBus
---@field Network WoWForeverRaceNetwork
---@field lbGlobal WoWForeverRaceLeaderboard
---@field lbPerClass table<string, WoWForeverRaceLeaderboard>
local WoWForeverRaceTracker = {}

-- bounds for remote timestamps, see ProcessPlayerInfo
local MIN_DINGED_AT = 946684800  -- 2000-01-01, long before any Classic realm opened
local MAX_CLOCK_SKEW = 600       -- seconds a peer's clock may run ahead of ours

local function leaderboardClassIndexes(config)
    local indexes = {0}
    for _, classIndex in ipairs(config.MopClassIndexes) do
        indexes[#indexes + 1] = classIndex
    end
    return indexes
end
WoWForeverRaceTracker.__index = WoWForeverRaceTracker
WoWForeverRace.Tracker = WoWForeverRaceTracker
setmetatable(WoWForeverRaceTracker, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function WoWForeverRaceTracker.new(Config, Core, DB, EventBus, Network)
    local self = setmetatable({}, WoWForeverRaceTracker)

    self.Config = Config
    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus
    self.Network = Network

    self.pendingRequesters = nil   -- non-nil only during active discovery window
    self.pendingDings = {}
    self.dingPushPending = false

    self.launchPurged = false      -- true once PurgePreLaunchData ran after the realm launch

    self:ReinitLeaderboards()
    self:NormalizeDB()
    self:PurgePreLaunchData()

    -- subscribe to network events
    EventBus:RegisterCallback(self.Config.Network.Events.PlayerInfoBatch, self, self.OnNetPlayerInfoBatch)
    EventBus:RegisterCallback(self.Config.Network.Events.DataAvailable, self, self.OnNetDataAvailable)
    EventBus:RegisterCallback(self.Config.Network.Events.DataRequest, self, self.OnNetDataRequest)
    -- subscribe to local events
    EventBus:RegisterCallback(self.Config.Events.SlashWhoResult, self, self.OnSlashWhoResult)
    EventBus:RegisterCallback(self.Config.Events.SyncResult, self, self.OnSyncResult)
    EventBus:RegisterCallback(self.Config.Events.FTLSyncResult, self, self.OnFTLSyncResult)
    EventBus:RegisterCallback(self.Config.Events.PHSyncResult, self, self.OnPHSyncResult)
    EventBus:RegisterCallback(self.Config.Events.ScanFinished, self, self.OnScanFinished)

    return self
end

function WoWForeverRaceTracker:ReinitLeaderboards()
    self.lbGlobal = WoWForeverRace.Leaderboard(self.Config, self.DB.factionrealm.leaderboard[0])
    self.lbPerClass = {}
    for _, classIndex in ipairs(self.Config.MopClassIndexes) do
        self.lbPerClass[classIndex] = WoWForeverRace.Leaderboard(self.Config, self.DB.factionrealm.leaderboard[classIndex])
    end
end

-- Heals data persisted by older versions: floors fractional timestamps and re-sorts
-- every leaderboard into the canonical order. Stored order predating the deterministic
-- sort otherwise causes permanent hash mismatches between clients holding identical data.
function WoWForeverRaceTracker:NormalizeDB()
    for _, classIndex in ipairs(leaderboardClassIndexes(self.Config)) do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        if lb then
            for _, player in ipairs(lb.players) do
                if player.dingedAt ~= nil then
                    player.dingedAt = math.floor(player.dingedAt)
                end
            end
            WoWForeverRace.Leaderboard.SortPlayers(lb.players)
        end
    end

    local ftl = self.DB.factionrealm.firstToLevel
    if ftl then
        for _, levels in pairs(ftl) do
            for _, record in pairs(levels) do
                if record.dingedAt ~= nil then
                    record.dingedAt = math.floor(record.dingedAt)
                end
            end
        end
    end

    self:PrunePlayerHistory()
end

-- The released race starts from fresh leaderboards: once the realm launch has passed, drops the
-- race data collected before it (beta) and the buddies met before it from this faction-realm.
-- Settings and whatever was collected since the launch stay. Runs once per session, at login or when the launch passes.
function WoWForeverRaceTracker:PurgePreLaunchData()
    if self.launchPurged or not self.Core:HasLaunched() then
        return
    end
    self.launchPurged = true

    local db = self.DB.factionrealm
    local purged = false

    for _, classIndex in ipairs(leaderboardClassIndexes(self.Config)) do
        local lb = db.leaderboard[classIndex]
        if lb then
            local highestLevel = 1
            local removed = false
            for i = #lb.players, 1, -1 do
                if self.Core:PredatesLaunch(lb.players[i].dingedAt) then
                    table.remove(lb.players, i)
                    removed = true
                else
                    highestLevel = math.max(highestLevel, lb.players[i].level)
                end
            end
            if removed then
                -- no longer full, so every level counts again
                lb.minLevel = 2
                lb.highestLevel = highestLevel
                purged = true
            end
        end
    end

    local raceStartedAt = nil
    for classFilter, levels in pairs(db.firstToLevel or {}) do
        for level, record in pairs(levels) do
            if self.Core:PredatesLaunch(record.dingedAt) then
                levels[level] = nil
                purged = true
            elseif classFilter == 0 and record.dingedAt ~= nil
                    and (raceStartedAt == nil or record.dingedAt < raceStartedAt) then
                raceStartedAt = record.dingedAt
            end
        end
    end

    for name, hist in pairs(db.playerHistory or {}) do
        for level, dingedAt in pairs(hist.levels or {}) do
            if self.Core:PredatesLaunch(dingedAt) then
                hist.levels[level] = nil
                purged = true
            end
        end
        if hist.levels == nil or next(hist.levels) == nil then
            db.playerHistory[name] = nil
        end
    end

    -- beta characters don't exist on the released realm, so neither do the buddies met there
    local buddiesPurged = false
    for name, buddy in pairs(db.buddies or {}) do
        if buddy.lastSeen == nil or self.Core:PredatesLaunch(buddy.lastSeen) then
            db.buddies[name] = nil
            buddiesPurged = true
        end
    end
    if buddiesPurged then
        WoWForeverRace:DebugPrint("Dropped buddies from before the realm launch")
        self.EventBus:PublishEvent(self.Config.Events.BuddyUpdate)
    end

    if self.Core:PredatesLaunch(db.raceStartedAt) then
        db.raceStartedAt = raceStartedAt
    end
    if self.Core:PredatesLaunch(db.realmOpenedAt) then
        db.realmOpenedAt = self.Core:LaunchTime()
        purged = true
    end

    if purged then
        WoWForeverRace:DebugPrint("Dropped race data from before the realm launch")
        -- a race finished on the beta says nothing about the released one
        db.finished = false
        self.EventBus:PublishEvent(self.Config.Events.RefreshGUI)
    end
end

-- A leaderboard is final when it's full and its lowest member has reached max
-- level: from then on, players absent from it can no longer enter the race for it.
local function isLeaderboardFinal(lb, config)
    return lb ~= nil and #lb.players >= config.MaxLeaderboardSize and lb.minLevel >= config.MaxLevel
end

-- playerHistory records every character a scan ever saw and would grow unbounded
-- (thousands of players on a busy realm). While the race is live everyone is kept -
-- a player who temporarily drops off a leaderboard may re-enter it and would lose
-- their history otherwise. Once the leaderboard a player competes on is final
-- (full at max level), or the race is finished, non-members are dropped.
-- Our own history is always kept.
function WoWForeverRaceTracker:PrunePlayerHistory()
    local playerHistory = self.DB.factionrealm.playerHistory
    if playerHistory == nil then return end

    local keep = {}
    for _, classIndex in ipairs(leaderboardClassIndexes(self.Config)) do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        if lb then
            for _, player in ipairs(lb.players) do
                keep[player.name] = true
            end
        end
    end
    keep[self.Core:Me()] = true

    local raceFinished = self.DB.factionrealm.finished
    local globalFinal = isLeaderboardFinal(self.DB.factionrealm.leaderboard[0], self.Config)

    for name, hist in pairs(playerHistory) do
        if not keep[name] then
            -- players with a known class compete on their class leaderboard;
            -- unknown-class players are gated on the global leaderboard instead
            local classIndex = hist ~= nil and hist.classIndex or nil
            local boardFinal
            if self.Config:IsValidClassIndex(classIndex) then
                boardFinal = isLeaderboardFinal(self.DB.factionrealm.leaderboard[classIndex], self.Config)
            else
                boardFinal = globalFinal
            end

            if raceFinished or boardFinal then
                playerHistory[name] = nil
            end
        end
    end
end

function WoWForeverRaceTracker:OnScanFinished(endofrace)
    -- the scanner believes the race may be over; verify against the actual boards
    if endofrace then
        self:CheckRaceFinished()
    end
end

function WoWForeverRaceTracker:CheckRaceFinished()
    -- The race isn't over until every playable class has filled its
    -- leaderboard at max level.
    for _, classIndex in ipairs(self.Config.MopClassIndexes) do
        if not isLeaderboardFinal(self.DB.factionrealm.leaderboard[classIndex], self.Config) then
            return
        end
    end

    self:RaceFinished()
end

function WoWForeverRaceTracker:RaceFinished()
    if not self.DB.factionrealm.finished then
        self.DB.factionrealm.finished = true

        self.EventBus:PublishEvent(self.Config.Events.RaceFinished)
    end
end

-- payload = {batchstr, isRebroadcast, classIndex}; only the batch is needed here,
-- the class index of the batch is implied by each player's own classIndex
function WoWForeverRaceTracker:OnNetPlayerInfoBatch(payload)
    if not self.DB.profile.options.networking then return end
    if type(payload) ~= "table" then return end

    local batch = WoWForeverRace.Serializer.DeserializePlayerInfoBatch(payload[1])
    self:ProcessPlayerInfoBatch(batch)
end

function WoWForeverRaceTracker:OnSlashWhoResult(playerInfoBatch)
    local changed = {}
    for _, playerInfo in ipairs(playerInfoBatch) do
        local normalizedInfo, isChanged = self:ProcessPlayerInfo(playerInfo)
        if isChanged then
            changed[#changed + 1] = normalizedInfo
        end
    end
    if #changed > 0 then
        self:ScheduleDingPush(changed)
    end
end

function WoWForeverRaceTracker:OnSyncResult(playerInfoBatch)
    self:ProcessPlayerInfoBatch(playerInfoBatch)
end

function WoWForeverRaceTracker:ScheduleDingPush(changedPlayers)
    if not self.DB.profile.options.networking then return end
    if self.DB.factionrealm.finished then return end

    -- YELL immediately so zone players get real-time updates
    local batchstr = WoWForeverRace.Serializer.SerializePlayerInfoBatch(changedPlayers)
    self.Network:SendObject(self.Config.Network.Events.PlayerInfoBatch, {batchstr, false, 0}, "YELL")

    -- accumulate into pending set (keyed by name to deduplicate across rapid scans)
    for _, p in ipairs(changedPlayers) do
        self.pendingDings[p.name] = p
    end

    if not self.dingPushPending then
        self.dingPushPending = true
        local _self = self
        C_Timer.After(self.Config.DingPushDelay, function()
            _self:FlushDingPush()
        end)
    end
end

function WoWForeverRaceTracker:FlushDingPush()
    self.dingPushPending = false

    local players = {}
    for _, p in pairs(self.pendingDings) do
        players[#players + 1] = p
    end
    self.pendingDings = {}

    if #players == 0 then return end

    local batchstr = WoWForeverRace.Serializer.SerializePlayerInfoBatch(players)
    local payload = {batchstr, false, 0}

    if IsInGuild() then
        self.Network:SendObject(self.Config.Network.Events.PlayerInfoBatch, payload, "GUILD")
    end

    -- whisper a random sample of buddies (capped at BuddyPingBatchSize)
    local names = {}
    for name, _ in pairs(self.DB.factionrealm.buddies) do
        names[#names + 1] = name
    end
    local batchSize = self.Config.BuddyPingBatchSize
    if #names > batchSize then
        for i = 1, batchSize do
            local j = math.random(i, #names)
            names[i], names[j] = names[j], names[i]
        end
        for i = batchSize + 1, #names do names[i] = nil end
    end
    for _, name in ipairs(names) do
        self.Network:SendObject(self.Config.Network.Events.PlayerInfoBatch, payload, "WHISPER", name)
    end
end

function WoWForeverRaceTracker:ProcessPlayerInfoBatch(playerInfoBatch)
    for _, playerInfo in ipairs(playerInfoBatch) do
        self:ProcessPlayerInfo(playerInfo)
    end
end

-- djb2 chain over all leaderboards in fixed order (global=0, class 1-12).
-- Any difference in any leaderboard produces a different hash.
function WoWForeverRaceTracker:ComputeFullHash()
    local hash = 5381
    for _, classIndex in ipairs(leaderboardClassIndexes(self.Config)) do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        if lb then
            hash = ((hash * 33) + WoWForeverRace.Leaderboard.ComputeHash(lb)) % 2147483647
        end
    end
    return hash
end

-- Returns {[classIndex]=true} for each leaderboard where requester's hash differs from ours.
-- Returns nil if requesterClassHashes is not a table (old client: treat as needs everything).
-- classHashes is a 1-based array: index i+1 corresponds to leaderboard[i].
function WoWForeverRaceTracker:ComputeNeedSet(requesterClassHashes)
    if type(requesterClassHashes) ~= "table" then
        return nil
    end
    local needSet = {}
    for _, classIndex in ipairs(leaderboardClassIndexes(self.Config)) do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        local myHash = lb and WoWForeverRace.Leaderboard.ComputeHash(lb) or 0
        -- nil: the requester's build does not track this class (other client or
        -- older build), it would discard the leaderboard anyway
        local theirHash = requesterClassHashes[classIndex + 1]
        if theirHash ~= nil and myHash ~= theirHash then
            needSet[classIndex] = true
        end
    end
    return needSet
end

function WoWForeverRaceTracker:InitDiscoveryTicker()
    local jitter = math.random(0, self.Config.BroadcastInterval - 1)
    C_Timer.After(jitter, function()
        self:SendDiscoveryBeacon()
        C_Timer.NewTicker(self.Config.BroadcastInterval, function()
            self:SendDiscoveryBeacon()
        end)
    end)
end

-- Collect global + class-unique players into batches ready for sending.
-- needSet: optional {[classIndex]=true} filter; nil means include all.
-- Returns nil if no batches would be produced.
function WoWForeverRaceTracker:CollectBatches(needSet)
    local globalPlayers = self.DB.factionrealm.leaderboard[0].players
    if #globalPlayers == 0 then return nil end

    local inGlobal = {}
    for _, p in ipairs(globalPlayers) do inGlobal[p.name] = true end

    local batches = {}
    if needSet == nil or needSet[0] then
        batches[#batches + 1] = { players = globalPlayers, classIndex = 0 }
    end

    for _, classIndex in ipairs(self.Config.MopClassIndexes) do
        if needSet == nil or needSet[classIndex] then
            local lb = self.DB.factionrealm.leaderboard[classIndex]
            if lb and #lb.players > 0 then
                local unique = {}
                for _, p in ipairs(lb.players) do
                    if not inGlobal[p.name] then unique[#unique + 1] = p end
                end
                if #unique > 0 then
                    batches[#batches + 1] = { players = unique, classIndex = classIndex }
                end
            end
        end
    end

    return #batches > 0 and batches or nil
end

-- Send collected batches to a channel.
-- YELL: chunked with delays to stay under single-message size.
-- WHISPER/GUILD/GROUP: full batches in one message each.
function WoWForeverRaceTracker:SendBatches(batches, channel, target)
    if channel == "YELL" then
        local chunkSize = self.Config.YellChunkSize
        local delay = 0
        for _, batchInfo in ipairs(batches) do
            local batchPlayers = batchInfo.players
            local classIdx = batchInfo.classIndex
            for i = 0, math.ceil(#batchPlayers / chunkSize) - 1 do
                local chunk = {}
                for j = i * chunkSize + 1, math.min((i + 1) * chunkSize, #batchPlayers) do
                    chunk[#chunk + 1] = batchPlayers[j]
                end
                C_Timer.After(delay, function()
                    local batch = WoWForeverRace.Serializer.SerializePlayerInfoBatch(chunk)
                    self.Network:SendObject(self.Config.Network.Events.PlayerInfoBatch, { batch, false, classIdx }, "YELL")
                end)
                delay = delay + self.Config.YellChunkDelay
            end
        end
    else
        for _, batchInfo in ipairs(batches) do
            local batch = WoWForeverRace.Serializer.SerializePlayerInfoBatch(batchInfo.players)
            self.Network:SendObject(self.Config.Network.Events.PlayerInfoBatch, { batch, false, batchInfo.classIndex }, channel, target)
        end
    end
end

-- Every BroadcastInterval seconds: announce our hash to YELL and open a
-- 5-second window for others to request our data.
-- Guild sync is handled separately by Sync:InitGuildTicker().
function WoWForeverRaceTracker:SendDiscoveryBeacon()
    -- the ticker doubles as the clock that notices the realm launch passing mid-session
    self:PurgePreLaunchData()
    if self.DB.factionrealm.finished then return end
    if not self.DB.profile.options.networking then return end
    if #self.DB.factionrealm.leaderboard[0].players == 0 then return end

    local fullHash = self:ComputeFullHash()

    -- open discovery window then announce hash to YELL
    self.pendingRequesters = {}
    self.Network:SendObject(self.Config.Network.Events.DataAvailable, fullHash, "YELL")

    local _self = self
    C_Timer.After(self.Config.RequestSyncWait, function()
        _self:ProcessDiscoveryResponses()
    end)
end

-- Called after the discovery window closes. Whispers data to a single
-- requester, or yells to the zone if multiple players need it.
-- Only sends leaderboards that each requester's hashes indicate they're missing.
function WoWForeverRaceTracker:ProcessDiscoveryResponses()
    local requesters = self.pendingRequesters
    self.pendingRequesters = nil

    if not requesters or #requesters == 0 then
        WoWForeverRace:DebugPrint("Discovery: no one needs data")
        return
    end

    WoWForeverRace:DebugPrint("Discovery: " .. #requesters .. " requester(s)")

    if #requesters == 1 then
        local needSet = self:ComputeNeedSet(requesters[1].classHashes)
        if needSet then
            local classes = {}
            for ci in pairs(needSet) do classes[#classes + 1] = ci end
            WoWForeverRace:AddHashLog(requesters[1].name, ">", classes, false)
        end
        local batches = self:CollectBatches(needSet)
        if batches then
            self:SendBatches(batches, "WHISPER", requesters[1].name)
        end
    else
        -- build the union of what all requesters need; fall back to nil (send all) for old clients
        local unionNeedSet = {}
        for _, req in ipairs(requesters) do
            if type(req.classHashes) ~= "table" then
                unionNeedSet = nil
                break
            end
            local needSet = self:ComputeNeedSet(req.classHashes)
            for classIndex, _ in pairs(needSet) do
                unionNeedSet[classIndex] = true
            end
        end
        if unionNeedSet then
            local classes = {}
            for ci in pairs(unionNeedSet) do classes[#classes + 1] = ci end
            WoWForeverRace:AddHashLog("(zone yell)", ">", classes, false)
        end
        local batches = self:CollectBatches(unionNeedSet)
        if batches then
            self:SendBatches(batches, "YELL")
        end
    end
end

-- Received when another player announces their leaderboard hash.
-- If ours differs, whisper back a data request with our per-class hashes
-- so the responder can skip sending leaderboards we already agree on.
function WoWForeverRaceTracker:OnNetDataAvailable(hash, sender)
    if not self.DB.profile.options.networking then return end

    local myHash = self:ComputeFullHash()
    if myHash == hash then return end

    -- send per-class hashes as 1-based array (index i+1 = leaderboard[i])
    local classHashes = {}
    for _, classIndex in ipairs(leaderboardClassIndexes(self.Config)) do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        classHashes[classIndex + 1] = lb and WoWForeverRace.Leaderboard.ComputeHash(lb) or 0
    end

    WoWForeverRace:DebugPrint("DataAvail from " .. sender .. ": hash differs, requesting")
    self.Network:SendObject(self.Config.Network.Events.DataRequest, classHashes, "WHISPER", sender)
end

-- Received when someone wants our data. Only accepted during the active
-- discovery window opened by SendDiscoveryBeacon.
function WoWForeverRaceTracker:OnNetDataRequest(classHashes, sender)
    if not self.DB.profile.options.networking then return end
    if self.pendingRequesters == nil then return end
    for _, req in ipairs(self.pendingRequesters) do
        if req.name == sender then return end
    end
    WoWForeverRace:DebugPrint("DataRequest from " .. sender)
    table.insert(self.pendingRequesters, { name = sender, classHashes = classHashes })
end

--[[
ProcessPlayerInfo updates the leaderboard and triggers notifications accordingly
]]--
function WoWForeverRaceTracker:ProcessPlayerInfo(playerInfo)
    -- beta records must not hold a slot against the first dings after the launch
    -- (same in OnPHSyncResult and OnFTLSyncResult)
    self:PurgePreLaunchData()

    -- don't process more player info when we know the race has finished
    if self.DB.factionrealm.finished then
        return
    end

    if playerInfo.dingedAt == nil then
        playerInfo.dingedAt = self.Core:Now()
    end
    -- a timestamp before the year 2000 (Classic realms opened in 2019) or in the
    -- future is forged or corrupt: "earliest wins" everywhere downstream, so a
    -- dingedAt of 0 would otherwise take rank 1, every pioneer slot and the race start
    local now = self.Core:Now()
    if type(playerInfo.dingedAt) ~= "number" or playerInfo.dingedAt ~= playerInfo.dingedAt
            or playerInfo.dingedAt < MIN_DINGED_AT or playerInfo.dingedAt > now + MAX_CLOCK_SKEW then
        WoWForeverRace:DebugPrint("Ignored player info with invalid dingedAt: " .. tostring(playerInfo.dingedAt))
        return
    end
    if self.Core:PredatesLaunch(playerInfo.dingedAt) then
        WoWForeverRace:DebugPrint("Ignored player info from before the realm launch: " .. tostring(playerInfo.dingedAt))
        return
    end
    -- keep timestamps integral: the wire format truncates to whole seconds, so a
    -- fractional local value would hash differently from its synced copy
    playerInfo.dingedAt = math.floor(playerInfo.dingedAt)

    if playerInfo.classIndex == nil and playerInfo.class ~= nil then
        playerInfo.classIndex = self.Core:ClassIndex(playerInfo.class)
        playerInfo.class = nil
    end

    -- remote data is untrusted: a nameless entry would corrupt the leaderboard and
    -- history tables, and a forged level above the configured max would permanently
    -- outrank every real player and falsely finish the race
    if type(playerInfo.name) ~= "string" or playerInfo.name == "" then
        WoWForeverRace:DebugPrint("Ignored player info without a name")
        return
    end
    -- the level must also be integral: peers receive it floored, and a fractional
    -- local value would hash differently from theirs forever
    if type(playerInfo.level) ~= "number" or playerInfo.level < 1
            or playerInfo.level > self.Config.MaxLevel or playerInfo.level % 1 ~= 0 then
        WoWForeverRace:DebugPrint("Ignored player info with invalid level: " .. tostring(playerInfo.level))
        return
    end

    WoWForeverRace:DebugPrint("[T] ProcessPlayerInfo: [" .. tostring(playerInfo.classIndex) .. "] "
            .. playerInfo.name .. " lvl" .. playerInfo.level)

    local globalRank, globalIsChanged = self.lbGlobal:ProcessPlayerInfo(playerInfo)
    local classRank, classIsChanged, classLowestLevel = nil, nil
    -- classIndex 0 (unknown class) has no class leaderboard
    if self.Config:IsValidClassIndex(playerInfo.classIndex) and self.lbPerClass[playerInfo.classIndex] ~= nil then
        classRank, classIsChanged, classLowestLevel = self.lbPerClass[playerInfo.classIndex]:ProcessPlayerInfo(playerInfo)
    end

    -- update pioneer records for every detected player
    self:UpdatePioneers(playerInfo)
    self:UpdatePlayerHistory(playerInfo)

    -- publish internal event
    if globalIsChanged or classIsChanged then
        self.EventBus:PublishEvent(self.Config.Events.Ding, playerInfo, globalRank, classRank)
    end

    -- a class leaderboard can only become final when its lowest ranked
    -- member reaches max level, so that's the moment to check the race
    if classLowestLevel == self.Config.MaxLevel then
        self:CheckRaceFinished()
    end

    -- return normalized playerinfo and boolean if anything changed
    return playerInfo, globalIsChanged or classIsChanged
end

-- Records this player's dingedAt in playerHistory for future per-character level breakdown.
function WoWForeverRaceTracker:UpdatePlayerHistory(playerInfo)
    local dingedAt = playerInfo.dingedAt
    if dingedAt == nil then return end

    local db = self.DB.factionrealm
    local name = playerInfo.name
    local level = playerInfo.level
    local classIndex = playerInfo.classIndex

    if db.playerHistory[name] == nil then
        db.playerHistory[name] = {classIndex = classIndex, levels = {}}
    end

    local hist = db.playerHistory[name]
    if hist.classIndex == nil and classIndex ~= nil then
        hist.classIndex = classIndex
    end
    -- only keep the earliest detection at each level
    if hist.levels[level] == nil or dingedAt < hist.levels[level] then
        hist.levels[level] = dingedAt
    end
end

-- Applies a record to the firstToLevel slot levels[level], keeping the earliest
-- dingedAt with name as deterministic tiebreaker. On otherwise identical records
-- a missing classIndex is filled in, so clients holding the same record with and
-- without class info converge on the same hash instead of mismatching forever.
-- Returns true when the slot was replaced.
local function mergeFTLRecord(levels, level, name, classIndex, dingedAt)
    local existing = levels[level]
    if existing == nil or dingedAt < existing.dingedAt
            or (dingedAt == existing.dingedAt and name < existing.name) then
        levels[level] = {name = name, classIndex = classIndex, dingedAt = dingedAt}
        return true
    end
    if dingedAt == existing.dingedAt and name == existing.name
            and (existing.classIndex == nil or existing.classIndex == 0)
            and classIndex ~= nil and classIndex ~= 0 then
        existing.classIndex = classIndex
    end
    return false
end

-- Updates firstToLevel (overall and per-class) and raceStartedAt for every detected player.
function WoWForeverRaceTracker:UpdatePioneers(playerInfo)
    local dingedAt = playerInfo.dingedAt
    if dingedAt == nil then return end

    local db = self.DB.factionrealm
    local name = playerInfo.name
    local level = playerInfo.level
    local classIndex = playerInfo.classIndex

    -- level 1 is not a ding, and levels outside the configured range are ignored
    if level < 2 or level > self.Config.MaxLevel then return end

    -- track the earliest detection as race start
    if db.raceStartedAt == nil or dingedAt < db.raceStartedAt then
        db.raceStartedAt = dingedAt
    end

    -- overall (classFilter 0)
    if db.firstToLevel[0] == nil then db.firstToLevel[0] = {} end
    mergeFTLRecord(db.firstToLevel[0], level, name, classIndex, dingedAt)

    -- per-class
    if self.Config:IsValidClassIndex(classIndex) then
        if db.firstToLevel[classIndex] == nil then db.firstToLevel[classIndex] = {} end
        mergeFTLRecord(db.firstToLevel[classIndex], level, name, classIndex, dingedAt)
    end
end

-- Merges a received playerHistory chunk, keeping the earliest dingedAt per
-- (player, level) and filling in a missing classIndex - deterministic and
-- monotonic, so repeated exchanges converge instead of ping-ponging.
-- batch = {[name] = {classIndex = ci, levels = {[level] = dingedAt}}}
function WoWForeverRaceTracker:OnPHSyncResult(batch)
    self:PurgePreLaunchData()
    local playerHistory = self.DB.factionrealm.playerHistory

    for name, remote in pairs(batch) do
        if type(remote) == "table" and type(remote.levels) == "table" then
            if playerHistory[name] == nil then
                playerHistory[name] = {classIndex = remote.classIndex, levels = {}}
            end
            local hist = playerHistory[name]

            if (hist.classIndex == nil or hist.classIndex == 0)
                    and remote.classIndex ~= nil and remote.classIndex ~= 0 then
                hist.classIndex = remote.classIndex
            end

            for level, dingedAt in pairs(remote.levels) do
                if type(level) == "number" and level >= 2 and level <= self.Config.MaxLevel
                        and type(dingedAt) == "number" and not self.Core:PredatesLaunch(dingedAt) then
                    if hist.levels[level] == nil or dingedAt < hist.levels[level] then
                        hist.levels[level] = math.floor(dingedAt)
                    end
                end
            end
        end
    end
end

-- Merges received firstToLevel data from a sync partner, keeping the earliest record per slot.
-- Also merges realmOpenedAt, keeping the earliest (closest to actual realm launch); once the
-- launch has passed, a value from before it is ignored.
function WoWForeverRaceTracker:OnFTLSyncResult(ftldb, remoteRealmOpenedAt)
    self:PurgePreLaunchData()
    local db = self.DB.factionrealm

    if remoteRealmOpenedAt and not self.Core:PredatesLaunch(remoteRealmOpenedAt)
            and (db.realmOpenedAt == nil or remoteRealmOpenedAt < db.realmOpenedAt) then
        db.realmOpenedAt = remoteRealmOpenedAt
    end

    for classFilter, levels in pairs(ftldb) do
        if classFilter == 0 or self.Config:IsValidClassIndex(classFilter) then
            if db.firstToLevel[classFilter] == nil then
                db.firstToLevel[classFilter] = {}
            end
            for level, record in pairs(levels) do
                -- only merge records that fit the wire format; remote data is untrusted
                if type(level) == "number" and level >= 2 and level <= self.Config.MaxLevel
                        and record.name ~= nil and record.dingedAt ~= nil
                        and not self.Core:PredatesLaunch(record.dingedAt) then
                    local merged = mergeFTLRecord(db.firstToLevel[classFilter], level,
                            record.name, record.classIndex, record.dingedAt)
                    if merged and (db.raceStartedAt == nil or record.dingedAt < db.raceStartedAt) then
                        db.raceStartedAt = record.dingedAt
                    end
                end
            end
        end
    end

    self.EventBus:PublishEvent(self.Config.Events.RefreshGUI)
end