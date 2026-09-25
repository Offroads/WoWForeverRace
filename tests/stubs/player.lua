-- Stubs for player / realm / group state and the /who API. Every stub comes
-- with a Set* helper so a test can put the world into the state it needs;
-- calling a Set* helper with nil restores the default.
local whoResults = {}
local whoTotal = nil
local whoQuery = nil

_G.C_FriendList = {
    -- returns (numWhos, totalCount) like the real API
    -- total: nil = same as the row count, false = the client reports no total
    GetNumWhoResults = function()
        if whoTotal == false then return #whoResults end
        return #whoResults, whoTotal or #whoResults
    end,
    GetWhoInfo = function(index)
        return whoResults[index]
    end,
    SetWhoToUi = function() end,
    SendWho = function(query)
        whoQuery = query
    end,
}
-- results: list of {fullName, level, filename, raceStr}; total: server-side match count
-- (defaults to #results, pass a higher value to simulate a truncated result)
_G.SetWhoResults = function(results, total)
    whoResults = results or {}
    whoTotal = total
end
_G.GetWhoQuery = function()
    return whoQuery
end
_G.ResetWhoQuery = function()
    whoQuery = nil
end
-- The Blizzard who panel is a real frame stub: WoW Forever keeps the who list in
-- LFGWhoListFrame (listening for WHO_LIST_UPDATE, not on screen by default).
_G.LFGWhoListFrame = _G.CreateFrame("Frame")
_G.LFGWhoListFrame:Hide()
_G.LFGWhoListFrame:RegisterEvent("WHO_LIST_UPDATE")
-- see SetWhoPanelVisible(visible): is the who panel on screen
_G.SetWhoPanelVisible = function(visible)
    if visible then
        _G.LFGWhoListFrame:Show()
    else
        _G.LFGWhoListFrame:Hide()
    end
end
-- see SetInCombat(inCombat): the combat lockdown
local inCombat = false
_G.InCombatLockdown = function()
    return inCombat
end
_G.SetInCombat = function(value)
    inCombat = value or false
end
_G.GetRealmName = function()
    return "NubVille"
end

-- Group members, see SetGroupMembers(members, inRaid): the unit tokens party1..
-- (or raid2.., raid1 being ourselves) resolve to these; every other unit token is
-- the player. Each member: {name, realm, level, class (file name), raceIndex,
-- faction (default the player's), connected}.
local groupMembers = {}

local function groupMember(unit)
    if type(unit) ~= "string" then return nil end
    local prefix, index = string.match(unit, "^(%a+)(%d+)$")
    if prefix == "party" then
        return groupMembers[tonumber(index)]
    elseif prefix == "raid" then
        return groupMembers[tonumber(index) - 1]
    end
    return nil
end

_G.UnitName = function(unit)
    local member = groupMember(unit)
    if member ~= nil then
        return member.name, member.realm
    end
    return "Nub"
end

-- the full name, with the realm appended for a cross realm unit when asked
_G.GetUnitName = function(unit, showServer)
    local name, realm = _G.UnitName(unit)
    if showServer and realm ~= nil and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

_G.UnitClass = function(unit)
    local member = groupMember(unit)
    if member ~= nil then
        return member.class, member.class, 0
    end
    return "Druid", "DRUID", 11
end

_G.UnitRace = function(unit)
    local member = groupMember(unit)
    if member ~= nil then
        return "Race", "Race", member.raceIndex
    end
    return "Night Elf", "NightElf", 4
end

_G.UnitLevel = function(unit)
    local member = groupMember(unit)
    if member ~= nil then
        return member.level or 0
    end
    return 60
end

-- The playable races as the enUS client names them. See SetRaceNames(names): the
-- stub reads the table on every call, but Core caches the names per instance, so
-- set them before creating the Core under test.
local defaultRaces = {
    [1] = {"Human", "Human"}, [2] = {"Orc", "Orc"}, [3] = {"Dwarf", "Dwarf"},
    [4] = {"Night Elf", "NightElf"}, [5] = {"Undead", "Scourge"}, [6] = {"Tauren", "Tauren"},
    [7] = {"Gnome", "Gnome"}, [8] = {"Troll", "Troll"},
    [95] = {"High Order Skyborne", "Skyborne"}, [96] = {"Windshaper Skyborne", "Skyborne"},
}
local raceNames = {}
_G.C_CreatureInfo = {
    GetRaceInfo = function(raceID)
        local race = defaultRaces[raceID]
        if race == nil then return nil end
        return {raceName = raceNames[raceID] or race[1], clientFileString = race[2], raceID = raceID}
    end,
}

-- names: {[raceID] = localized name}, to simulate another client language
_G.SetRaceNames = function(names)
    raceNames = names or {}
end

-- see SetFaction(faction): the stub reads the variable on every call, because
-- AceDB and core.lua capture the function itself when they load
local defaultFaction = "Alliance"
local playerFaction = defaultFaction
_G.UnitFactionGroup = function(unit)
    local member = groupMember(unit)
    if member ~= nil then
        return member.faction or playerFaction
    end
    return playerFaction
end

_G.SetFaction = function(faction)
    if faction == nil then
        faction = defaultFaction
    end
    playerFaction = faction
end

_G.GetBuildInfo = function()
    return "1.60.1", "69893", "Sep 16 2026", 16001
end

local defaultIsInGuild = true
local isInGuild = defaultIsInGuild
_G.IsInGuild = function()
    return isInGuild
end

_G.SetIsInGuild = function(inGuild)
    if inGuild == nil then
        inGuild = defaultIsInGuild
    end
    isInGuild = inGuild
end

-- the guild roster, see SetGuildRoster(members): each member is
-- {name (Name-Realm), level, class (file name), online, race (client file string,
-- nil when the client doesn't know the player yet)}; GetPlayerInfoByGUID resolves
-- the member's guid ("Player-<index>") to it
local guildRoster = {}
local guildRosterRequests = 0
_G.GetNumGuildMembers = function()
    local online = 0
    for _, member in ipairs(guildRoster) do
        if member.online then online = online + 1 end
    end
    return #guildRoster, online
end
_G.GetGuildRosterInfo = function(i)
    local member = guildRoster[i]
    if member == nil then return nil end
    return member.name, "Member", 1, member.level, member.class, "Zone", "", "", member.online or false,
        0, member.class, 0, 0, false, false, 0, "Player-" .. i
end
_G.GetPlayerInfoByGUID = function(guid)
    local index = tonumber(string.match(tostring(guid), "^Player%-(%d+)$"))
    local member = index and guildRoster[index]
    if member == nil or member.race == nil then return nil end
    return member.class, member.class, member.race, member.race, 2, member.name, "", member.level
end
_G.C_GuildInfo = {
    GuildRoster = function()
        guildRosterRequests = guildRosterRequests + 1
    end,
}
_G.SetGuildRoster = function(members)
    guildRoster = members or {}
    guildRosterRequests = 0
end
-- how many times the roster was requested since SetGuildRoster
_G.GetGuildRosterRequests = function()
    return guildRosterRequests
end

_G.GetLocale = function()
    return "enUS"
end

_G.GetCurrentRegion = function()
    return 3 -- EU, from ("US", "KR", "EU", "TW", "CN")
end

_G.GetCurrentRegionName = function()
    return "EU"
end

_G.UnitFullName = function(target)
    -- @TODO: returns name-server for cross realm, should make a test for this
    if target == "player" then
        return _G.UnitName(), _G.GetRealmName()
    else
        error("unsupported", 1)
    end
end

local defaultRealZoneText = "Ironforge"
local realZoneText = defaultRealZoneText
_G.SetRealZoneText = function(zoneText)
    if zoneText == nil then
        zoneText = defaultRealZoneText
    end
    realZoneText = zoneText
end

_G.GetRealZoneText = function()
    return realZoneText
end

-- group state, see SetGroupState(numMembers, isRaid, isInstanceGroup)
local defaultNumGroupMembers = 0
local numGroupMembers = defaultNumGroupMembers
local isInRaid = false
local isInInstanceGroup = false
_G.LE_PARTY_CATEGORY_HOME = 1
_G.LE_PARTY_CATEGORY_INSTANCE = 2

_G.SetNumGroupMembers = function(members)
    if members == nil then
        members = defaultNumGroupMembers
    end
    numGroupMembers = members
end

_G.SetGroupState = function(members, inRaid, inInstanceGroup)
    _G.SetNumGroupMembers(members)
    isInRaid = inRaid or false
    isInInstanceGroup = inInstanceGroup or false
end

_G.GetNumGroupMembers = function()
    return numGroupMembers
end

-- the other members of our group (the player is counted on top), nil leaves the group
_G.SetGroupMembers = function(members, inRaid)
    groupMembers = members or {}
    if #groupMembers == 0 then
        _G.SetGroupState(nil)
    else
        _G.SetGroupState(#groupMembers + 1, inRaid)
    end
end

_G.IsInRaid = function()
    return isInRaid
end

_G.IsInGroup = function(category)
    if category == _G.LE_PARTY_CATEGORY_INSTANCE then
        return isInInstanceGroup
    end
    return numGroupMembers > 0
end

_G.GetRaidRosterInfo = function(i)
    -- @TODO: returns name-server for cross realm, should make a test for this
    if i == 1 then
        return _G.UnitName()
    end

    return "Player-" .. i
end
