-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- WoW API
local C_FriendList = _G.C_FriendList
local CreateFrame = _G.CreateFrame
local WorldFrame = _G.WorldFrame
local GetTime = _G.GetTime

--[[
Scanner listens passively to WHO_LIST_UPDATE events and publishes results via EventBus.

SendWho() is a protected function in MoP Classic and cannot be called from timers or
any non-hardware-event context. TriggerScan() is therefore wired to hardware events:
  - WorldFrame OnMouseDown (every in-world click), with a 15s cooldown
  - The minimap icon's OnClick

This mirrors the CensusPlusClassic approach: piggyback on the player's existing
hardware events rather than requiring a dedicated UI button.
]]--
---@class WoWForeverRaceScanner
local WoWForeverRaceScanner = {}
WoWForeverRaceScanner.__index = WoWForeverRaceScanner
WoWForeverRace.Scanner = WoWForeverRaceScanner
setmetatable(WoWForeverRaceScanner, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

local SCAN_COOLDOWN  = 15  -- seconds between automatic scans
local SCAN_TIMEOUT   = 60  -- seconds before an unanswered /who is abandoned
local WHO_RESULT_CAP = 50  -- WoW never returns more than this many /who rows
local LEVEL_STEP     = 10  -- levels to shift the scan floor up/down
local CLASS_COMPLETE_TTL = 900  -- seconds before a fully-scanned class is scanned again

function WoWForeverRaceScanner.new(Core, DB, EventBus)
    local self = setmetatable({}, WoWForeverRaceScanner)

    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus
    self.lastScanTime = -SCAN_COOLDOWN
    self.nextScanClassIdx = 1  -- cycles through MopClassIndexes
    self.lastScanClassIndex = nil
    self.classScanFloor = {}   -- per-class adaptive floor level
    self.classScanComplete = {} -- per-class: time a full-range scan returned complete
    self.globalScanFloor = nil
    self.globalResultFull = nil
    self.scanPending = false
    self.pendingScanMin = nil
    self.lastResultFull = {}   -- per-class: did last scan hit WHO_RESULT_CAP?

    self.whoFrame = CreateFrame("Frame")
    self.whoFrame:RegisterEvent("WHO_LIST_UPDATE")
    local _self = self
    self.whoFrame:SetScript("OnEvent", function(_, event)
        if event == "WHO_LIST_UPDATE" then
            _self:OnWhoListUpdate()
        end
    end)

    -- Piggyback on every in-world mouse click (hardware event) to drive periodic scans.
    -- TriggerScan enforces a cooldown so clicks don't spam /who.
    if WorldFrame then
        WorldFrame:HookScript("OnMouseDown", function()
            _self:TriggerScan()
        end)
    end

    return self
end

function WoWForeverRaceScanner:ResetState()
    self.lastScanTime = -SCAN_COOLDOWN
    self.nextScanClassIdx = 1
    self.lastScanClassIndex = nil
    self.classScanFloor = {}
    self.lastResultFull = {}
    self.classScanComplete = {}
    self.globalScanFloor = nil
    self.globalResultFull = nil
    self.scanPending = false
    self.pendingScanMin = nil
end

function WoWForeverRaceScanner:OnWhoListUpdate()
    if not self.scanPending then return end

    -- GetNumWhoResults() returns (numWhos, totalCount): the number of rows the
    -- client received (capped at WHO_RESULT_CAP) and the server-side match count
    local numShown, total = C_FriendList.GetNumWhoResults()
    numShown = numShown or 0

    -- Collect the rows first: a manual /who fired while our scan is pending
    -- also raises WHO_LIST_UPDATE, and must not be misattributed to the scan.
    local pendingClass = self.lastScanClassIndex ~= nil
            and WoWForeverRace.Config.Classes[self.lastScanClassIndex] or nil
    local matchesQuery = true
    local batch = {}
    for i = 1, numShown do
        local name, level, filename

        local info = C_FriendList.GetWhoInfo(i)
        if type(info) == "table" then
            name     = info.fullName
            level    = tonumber(info.level)
            filename = info.filename
        else
            -- Positional API fallback: charName, guild, charLevel, race, class, zone, filename, gender
            local charName, _, charLevel, _, _, _, charFilename = C_FriendList.GetWhoInfo(i)
            name     = charName
            level    = tonumber(charLevel)
            filename = charFilename
        end

        if level ~= nil and self.pendingScanMin ~= nil and level < self.pendingScanMin then
            matchesQuery = false
        end
        if filename ~= nil and pendingClass ~= nil and string.upper(filename) ~= pendingClass then
            matchesQuery = false
        end

        if name and level and level > 1 then
            local playerName, playerRealm = self.Core:SplitFullPlayer(name)
            if playerRealm == nil or self.Core:IsMyRealm(playerRealm) then
                table.insert(batch, {
                    name  = playerName,
                    level = level,
                    class = filename and string.upper(filename) or nil,
                })
            end
        end
    end

    -- Not our scan's response: leave the scan pending, the real response
    -- (or the SCAN_TIMEOUT in TriggerScan) will resolve it.
    if not matchesQuery then return end

    self.scanPending = false

    -- Restore FriendsFrame so manual /who works normally again.
    -- Must happen before any early return, or manual /who stays broken.
    local ff = _G.FriendsFrame
    if ff then ff:RegisterEvent("WHO_LIST_UPDATE") end

    if self.DB.factionrealm.finished then
        self.pendingScanMin = nil
        return
    end

    -- the result is complete when the server had no more matches than it sent us;
    -- the row cap is only a fallback for clients that don't report the total
    local resultComplete
    if total ~= nil then
        resultComplete = total <= numShown
    else
        resultComplete = numShown < WHO_RESULT_CAP
    end

    if self.lastScanClassIndex then
        self.lastResultFull[self.lastScanClassIndex] = not resultComplete
        if resultComplete and self.pendingScanMin ~= nil and self.pendingScanMin <= 2 then
            -- /who only returns online players, so a complete result is just a
            -- snapshot: rest the class for CLASS_COMPLETE_TTL, don't retire it.
            self.classScanComplete[self.lastScanClassIndex] = GetTime()
        end
    else
        self.globalResultFull = not resultComplete
    end
    self.pendingScanMin = nil

    if #batch == 0 then return end

    if #batch > 1 then
        table.sort(batch, function(a, b) return a.level > b.level end)
    end

    self.EventBus:PublishEvent(WoWForeverRace.Config.Events.SlashWhoResult, batch)
end

-- TriggerScan sends a /who query for the next class leaderboard that isn't full.
-- Once all class leaderboards reach 50 players it falls back to a global level scan.
-- MUST be called from a hardware event context (mouse click, key press).
-- Safe to call frequently; enforces a 15s cooldown internally.
function WoWForeverRaceScanner:TriggerScan()
    if self.DB.factionrealm.finished then return end

    local now = GetTime()

    if self.scanPending then
        if now - self.lastScanTime < SCAN_TIMEOUT then return end
        -- The server silently dropped the /who response; abandon the pending
        -- scan so a lost reply can't disable scanning for the whole session.
        self.scanPending = false
        self.pendingScanMin = nil
        local ff = _G.FriendsFrame
        if ff then ff:RegisterEvent("WHO_LIST_UPDATE") end
    end

    if now - self.lastScanTime < SCAN_COOLDOWN then return end
    self.lastScanTime = now

    local maxLevel   = WoWForeverRace.Config.MaxLevel
    local maxSize    = WoWForeverRace.Config.MaxLeaderboardSize
    local validIdx   = WoWForeverRace.Config.MopClassIndexes
    local numClasses = #validIdx
    local query      = nil

    -- Bootstrap from the top, then widen the range when the result is complete
    -- but empty. This lets a fresh low-pop realm discover its first players.
    local globalLb = self.DB.factionrealm.leaderboard[0]
    if not globalLb or #globalLb.players == 0 then
        self.lastScanClassIndex = nil
        local scanMin
        if self.globalScanFloor == nil then
            scanMin = math.max(maxLevel - 10, 1)
        elseif self.globalResultFull then
            scanMin = math.min(self.globalScanFloor + LEVEL_STEP, maxLevel - 1)
        else
            scanMin = math.max(self.globalScanFloor - LEVEL_STEP, 2)
        end
        self.globalScanFloor = scanMin
        query = tostring(scanMin) .. "-" .. tostring(maxLevel)
    end

    -- Cycle through classes that still need work.
    -- A class is done only when its leaderboard is full AND the lowest player is already at max level.
    if not query then for i = 0, numClasses - 1 do
        local slot       = ((self.nextScanClassIdx - 1 + i) % numClasses) + 1
        local classIndex = validIdx[slot]
        local classLb    = self.DB.factionrealm.leaderboard[classIndex]
        local className  = WoWForeverRace.Config.Classes[classIndex]
        local filter     = WoWForeverRace.Config.WhoClassFilter[className]
        local completeAt = self.classScanComplete[classIndex]
        local restingComplete = completeAt ~= nil and now - completeAt < CLASS_COMPLETE_TTL
        local isDone = classLb and (
                restingComplete
                or (#classLb.players >= maxSize and classLb.minLevel >= maxLevel))

        if filter and classLb and not isDone then
            self.nextScanClassIdx = (slot % numClasses) + 1
            self.lastScanClassIndex = classIndex

            local scanMin, scanMax
            scanMax = maxLevel

            if #classLb.players < maxSize then
                -- Adapt the floor based on whether the last scan for this class hit the cap.
                -- Hit cap → raise floor (zoom in on highest players).
                -- Under cap → lower floor (widen search to catch missed players).
                local floor = self.classScanFloor[classIndex] or (maxLevel - 20)
                if self.lastResultFull[classIndex] then
                    floor = math.min(floor + LEVEL_STEP, maxLevel - 1)
                else
                    floor = math.max(floor - LEVEL_STEP, 2)
                end
                self.classScanFloor[classIndex] = floor
                scanMin = floor
            else
                -- Leaderboard full but players still leveling: floor at the lowest known level.
                scanMin = classLb.minLevel
                if scanMin >= maxLevel then scanMin = maxLevel - 1 end
            end

            query = tostring(scanMin) .. "-" .. tostring(scanMax) .. " c-" .. filter
            break
        end
    end end -- end class scan loop + if not query guard

    -- All class leaderboards done: scan by global top range
    if not query then
        self.lastScanClassIndex = nil
        local lb = self.DB.factionrealm.leaderboard[0]

        -- Global leaderboard is also full with everyone at max level - the race
        -- may be over; the Tracker verifies every class board before finishing.
        if #lb.players >= maxSize and lb.minLevel >= maxLevel then
            self.EventBus:PublishEvent(WoWForeverRace.Config.Events.ScanFinished, true)
            return
        end

        local scanMin = math.max(lb.minLevel, lb.highestLevel)
        if scanMin <= 1 then scanMin = maxLevel - 10 end
        if scanMin >= maxLevel then scanMin = maxLevel - 1 end
        query = tostring(scanMin) .. "-" .. tostring(maxLevel)
    end

    WoWForeverRace:DebugPrint("Scanning /who " .. query)

    if C_FriendList and C_FriendList.SendWho then
        local ff = _G.FriendsFrame
        if ff then ff:UnregisterEvent("WHO_LIST_UPDATE") end
        if C_FriendList.SetWhoToUi then C_FriendList.SetWhoToUi(true) end
        self.pendingScanMin = tonumber(string.match(query, "^(%d+)-"))
        self.scanPending = true
        C_FriendList.SendWho(query)
    end
end
