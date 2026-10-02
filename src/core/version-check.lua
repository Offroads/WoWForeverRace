-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- WoW API
local C_Timer = _G.C_Timer

local CLOCK_SLACK = 24 * 60 * 60 -- a build can't be newer than now, give or take a day

-- How stable a build is, read from its version (the tag name): the packager publishes a
-- tag with "alpha" or "beta" in it as that release type, and the build of an untagged
-- commit ("v1.0.0-3-g1a2b3c4") is nothing anybody was offered.
local ALPHA, BETA, RELEASE = 1, 2, 3
local function releaseRank(version)
    local lower = version:lower()
    if lower:find("alpha", 1, true) or lower:find("%-%d+%-g%x+$") then
        return ALPHA
    elseif lower:find("beta", 1, true) then
        return BETA
    end
    return RELEASE
end

--[[
VersionCheck tells the player when a newer version of the addon is out.

An addon can't reach the internet, so the clients tell each other: every client adds its
build to the CHSYNC it sends to the realm channel (field 4, {buildTime, version}, see
Config:BuildInfo and Sync:SendChannelSync), which the whole faction hears. A client that
hears a newer build there remembers it and warns its player, once per session.

Addon messages are not signed, so a build only counts once Config.VersionConfirmations
different players announced it (or a newer one), and a client only ever announces its
own build, never what it heard.
]]--
---@class WoWForeverRaceVersionCheck
---@field Config WoWForeverRaceConfig
---@field Core WoWForeverRaceCore
---@field DB table<string, table>
---@field EventBus WoWForeverRaceEventBus
local WoWForeverRaceVersionCheck = {}
WoWForeverRaceVersionCheck.__index = WoWForeverRaceVersionCheck
WoWForeverRace.VersionCheck = WoWForeverRaceVersionCheck
setmetatable(WoWForeverRaceVersionCheck, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function WoWForeverRaceVersionCheck.new(Config, Core, DB, EventBus)
    local self = setmetatable({}, WoWForeverRaceVersionCheck)

    self.Config = Config
    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus

    -- the newest builds announced this session, one per sender, newest first
    self.claims = {}
    self.warned = false

    EventBus:RegisterCallback(self.Config.Network.Events.ChannelSync, self, self.OnNetChannelSync)

    return self
end

-- At login: what an earlier session heard still stands, unless we were updated since.
function WoWForeverRaceVersionCheck:Init()
    if self:NewerVersion() == nil then
        self.DB.global.newerVersion = nil
        return
    end

    -- after the login chatter, so the line is not scrolled away
    local _self = self
    C_Timer.After(self.Config.VersionWarnDelay, function() _self:Warn() end)
end

-- Whether a build is one to tell the player about. It comes from another client or from
-- the saved variables, and its version ends up in the chat frame: only a short one made
-- of letters, digits, dots and hyphens passes, so no escape code or link does.
function WoWForeverRaceVersionCheck:IsNewer(buildTime, version)
    local mine = self.Config:BuildInfo()
    if mine == nil then return false end

    if type(buildTime) ~= "number" or buildTime % 1 ~= 0 then return false end
    if type(version) ~= "string" or #version > self.Config.VersionMaxLength
            or not version:find("^[%w%.%-]+$") then
        return false
    end
    if buildTime <= mine[1] or buildTime > self.Core:Now() + CLOCK_SLACK then return false end

    -- a player on a release is not sent after a beta, their addon manager would not offer it
    return releaseRank(version) >= releaseRank(mine[2])
end

-- The version of the newest build we know of, nil when ours is the newest.
function WoWForeverRaceVersionCheck:NewerVersion()
    local known = self.DB.global.newerVersion
    if type(known) ~= "table" or not self:IsNewer(known.buildTime, known.version) then
        return nil
    end
    return known.version
end

-- A player announced itself on the realm channel (CHSYNC, field 4 = its build).
function WoWForeverRaceVersionCheck:OnNetChannelSync(payload, sender)
    if type(payload) ~= "table" or type(sender) ~= "string" then return end
    local build = payload[4]
    if type(build) ~= "table" then return end
    local buildTime, version = build[1], build[2]
    if not self:IsNewer(buildTime, version) then return end

    -- each sender counts once, with the newest build it announced
    local claims = self.claims
    for i, claim in ipairs(claims) do
        if claim.sender == sender then
            if claim.buildTime >= buildTime then return end
            table.remove(claims, i)
            break
        end
    end
    claims[#claims + 1] = {sender = sender, buildTime = buildTime, version = version}
    table.sort(claims, function(a, b) return a.buildTime > b.buildTime end)

    -- Only the newest VersionConfirmations claims are kept. The oldest of them is the
    -- build that many players run at least: that one is confirmed.
    local needed = self.Config.VersionConfirmations
    claims[needed + 1] = nil
    local confirmed = claims[needed]
    if confirmed == nil then return end

    if self:NewerVersion() == nil or confirmed.buildTime > self.DB.global.newerVersion.buildTime then
        WoWForeverRace:DebugPrint("Newer version heard: " .. confirmed.version)
        self.DB.global.newerVersion = {buildTime = confirmed.buildTime, version = confirmed.version}
    end
    self:Warn()
end

-- One chat line per session.
function WoWForeverRaceVersionCheck:Warn()
    if self.warned then return end
    local newer = self:NewerVersion()
    if newer == nil then return end

    self.warned = true
    WoWForeverRace:PPrint("A newer version is available: " .. newer .. " (you have "
            .. self.Config:DisplayVersion() .. "). Update it with your addon manager or from CurseForge.")
end
