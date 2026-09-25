-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- WoW API
local CreateFrame, C_Timer = _G.CreateFrame, _G.C_Timer
local IsInGuild, GetNumGuildMembers, GetGuildRosterInfo = _G.IsInGuild, _G.GetNumGuildMembers, _G.GetGuildRosterInfo
local IsInRaid, GetNumGroupMembers = _G.IsInRaid, _G.GetNumGroupMembers
local UnitName, UnitLevel, UnitClass, UnitRace, UnitFactionGroup =
    _G.UnitName, _G.UnitLevel, _G.UnitClass, _G.UnitRace, _G.UnitFactionGroup

-- how often the guild roster is requested from the server (which ignores requests
-- that come in closer than 10s apart); the client also refreshes it on its own
local GUILD_ROSTER_REFRESH = 60
-- a level already forwarded is forwarded again after this long, so the tracker
-- sees every roster member again now and then (e.g. after its data was purged)
local RESEND_TTL = 15 * 60

--[[
Roster feeds the levels the client already knows into the tracker: the guild
roster and the members of the own party / raid. Both are exact, cost no /who
query and see players a /who scan can't (offline guild members). Every row is
published like a /who result, so it lands on the leaderboards and is pushed to
peers like any other ding.
]]--
---@class WoWForeverRaceRoster
---@field Core WoWForeverRaceCore
---@field DB table<string, table>
---@field EventBus WoWForeverRaceEventBus
local WoWForeverRaceRoster = {}
WoWForeverRaceRoster.__index = WoWForeverRaceRoster
WoWForeverRace.Roster = WoWForeverRaceRoster
setmetatable(WoWForeverRaceRoster, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function WoWForeverRaceRoster.new(Core, DB, EventBus)
    local self = setmetatable({}, WoWForeverRaceRoster)

    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus

    self:ResetState()

    self.Thread = CreateFrame("Frame")
    self.Thread:Hide()
    self.Thread:SetScript("OnEvent", function(_, event)
        if event == "GUILD_ROSTER_UPDATE" then
            self:OnGuildRosterUpdate()
        else
            self:OnGroupUpdate()
        end
    end)
    self.Thread:RegisterEvent("GUILD_ROSTER_UPDATE")
    self.Thread:RegisterEvent("GROUP_ROSTER_UPDATE")
    -- a group member leveling up
    self.Thread:RegisterEvent("UNIT_LEVEL")

    return self
end

-- forgets which levels were forwarded, so the next roster event re-feeds everyone
function WoWForeverRaceRoster:ResetState()
    -- [name] = {level, at}
    self.seen = {}
end

-- Ask the server for the guild roster now and then; GUILD_ROSTER_UPDATE follows.
function WoWForeverRaceRoster:InitGuildRosterTicker()
    local _self = self
    C_Timer.NewTicker(GUILD_ROSTER_REFRESH, function()
        _self:RequestGuildRoster()
    end)
    self:RequestGuildRoster()
end

function WoWForeverRaceRoster:RequestGuildRoster()
    if not IsInGuild() then return end
    if self.DB.factionrealm.finished then return end

    local guildInfo = _G.C_GuildInfo
    if guildInfo ~= nil and guildInfo.GuildRoster ~= nil then
        guildInfo.GuildRoster()
    elseif _G.GuildRoster ~= nil then
        _G.GuildRoster()
    end
end

function WoWForeverRaceRoster:OnGuildRosterUpdate()
    if not IsInGuild() then return end

    local batch = {}
    for i = 1, GetNumGuildMembers() or 0 do
        -- name, rankName, rankIndex, level, classDisplayName, zone, publicNote, officerNote, isOnline, status, class
        local fullName, _, _, level, _, _, _, _, _, _, class = GetGuildRosterInfo(i)
        -- the roster has no race; the tracker falls back to the one it remembers
        self:Collect(batch, fullName, level, class, nil)
    end
    self:Publish(batch)
end

function WoWForeverRaceRoster:OnGroupUpdate()
    local numMembers = GetNumGroupMembers() or 0
    if numMembers == 0 then return end

    local batch = {}
    local myFaction = self.Core:MyFaction()
    -- raid tokens include ourselves, party tokens don't (the Updater covers our own dings)
    local prefix, first, last = "party", 1, numMembers - 1
    if IsInRaid() then
        prefix, first, last = "raid", 1, numMembers
    end
    for i = first, last do
        local unit = prefix .. i
        local name, realm = UnitName(unit)
        -- cross faction groups exist on the retail family API: only our own race counts
        if name ~= nil and UnitFactionGroup(unit) == myFaction then
            if realm ~= nil and realm ~= "" then
                name = name .. "-" .. realm
            end
            local _, class = UnitClass(unit)
            local _, _, raceIndex = UnitRace(unit)
            self:Collect(batch, name, UnitLevel(unit), class, raceIndex)
        end
    end
    self:Publish(batch)
end

-- Adds one roster row to the batch when it is worth the tracker's time: a player
-- of our realm at a level we haven't forwarded yet (or not for a while).
function WoWForeverRaceRoster:Collect(batch, fullName, level, class, raceIndex)
    if type(fullName) ~= "string" or fullName == "" then return end
    level = tonumber(level)
    -- level 1 is no ding; 0 / -1 is what the client reports for a unit it doesn't know
    if level == nil or level < 2 or level > self.Core.Config.MaxLevel then return end

    local name, realm = self.Core:SplitFullPlayer(fullName)
    if not self.Core:IsMyRealm(realm) then return end

    local now = self.Core:Now()
    local seen = self.seen[name]
    if seen ~= nil and level <= seen.level and now - seen.at < RESEND_TTL then return end
    self.seen[name] = {level = level, at = now}

    batch[#batch + 1] = {
        name = name,
        level = level,
        class = type(class) == "string" and string.upper(class) or nil,
        raceIndex = self.Core:IsValidRaceIndex(raceIndex) and raceIndex or nil,
    }
end

function WoWForeverRaceRoster:Publish(batch)
    if #batch == 0 then return end
    if self.DB.factionrealm.finished then return end

    WoWForeverRace:DebugPrint("[R] roster: " .. #batch .. " players")
    self.EventBus:PublishEvent(WoWForeverRace.Config.Events.SlashWhoResult, batch)
end
