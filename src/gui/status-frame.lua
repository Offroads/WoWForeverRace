-- Libs
local LibStub = _G.LibStub

-- Addon global
local WoWForeverRace = _G.WoWForeverRace

-- deps
local AceGUI = LibStub("AceGUI-3.0")

-- WoW API
local GameFontNormalLarge, CLASS_ICON_TCOORDS = _G.GameFontNormalLarge, _G.CLASS_ICON_TCOORDS
local C_Timer = _G.C_Timer

-- colors
local SEYELLOW = WoWForeverRace.Colors.SYSTEM_EVENT_YELLOW
local WHITE = WoWForeverRace.Colors.WHITE

---@class WoWForeverRaceStatusFrame
local WoWForeverRaceStatusFrame = {}
WoWForeverRaceStatusFrame.__index = WoWForeverRaceStatusFrame
WoWForeverRace.StatusFrame = WoWForeverRaceStatusFrame
setmetatable(WoWForeverRaceStatusFrame, {
    __call = function(cls, ...)
        return cls.new(...)
    end,
})

function WoWForeverRaceStatusFrame.new(Config, Core, DB, EventBus)
    local self = setmetatable({}, WoWForeverRaceStatusFrame)

    self.Config = Config
    self.Core = Core
    self.DB = DB
    self.EventBus = EventBus

    self.myClassIndex, self.myClass = self.Core:MyClass()

    -- subscribe to local events
    EventBus:RegisterCallback(self.Config.Events.Ding, self, self.OnDing)
    EventBus:RegisterCallback(self.Config.Events.RefreshGUI, self, self.OnRefreshGUI)

    self.classIndex = 0
    self.view = "leaderboard"   -- "leaderboard" or "pioneers"
    self.frame = nil
    self.tabicons = nil
    self.lefticons = nil
    self.contentframe = nil
    self.refreshPending = false

    self.players = self.DB.factionrealm.leaderboard[self.classIndex].players

    self.pioneersView = WoWForeverRace.PioneersView(Config, Core, DB)

    self:OnRefreshGUI()

    return self
end

-- Coalesces rapid-fire Ding/RefreshGUI events (e.g. 50-player sync batch) into
-- a single UI rebuild at the start of the next frame via C_Timer.After(0).
function WoWForeverRaceStatusFrame:ScheduleRefresh()
    if self.refreshPending then return end
    self.refreshPending = true
    local _self = self
    C_Timer.After(0, function()
        _self.refreshPending = false
        _self:Refresh()
    end)
end

function WoWForeverRaceStatusFrame:OnDing()
    self:ScheduleRefresh()
end

function WoWForeverRaceStatusFrame:OnRefreshGUI()
    self:ScheduleRefresh()
end

function WoWForeverRaceStatusFrame:Refresh()
    self.players = self.DB.factionrealm.leaderboard[self.classIndex].players

    if self.frame ~= nil and self.contentframe ~= nil then
        self:RenderLeftIcon()
        self:RenderTabicons()
        self:Render()
    end
end

function WoWForeverRaceStatusFrame:Show()
    -- close currently open frame
    if self.frame then
        self.frame:Hide()
    end

    local _self = self

    -- toggle display state in DB
    self.DB.profile.gui.display = true

    local frame = AceGUI:Create("Window")
    -- bind status to DB, default width/height in defaultdb schema
    frame:SetStatusTable(self.DB.profile.gui.statusFrameStatus)
    frame:SetTitle("The Classic Race")
    frame.frame:SetFrameStrata("LOW")
    frame:SetLayout("Flow")
    frame:SetCallback("OnClose", function(widget)
        -- toggle display state in DB
        _self.DB.profile.gui.display = false

        -- release self
        widget:Release()
        _self.frame = nil

        -- release tabicons
        if _self.tabicons then
            _self.tabicons:Release()
            _self.tabicons = nil
        end

        -- release left icon
        if _self.lefticons then
            _self.lefticons:Release()
            _self.lefticons = nil
        end
    end)
    WoWForeverRaceStatusFrame.FixResizeStatusUpdates(frame)
    frame:DoLayout()

    self.players = self.DB.factionrealm.leaderboard[self.classIndex].players
    self.frame = frame

    self:RenderLeftIcon()
    self:RenderTabicons()
    self:Render()
end

--[[
FixResizeStatusUpdates fixes a bug in AceGUI
The OnMouseUp of the sizers don't update the status, so we add a new OnMouseUp that does
--]]
function WoWForeverRaceStatusFrame.FixResizeStatusUpdates(frame)
    for _, sizer in ipairs({ frame.sizer_se, frame.sizer_s, frame.sizer_e }) do
        sizer:SetScript("OnMouseUp", function()
            frame.frame:StopMovingOrSizing()
            local status = frame.status or frame.localstatus
            status.width = frame.frame:GetWidth()
            status.height = frame.frame:GetHeight()
            status.top = frame.frame:GetTop()
            status.left = frame.frame:GetLeft()
        end)
    end
end

-- Left-side icon that toggles between the leaderboard and pioneers views.
function WoWForeverRaceStatusFrame:RenderLeftIcon()
    if self.lefticons then
        self.lefticons:Release()
    end

    local lefticons = AceGUI:Create("SimpleGroup")
    lefticons.frame:SetFrameStrata("LOW")
    lefticons:SetLayout("Flow")
    lefticons:SetWidth(20)
    lefticons:SetFullWidth(false)
    lefticons.frame:Show()

    local icon = AceGUI:Create("Icon")
    icon:SetCallback("OnClick", function()
        self.view = (self.view == "pioneers") and "leaderboard" or "pioneers"
        self:Refresh()
    end)
    icon:SetLabel(nil)
    icon:SetImage("Interface\\Icons\\Achievement_GuildPerk_FastTrack")
    icon:SetImageSize(20, 20)
    icon:SetWidth(20)
    icon:SetHeight(20)
    -- dim when leaderboard is active; full brightness when pioneers is active
    if self.view ~= "pioneers" then
        icon.image:SetVertexColor(0.8, 0.8, 0.8, 0.8)
    end
    lefticons:AddChild(icon)

    lefticons:SetHeight(22)
    lefticons:ClearAllPoints()
    lefticons.frame:SetPoint("TOPRIGHT", self.frame.frame, "TOPLEFT")
    lefticons.frame:Show()

    self.lefticons = lefticons
end

function WoWForeverRaceStatusFrame:RenderTabicons()
    if self.tabicons then
        self.tabicons:Release()
    end

    local tabicons = AceGUI:Create("SimpleGroup")
    tabicons.frame:SetFrameStrata("LOW")
    tabicons:SetLayout("Flow")
    tabicons:SetWidth(20)
    tabicons:SetFullWidth(false)
    tabicons.frame:Show()

    local iconCount = 0

    local function addIcon(image, coords, classIndex)
        local icon = AceGUI:Create("Icon")
        icon:SetCallback("OnClick", function()
            self.classIndex = classIndex
            self:Refresh()
        end)
        icon:SetLabel(nil)
        if coords then
            icon:SetImage(image, unpack(coords))
        else
            icon:SetImage(image)
        end
        icon:SetImageSize(20, 20)
        icon:SetWidth(20)
        icon:SetHeight(20)
        if self.classIndex ~= classIndex then
            icon.image:SetVertexColor(0.8, 0.8, 0.8, 0.8)
        end
        tabicons:AddChild(icon)
        iconCount = iconCount + 1
    end

    -- Global tab (always shown)
    addIcon("Interface\\PaperDollInfoFrame\\SpellSchoolIcon7", nil, 0)

    -- One tab per class that has at least one discovered player
    for _, classIndex in ipairs(self.Config.MopClassIndexes) do
        local classLb = self.DB.factionrealm.leaderboard[classIndex]
        if classLb and #classLb.players > 0 then
            local className = self.Config.Classes[classIndex]
            local coords    = CLASS_ICON_TCOORDS[className]
            if coords then
                addIcon("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES", coords, classIndex)
            end
        end
    end

    tabicons:SetHeight(iconCount * 22)
    tabicons:ClearAllPoints()
    tabicons.frame:SetPoint("TOPLEFT", self.frame.frame, "TOPRIGHT")
    tabicons.frame:Show()

    self.tabicons = tabicons
end

function WoWForeverRaceStatusFrame:Render()
    -- clear the old content
    self.frame:ReleaseChildren()

    local _self = self

    -- need a container
    local frame = AceGUI:Create("SimpleGroup")
    frame:SetLayout("Flow")
    frame:SetFullWidth(true)
    frame:SetFullHeight(true)
    frame:SetCallback("OnClose", function(widget)
        widget:ReleaseChildren()
        widget:Release()
        _self.contentframe = nil
    end)
    self.frame:AddChild(frame)

    if self.view == "pioneers" then
        self.pioneersView:Render(frame, self.classIndex)
    else
        self:RenderLeaderboard(frame)
    end

    self.contentframe = frame
end

function WoWForeverRaceStatusFrame:RenderLeaderboard(frame)
    -- display the leader
    if #self.players > 0 then
        local leader = self.players[1]

        -- determine your own rank
        local selfRank = nil
        for rank, playerInfo in ipairs(self.players) do
            if playerInfo.name == self.Core:Me() then
                selfRank = rank
                break
            end
        end

        -- special leader display when you are the leader!
        if selfRank ~= nil and selfRank == 1 then
            local leaderLabel = AceGUI:Create("Label")
            leaderLabel:SetFullWidth(true)
            leaderLabel:SetText(SEYELLOW .. "You|r are #1! lvl" .. leader.level)
            leaderLabel:SetFont(GameFontNormalLarge:GetFont())
            leaderLabel.label:SetJustifyH("CENTER")
            frame:AddChild(leaderLabel)
        else
            local leaderClass = self.Core:ClassByIndex(leader.classIndex)
            local color = WoWForeverRace.Colors[leaderClass]
            if color == nil then
                color = WHITE
            end

            local leaderLabel = AceGUI:Create("Label")
            leaderLabel:SetFullWidth(true)
            leaderLabel:SetText("#1 " .. color .. leader.name .. "|r lvl" .. leader.level)
            leaderLabel:SetFont(GameFontNormalLarge:GetFont())
            leaderLabel.label:SetJustifyH("CENTER")
            frame:AddChild(leaderLabel)
        end

        -- special added line if you are on the leaderboard but not the leader
        if selfRank ~= nil and selfRank > 1 then
            local you = AceGUI:Create("Label")
            you:SetFullWidth(true)
            you:SetText("You are #" .. selfRank .. "! lvl" .. self.players[selfRank].level)
            you:SetFont(GameFontNormalLarge:GetFont())
            you.label:SetJustifyH("CENTER")
            frame:AddChild(you)
        end
    end

    local scrolltainer = AceGUI:Create("SimpleGroup")
    scrolltainer:SetLayout("Fill") -- important! first child fills container
    scrolltainer:SetFullWidth(true)
    scrolltainer:SetFullHeight(true)
    frame:AddChild(scrolltainer)

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("Flow")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    scrolltainer:AddChild(scroll)

    -- Extra bottom clearance so the scrollbar doesn't cover the resize grip (sizer_se ~16 px).
    scroll.scrollbar:ClearAllPoints()
    scroll.scrollbar:SetPoint("TOPLEFT", scroll.scrollframe, "TOPRIGHT", 4, -16)
    scroll.scrollbar:SetPoint("BOTTOMLEFT", scroll.scrollframe, "BOTTOMRIGHT", 4, 32)

    for rank, playerInfo in ipairs(self.players) do
        if rank ~= 1 then
            local playerClass = self.Core:ClassByIndex(playerInfo.classIndex)
            local color = WoWForeverRace.Colors[playerClass]
            if color == nil then
                color = WHITE
            end

            local player = AceGUI:Create("Label")
            player:SetText("#" .. rank .. " " .. color .. playerInfo.name .. "|r lvl" .. playerInfo.level)

            scroll:AddChild(player)
        end
    end

    -- trigger layout update to fix blank first row
    scroll:DoLayout()
end
