-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- WoW API
local GetServerTime, UnitClass, UnitFactionGroup = _G.GetServerTime, _G.UnitClass, _G.UnitFactionGroup

---@class WoWForeverRaceCore
---@field Config WoWForeverRaceConfig
local WoWForeverRaceCore = {}
WoWForeverRaceCore.__index = WoWForeverRaceCore
WoWForeverRace.Core = WoWForeverRaceCore

setmetatable(WoWForeverRaceCore, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function WoWForeverRaceCore.new(Config, player, realm)
    local self = setmetatable({}, WoWForeverRaceCore)

    self.Config = Config
    self.loginTime = GetServerTime()

    self.InitMe(self, player, realm)

    return self
end

function WoWForeverRaceCore:InitMe(player, realm)
    WoWForeverRace:DebugPrint("InitMe: " .. tostring(player)  .. ", " .. tostring(realm))
    if realm == nil then
        realm = "NaN"
    end

    self.realm = realm
    self.realme = player
    self.me = self.realme
end

function WoWForeverRaceCore:PlayerFull(player, realm)
    if realm == nil then
        realm = self.realm
    end

    return player .. "-" .. realm
end

function WoWForeverRaceCore:IsMyRealm(realm)
    return realm == nil or realm == self.realm
end

function WoWForeverRaceCore:MyRealm()
    return self.realm
end

function WoWForeverRaceCore:Me()
    return self.me
end

function WoWForeverRaceCore:RealMe()
    return self.realme
end

function WoWForeverRaceCore:FullMe()
    return self:PlayerFull(self.me)
end

function WoWForeverRaceCore:FullRealMe()
    return self:PlayerFull(self.realme)
end

function WoWForeverRaceCore:MyClass()
    local _, className, _ = UnitClass("player")
    return self:ClassIndex(className), className
end

-- The English faction tag ("Horde" / "Alliance"), the same value AceDB scopes the
-- factionrealm data by; never the localized second return.
function WoWForeverRaceCore:MyFaction()
    local faction = UnitFactionGroup("player")
    return faction
end

function WoWForeverRaceCore:ClassIndex(className)
    className = string.upper(className)
    className = string.gsub(className, " ", "")
    if self.Config.ClassIndexes[className] ~= nil then
        return self.Config.ClassIndexes[className]
    else
        return self.Config.UnknownClassIndex
    end
end

function WoWForeverRaceCore:ClassByIndex(classIndex)
    if classIndex ~= nil and self.Config.Classes[classIndex] ~= nil then
        return self.Config.Classes[classIndex]
    else
        return "UNKNOWN"
    end
end

function WoWForeverRaceCore:SplitFullPlayer(fullPlayer)
    local splt = WoWForeverRace.SplitString(fullPlayer, "-")

    return splt[1], splt[2]
end


function WoWForeverRaceCore:Now()
    return GetServerTime()
end

-- Reference time the race is measured from: the official realm launch once it has passed,
-- else (before launch, e.g. on the beta) the given inferred fallback. A ding from before the
-- launch (beta leftovers) keeps the fallback, so it never ends up with a negative time.
function WoWForeverRaceCore:RaceStartTime(fallback, dingedAt)
    local launchAt = self:LaunchTime()
    if self:HasLaunched() and (dingedAt == nil or dingedAt >= launchAt) then
        return launchAt
    end
    return fallback
end

function WoWForeverRaceCore:LaunchTime()
    return self.Config.RealmLaunchAt
end

function WoWForeverRaceCore:HasLaunched()
    local launchAt = self:LaunchTime()
    return launchAt ~= nil and self:Now() >= launchAt
end

-- True for a timestamp from before the realm launch, once that launch has passed. The released
-- race starts from fresh leaderboards, so such (beta) data is neither kept nor accepted.
function WoWForeverRaceCore:PredatesLaunch(timestamp)
    return self:HasLaunched() and type(timestamp) == "number" and timestamp < self:LaunchTime()
end

function WoWForeverRaceCore:LoginTime()
    return self.loginTime
end
