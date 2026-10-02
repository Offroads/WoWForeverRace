-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- WoW API
local C_Timer, IsInGuild = _G.C_Timer, _G.IsInGuild

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

An addon can't reach the internet, so the clients tell each other. Every client adds its
build ({buildTime, version}, see Config:BuildInfo) to the CHSYNC it sends to the realm
channel (field 4, see Sync:SendChannelSync), which the whole faction hears. Once per login
it also sends it as VERSION to its guild and to every buddy (Announce): the players it
knows, who may be outside the channel. A client that hears a newer build remembers it and
warns its player, once per session.

One player on a newer build is enough: few players run the addon, and the first to update
may be the only one online. Addon messages are not signed, so a forged build can make
clients print a warning that is not true, nothing more: what is accepted is checked
(IsNewer), and a client only ever announces its own build, never what it heard.
]]--
---@class WoWForeverRaceVersionCheck
---@field Config WoWForeverRaceConfig
---@field Core WoWForeverRaceCore
---@field DB table<string, table>
---@field EventBus WoWForeverRaceEventBus
---@field Network WoWForeverRaceNetwork
local WoWForeverRaceVersionCheck = {}
WoWForeverRaceVersionCheck.__index = WoWForeverRaceVersionCheck
WoWForeverRace.VersionCheck = WoWForeverRaceVersionCheck
setmetatable(WoWForeverRaceVersionCheck, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function WoWForeverRaceVersionCheck.new(Config, Core, DB, EventBus, Network)
    local self = setmetatable({}, WoWForeverRaceVersionCheck)

    self.Config = Config
    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus
    self.Network = Network

    self.warned = false

    EventBus:RegisterCallback(self.Config.Network.Events.ChannelSync, self, self.OnNetChannelSync)
    EventBus:RegisterCallback(self.Config.Network.Events.Version, self, self.OnNetVersion)

    return self
end

-- At login.
function WoWForeverRaceVersionCheck:Init()
    local _self = self
    C_Timer.After(self.Config.VersionAnnounceDelay, function() _self:Announce() end)

    -- what an earlier session heard still stands, unless we were updated since
    if self:NewerVersion() == nil then
        self.DB.global.newerVersion = nil
        return
    end
    -- after the login chatter, so the line is not scrolled away
    C_Timer.After(self.Config.VersionWarnDelay, function() _self:Warn() end)
end

-- Tells the guild and every buddy which build we run, once per login. Buddies we did
-- not hear from for BuddyMaxAge are about to be dropped (Sync:PruneBuddies): not them.
function WoWForeverRaceVersionCheck:Announce()
    local build = self.Config:BuildInfo()
    if build == nil then return end
    if not self.DB.profile.options.networking or self.DB.factionrealm.finished then return end

    -- The messages held back during a chat messaging lockdown are capped, a whisper per
    -- buddy would push the others out: wait until it has ended
    if self.Network.IsLockedDown and self.Network:IsLockedDown() then
        local _self = self
        C_Timer.After(self.Config.RetrySyncWait, function() _self:Announce() end)
        return
    end

    local event = self.Config.Network.Events.Version
    if IsInGuild() then
        self.Network:SendObject(event, build, "GUILD")
    end
    local oldest = self.Core:Now() - self.Config.BuddyMaxAge
    for name, buddy in pairs(self.DB.factionrealm.buddies) do
        if buddy.lastSeen ~= nil and buddy.lastSeen >= oldest then
            self.Network:SendObject(event, build, "WHISPER", name)
        end
    end
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
    if type(payload) ~= "table" then return end
    self:OnNetVersion(payload[4], sender)
end

-- A guild member or a buddy told us its build (VERSION), or a player on the realm channel.
function WoWForeverRaceVersionCheck:OnNetVersion(build, sender)
    if type(build) ~= "table" then return end
    local buildTime, version = build[1], build[2]
    if not self:IsNewer(buildTime, version) then return end

    if self:NewerVersion() == nil or buildTime > self.DB.global.newerVersion.buildTime then
        WoWForeverRace:DebugPrint("Newer version heard from " .. tostring(sender) .. ": " .. version)
        self.DB.global.newerVersion = {buildTime = buildTime, version = version}
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
