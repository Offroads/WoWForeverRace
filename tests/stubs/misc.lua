-- Minimal stand-ins for WoW globals that are not tied to the player or to
-- frames (those live in player.lua / createframe.lua). Only what the addon and
-- the Ace3 libraries loaded by testbase.lua actually touch is stubbed; add a
-- stub here when a library upgrade starts using a new global.

-- string / table helpers WoW adds to the global namespace
_G.strmatch = string.match            -- LibStub
_G.strlenutf8 = function(s)           -- AceDB
    -- count bytes that are not UTF-8 continuation bytes (0x80-0xBF)
    local _, count = string.gsub(s, "[^\128-\191]", "")
    return count
end
_G.wipe = function(t)                 -- ChatThrottleLib (as table.wipe)
    for k in pairs(t) do
        t[k] = nil
    end
    return t
end
_G.table.wipe = _G.wipe
_G.geterrorhandler = function()       -- ChatThrottleLib, EventBus
    return error
end
_G.hooksecurefunc = function() end    -- ChatThrottleLib
_G.GetFramerate = function()          -- ChatThrottleLib
    return 60
end

-- chat globals required by ChatThrottleLib and AceComm (Enum lives in chatinfo.lua)
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
-- After() callback and NewTicker() tick that became due, in due-time order,
-- including timers that a fired callback schedules for the same moment (WoW
-- would run those on the next frame). Reset() between tests.
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

local function tickerIsLive(ticker)
    return not ticker.cancelled and (ticker.remaining == nil or ticker.remaining > 0)
end

-- pops the earliest due one-shot timer, or nil when none is due
local function popDueTimer()
    local now = _G.C_Timer.now
    local dueIndex = nil
    for i, after in ipairs(_G.C_Timer.after) do
        if after[1] <= now and (dueIndex == nil or after[1] < _G.C_Timer.after[dueIndex][1]) then
            dueIndex = i
        end
    end
    if dueIndex == nil then
        return nil
    end
    return table.remove(_G.C_Timer.after, dueIndex)
end

function _G.C_Timer.Advance(seconds)
    _G.C_Timer.now = _G.C_Timer.now + seconds

    -- one-shot timers: keep firing until nothing is due anymore, so a timer
    -- scheduled by a callback for a time we already passed still runs
    local after = popDueTimer()
    while after ~= nil do
        after[2]()
        after = popDueTimer()
    end

    -- tick repeating timers as often as they became due
    for _, ticker in ipairs(_G.C_Timer.tickers) do
        while tickerIsLive(ticker) and ticker.nextAt <= _G.C_Timer.now do
            ticker.nextAt = ticker.nextAt + ticker.interval
            if ticker.remaining ~= nil then
                ticker.remaining = ticker.remaining - 1
            end
            ticker.callback(ticker)
        end
    end
    _G.C_Timer.tickers = WoWForeverRace.list.filter(_G.C_Timer.tickers, tickerIsLive)
end
