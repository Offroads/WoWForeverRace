--[[
This file contains development-only things that aren't pretty but don't need to be ... xD

It is only loaded from an unpackaged checkout (see the @debug@ block in the .toc),
release builds never ship it.
--]]
-- Addon global
local WoWForeverRace = _G.WoWForeverRace

local HELP = {
    "/wfr show           show the leaderboard window",
    "/wfr debug          show the debug window (message stats, hash log, buddies)",
    "/wfr render         re-render the leaderboard window",
    "/wfr status         print scanner / sync / leaderboard state",
    "/wfr scan           trigger a /who scan now (must be typed, needs a hardware event)",
    "/wfr update         re-run the login sync",
    "/wfr ding NAME LVL [CLASS]   fake a /who result for a player",
    "/wfr whoami NAME    pretend to be another player on this realm",
    "/wfr reset          wipe the leaderboards, pioneers and history for this faction-realm (keeps realmOpenedAt)",
}

--[[
The /wfr handler, overwrites with a more advanced development mode /wfr
--]]
function WoWForeverRace:slashwfr(input)
    local action, arg1, arg2, arg3 = self:GetArgs(input, 4)

    --[[SCAN]]--
    if action == "scan" then
        self.scanner:TriggerScan()

    --[[RESET]]--
    elseif action == "reset" then
        -- go through our own ResetDB (keeps the realm-opened timestamp and
        -- the db version; the components re-bind through OnDatabaseReset)
        self:ResetDB()
        self:PPrint("Database reset.")

    --[[SHOW FRAME]]--
    elseif action == "show" or action == nil or action == "" then
        self.StatusFrame:Show()

    --[[DEBUG FRAME]]--
    elseif action == "debug" then
        self.DebugFrame:Show()

    --[[UPDATE FRAME]]--
    elseif action == "render" then
        self.StatusFrame:Render()

    --[[REQUEST UPDATE]]--
    elseif action == "update" then
        self.Sync:InitSync()

    --[[STATUS]]--
    elseif action == "status" then
        self:PrintDevStatus()

    --[[WHOAMI]]--
    elseif action == "whoami" then
        if arg1 == nil then
            self:PPrint("usage: /wfr whoami NAME")
            return
        end
        self.Core:InitMe(arg1, self.Core:MyRealm())

    --[[DING name level]]--
    elseif action == "ding" then
        if arg1 == nil or tonumber(arg2) == nil then
            self:PPrint("usage: /wfr ding NAME LEVEL [CLASS]")
            return
        end
        self:DebugPrint("Forced Ding [" .. arg1 .. "] lvl" .. arg2 .. ".")
        self.EventBus:PublishEvent(self.Config.Events.SlashWhoResult, {{
            name = arg1,
            level = tonumber(arg2),
            class = arg3 and string.upper(arg3) or "DRUID",
        }})

    --[[HELP]]--
    elseif action == "help" then
        for _, line in ipairs(HELP) do
            self:PPrint(line)
        end
    else
        self:PPrint("Unknown action: " .. tostring(action) .. " (try /wfr help)")
    end
end

-- Dumps the in-memory state that is otherwise only visible through debug prints.
function WoWForeverRace:PrintDevStatus()
    local db = self.DB.factionrealm
    local scanner = self.scanner
    local sync = self.Sync

    self:PPrint("version " .. tostring(self.Config.Version) .. ", me: " .. tostring(self.Core:FullRealMe())
            .. ", expansion max level " .. tostring(self.Config.MaxLevel))
    self:PPrint("db version " .. tostring(db.dbversion) .. ", finished: " .. tostring(db.finished)
            .. ", realm opened " .. tostring(db.realmOpenedAt))

    for _, classIndex in ipairs({0, unpack(self.Config.MopClassIndexes)}) do
        local lb = db.leaderboard[classIndex]
        if lb and #lb.players > 0 then
            self:PPrint(string.format("  board %2d (%s): %d players, min lvl %d, max lvl %d",
                    classIndex, self.Core:ClassByIndex(classIndex), #lb.players, lb.minLevel, lb.highestLevel))
        end
    end

    self:PPrint("scanner: pending=" .. tostring(scanner.scanPending)
            .. " pendingMin=" .. tostring(scanner.pendingScanMin)
            .. " lastClass=" .. tostring(scanner.lastScanClassIndex)
            .. " nextClassSlot=" .. tostring(scanner.nextScanClassIdx)
            .. " lastScan=" .. tostring(scanner.lastScanTime))
    self:PPrint("sync: ready=" .. tostring(sync.isReady)
            .. " offers=" .. tostring(#sync.offers)
            .. " partner=" .. tostring(sync.syncPartner and sync.syncPartner.name)
            .. " lastSync=" .. tostring(sync.lastSync))

    self:PPrint("buddies: " .. WoWForeverRace.table.cnt(db.buddies)
            .. ", players with history: " .. WoWForeverRace.table.cnt(db.playerHistory))
end
