-- Minimal stand-ins for WoW globals that are not tied to the player or to
-- frames (those live in player.lua / createframe.lua). Only what the addon and
-- the Ace3 libraries loaded by testbase.lua actually touch is stubbed.

-- string helpers WoW adds to the global namespace
_G.strmatch = string.match
_G.strfind = string.find
_G.strsub = string.sub
_G.strlower = string.lower
_G.strupper = string.upper
_G.strtrim = function(s)
    return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end
_G.strsplit = function(sep, s)
    local parts = {}
    for part in string.gmatch(s, "([^" .. sep .. "]+)") do
        parts[#parts + 1] = part
    end
    return unpack(parts)
end
_G.strjoin = function(sep, ...)
    return table.concat({...}, sep)
end
_G.strlenutf8 = function(s)
    -- count bytes that are not UTF-8 continuation bytes (0x80-0xBF)
    local _, count = string.gsub(s, "[^\128-\191]", "")
    return count
end
_G.tinsert = table.insert
_G.tremove = table.remove
_G.wipe = function(t)
    for k in pairs(t) do
        t[k] = nil
    end
    return t
end
_G.geterrorhandler = function()
    return error
end
_G.hooksecurefunc = function() end
_G.debugprofilestop = function()
    return 0
end
_G.GetFramerate = function()
    return 60
end

-- Enum / chat globals required by ChatThrottleLib and AceComm
_G.Enum = _G.Enum or {}
_G.DEFAULT_CHAT_FRAME = { AddMessage = function() end }
_G.SendChatMessage = function() end
_G.SendAddonMessage = function() end
_G.BNSendGameData = function() end
_G.C_BattleNet = {}

-- Mockable clock: GetTime() (uptime) and GetServerTime() (epoch) both return
-- the same controllable value; SetTime() moves it.
local time = 1000000000

function _G.GetTime()
    return time
end

function _G.GetServerTime()
    return time
end

function _G.SetTime(newTime)
    time = newTime
end

-- C_Timer with a manually advanced clock: C_Timer.Advance(seconds) fires every
-- After() callback and NewTicker() tick that became due. Reset() between tests.
_G.C_Timer = {
    now = 0,
    after = {},
    tickers = {},
}

function _G.C_Timer.Reset()
    _G.C_Timer.now = 0
    _G.C_Timer.after = {}
    _G.C_Timer.tickers = {}
end

function _G.C_Timer.After(seconds, cb)
    table.insert(_G.C_Timer.after, {_G.C_Timer.now + seconds, cb})
end

function _G.C_Timer.NewTicker(seconds, cb, iterations)
    local ticker = {
        interval = seconds,
        callback = cb,
        remaining = iterations,
        nextAt = _G.C_Timer.now + seconds,
        cancelled = false,
    }
    function ticker:Cancel()
        self.cancelled = true
    end
    function ticker:IsCancelled()
        return self.cancelled
    end
    table.insert(_G.C_Timer.tickers, ticker)
    return ticker
end

function _G.C_Timer.Advance(seconds)
    _G.C_Timer.now = _G.C_Timer.now + seconds

    -- execute one-shot entries that passed (callbacks may schedule new ones)
    local due = {}
    for _, after in ipairs(_G.C_Timer.after) do
        if after[1] <= _G.C_Timer.now then
            due[#due + 1] = after
        end
    end
    for _, after in ipairs(due) do
        after[2]()
    end

    -- truncate any entries that passed
    _G.C_Timer.after = WoWForeverRace.list.filter(_G.C_Timer.after, function(after)
        return after[1] > _G.C_Timer.now
    end)

    -- tick repeating timers as often as they became due
    for _, ticker in ipairs(_G.C_Timer.tickers) do
        while not ticker.cancelled and ticker.nextAt <= _G.C_Timer.now
                and (ticker.remaining == nil or ticker.remaining > 0) do
            ticker.nextAt = ticker.nextAt + ticker.interval
            if ticker.remaining ~= nil then
                ticker.remaining = ticker.remaining - 1
            end
            ticker.callback(ticker)
        end
    end
    _G.C_Timer.tickers = WoWForeverRace.list.filter(_G.C_Timer.tickers, function(ticker)
        return not ticker.cancelled and (ticker.remaining == nil or ticker.remaining > 0)
    end)
end
