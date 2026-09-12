-- Luacheck configuration, see https://luacheck.readthedocs.io
--
-- WoW embeds Lua 5.1, so that is the standard library we lint against. WoW API
-- functions the addon uses are declared below as read-only globals; add to the
-- list when you start using a new API (a typo in an API name then fails lint
-- instead of erroring in-game).
std = "lua51"
codes = true
max_line_length = false

ignore = {
    "212/self",   -- unused argument self (methods that don't need it)
    "542",        -- empty if branch (used for documented no-op cases)
    "142/string", -- setting a field of the global string table (string:SplitString)
    "614",        -- trailing whitespace in a comment
}

-- the addon object is the single global the addon defines (in main.lua)
globals = {
    "WoWForeverRace",
}

read_globals = {
    -- string / table helpers WoW adds to the global namespace
    "strmatch", "strfind", "strsub", "strlower", "strupper", "strtrim", "strsplit", "strjoin",
    "strlenutf8", "tinsert", "tremove", "wipe", "hooksecurefunc", "geterrorhandler",
    "debugprofilestop",
    -- libraries
    "LibStub",
    -- WoW API used by the addon
    "C_FriendList", "C_Timer", "C_ChatInfo", "CreateFrame",
    "GetBuildInfo", "GetServerTime", "GetTime", "GetFramerate",
    "GetNumGroupMembers", "IsInGuild", "IsInRaid", "IsInGroup",
    "UnitClass", "UnitFactionGroup", "UnitFullName", "UnitName", "GetRealmName",
    -- WoW UI globals / constants
    "FriendsFrame", "WorldFrame", "GameFontNormalLarge", "CLASS_ICON_TCOORDS",
    "DEFAULT_CHAT_FRAME", "LE_PARTY_CATEGORY_HOME", "LE_PARTY_CATEGORY_INSTANCE",
}

files["src/config.lua"] = {
    -- Debug/Trace are assigned twice on purpose (the @debug@ block)
    ignore = {"314"},
}

-- tests run under busted and use the helpers exported by tests/stubs/*.lua
files["tests"] = {
    std = "+busted",
    ignore = {
        "411",        -- redefining a local (assert blocks reuse the same names)
        "143/string", -- string:SplitString is added by src/util/util.lua
    },
    globals = {"WoWForeverRace"},
    read_globals = {
        "SetTime", "SetWhoResults", "GetWhoQuery", "ResetWhoQuery",
        "SetIsInGuild", "SetRealZoneText", "SetNumGroupMembers", "SetGroupState",
        "GetRaidRosterInfo", "GetRealZoneText", "GetLocale", "GetCurrentRegion", "UnitRace",
        "SendChatMessage", "SendAddonMessage", "BNSendGameData", "C_BattleNet", "Enum",
    },
}

-- the stubs define WoW globals through _G, that's their whole purpose
files["tests/stubs"] = {
    allow_defined_top = true,
}
