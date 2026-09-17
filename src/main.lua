-- Libs
local LibStub = _G.LibStub

-- Addon global
---@class WoWForeverRace
---@field Config        WoWForeverRaceConfig
---       our config table
---@field Colors        WoWForeverRaceColors
---       our color shorthand table
---@field Serializer    WoWForeverRaceSerializer
---       our custom serializer
---@field Core          WoWForeverRaceCore
---       contains basic helpers such as :Me(), :Now(), etc
---@field EventBus      WoWForeverRaceEventBus
---       event bus to facilitate communication between components
---@field Network       WoWForeverRaceNetwork
---       bridge between AceComms and our EventBus
---@field Scanner       WoWForeverRaceScanner
---       contains ticker to start Scans and publishes events based of Scan results
---@field Tracker       WoWForeverRaceTracker
---       manages the leaderboard based on events
---@field ChatNotifier  WoWForeverRaceChatNotifier
---       writes notifications in chat window based on events
---@field updater       WoWForeverRaceUpdater
---@field Sync          WoWForeverRaceSync
---       handles syncing when coming online
---@field StatusFrame   WoWForeverRaceStatusFrame
---       GUI element to display the leaderboard
---@field PioneersView  WoWForeverRacePioneersView
---       renders the Pioneers (first-to-level) tab inside the status frame
---@field DefaultDB     WoWForeverRaceDefaultDB
WoWForeverRace = LibStub("AceAddon-3.0"):NewAddon("WoWForeverRace", "AceConsole-3.0")

function WoWForeverRace:OnInitialize()
    self.Config = WoWForeverRace.Config
    self.Colors = WoWForeverRace.Colors
    self:ApplyExpansionConfig()
    self.DB = LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)

    -- determine who we are
    local player, realm = UnitFullName("player")

    -- init components (should have minimal side effects)
    self.Core = WoWForeverRace.Core(self.Config, player, realm)
    self.EventBus = WoWForeverRace.EventBus()
    self.Network = WoWForeverRace.Network(self.Core, self.EventBus)
    self.Tracker = WoWForeverRace.Tracker(self.Config, self.Core, self.DB, self.EventBus, self.Network)
    self.ChatNotifier = WoWForeverRace.ChatNotifier(self.Config, self.Core, self.DB, self.EventBus)
    self.Sync = WoWForeverRace.Sync(self.Config, self.Core, self.DB, self.EventBus, self.Network)
    self.updater = WoWForeverRace.Updater(self.Core, self.EventBus)
    self.StatusFrame = WoWForeverRace.StatusFrame(self.Config, self.Core, self.DB, self.EventBus)
    self.DebugFrame = WoWForeverRace.DebugFrame(self.Config, self.Core, self.DB, self.EventBus)

    self.scanner = WoWForeverRace.Scanner(self.Core, self.DB, self.EventBus)

    -- message stats counters and hash mismatch log (only populated when debug mode is on)
    WoWForeverRace.MsgStats = { send = {}, recv = {} }
    WoWForeverRace.HashLog = {}

    -- any reset of the database (ours, the options panel, a dev command, a
    -- future profile reset) hands the components fresh tables to bind to
    self.DB.RegisterCallback(self, "OnDatabaseReset", "OnDatabaseReset")

    self:DBMigrations()

    self.EventBus:RegisterCallback(self.Config.Events.NetworkReady, self, function()
        self.Sync:InitSync()
    end)

    self:DebugPrint("me: " .. self.Core:RealMe())
end

function WoWForeverRace:OnEnable()
    -- debug print, will also help us know if debugging is enabled
    self:DebugPrint("WoWForeverRace:OnEnable")

    self:RegisterOptions()
    self:RegisterChatCommand("wfr", "slashwfr")

    -- determine who we are
    local player, realm = UnitFullName("player")
    self.Core:InitMe(player, realm)
    self:DebugPrint("me: " .. self.Core:RealMe())

    self.Network:Init()

    self.Tracker:InitDiscoveryTicker()
    self.Sync:InitGuildTicker()
    self.Sync:InitBuddyTicker()

    local groupEventFrame = CreateFrame("Frame")
    groupEventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    groupEventFrame:SetScript("OnEvent", function()
        self.Sync:OnGroupRosterUpdate()
    end)

    if self.DB.profile.gui.display then
        self.StatusFrame:Show()
    end

    if self.DB.profile.options.debug then
        self.DebugFrame:Show()
    end
end

function WoWForeverRace:DBMigrations()
    -- fresh DB or pre-versioning DB, reset and init ...
    if self.DB.factionrealm.dbversion == "0.0.0" then
        self:ResetDB()
        -- Record server time as realm-opened reference on first ever login.
        -- GetServerTime() is server-synced (UTC), not affected by client timezone.
        self.DB.factionrealm.realmOpenedAt = GetServerTime()
        return
    end
    -- one-time migration: seed pioneer data from existing leaderboard entries
    if not self.DB.factionrealm.pioneersMigrated then
        self:MigratePioneerData()
        self.DB.factionrealm.pioneersMigrated = true
    end
end

-- Populates firstToLevel and playerHistory from whatever leaderboard data already exists.
-- Only runs once per DB (on first load after the pioneers feature is introduced).
function WoWForeverRace:MigratePioneerData()
    local classIndexes = {0}
    for _, classIndex in ipairs(self.Config.MopClassIndexes) do
        classIndexes[#classIndexes + 1] = classIndex
    end

    for _, classIndex in ipairs(classIndexes) do
        local lb = self.DB.factionrealm.leaderboard[classIndex]
        if lb and #lb.players > 0 then
            for _, player in ipairs(lb.players) do
                if player.dingedAt then
                    self.Tracker:UpdatePioneers(player)
                    self.Tracker:UpdatePlayerHistory(player)
                end
            end
        end
    end
end

function WoWForeverRace:ResetDB()
    -- Preserve realmOpenedAt so a manual data reset doesn't lose the realm launch timestamp.
    local realmOpenedAt = self.DB.factionrealm.realmOpenedAt
    -- fires OnDatabaseReset, which re-binds the components to the new tables
    self.DB:ResetDB()
    self.DB.factionrealm.dbversion = self.Config.Version
    if realmOpenedAt then
        self.DB.factionrealm.realmOpenedAt = realmOpenedAt
    end
end

-- AceDB replaces db.factionrealm and db.profile on a reset; everything that
-- cached a sub-table has to pick up the new one.
function WoWForeverRace:OnDatabaseReset()
    if self.Tracker then
        self.Tracker:ReinitLeaderboards()
    end
    if self.scanner then
        self.scanner:ResetState()
    end
    if self.StatusFrame then
        if self.StatusFrame.frame then
            -- re-open so the window binds to the fresh profile status table too
            self.StatusFrame:Show()
        else
            self.StatusFrame:Refresh()
        end
    end
end

--[[
The /wfr handler, toggles the frame, unless overwritten in dev.lua with a more advanced development mode /wfr
--]]
function WoWForeverRace:slashwfr(input)
    if input == "debug" then
        self.DebugFrame:Show()
    else
        self.StatusFrame:Show()
    end
end

function WoWForeverRace:ApplyExpansionConfig()
    self.Config:ApplyExpansion(nil, UnitFactionGroup("player"))
end
