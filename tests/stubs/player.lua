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
_G.GetRealmName = function()
    return "NubVille"
end

_G.UnitName = function()
    return "Nub"
end

_G.UnitClass = function()
    return "Druid", "DRUID", 11
end

_G.UnitRace = function()
    return "Night Elf", "NightElf", 4
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
_G.UnitFactionGroup = function()
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
