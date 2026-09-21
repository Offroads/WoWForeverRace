-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- WoW API
local C_FriendList = _G.C_FriendList
local CreateFrame = _G.CreateFrame
local WorldFrame = _G.WorldFrame
local GetTime = _G.GetTime
local C_Timer = _G.C_Timer
local hooksecurefunc = _G.hooksecurefunc

--[[
Scanner listens passively to WHO_LIST_UPDATE events and publishes results via EventBus.

SendWho() is a restricted function in WoW Forever and cannot be called from
timers or any non-hardware-event context. TriggerScan() is therefore wired to hardware events:
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
local CLASS_COMPLETE_TTL = 900  -- seconds before a fully-scanned class or race is scanned again
local FLOOR_BOUND_TTL = 900  -- seconds a class or race floor is remembered as overflowing / fitting

-- Blizzard frames that open the who panel on WHO_LIST_UPDATE. In WoW Forever the who
-- list lives in the load-on-demand group finder. Looked up by name at scan time.
local WHO_UI_FRAMES = {"LFGWhoListFrame"}

function WoWForeverRaceScanner.new(Core, DB, EventBus)
    local self = setmetatable({}, WoWForeverRaceScanner)

    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus
    self.lastScanTime = -SCAN_COOLDOWN
    -- The filtered scans cycle through slots: the classes, then the races of our
    -- faction (ScanSlots). The per-class state below is keyed by the slot's
    -- leaderboard index, so it serves the race slots as well.
    self.nextScanClassIdx = 1  -- cycles through ScanSlots
    self.lastScanClassIndex = nil  -- leaderboard index of the pending filtered scan
    self.lastScanRaceIndex = nil   -- race of the pending scan, when it is a race scan
    self.classScanFloor = {}   -- per-class adaptive floor level
    self.classCappedFloor = {} -- per-class: {level, at} of the highest floor that overflowed the row cap
    self.classFittingFloor = {} -- per-class: {level, at} of the lowest floor that fit under the row cap
    self.classScanComplete = {} -- per-class: time a full-range scan returned complete
    self.probe = nil           -- level/class sample of the session's first, unfiltered scan
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

    -- Notice /who queries that are not ours (the player, other addons), see OnSendWho.
    if hooksecurefunc and C_FriendList and C_FriendList.SendWho then
        hooksecurefunc(C_FriendList, "SendWho", function()
            _self:OnSendWho()
        end)
    end

    return self
end

function WoWForeverRaceScanner:ResetState()
    self.lastScanTime = -SCAN_COOLDOWN
    self.nextScanClassIdx = 1
    self.lastScanClassIndex = nil
    self.lastScanRaceIndex = nil
    self.classScanFloor = {}
    self.classCappedFloor = {}
    self.classFittingFloor = {}
    self.lastResultFull = {}
    self.classScanComplete = {}
    self.probe = nil
    self.scanPending = false
    self.pendingScanMin = nil
    self:RestoreWhoUi()
end

-- Gives up on the pending scan (lost reply) and hands the who UI back.
function WoWForeverRaceScanner:AbandonScan()
    self.scanPending = false
    self.pendingScanMin = nil
    self:RestoreWhoUi()
end

-- Called for every C_FriendList.SendWho, ours included. An empty result can't be
-- told apart from the empty result of somebody else's query, so once a foreign
-- /who was sent while our scan is pending, empty results are no longer trusted.
function WoWForeverRaceScanner:OnSendWho()
    if self.sendingWho then return end
    if self.scanPending then
        self.foreignWhoSeen = true
    end
end

-- The class part of a /who query. The server matches the localized class name,
-- the English names in Config.WhoClassFilter are the fallback.
function WoWForeverRaceScanner:ClassWhoFilter(className)
    local localized = _G.LocalizedClassList and _G.LocalizedClassList(false)
            or _G.LOCALIZED_CLASS_NAMES_MALE
    local name = localized and localized[className] or WoWForeverRace.Config.WhoClassFilter[className]
    if not name then return nil end
    return (_G.WHO_TAG_CLASS or "c-") .. '"' .. name .. '"'
end

-- The race part of a /who query. The server matches the localized race name too.
function WoWForeverRaceScanner:RaceWhoFilter(raceIndex)
    local name = self.Core:RaceName(raceIndex)
    if not name then return nil end
    return (_G.WHO_TAG_RACE or "r-") .. '"' .. name .. '"'
end

-- The filtered scans of one cycle: every class, then every race of our faction.
-- boardIndex is the leaderboard the slot fills and the key of its scan state.
function WoWForeverRaceScanner:ScanSlots()
    local config = WoWForeverRace.Config
    local slots = {}
    for _, classIndex in ipairs(config.MopClassIndexes) do
        slots[#slots + 1] = {
            boardIndex = classIndex,
            filter = self:ClassWhoFilter(config.Classes[classIndex]),
        }
    end
    for _, raceIndex in ipairs(self.Core:MyRaceIndexes()) do
        slots[#slots + 1] = {
            boardIndex = config:RaceBoardIndex(raceIndex),
            raceIndex = raceIndex,
            filter = self:RaceWhoFilter(raceIndex),
        }
    end
    return slots
end

-- Stops the Blizzard who panel from popping up for the response to our scan.
function WoWForeverRaceScanner:SuppressWhoUi()
    self.suppressedWhoFrames = {}
    for _, frameName in ipairs(WHO_UI_FRAMES) do
        local frame = _G[frameName]
        -- only touch frames that are listening, so RestoreWhoUi never
        -- registers the event on a frame that did not have it
        if frame and frame:IsEventRegistered("WHO_LIST_UPDATE") then
            frame:UnregisterEvent("WHO_LIST_UPDATE")
            table.insert(self.suppressedWhoFrames, frame)
        end
    end
    if C_FriendList.SetWhoToUi then C_FriendList.SetWhoToUi(true) end
end

-- Restores the Blizzard who panel so manual /who works normally again.
function WoWForeverRaceScanner:RestoreWhoUi()
    if not self.suppressedWhoFrames then return end

    local whoPanelShown = false
    for _, frame in ipairs(self.suppressedWhoFrames) do
        frame:RegisterEvent("WHO_LIST_UPDATE")
        if frame:IsVisible() then whoPanelShown = true end
    end
    self.suppressedWhoFrames = nil

    -- IsVisible, not IsShown: the who list is a tab child that stays "shown" after
    -- its parent panel closes. The who panel keeps whoToUi on while it is open;
    -- otherwise hand short manual /who results back to the chat frame
    if not whoPanelShown and C_FriendList.SetWhoToUi then
        C_FriendList.SetWhoToUi(false)
    end
end

function WoWForeverRaceScanner:OnWhoListUpdate()
    if not self.scanPending then return end

    -- GetNumWhoResults() returns (numWhos, totalCount): the number of rows the
    -- client received (capped at WHO_RESULT_CAP) and the server-side match count
    local numShown, total = C_FriendList.GetNumWhoResults()
    numShown = numShown or 0

    -- Collect the rows first: a manual /who fired while our scan is pending
    -- also raises WHO_LIST_UPDATE, and must not be misattributed to the scan.
    -- (a race scan's leaderboard index is no class index, so it has no pending class)
    local pendingClass = self.lastScanClassIndex ~= nil
            and WoWForeverRace.Config.Classes[self.lastScanClassIndex] or nil
    local pendingRace = self.lastScanRaceIndex
    local matchesQuery = true
    local batch = {}
    for i = 1, numShown do
        local name, level, filename, raceStr

        local info = C_FriendList.GetWhoInfo(i)
        if type(info) == "table" then
            name     = info.fullName
            level    = tonumber(info.level)
            filename = info.filename
            raceStr  = info.raceStr
        else
            -- Positional API fallback: charName, guild, charLevel, race, class, zone, filename, gender
            local charName, _, charLevel, charRace, _, _, charFilename = C_FriendList.GetWhoInfo(i)
            name     = charName
            level    = tonumber(charLevel)
            filename = charFilename
            raceStr  = charRace
        end

        -- the row only has the localized race name; nil when it is none of our faction's
        local raceIndex = self.Core:RaceIndexByName(raceStr)

        if level ~= nil and self.pendingScanMin ~= nil and level < self.pendingScanMin then
            matchesQuery = false
        end
        if filename ~= nil and pendingClass ~= nil and string.upper(filename) ~= pendingClass then
            matchesQuery = false
        end
        -- Only another known race gives a foreign result away: a name we can't
        -- resolve (other client languages may use gendered names) proves nothing.
        if raceIndex ~= nil and pendingRace ~= nil and raceIndex ~= pendingRace then
            matchesQuery = false
        end

        if name and level and level > 1 then
            local playerName, playerRealm = self.Core:SplitFullPlayer(name)
            if playerRealm == nil or self.Core:IsMyRealm(playerRealm) then
                table.insert(batch, {
                    name  = playerName,
                    level = level,
                    class = filename and string.upper(filename) or nil,
                    raceIndex = raceIndex,
                })
            end
        end
    end

    -- an empty result after somebody else's /who may well be theirs
    if numShown == 0 and self.foreignWhoSeen then
        matchesQuery = false
    end

    -- Not our scan's response: leave the scan pending, the real response
    -- (or the SCAN_TIMEOUT) will resolve it.
    if not matchesQuery then return end

    self.scanPending = false

    -- Must happen before any early return, or manual /who stays broken.
    self:RestoreWhoUi()

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
        if self.pendingScanMin ~= nil then
            local bounds = resultComplete and self.classFittingFloor or self.classCappedFloor
            bounds[self.lastScanClassIndex] = {level = self.pendingScanMin, at = GetTime()}
        end
        if resultComplete and self.pendingScanMin ~= nil and self.pendingScanMin <= 2 then
            -- /who only returns online players, so a complete result is just a
            -- snapshot: rest the class or race for CLASS_COMPLETE_TTL, don't retire it.
            self.classScanComplete[self.lastScanClassIndex] = GetTime()
        end
    elseif self.probePending then
        self:RecordProbe(batch, total)
    end
    self.probePending = false
    self.pendingScanMin = nil
    self.lastScanRaceIndex = nil

    if #batch == 0 then return end

    if #batch > 1 then
        table.sort(batch, function(a, b) return a.level > b.level end)
    end

    self.EventBus:PublishEvent(WoWForeverRace.Config.Events.SlashWhoResult, batch)
end

-- Keeps the unfiltered probe scan as a sample of who is online: the server's match
-- count plus the levels, classes and races of the rows it sent, see ProbeFloor.
function WoWForeverRaceScanner:RecordProbe(batch, total)
    local probe = {total = total, levels = {}, classCount = {}, raceCount = {}}
    for _, player in ipairs(batch) do
        table.insert(probe.levels, player.level)
        if player.class then
            probe.classCount[player.class] = (probe.classCount[player.class] or 0) + 1
        end
        if player.raceIndex then
            probe.raceCount[player.raceIndex] = (probe.raceCount[player.raceIndex] or 0) + 1
        end
    end
    table.sort(probe.levels, function(a, b) return a > b end)
    self.probe = probe
end

-- Estimates from the probe sample where a class scan (or, without a className, the
-- scan of a race) has to start to fit under the row cap. nil when the whole class
-- is expected to fit (or there is no usable probe).
function WoWForeverRaceScanner:ProbeFloor(className, raceIndex)
    local probe = self.probe
    if not probe or not probe.total or #probe.levels == 0 then return nil end

    local sampled    = #probe.levels
    local count
    if className ~= nil then
        count = probe.classCount[className]
    else
        count = probe.raceCount and probe.raceCount[raceIndex]
    end
    local classTotal = probe.total * (count or 0) / sampled
    if classTotal <= WHO_RESULT_CAP then return nil end

    -- the share of the class that fits, applied to the sampled level distribution
    local keep  = math.max(math.floor(sampled * WHO_RESULT_CAP / classTotal), 1)
    local floor = probe.levels[keep]
    -- ties below the cut would come along, so start above them
    if probe.levels[keep + 1] == floor then floor = floor + 1 end
    return floor
end

-- The floor for the next scan of a class or race, by its leaderboard index. Starts at the probe's estimate, or at lo
-- (nothing below it matters), and bisects towards the lowest floor whose result still fits under the /who row
-- cap: an overflowing result is an arbitrary subset that can miss the top players.
-- hi is the highest level seen so far, there is no point in probing far above it.
function WoWForeverRaceScanner:NextClassFloor(classIndex, lo, hi, now)
    local floor = self.classScanFloor[classIndex]
    local full  = self.lastResultFull[classIndex]
    -- consumed: a lost reply must repeat the floor, not move it again
    self.lastResultFull[classIndex] = nil

    if floor == nil then
        -- a leaderboard index that is no class index belongs to a race
        local className = WoWForeverRace.Config.Classes[classIndex]
        local raceIndex = className == nil and classIndex - WoWForeverRace.Config.RaceBoardOffset or nil
        floor = self:ProbeFloor(className, raceIndex) or lo
    elseif full == true then
        -- Over the cap → raise floor, halfway to a floor known to fit (or to hi).
        local target  = hi
        local fitting = self.classFittingFloor[classIndex]
        if fitting and fitting.level > floor and now - fitting.at < FLOOR_BOUND_TTL then
            target = fitting.level
        end
        floor = floor + math.max(math.ceil((target - floor) / 2), 1)
    elseif full == false then
        -- Under the cap → lower floor, but not back into a range known to overflow.
        local low    = lo
        local capped = self.classCappedFloor[classIndex]
        if capped and now - capped.at < FLOOR_BOUND_TTL then
            low = math.max(low, capped.level + 1)
        end
        if floor > low then
            floor = floor - math.ceil((floor - low) / 2)
        end
    end

    floor = math.min(math.max(floor, lo), WoWForeverRace.Config.MaxLevel - 1)
    self.classScanFloor[classIndex] = floor
    return floor
end

-- TriggerScan sends a /who query for the next class or race leaderboard that isn't final.
-- Once all of them are it falls back to a global level scan.
-- MUST be called from a hardware event context (mouse click, key press).
-- Safe to call frequently; enforces a 15s cooldown internally.
function WoWForeverRaceScanner:TriggerScan()
    local now = GetTime()

    -- before the finished check: a scan that was pending when the race finished
    -- must still hand the who UI back
    if self.scanPending then
        if now - self.lastScanTime < SCAN_TIMEOUT then return end
        -- The server silently dropped the /who response; abandon the pending
        -- scan so a lost reply can't disable scanning for the whole session.
        self:AbandonScan()
    end

    if self.DB.factionrealm.finished then return end

    if now - self.lastScanTime < SCAN_COOLDOWN then return end
    self.lastScanTime = now

    local maxLevel   = WoWForeverRace.Config.MaxLevel
    local maxSize    = WoWForeverRace.Config.MaxLeaderboardSize
    local slots      = self:ScanSlots()
    local numSlots   = #slots
    local query      = nil

    -- The session's first scan is an unfiltered probe of the whole level range: its
    -- rows tell the class scans where to start, see ProbeFloor. On an empty
    -- leaderboard it repeats until somebody is found.
    local globalLb = self.DB.factionrealm.leaderboard[0]
    local probing = self.probe == nil or not globalLb or #globalLb.players == 0
    if probing then
        self.lastScanClassIndex = nil
        self.lastScanRaceIndex = nil
        query = "2-" .. tostring(maxLevel)
    end

    -- Cycle through the classes and races that still need work.
    -- One is done only when its leaderboard is full AND the lowest player is already at max level.
    if not query then for i = 0, numSlots - 1 do
        local slot       = ((self.nextScanClassIdx - 1 + i) % numSlots) + 1
        local classIndex = slots[slot].boardIndex
        local classLb    = self.DB.factionrealm.leaderboard[classIndex]
        local filter     = slots[slot].filter
        local completeAt = self.classScanComplete[classIndex]
        local restingComplete = completeAt ~= nil and now - completeAt < CLASS_COMPLETE_TTL
        local isDone = classLb and (
                restingComplete
                or (#classLb.players >= maxSize and classLb.minLevel >= maxLevel))

        if filter and classLb and not isDone then
            self.nextScanClassIdx = (slot % numSlots) + 1
            self.lastScanClassIndex = classIndex
            self.lastScanRaceIndex = slots[slot].raceIndex

            -- Leaderboard full but players still leveling: nothing below the lowest known level matters.
            local lo = 2
            if #classLb.players >= maxSize then
                lo = math.min(math.max(classLb.minLevel, 2), maxLevel - 1)
            end
            local hi = math.max(classLb.highestLevel, globalLb.highestLevel)
            local scanMin = self:NextClassFloor(classIndex, lo, hi, now)

            query = tostring(scanMin) .. "-" .. tostring(maxLevel) .. " " .. filter
            break
        end
    end end -- end class / race scan loop + if not query guard

    -- All class and race leaderboards done: scan by global top range
    if not query then
        self.lastScanClassIndex = nil
        self.lastScanRaceIndex = nil
        local lb = self.DB.factionrealm.leaderboard[0]

        -- Global leaderboard is also full with everyone at max level - the race
        -- may be over; the Tracker verifies every class and race board before finishing.
        if #lb.players >= maxSize and lb.minLevel >= maxLevel then
            self.EventBus:PublishEvent(WoWForeverRace.Config.Events.ScanFinished, true)
            return
        end

        local scanMin = math.max(lb.minLevel, lb.highestLevel)
        if scanMin <= 1 then scanMin = maxLevel - 10 end
        if scanMin >= maxLevel then scanMin = maxLevel - 1 end
        query = tostring(scanMin) .. "-" .. tostring(maxLevel)
    end

    WoWForeverRace:DebugPrint("Scanning /who " .. query, true)

    if C_FriendList and C_FriendList.SendWho then
        self:SuppressWhoUi()
        self.pendingScanMin = tonumber(string.match(query, "^(%d+)-"))
        self.probePending = probing
        self.scanPending = true
        self.foreignWhoSeen = false
        self.sendingWho = true
        C_FriendList.SendWho(query)
        self.sendingWho = false

        -- Restoring the who UI needs no hardware event, so a lost reply is not
        -- left waiting for the player's next world click.
        self.scanToken = (self.scanToken or 0) + 1
        local token, _self = self.scanToken, self
        C_Timer.After(SCAN_TIMEOUT, function()
            if _self.scanPending and _self.scanToken == token then
                _self:AbandonScan()
            end
        end)
    end
end
