-- Libs
local LibStub = _G.LibStub

-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- deps
local AceGUI = LibStub("AceGUI-3.0")

-- WoW API
local GetServerTime, math, C_Timer = _G.GetServerTime, _G.math, _G.C_Timer

local WHITE  = "|cffffffff"
local YELLOW = "|cffffff00"
local GRAY   = "|cff888888"
local GREEN  = "|cff44ff44"
local ORANGE = "|cffffaa00"

-- Short label for a class index used in hash log display
local CLASS_SHORT = { [0]="G","Wa","Pa","Hu","Ro","Pr","DK","Sh","Ma","Wl","Mo","Dr","DH" }

-- Relative column widths - must sum to < 1.0 so the leftover gap never
-- fits the next row's first widget, guaranteeing correct line breaks in
-- AceGUI's Flow layout.
local REL_EVENT = 0.62
local REL_COUNT = 0.18   -- two count columns * 0.18 = 0.36 → total 0.98

-- Human-readable names for network event codes
local EVENT_NAMES = {
    PINFOB    = "PlayerInfoBatch",
    REQSYNC   = "RequestSync",
    OFFERSYNC = "OfferSync",
    STARTSYNC = "StartSync",
    SYNC      = "SyncPayload",
    DATAAVAIL = "DataAvail",
    DATAREQ   = "DataRequest",
    GUILDSYNC = "GuildSync",
    GUILDOFFR = "GuildOffer",
    BPING     = "BuddyPing",
    BPONG     = "BuddyPong",
    FTLSYNC   = "FTLSync",
    PHSYNC    = "PlayerHistorySync",
}

local function formatAge(timestamp)
    if not timestamp then return "never" end
    local diff = GetServerTime() - timestamp
    if diff < 60 then
        return diff .. "s ago"
    elseif diff < 3600 then
        return math.floor(diff / 60) .. "m ago"
    else
        return math.floor(diff / 3600) .. "h ago"
    end
end

---@class WoWForeverRaceDebugFrame
local WoWForeverRaceDebugFrame = {}
WoWForeverRaceDebugFrame.__index = WoWForeverRaceDebugFrame
WoWForeverRace.DebugFrame = WoWForeverRaceDebugFrame
setmetatable(WoWForeverRaceDebugFrame, {
    __call = function(cls, ...) return cls.new(...) end,
})

function WoWForeverRaceDebugFrame.new(Config, Core, DB, EventBus)
    local self = setmetatable({}, WoWForeverRaceDebugFrame)
    self.Config = Config
    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus
    self.frame = nil
    self.scroll = nil

    local _self = self
    EventBus:RegisterCallback(Config.Events.MsgStats, self, function() _self:Render() end)
    EventBus:RegisterCallback(Config.Events.BuddyUpdate, self, function() _self:Render() end)

    return self
end

function WoWForeverRaceDebugFrame:Hide()
    self:HideLog()
    if self.frame then
        self.frame:Hide()
        self.frame:Release()
        self.frame = nil
        self.scroll = nil
    end
end

function WoWForeverRaceDebugFrame:Show()
    if self.frame then
        self.frame:Hide()
        self.frame:Release()
        self.frame = nil
        self.scroll = nil
    end

    local _self = self

    local frame = AceGUI:Create("Window")
    frame:SetTitle(self.Config.Name .. " Debug")
    frame:SetWidth(320)
    frame:SetHeight(480)
    frame:SetLayout("Flow")
    frame:SetCallback("OnClose", function(widget)
        widget:Release()
        _self.frame = nil
        _self.scroll = nil
    end)
    self.frame = frame

    local pingBtn = AceGUI:Create("Button")
    pingBtn:SetText("Ping Buddies")
    pingBtn:SetWidth(150)
    pingBtn:SetCallback("OnClick", function()
        WoWForeverRace.Sync:SendBuddyPings()
        _self:Render()
    end)
    frame:AddChild(pingBtn)

    local clearBtn = AceGUI:Create("Button")
    clearBtn:SetText("Clear Buddies")
    clearBtn:SetWidth(150)
    clearBtn:SetCallback("OnClick", function()
        _self.DB.factionrealm.buddies = {}
        _self:Render()
    end)
    frame:AddChild(clearBtn)

    local resetStatsBtn = AceGUI:Create("Button")
    resetStatsBtn:SetText("Reset Stats")
    resetStatsBtn:SetWidth(150)
    resetStatsBtn:SetCallback("OnClick", function()
        WoWForeverRace.MsgStats = { send = {}, recv = {} }
        _self:Render()
    end)
    frame:AddChild(resetStatsBtn)

    local logBtn = AceGUI:Create("Button")
    logBtn:SetText("Debug Log")
    logBtn:SetWidth(150)
    logBtn:SetCallback("OnClick", function() _self:ShowLog() end)
    frame:AddChild(logBtn)

    local scrolltainer = AceGUI:Create("SimpleGroup")
    scrolltainer:SetLayout("Fill")
    scrolltainer:SetFullWidth(true)
    scrolltainer:SetFullHeight(true)
    frame:AddChild(scrolltainer)

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("Flow")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    scrolltainer:AddChild(scroll)
    self.scroll = scroll

    self:Render()
end

function WoWForeverRaceDebugFrame:HideLog()
    if self.logFrame then
        self.logFrame:Hide()
        self.logFrame:Release()
        self.logFrame = nil
        self.logBox = nil
    end
end

-- Every debug / trace message of the session in a scrollable edit box:
-- click into it, Ctrl+A / Ctrl+C to copy.
function WoWForeverRaceDebugFrame:ShowLog()
    self:HideLog()

    local _self = self

    local frame = AceGUI:Create("Window")
    frame:SetTitle(self.Config.Name .. " Debug Log")
    frame:SetWidth(640)
    frame:SetHeight(480)
    frame:SetLayout("Flow")
    frame:SetCallback("OnClose", function(widget)
        widget:Release()
        _self.logFrame = nil
        _self.logBox = nil
    end)
    self.logFrame = frame

    local refreshBtn = AceGUI:Create("Button")
    refreshBtn:SetText("Refresh")
    refreshBtn:SetWidth(150)
    refreshBtn:SetCallback("OnClick", function() _self:RenderLog() end)
    frame:AddChild(refreshBtn)

    local clearBtn = AceGUI:Create("Button")
    clearBtn:SetText("Clear Log")
    clearBtn:SetWidth(150)
    clearBtn:SetCallback("OnClick", function()
        WoWForeverRace.DebugLog = {}
        _self:RenderLog()
    end)
    frame:AddChild(clearBtn)

    local box = AceGUI:Create("MultiLineEditBox")
    box:SetLabel("")
    box:DisableButton(true)
    box:SetFullWidth(true)
    box:SetFullHeight(true)
    frame:AddChild(box)
    self.logBox = box

    self:RenderLog()
end

function WoWForeverRaceDebugFrame:RenderLog()
    if not self.logBox then return end
    local text = table.concat(WoWForeverRace.DebugLog, "\n")
    self.logBox:SetText(text)
    -- the scroll frame follows the cursor: jump to the newest line
    self.logBox.editBox:SetCursorPosition(#text)
end

-- Called for every logged message. Redraws are batched, and skipped while the box
-- has focus so a selection being copied is not thrown away (Escape or Refresh resumes).
function WoWForeverRaceDebugFrame:OnDebugLog()
    if not self.logBox or self.logRenderPending then return end
    self.logRenderPending = true

    local _self = self
    C_Timer.After(0.2, function()
        _self.logRenderPending = false
        if _self.logBox and not _self.logBox.editBox:HasFocus() then
            _self:RenderLog()
        end
    end)
end

-- Three-column row using relative widths so the columns always fill the
-- container and the Flow layout never places the next row on the same line.
function WoWForeverRaceDebugFrame:AddRow(col1, col2, col3, col1Color, col2Color, col3Color)
    local nameLabel = AceGUI:Create("Label")
    nameLabel:SetRelativeWidth(REL_EVENT)
    nameLabel:SetText((col1Color or WHITE) .. col1 .. "|r")
    self.scroll:AddChild(nameLabel)

    local sentLabel = AceGUI:Create("Label")
    sentLabel:SetRelativeWidth(REL_COUNT)
    sentLabel:SetText((col2Color or WHITE) .. col2 .. "|r")
    sentLabel:SetJustifyH("RIGHT")
    self.scroll:AddChild(sentLabel)

    local recvLabel = AceGUI:Create("Label")
    recvLabel:SetRelativeWidth(REL_COUNT)
    recvLabel:SetText((col3Color or WHITE) .. col3 .. "|r")
    recvLabel:SetJustifyH("RIGHT")
    self.scroll:AddChild(recvLabel)
end

function WoWForeverRaceDebugFrame:AddSeparator()
    local sep = AceGUI:Create("Label")
    sep:SetFullWidth(true)
    sep:SetText(GRAY .. string.rep("-", 32) .. "|r")
    self.scroll:AddChild(sep)
end

function WoWForeverRaceDebugFrame:AddSpacer()
    local spacer = AceGUI:Create("Label")
    spacer:SetFullWidth(true)
    spacer:SetText(" ")
    self.scroll:AddChild(spacer)
end

function WoWForeverRaceDebugFrame:Render()
    if not self.scroll then return end
    self.scroll:ReleaseChildren()
    self:RenderMsgStats()
    self:RenderHashLog()
    self:RenderBuddies()
    self.scroll:DoLayout()
end

function WoWForeverRaceDebugFrame:RenderMsgStats()
    local stats = WoWForeverRace.MsgStats
    if not stats then return end

    local allEvents = {}
    local seen = {}
    for event in pairs(stats.send) do
        if not seen[event] then seen[event] = true; allEvents[#allEvents + 1] = event end
    end
    for event in pairs(stats.recv) do
        if not seen[event] then seen[event] = true; allEvents[#allEvents + 1] = event end
    end
    table.sort(allEvents)

    self:AddRow("Message Type", "Snt", "Rcv", YELLOW, YELLOW, YELLOW)
    self:AddSeparator()

    if #allEvents == 0 then
        local none = AceGUI:Create("Label")
        none:SetFullWidth(true)
        none:SetText(GRAY .. "no messages yet|r")
        self.scroll:AddChild(none)
    else
        local totalSend, totalRecv = 0, 0
        for _, event in ipairs(allEvents) do
            local s = stats.send[event] or 0
            local r = stats.recv[event] or 0
            totalSend = totalSend + s
            totalRecv = totalRecv + r
            local name = EVENT_NAMES[event] or event
            self:AddRow(name, tostring(s), tostring(r),
                WHITE,
                s > 0 and WHITE or GRAY,
                r > 0 and WHITE or GRAY)
        end
        self:AddSeparator()
        self:AddRow("Total", tostring(totalSend), tostring(totalRecv), YELLOW, YELLOW, YELLOW)
    end

    self:AddSpacer()
end

function WoWForeverRaceDebugFrame:RenderHashLog()
    local log = WoWForeverRace.HashLog
    if not log or #log == 0 then return end

    local header = AceGUI:Create("Label")
    header:SetFullWidth(true)
    header:SetText(YELLOW .. "Hash Mismatches|r")
    self.scroll:AddChild(header)

    self:AddSeparator()

    for _, entry in ipairs(log) do
        local t = entry.time
        local timeStr = string.format("%02d:%02d:%02d",
            math.floor(t / 3600) % 24,
            math.floor(t / 60) % 60,
            t % 60)

        local arrow = entry.direction == ">" and GREEN .. ">|r" or ORANGE .. "<|r"

        local parts = {}
        table.sort(entry.classes)
        for _, ci in ipairs(entry.classes) do
            parts[#parts + 1] = CLASS_SHORT[ci] or tostring(ci)
        end
        if entry.ftl then parts[#parts + 1] = "FTL" end
        local clsStr = #parts > 0 and table.concat(parts, ",") or "?"

        local label = AceGUI:Create("Label")
        label:SetFullWidth(true)
        label:SetText(GRAY .. timeStr .. "|r " .. arrow .. " "
                .. WHITE .. entry.sender .. "|r "
                .. GRAY .. "[" .. clsStr .. "]|r")
        self.scroll:AddChild(label)
    end

    self:AddSpacer()
end

function WoWForeverRaceDebugFrame:RenderBuddies()
    local buddies = self.DB.factionrealm.buddies

    local list = {}
    for name, info in pairs(buddies) do
        list[#list + 1] = { name = name, lastSeen = info.lastSeen }
    end
    table.sort(list, function(a, b)
        return (a.lastSeen or 0) > (b.lastSeen or 0)
    end)

    local buddyHeader = AceGUI:Create("Label")
    buddyHeader:SetFullWidth(true)
    buddyHeader:SetText(YELLOW .. "Buddies: " .. #list .. "|r")
    self.scroll:AddChild(buddyHeader)

    self:AddSeparator()

    for _, buddy in ipairs(list) do
        local label = AceGUI:Create("Label")
        label:SetFullWidth(true)
        label:SetText(WHITE .. buddy.name .. "  " .. GRAY .. formatAge(buddy.lastSeen) .. "|r")
        self.scroll:AddChild(label)
    end
end
