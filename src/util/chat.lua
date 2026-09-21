local WoWForeverRace = _G.WoWForeverRace

local function dumpTable(o)
    if type(o) == "table" then
        local s = "{ "
        for k,v in pairs(o) do
            s = s .. "[" .. k .. "] = " .. dumpTable(v) .. ", "
        end
        return s .. "} "
    else
        return tostring(o)
    end
end

function WoWForeverRace:Print(message)
    print("|cFFFFFFFF", message)
end

function WoWForeverRace:SystemEventPrint(message)
    print(WoWForeverRace.Colors.SYSTEM_EVENT_YELLOW, message)
end

function WoWForeverRace:PPrint(message)
    print("|cFF7777FFWoWForeverRace:|cFFFFFFFF", message)
end

-- Debug / trace output is also kept here (oldest first, plain text) so the debug
-- window can show more than the chat frame holds, in a box it can be copied from.
local DEBUG_LOG_MAX = 2000
WoWForeverRace.DebugLog = {}

function WoWForeverRace:AddDebugLog(message)
    local log = self.DebugLog
    -- strip colors and hyperlinks, an edit box would hand them out as raw escape codes
    local text = tostring(message)
        :gsub("|c%x%x%x%x%x%x%x%x", "")
        :gsub("|r", "")
        :gsub("|H.-|h(.-)|h", "%1")
    log[#log + 1] = (_G.date or os.date)("%H:%M:%S") .. " " .. text
    while #log > DEBUG_LOG_MAX do table.remove(log, 1) end

    if self.DebugFrame then
        self.DebugFrame:OnDebugLog()
    end
end

-- Debug / trace output goes to the debug window log only; pass toChat for the
-- few messages that should also show up in the chat frame.
function WoWForeverRace:DebugPrint(message, toChat)
    local enabled = self.DB and self.DB.profile.options.debug or (not self.DB and self.Config.Debug)
    if enabled then
        if toChat then
            print("|cFF7777FFWoWForeverRace Debug:|cFFFFFFFF", message)
        end
        self:AddDebugLog(message)
    end
end

function WoWForeverRace:TracePrint(message)
    if (self.Config.Trace == true) then
        self:AddDebugLog(message)
    end
end

function WoWForeverRace:DebugPrintTable(t)
    local enabled = self.DB and self.DB.profile.options.debug or (not self.DB and self.Config.Debug)
    if enabled then
        self:AddDebugLog(dumpTable(t))
    end
end

function WoWForeverRace:TracePrintTable(t)
    if (self.Config.Trace == true) then
        self:AddDebugLog(dumpTable(t))
    end
end

-- Records a hash mismatch event into HashLog (newest first, capped at 12).
-- direction: ">" we sent data to sender, "<" we received data from sender.
-- classes: list of classIndex values that differed (0=global).
-- ftl: boolean, whether FTL also differed.
function WoWForeverRace:AddHashLog(sender, direction, classes, ftl)
    if not self.DB or not self.DB.profile.options.debug then return end
    local GetServerTime = _G.GetServerTime
    table.insert(self.HashLog, 1, {
        time      = GetServerTime(),
        sender    = sender,
        direction = direction,
        classes   = classes or {},
        ftl       = ftl or false,
    })
    while #self.HashLog > 12 do table.remove(self.HashLog) end
    self.EventBus:PublishEvent(self.Config.Events.MsgStats)
end

function WoWForeverRace:PlayerChatLink(playerName, linkTitle, className)
    if linkTitle == nil then
        linkTitle = playerName
    end

    local color = WoWForeverRace.Colors.SYSTEM_EVENT_YELLOW
    if className ~= nil and WoWForeverRace.Colors[className] ~= nil then
        color = WoWForeverRace.Colors[className]
    end

    return color .. "|Hplayer:" .. playerName .. "|h[" .. linkTitle .. "]|h|r"
end