-- Luacheck configuration, see https://luacheck.readthedocs.io
--
-- WoW embeds Lua 5.1, so that is the standard library we lint against. Every
-- WoW API function the addon references as a bare global is declared below as
-- read-only; add to the list when you start using a new API (a typo in an API
-- name then fails lint instead of erroring in-game). Globals reached through
-- `_G.Name` are not checked by luacheck and need no entry.
std = "lua51"
codes = true
max_line_length = false

ignore = {
    "212/self", -- unused argument self (methods that don't need it)
    "542",      -- empty if branch (used for documented no-op cases)
    "614",      -- trailing whitespace in a comment
}

-- the addon object is the single global the addon defines (in main.lua)
globals = {
    "WoWForeverRace",
}

read_globals = {
    -- src/util/util.lua adds string:SplitString
    string = { fields = { SplitString = { read_only = false } } },
    -- libraries
    "LibStub",
    -- WoW API used as bare globals by the addon
    "CreateFrame", "GetServerTime", "UnitFactionGroup", "UnitFullName",
    "geterrorhandler", "unpack",
}

files["src/config.lua"] = {
    -- Debug/Trace are assigned twice on purpose (the @debug@ block)
    ignore = {"314"},
}

-- generated data fixtures (tests/fixtures/*.lua) are plain `return {...}` tables
exclude_files = {"tests/fixtures/*.lua"}

-- tests run under busted and use the helpers exported by tests/stubs/*.lua
files["tests"] = {
    std = "+busted",
    globals = {"WoWForeverRace"},
    read_globals = {
        "SetTime", "SetWhoResults", "GetWhoQuery", "ResetWhoQuery", "SetWhoPanelVisible", "SetChatLockdown",
        "SetIsInGuild", "SetGroupState", "SetGroupMembers", "SetGuildRoster", "GetGuildRosterRequests",
        "SetFaction", "SetRaceNames", "SetInCombat",
    },
}
