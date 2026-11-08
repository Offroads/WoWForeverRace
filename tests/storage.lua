local WoWForeverRace = require("testbase")

-- local alias, the tests below reset library registrations on it
local LibStub = _G.LibStub

-- AceDB computes its scope keys (faction, realm, ...) once, when its file is loaded,
-- so logging in on a character of another faction is simulated by loading it again
local function reloadAceDB()
    LibStub.libs["AceDB-3.0"] = nil
    LibStub.minors["AceDB-3.0"] = nil
    dofile("libs/AceDB/AceDB-3.0.lua")
end

local function newDB()
    return LibStub("AceDB-3.0"):New("WoWForeverRace_DB", WoWForeverRace.DefaultDB, true)
end

local function sortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

describe("Storage", function()
    local time = 1000000000

    before_each(function()
        _G.C_Timer.Reset()
        _G.WoWForeverRace_DB = nil
    end)

    after_each(function()
        -- the other test files share this Lua state and expect the Alliance default
        SetFaction(nil)
        SetRuleset(nil)
        reloadAceDB()
        _G.WoWForeverRace_DB = nil
    end)

    it("keeps the race data of both factions of one account apart", function()
        local alliance = newDB()
        assert.equals("Alliance - ", string.sub(alliance.keys.factionrealm, 1, 11))
        alliance.factionrealm.leaderboard[0].players[1] = {name = "Ally", level = 10, classIndex = 11, dingedAt = time}
        alliance.factionrealm.leaderboard[WoWForeverRace.Config:RaceBoardIndex(4)].players[1] =
                {name = "Ally", level = 10, classIndex = 11, raceIndex = 4, dingedAt = time}
        alliance.factionrealm.firstToLevel[0] = {[10] = {name = "Ally", classIndex = 11, dingedAt = time}}
        alliance.factionrealm.playerHistory["Ally"] = {classIndex = 11, levels = {[10] = time}}
        alliance.factionrealm.buddies["Ally"] = {lastSeen = time}
        alliance.factionrealm.realmOpenedAt = time

        SetFaction("Horde")
        reloadAceDB()
        local horde = newDB()

        assert.equals("Horde - ", string.sub(horde.keys.factionrealm, 1, 8))
        assert.equals(0, #horde.factionrealm.leaderboard[0].players)
        assert.equals(0, #horde.factionrealm.leaderboard[WoWForeverRace.Config:RaceBoardIndex(4)].players)
        assert.is_nil(next(horde.factionrealm.firstToLevel))
        assert.is_nil(next(horde.factionrealm.playerHistory))
        assert.is_nil(next(horde.factionrealm.buddies))
        assert.is_nil(horde.factionrealm.realmOpenedAt)

        horde.factionrealm.leaderboard[0].players[1] = {name = "Hordie", level = 12, classIndex = 7, dingedAt = time}

        local saved = _G.WoWForeverRace_DB.factionrealm
        assert.equals(2, #sortedKeys(saved))
        local allianceBoard = saved[alliance.keys.factionrealm].leaderboard[0]
        assert.equals(1, #allianceBoard.players)
        assert.equals("Ally", allianceBoard.players[1].name)
        assert.equals("Hordie", saved[horde.keys.factionrealm].leaderboard[0].players[1].name)
    end)

    it("keys the faction-realm by ruleset on WoW Forever", function()
        SetRuleset("PvP")
        reloadAceDB()
        assert.equals("Alliance - PvP", newDB().keys.factionrealm)

        SetRuleset("PvE")
        reloadAceDB()
        assert.equals("Alliance - PvE", newDB().keys.factionrealm)
    end)

    describe("reset", function()
        local function seed(db, name)
            db.factionrealm.dbversion = "v1.0.1"
            db.factionrealm.leaderboard[0].players[1] = {name = name, level = 60, classIndex = 1, dingedAt = time}
            db.factionrealm.firstToLevel[0] = {[60] = {name = name, classIndex = 1, dingedAt = time}}
            db.factionrealm.playerHistory[name] = {classIndex = 1, levels = {[60] = time}}
            db.factionrealm.buddies[name] = {lastSeen = time}
            db.factionrealm.pioneersMigrated = true
        end

        it("leaves the other rulesets of the account alone", function()
            -- a character on a PvP realm, with race data and settings of its own
            SetRuleset("PvP")
            reloadAceDB()
            local pvp = newDB()
            seed(pvp, "Pvp Racer")
            pvp.profile.options.scanCooldown = 30

            -- the first login on a PvE realm finds no race data and resets it
            SetRuleset("PvE")
            reloadAceDB()
            local pve = newDB()
            assert.equals("0.0.0", pve.factionrealm.dbversion)
            WoWForeverRace.ResetFactionRealm(pve)

            local saved = _G.WoWForeverRace_DB
            local pvpData = saved.factionrealm["Alliance - PvP"]
            assert.is_not_nil(pvpData)
            assert.equals("v1.0.1", pvpData.dbversion)
            assert.equals("Pvp Racer", pvpData.leaderboard[0].players[1].name)
            assert.equals("Pvp Racer", pvpData.firstToLevel[0][60].name)
            assert.is_not_nil(pvpData.playerHistory["Pvp Racer"])
            assert.is_not_nil(pvpData.buddies["Pvp Racer"])
            assert.is_true(pvpData.pioneersMigrated)
            assert.equals(30, saved.profiles["Default"].options.scanCooldown)

            -- and back on the PvP realm, the race goes on where it was
            SetRuleset("PvP")
            reloadAceDB()
            local again = newDB()
            assert.equals("v1.0.1", again.factionrealm.dbversion)
            assert.equals("Pvp Racer", again.factionrealm.leaderboard[0].players[1].name)
        end)

        it("empties this faction-realm and fills it with the defaults", function()
            SetRuleset("PvP")
            reloadAceDB()
            local db = newDB()
            seed(db, "Pvp Racer")
            local old = db.factionrealm

            local fresh = WoWForeverRace.ResetFactionRealm(db)

            assert.are_not.equal(old, fresh)
            assert.equals(fresh, db.factionrealm)
            assert.equals(fresh, _G.WoWForeverRace_DB.factionrealm["Alliance - PvP"])
            assert.equals("0.0.0", fresh.dbversion)
            assert.equals(0, #fresh.leaderboard[0].players)
            assert.equals(2, fresh.leaderboard[1].minLevel)
            assert.is_nil(next(fresh.firstToLevel))
            assert.is_nil(next(fresh.playerHistory))
            assert.is_nil(next(fresh.buddies))
            assert.is_false(fresh.pioneersMigrated)
        end)
    end)

    -- A failure here means data was added outside the factionrealm scope. Race data
    -- (leaderboards, pioneers, history, buddies, race timestamps) belongs in factionrealm:
    -- every other scope is shared by the Horde and Alliance characters of an account.
    -- Extend the expected lists only for settings and for what is about the addon itself
    -- (global: the newer version other players announced).
    it("declares race data in the factionrealm scope only", function()
        assert.same({"factionrealm", "global", "profile"}, sortedKeys(WoWForeverRace.DefaultDB))
        assert.same({}, sortedKeys(WoWForeverRace.DefaultDB.global))
        assert.same({"gui", "options"}, sortedKeys(WoWForeverRace.DefaultDB.profile))
    end)

    it("writes race data to the factionrealm scope only", function()
        local db = newDB()
        local core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
        function core:Now() return time end
        local eventbus = WoWForeverRace.EventBus()
        local network = {SendObject = function() end}
        local tracker = WoWForeverRace.Tracker(WoWForeverRace.Config, core, db, eventbus, network)
        local sync = WoWForeverRace.Sync(WoWForeverRace.Config, core, db, eventbus, network)

        tracker:ProcessPlayerInfoBatch({ {name = "Nubone", level = 5, classIndex = 11, dingedAt = time} })
        sync:AddBuddy("Dude")

        assert.equals(1, #db.factionrealm.leaderboard[0].players)
        -- AceDB creates a section in the saved variable on first access
        local allowed = {profileKeys = true, profiles = true, factionrealm = true}
        for _, key in ipairs(sortedKeys(_G.WoWForeverRace_DB)) do
            assert.is_true(allowed[key] == true, "unexpected saved scope: " .. tostring(key))
        end
    end)
end)
