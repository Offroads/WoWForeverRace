-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- WoW API
local C_Timer, IsInGuild, math = _G.C_Timer, _G.IsInGuild, _G.math
local GetNumGroupMembers = _G.GetNumGroupMembers

-- peerHashes: optional per-class hash table received from a peer (index i+1 =
-- leaderboard[i]). Builds for other clients track other classes (Classic Era has
-- no Horde Paladins, older builds treat WoW Forever that way), so when given,
-- only the leaderboards that peer reported are included. Without this a class
-- the peer does not track looks like a difference forever and is re-sent on
-- every sync round.
local function leaderboardClassIndexes(config, peerHashes)
    local indexes = {0}
    for _, classIndex in ipairs(config.MopClassIndexes) do
        if type(peerHashes) ~= "table" or peerHashes[classIndex + 1] ~= nil then
            indexes[#indexes + 1] = classIndex
        end
    end
    return indexes
end

-- djb2 chain over all leaderboards - mirrors Tracker:ComputeFullHash without a cross-component dependency
local function computeFullHash(db, config, peerHashes)
    local hash = 5381
    for _, classIndex in ipairs(leaderboardClassIndexes(config, peerHashes)) do
        local lb = db.factionrealm.leaderboard[classIndex]
        if lb then
            hash = ((hash * 33) + WoWForeverRace.Leaderboard.ComputeHash(lb)) % 2147483647
        end
    end
    return hash
end

-- djb2 hash over all firstToLevel records in deterministic order.
-- Covers every classFilter the serializer transmits (0 = overall, 1..#Classes)
-- and the configured level range; fields are ':'-separated
-- so different records can't concatenate to the same entry string.
local function computeFTLHash(db, config, peerHashes)
    local hash = 5381
    local ftl = db.factionrealm.firstToLevel
    if not ftl then return hash end
    for _, classFilter in ipairs(leaderboardClassIndexes(config, peerHashes)) do
        local levels = ftl[classFilter]
        if levels then
            for level = 2, config.MaxLevel do
                local record = levels[level]
                if record then
                    local entry = classFilter .. ":" .. level .. ":" .. record.name .. ":"
                            .. (record.classIndex or 0) .. ":" .. math.floor(record.dingedAt or 0)
                    for i = 1, #entry do
                        hash = ((hash * 33) + string.byte(entry, i)) % 2147483647
                    end
                end
            end
        end
    end
    return hash
end

-- Sorted list of names that have playerHistory AND are on any leaderboard.
-- playerHistory itself is unbounded (every character a scan ever saw), so both the
-- history hash and the history sync payload are scoped to this bounded subset.
local function relevantHistoryNames(db, config)
    local onLeaderboard = {}
    for _, classIndex in ipairs(leaderboardClassIndexes(config)) do
        local lb = db.factionrealm.leaderboard[classIndex]
        if lb then
            for _, player in ipairs(lb.players) do
                onLeaderboard[player.name] = true
            end
        end
    end

    local names = {}
    for name, _ in pairs(db.factionrealm.playerHistory or {}) do
        if onLeaderboard[name] then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

-- djb2 hash over the leaderboard-scoped playerHistory subset in deterministic order
local function computePHHash(db, config)
    local hash = 5381
    local playerHistory = db.factionrealm.playerHistory or {}
    for _, name in ipairs(relevantHistoryNames(db, config)) do
        local hist = playerHistory[name]
        local entry = name .. ":" .. (hist.classIndex or 0)
        for level = 2, config.MaxLevel do
            local dingedAt = hist.levels ~= nil and hist.levels[level] or nil
            if dingedAt ~= nil then
                entry = entry .. ":" .. level .. ":" .. math.floor(dingedAt)
            end
        end
        for i = 1, #entry do
            hash = ((hash * 33) + string.byte(entry, i)) % 2147483647
        end
    end
    return hash
end

--[[
WoWForeverRaceSync handles both requesting a sync when we login and responding to others who are request a sync
]]--
---@class WoWForeverRaceSync
---@field Config WoWForeverRaceConfig
---@field Core WoWForeverRaceCore
---@field DB table<string, table>
---@field EventBus WoWForeverRaceEventBus
local WoWForeverRaceSync = {}
WoWForeverRaceSync.__index = WoWForeverRaceSync
WoWForeverRace.Sync = WoWForeverRaceSync
setmetatable(WoWForeverRaceSync, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

-- exposed as statics for tests and diagnostics
WoWForeverRaceSync.ComputeFTLHash = computeFTLHash
WoWForeverRaceSync.ComputeFullHash = computeFullHash
WoWForeverRaceSync.ComputePHHash = computePHHash

function WoWForeverRaceSync.new(Config, Core, DB, EventBus, Network)
    local self = setmetatable({}, WoWForeverRaceSync)

    self.Config = Config
    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus
    self.Network = Network

    self.classIndex = self.Core:MyClass()

    self.isReady = false
    self.offers = {}
    self.syncPartner = nil
    self.lastSync = nil
    self.guildOffers = nil  -- non-nil only during active guild sync window
    self.guildPHWanted = false  -- whether the open guild window should also pull player history

    EventBus:RegisterCallback(self.Config.Network.Events.RequestSync, self, self.OnNetRequestSync)
    EventBus:RegisterCallback(self.Config.Network.Events.OfferSync, self, self.OnNetOfferSync)
    EventBus:RegisterCallback(self.Config.Network.Events.StartSync, self, self.OnNetStartSync)
    EventBus:RegisterCallback(self.Config.Network.Events.SyncPayload, self, self.OnNetSyncPayload)
    EventBus:RegisterCallback(self.Config.Network.Events.GuildSync, self, self.OnNetGuildSync)
    EventBus:RegisterCallback(self.Config.Network.Events.GuildOffer, self, self.OnNetGuildOffer)
    EventBus:RegisterCallback(self.Config.Network.Events.BuddyPing, self, self.OnNetBuddyPing)
    EventBus:RegisterCallback(self.Config.Network.Events.BuddyPong, self, self.OnNetBuddyPong)
    EventBus:RegisterCallback(self.Config.Network.Events.FTLSync, self, self.OnNetFTLSync)
    EventBus:RegisterCallback(self.Config.Network.Events.PlayerHistorySync, self, self.OnNetPHSync)

    return self
end

function WoWForeverRaceSync:InitSync()
    -- don't request updates when we know the race has finished
    if self.DB.factionrealm.finished then
        return
    end
    -- don't request updates when we've disabled networking
    if not self.DB.profile.options.networking then
        return
    end

    -- Logged in (or reloaded) inside a chat messaging lockdown: nobody can answer
    -- yet, so run the once-per-login sync when the lockdown has ended.
    if self.Network.IsLockedDown and self.Network:IsLockedDown() then
        local _self = self
        C_Timer.After(self.Config.RetrySyncWait, function() _self:InitSync() end)
        return
    end

    -- include our leaderboard, FTL and history hashes so partners can skip offering when already in sync
    local globalHash = WoWForeverRace.Leaderboard.ComputeHash(self.DB.factionrealm.leaderboard[0])
    local classHash = WoWForeverRace.Leaderboard.ComputeHash(
            self.DB.factionrealm.leaderboard[self.classIndex] or {players = {}})
    local ftlHash = computeFTLHash(self.DB, self.Config)
    local phHash = computePHHash(self.DB, self.Config)
    local payload = {self.classIndex, globalHash, classHash, ftlHash, phHash}

    self.Network:SendObject(self.Config.Network.Events.RequestSync, payload, "YELL")

    -- after 5s we attempt to sync with somebody who offered via YELL
    local _self = self
    C_Timer.After(self.Config.RequestSyncWait, function() _self:DoSync() end)

    -- guild sync: announce to GUILD and pick the longest-uptime partner after GuildSyncWait+1s
    -- withPlayerHistory: we just logged in, so this is the once-per-login history pull
    self:SendGuildSync(true)
end

function WoWForeverRaceSync:OnNetRequestSync(payload, sender)
    -- don't respond to requests when we've disabled networking
    if not self.DB.profile.options.networking then
        return
    end

    WoWForeverRace:DebugPrint("OnNetRequestSync(" .. sender .. ") isReady=" .. tostring(self.isReady))
    -- if we're still in the process of syncing up ourselves then we shouldn't offer ourselves to sync with
    if not self.isReady then
        return
    end

    -- extract requester's classIndex and hashes (payload is a table in new clients, plain number in old)
    local requesterClassIndex, requesterGlobalHash, requesterClassHash, requesterFTLHash, requesterPHHash
    if type(payload) == "table" then
        requesterClassIndex, requesterGlobalHash, requesterClassHash, requesterFTLHash, requesterPHHash =
                payload[1], payload[2], payload[3], payload[4], payload[5]
    else
        requesterClassIndex = payload
    end

    -- compute our hashes to include in offer and to decide whether to offer at all
    local myGlobalHash = WoWForeverRace.Leaderboard.ComputeHash(self.DB.factionrealm.leaderboard[0])
    local myClassHash = WoWForeverRace.Leaderboard.ComputeHash(
            self.DB.factionrealm.leaderboard[self.classIndex] or {players = {}})
    local myFTLHash = computeFTLHash(self.DB, self.Config)
    local myPHHash = computePHHash(self.DB, self.Config)

    -- skip offering if the requester already has identical data to us
    if requesterGlobalHash ~= nil and requesterGlobalHash == myGlobalHash
            and (requesterFTLHash == nil or requesterFTLHash == myFTLHash)
            and (requesterPHHash == nil or requesterPHHash == myPHHash) then
        local classSyncNeeded = requesterClassIndex == self.classIndex
                and requesterClassHash ~= nil
                and requesterClassHash ~= myClassHash
        if not classSyncNeeded then
            WoWForeverRace:DebugPrint("Skipping offer to " .. sender .. " (already in sync)")
            return
        end
    end

    self.Network:SendObject(self.Config.Network.Events.OfferSync,
            { self.classIndex, self.lastSync, myGlobalHash, myClassHash, myFTLHash, myPHHash }, "WHISPER", sender)
end

function WoWForeverRaceSync:OnNetOfferSync(offer, sender)
    local classIndex, lastSync, globalHash, classHash, ftlHash, phHash =
            offer[1], offer[2], offer[3], offer[4], offer[5], offer[6]
    WoWForeverRace:DebugPrint("OnNetOfferSync(" .. sender .. ")")
    -- add anyone who offers to sync with us
    table.insert(self.offers, {name = sender, classIndex = classIndex, lastSync = lastSync,
                               globalHash = globalHash, classHash = classHash, ftlHash = ftlHash,
                               phHash = phHash})
    self:AddBuddy(sender)
end

function WoWForeverRaceSync:SelectPartner()
    -- we prefer to sync with same class without violating their throttle
    -- otherwise same class, but violate their throttle
    -- otherwise any class without violating their throttle
    -- otherwise any class, but voilate their throttle
    local now = self.Core:Now()
    local classIndex = self.classIndex
    local OfferSyncThrottle = self.Config.OfferSyncThrottle

    local offerModes = {"SAME_CLASS_THROTTLED", "SAME_CLASS", "THROTTLED", "ALL"}
    for _, offerMode in ipairs(offerModes) do
        local offers
        if offerMode == "SAME_CLASS_THROTTLED" then
            offers = WoWForeverRace.list.filter(self.offers, function(offer)
                return offer.classIndex == classIndex and
                        (offer.lastSync == nil or offer.lastSync < now - OfferSyncThrottle)
            end)
        elseif offerMode == "SAME_CLASS" then
            offers = WoWForeverRace.list.filter(self.offers, function(offer)
                return offer.classIndex == classIndex
            end)
        elseif offerMode == "THROTTLED" then
            offers = WoWForeverRace.list.filter(self.offers, function(offer)
                return offer.lastSync == nil or offer.lastSync < now - OfferSyncThrottle
            end)
        else
            offers = self.offers
        end

        if #offers > 0 then
            return self:SelectPartnerFromList(offers)
        end
    end
end

function WoWForeverRaceSync:SelectPartnerFromList(offers)
    -- select random offer
    local index = math.random(1, #offers)
    return table.remove(offers, index)
end

function WoWForeverRaceSync:SetReady()
    if not self.isReady then
        self.isReady = true
        WoWForeverRace:DebugPrint("Sync done", true)
        self:SendBuddyPings()
    end
end

function WoWForeverRaceSync:DoSync()
    -- no offers
    if #self.offers == 0 then
        WoWForeverRace:DebugPrint("no sync partners")

        -- mark ourselves as synced up, otherwise nobody can ever sync
        self:SetReady()
        return
    end

    -- select a partner to sync with
    self.syncPartner = self:SelectPartner()

    -- remove the partner from the list of offers (in case we want to retry with another partner)
    self.offers = WoWForeverRace.list.filter(self.offers, function(offer)
        return offer.name ~= self.syncPartner.name
    end)

    WoWForeverRace:DebugPrint("DoSync(" .. self.syncPartner.name .. ")")

    -- compute our hashes to send and to decide what actually needs syncing
    local myGlobalHash = WoWForeverRace.Leaderboard.ComputeHash(self.DB.factionrealm.leaderboard[0])
    local sameClass = self.syncPartner.classIndex == self.classIndex
    local myClassHash = sameClass and WoWForeverRace.Leaderboard.ComputeHash(
            self.DB.factionrealm.leaderboard[self.classIndex] or {players = {}})
    local myFTLHash = computeFTLHash(self.DB, self.Config)
    local myPHHash = computePHHash(self.DB, self.Config)

    local globalMatch = self.syncPartner.globalHash ~= nil and self.syncPartner.globalHash == myGlobalHash
    local classMatch = not sameClass
            or (self.syncPartner.classHash ~= nil and self.syncPartner.classHash == myClassHash)
    local ftlMatch = self.syncPartner.ftlHash ~= nil and self.syncPartner.ftlHash == myFTLHash
    -- player history is pull-only: a nil offer hash means an old client that can't
    -- provide it, so treat that as matching rather than waiting on it
    local phMatch = self.syncPartner.phHash == nil or self.syncPartner.phHash == myPHHash

    if globalMatch and classMatch and ftlMatch and phMatch then
        WoWForeverRace:DebugPrint("Already in sync with " .. self.syncPartner.name)
        self:SetReady()
        return
    end

    -- include our hashes so the partner can also skip sending back data we already agree on
    self.Network:SendObject(self.Config.Network.Events.StartSync,
            {self.classIndex, myGlobalHash, myClassHash, myFTLHash, myPHHash}, "WHISPER", self.syncPartner.name)

    -- check if we need to retry syncing after a short timeout
    local _self = self
    C_Timer.After(self.Config.RetrySyncWait, function()
        if not self.isReady then
            _self:DoSync()
        end
    end)

    -- only send leaderboards / FTL data the partner doesn't already have
    if not globalMatch then
        self:Sync(self.syncPartner.name, 0)
    end
    if sameClass and not classMatch then
        self:Sync(self.syncPartner.name, self.classIndex)
    end
    if not ftlMatch then
        self:SyncFTL(self.syncPartner.name)
    end
end

function WoWForeverRaceSync:Sync(syncTo, classIndex)
    local batchstr = WoWForeverRace.Serializer.SerializePlayerInfoBatch(self.DB.factionrealm.leaderboard[classIndex].players)

    self.Network:SendObject(self.Config.Network.Events.SyncPayload, batchstr, "WHISPER", syncTo)
end

function WoWForeverRaceSync:OnNetStartSync(payload, sender)
    if not self.DB.profile.options.networking then return end
    WoWForeverRace:DebugPrint("OnNetStartSync(" .. sender .. ")")
    self.lastSync = self.Core:Now()

    local requesterClassIndex, requesterGlobalHash, requesterClassHash, requesterFTLHash, requesterPHHash
    if type(payload) == "table" then
        requesterClassIndex = payload[1]

        if type(payload[2]) == "table" then
            -- guild sync: payload[2] is per-class hashes - send every leaderboard that differs
            local perClassHashes = payload[2]
            for _, classIndex in ipairs(leaderboardClassIndexes(self.Config, perClassHashes)) do
                local lb = self.DB.factionrealm.leaderboard[classIndex]
                if lb and #lb.players > 0 then
                    local myHash = WoWForeverRace.Leaderboard.ComputeHash(lb)
                    if myHash ~= (perClassHashes[classIndex + 1] or 0) then
                        self:Sync(sender, classIndex)
                    end
                end
            end
            -- payload[3] is the requester's FTL hash; only send FTL when it differs
            -- (older clients don't include it - send unconditionally for those)
            local guildFTLHash = payload[3]
            if guildFTLHash == nil or guildFTLHash ~= computeFTLHash(self.DB, self.Config, perClassHashes) then
                self:SyncFTL(sender)
            end
            -- payload[4] is the requester's history hash, only present on their
            -- once-per-login pull; never send history to clients that didn't ask
            local guildPHHash = payload[4]
            if guildPHHash ~= nil and guildPHHash ~= computePHHash(self.DB, self.Config) then
                self:SyncPlayerHistory(sender)
            end
            return
        end

        -- zone sync: payload[2] is globalHash, payload[3] is classHash, payload[4] is ftlHash,
        -- payload[5] is the history hash
        requesterGlobalHash, requesterClassHash, requesterFTLHash, requesterPHHash =
                payload[2], payload[3], payload[4], payload[5]
    else
        requesterClassIndex = payload
    end

    -- only send global + own class (zone sync path)
    local myGlobalHash = WoWForeverRace.Leaderboard.ComputeHash(self.DB.factionrealm.leaderboard[0])
    if requesterGlobalHash == nil or requesterGlobalHash ~= myGlobalHash then
        self:Sync(sender, 0)
    end

    if requesterClassIndex == self.classIndex then
        local myClassHash = WoWForeverRace.Leaderboard.ComputeHash(
                self.DB.factionrealm.leaderboard[self.classIndex] or {players = {}})
        if requesterClassHash == nil or requesterClassHash ~= myClassHash then
            self:Sync(sender, self.classIndex)
        end
    end

    local myFTLHash = computeFTLHash(self.DB, self.Config)
    if requesterFTLHash == nil or requesterFTLHash ~= myFTLHash then
        self:SyncFTL(sender)
    end

    -- player history is pull-only and potentially large: only send it when the
    -- requester explicitly announced a differing hash (old clients never do)
    if requesterPHHash ~= nil and requesterPHHash ~= computePHHash(self.DB, self.Config) then
        self:SyncPlayerHistory(sender)
    end
end

function WoWForeverRaceSync:OnNetSyncPayload(payload, sender)
    if not self.DB.profile.options.networking then return end
    WoWForeverRace:DebugPrint("OnNetSyncPayload(" .. sender .. ")")

    local batch = WoWForeverRace.Serializer.DeserializePlayerInfoBatch(payload)

    self.EventBus:PublishEvent(self.Config.Events.SyncResult, batch)

    -- mark ourselves as synced up
    self:SetReady()
end

-- Periodic guild sync ticker: re-runs the guild sync flow every GuildSyncInterval seconds.
-- Only fires once we're ready (initial zone sync complete).
function WoWForeverRaceSync:InitGuildTicker()
    local _self = self
    C_Timer.NewTicker(self.Config.GuildSyncInterval, function()
        if _self.isReady then
            _self:SendGuildSync()
        end
    end)
end

-- Announce our presence to the guild and open a window for offers.
-- Used both on login (called from InitSync) and by the periodic ticker.
-- withPlayerHistory: true only for the login call - player history is potentially
-- large, so it's pulled once per login and never re-negotiated by the ticker.
function WoWForeverRaceSync:SendGuildSync(withPlayerHistory)
    if not IsInGuild() then return end
    if not self.DB.profile.options.networking then return end
    if self.DB.factionrealm.finished then return end

    self.guildOffers = {}
    self.guildPHWanted = withPlayerHistory or false

    local fullHash = computeFullHash(self.DB, self.Config)
    local ftlHash = computeFTLHash(self.DB, self.Config)
    local phHash = withPlayerHistory and computePHHash(self.DB, self.Config) or nil
    self.Network:SendObject(self.Config.Network.Events.GuildSync,
            {self.classIndex, fullHash, self.Core:LoginTime(), ftlHash, phHash}, "GUILD")

    local _self = self
    C_Timer.After(self.Config.GuildSyncWait + 1, function()
        _self:DoGuildSync()
    end)
end

-- Received when another guild member announces via GuildSync.
-- If our data differs, whisper back an offer after a random delay to spread load.
function WoWForeverRaceSync:OnNetGuildSync(payload, sender)
    if not self.DB.profile.options.networking then return end
    if not self.isReady then return end

    local requesterFullHash, requesterFTLHash, requesterPHHash = payload[2], payload[4], payload[5]

    local myFullHash = computeFullHash(self.DB, self.Config)
    local myFTLHash = computeFTLHash(self.DB, self.Config)
    -- older clients don't announce an FTL hash; treat that as matching.
    -- the history hash is only present on a login announce (once-per-login pull)
    local ftlDiffers = requesterFTLHash ~= nil and requesterFTLHash ~= myFTLHash
    local phDiffers = requesterPHHash ~= nil and requesterPHHash ~= computePHHash(self.DB, self.Config)
    if myFullHash == requesterFullHash and not ftlDiffers and not phDiffers then return end

    local delay = math.random(0, self.Config.GuildSyncWait)
    local _self = self
    C_Timer.After(delay, function()
        local myGlobalHash = WoWForeverRace.Leaderboard.ComputeHash(_self.DB.factionrealm.leaderboard[0])
        local myClassHash = WoWForeverRace.Leaderboard.ComputeHash(
                _self.DB.factionrealm.leaderboard[_self.classIndex] or {players = {}})
        _self.Network:SendObject(_self.Config.Network.Events.GuildOffer,
                {_self.classIndex, _self.lastSync, myFullHash, myGlobalHash, myClassHash, _self.Core:LoginTime(),
                 computeFTLHash(_self.DB, _self.Config), computePHHash(_self.DB, _self.Config)},
                "WHISPER", sender)
    end)
end

-- Collect guild offers during the open window.
function WoWForeverRaceSync:OnNetGuildOffer(offer, sender)
    if self.guildOffers == nil then return end
    local classIndex, lastSync, fullHash, globalHash, classHash, loginTime, ftlHash, phHash =
            offer[1], offer[2], offer[3], offer[4], offer[5], offer[6], offer[7], offer[8]
    WoWForeverRace:DebugPrint("GuildOffer from " .. sender)
    table.insert(self.guildOffers, {
        name = sender, classIndex = classIndex, lastSync = lastSync,
        fullHash = fullHash, globalHash = globalHash, classHash = classHash, loginTime = loginTime,
        ftlHash = ftlHash, phHash = phHash,
    })
end

-- Add or update a buddy entry in the persistent DB list.
function WoWForeverRaceSync:AddBuddy(name)
    -- senders normally come without a realm; normalize a same-realm "Name-Realm"
    -- anyway so we don't store duplicates (and a whisper to "Name-Realm" is not delivered)
    local shortName, realm = self.Core:SplitFullPlayer(name)
    if self.Core:IsMyRealm(realm) then
        if shortName == self.Core:RealMe() then return end
        name = shortName
    elseif name == self.Core:FullRealMe() then
        return
    end
    local buddies = self.DB.factionrealm.buddies
    if not buddies[name] then
        buddies[name] = {}
    end
    buddies[name].lastSeen = self.Core:Now()
    WoWForeverRace:DebugPrint("Buddy: added/updated " .. name)
    self.EventBus:PublishEvent(self.Config.Events.BuddyUpdate)
end

-- Send BPING to up to BuddyPingBatchSize buddies (random sample if more).
function WoWForeverRaceSync:SendBuddyPings()
    if not self.isReady then return end
    if self.DB.factionrealm.finished then return end
    if not self.DB.profile.options.networking then return end

    local names = {}
    for name, _ in pairs(self.DB.factionrealm.buddies) do
        names[#names + 1] = name
    end
    if #names == 0 then return end

    local batchSize = self.Config.BuddyPingBatchSize
    local selected = names
    if #names > batchSize then
        selected = {}
        for i = 1, batchSize do
            local j = math.random(i, #names)
            names[i], names[j] = names[j], names[i]
            selected[i] = names[i]
        end
    end

    local myFullHash = computeFullHash(self.DB, self.Config)
    local myPerClassHashes = {}
    for _, classIndex in ipairs(leaderboardClassIndexes(self.Config)) do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        myPerClassHashes[classIndex + 1] = lb and WoWForeverRace.Leaderboard.ComputeHash(lb) or 0
    end
    local myFTLHash = computeFTLHash(self.DB, self.Config)
    local payload = {myFullHash, myPerClassHashes, myFTLHash}

    WoWForeverRace:DebugPrint("BuddyPing: pinging " .. #selected .. " of " .. #names .. " buddies")
    for _, name in ipairs(selected) do
        self.Network:SendObject(self.Config.Network.Events.BuddyPing, payload, "WHISPER", name)
    end
end

-- Received BPING from a buddy: update their last-seen, push leaderboards they're missing, ack with BPONG.
-- BPONG includes our own hashes so the sender can also push what we're missing (bidirectional in one round trip).
function WoWForeverRaceSync:OnNetBuddyPing(payload, sender)
    if not self.DB.profile.options.networking then return end
    self:AddBuddy(sender)

    local myFullHash = computeFullHash(self.DB, self.Config)
    local myPerClassHashes = {}
    for _, classIndex in ipairs(leaderboardClassIndexes(self.Config)) do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        myPerClassHashes[classIndex + 1] = lb and WoWForeverRace.Leaderboard.ComputeHash(lb) or 0
    end
    local myFTLHash = computeFTLHash(self.DB, self.Config)

    -- always ack with our hashes so the sender knows we're online and can push back
    self.Network:SendObject(self.Config.Network.Events.BuddyPong,
            {myFullHash, myPerClassHashes, myFTLHash}, "WHISPER", sender)

    if not self.isReady then return end

    local senderFullHash = payload[1]
    local senderFTLHash = payload[3]

    -- compare over the leaderboards the sender tracks, see leaderboardClassIndexes
    local leaderboardsDiffer = computeFullHash(self.DB, self.Config, payload[2]) ~= senderFullHash
    local ftlDiffers = senderFTLHash == nil
            or senderFTLHash ~= computeFTLHash(self.DB, self.Config, payload[2])

    if not leaderboardsDiffer and not ftlDiffers then return end

    local diffClasses = {}
    if leaderboardsDiffer then
        local senderPerClassHashes = payload[2]
        for _, classIndex in ipairs(leaderboardClassIndexes(self.Config, senderPerClassHashes)) do
            local lb = self.DB.factionrealm.leaderboard[classIndex]
            if lb and #lb.players > 0 then
                local myHash = myPerClassHashes[classIndex + 1]
                local theirHash = senderPerClassHashes and senderPerClassHashes[classIndex + 1] or 0
                if myHash ~= theirHash then
                    diffClasses[#diffClasses + 1] = classIndex
                    self:Sync(sender, classIndex)
                end
            end
        end
    end

    if ftlDiffers then
        self:SyncFTL(sender)
    end

    if leaderboardsDiffer or ftlDiffers then
        WoWForeverRace:AddHashLog(sender, ">", diffClasses, ftlDiffers)
    end
end

-- Received BPONG from a buddy: update their last-seen, push any leaderboards / FTL they're missing.
function WoWForeverRaceSync:OnNetBuddyPong(payload, sender)
    if not self.DB.profile.options.networking then return end
    self:AddBuddy(sender)
    WoWForeverRace:DebugPrint("BuddyPong from " .. sender)

    if not self.isReady then return end

    local senderFullHash = payload[1]
    if not senderFullHash then return end

    local senderFTLHash = payload[3]

    -- compare over the leaderboards the sender tracks, see leaderboardClassIndexes
    local leaderboardsDiffer = computeFullHash(self.DB, self.Config, payload[2]) ~= senderFullHash
    local ftlDiffers = senderFTLHash == nil
            or senderFTLHash ~= computeFTLHash(self.DB, self.Config, payload[2])

    local diffClasses = {}
    if leaderboardsDiffer then
        local senderPerClassHashes = payload[2]
        for _, classIndex in ipairs(leaderboardClassIndexes(self.Config, senderPerClassHashes)) do
            local lb = self.DB.factionrealm.leaderboard[classIndex]
            if lb and #lb.players > 0 then
                local myHash = WoWForeverRace.Leaderboard.ComputeHash(lb)
                local theirHash = senderPerClassHashes and senderPerClassHashes[classIndex + 1] or 0
                if myHash ~= theirHash then
                    diffClasses[#diffClasses + 1] = classIndex
                    self:Sync(sender, classIndex)
                end
            end
        end
    end

    if ftlDiffers then
        self:SyncFTL(sender)
    end

    if leaderboardsDiffer or ftlDiffers then
        WoWForeverRace:AddHashLog(sender, ">", diffClasses, ftlDiffers)
    end
end

-- Whispers our complete firstToLevel dataset to the target player.
-- Payload is a table {ftlBatchString, realmOpenedAt} so both are synced together.
function WoWForeverRaceSync:SyncFTL(syncTo)
    local ftlstr = WoWForeverRace.Serializer.SerializeFTLBatch(self.DB.factionrealm.firstToLevel or {})
    local payload = {ftlstr, self.DB.factionrealm.realmOpenedAt}
    self.Network:SendObject(self.Config.Network.Events.FTLSync, payload, "WHISPER", syncTo)
end

-- Received a firstToLevel sync payload - deserialize and forward to tracker for merging.
-- Accepts both the new table format {ftlstr, realmOpenedAt} and the old bare-string format.
function WoWForeverRaceSync:OnNetFTLSync(payload, sender)
    if not self.DB.profile.options.networking then return end
    WoWForeverRace:DebugPrint("OnNetFTLSync(" .. sender .. ")")
    local ftlstr, remoteRealmOpenedAt
    if type(payload) == "table" then
        ftlstr = payload[1]
        remoteRealmOpenedAt = payload[2]
    else
        ftlstr = payload
    end
    local ftldb = WoWForeverRace.Serializer.DeserializeFTLBatch(ftlstr or "")
    self.EventBus:PublishEvent(self.Config.Events.FTLSyncResult, ftldb, remoteRealmOpenedAt)

    -- an FTL payload also completes our initial sync: when only FTL differed from
    -- our partner this is the only payload we'll receive, and without marking
    -- ready we'd keep retrying other partners until the offer list runs dry
    self:SetReady()
end

-- Whispers the leaderboard-scoped playerHistory subset to the target player, in
-- chunks of PlayerHistoryChunkSize players spaced PlayerHistoryChunkDelay seconds
-- apart, so a large transfer stays friendly to the addon channel throttle.
-- Only called for the target's once-per-login pull.
function WoWForeverRaceSync:SyncPlayerHistory(syncTo)
    local names = relevantHistoryNames(self.DB, self.Config)
    local chunks = WoWForeverRace.Serializer.SerializePlayerHistoryChunks(
            self.DB.factionrealm.playerHistory or {}, names, self.Config.PlayerHistoryChunkSize)

    WoWForeverRace:DebugPrint("SyncPlayerHistory(" .. syncTo .. "): "
            .. #names .. " players in " .. #chunks .. " chunk(s)")

    local _self = self
    for i, chunk in ipairs(chunks) do
        C_Timer.After((i - 1) * self.Config.PlayerHistoryChunkDelay, function()
            _self.Network:SendObject(_self.Config.Network.Events.PlayerHistorySync, chunk, "WHISPER", syncTo)
        end)
    end
end

-- Received a playerHistory chunk - deserialize and forward to tracker for merging.
-- Chunks are independently parseable, so each is merged as it arrives.
function WoWForeverRaceSync:OnNetPHSync(payload, sender)
    if not self.DB.profile.options.networking then return end
    WoWForeverRace:DebugPrint("OnNetPHSync(" .. sender .. ")")

    local batch = WoWForeverRace.Serializer.DeserializePlayerHistoryBatch(payload or "")
    self.EventBus:PublishEvent(self.Config.Events.PHSyncResult, batch)

    -- a history payload also completes our initial sync: when only history differed
    -- from our partner this is the only payload we'll receive
    self:SetReady()
end

-- Called when the party roster changes. Debounced to avoid firing multiple times
-- in quick succession. Sends BPING to GROUP so all members can exchange hashes
-- and push any missing leaderboards.
function WoWForeverRaceSync:OnGroupRosterUpdate()
    if not self.isReady then return end
    if not self.DB.profile.options.networking then return end
    if self.DB.factionrealm.finished then return end
    if GetNumGroupMembers() == 0 then return end

    -- debounce: multiple roster events can fire in quick succession
    if self.groupSyncPending then return end
    self.groupSyncPending = true
    local _self = self
    C_Timer.After(2, function()
        _self.groupSyncPending = nil
        _self:SendGroupSync()
    end)
end

function WoWForeverRaceSync:SendGroupSync()
    if GetNumGroupMembers() == 0 then return end
    WoWForeverRace:DebugPrint("GroupSync: sending BPING to GROUP")

    local myFullHash = computeFullHash(self.DB, self.Config)
    local myPerClassHashes = {}
    for _, classIndex in ipairs(leaderboardClassIndexes(self.Config)) do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        myPerClassHashes[classIndex + 1] = lb and WoWForeverRace.Leaderboard.ComputeHash(lb) or 0
    end
    local myFTLHash = computeFTLHash(self.DB, self.Config)
    self.Network:SendObject(self.Config.Network.Events.BuddyPing, {myFullHash, myPerClassHashes, myFTLHash}, "GROUP")
end

-- Start the periodic buddy ping ticker.
function WoWForeverRaceSync:InitBuddyTicker()
    local _self = self
    C_Timer.NewTicker(self.Config.BuddySyncInterval, function()
        _self:SendBuddyPings()
    end)
end

-- Called after the guild offer window closes.
-- Picks the offer with the lowest loginTime (longest uptime = most authoritative)
-- and requests all missing leaderboards from that partner via STARTSYNC with per-class hashes.
function WoWForeverRaceSync:DoGuildSync()
    local offers = self.guildOffers
    self.guildOffers = nil

    if not offers or #offers == 0 then
        WoWForeverRace:DebugPrint("Guild sync: no offers")
        return
    end

    -- pick longest-uptime partner (lowest loginTime)
    local best = offers[1]
    for _, offer in ipairs(offers) do
        if offer.loginTime ~= nil and (best.loginTime == nil or offer.loginTime < best.loginTime) then
            best = offer
        end
    end

    WoWForeverRace:DebugPrint("DoGuildSync with " .. best.name)

    -- sanity check: if full hashes (and FTL/history, when negotiated) match now,
    -- nothing to do
    local myFTLHash = computeFTLHash(self.DB, self.Config)
    local myPHHash = self.guildPHWanted and computePHHash(self.DB, self.Config) or nil
    local ftlDiffers = best.ftlHash ~= nil and best.ftlHash ~= myFTLHash
    local phDiffers = myPHHash ~= nil and best.phHash ~= nil and best.phHash ~= myPHHash
    if best.fullHash == computeFullHash(self.DB, self.Config) and not ftlDiffers and not phDiffers then
        WoWForeverRace:DebugPrint("Already in sync with guild partner " .. best.name)
        return
    end

    -- send per-class hashes so the partner knows exactly which leaderboards to send back
    local myPerClassHashes = {}
    for _, classIndex in ipairs(leaderboardClassIndexes(self.Config)) do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        myPerClassHashes[classIndex + 1] = lb and WoWForeverRace.Leaderboard.ComputeHash(lb) or 0
    end

    -- the history hash is only included on the once-per-login pull
    self.Network:SendObject(self.Config.Network.Events.StartSync,
            {self.classIndex, myPerClassHashes, myFTLHash, myPHHash}, "WHISPER", best.name)
end

