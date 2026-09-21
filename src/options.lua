local WoWForeverRace = _G.WoWForeverRace

-- Libs
local LibStub = _G.LibStub
local LibDBIcon = LibStub("LibDBIcon-1.0")
local LibDataBroker = LibStub("LibDataBroker-1.1")
local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")

-- colors
local WHITE = WoWForeverRace.Colors.WHITE
local BROWN = WoWForeverRace.Colors.BROWN

function WoWForeverRace:RegisterOptions()
    local _self = self

    local configOptions = {
        type = "group",
        args = {
            enable = {
                name = "Show Minimap Icon",
                desc = "Enables / disables the minimap icon",
                type = "toggle",
                set = function(_, val)
                    _self.DB.profile.options.minimap.hide = not val
                    if val then
                        LibDBIcon:Show(WoWForeverRace.Config.LDB)
                    else
                        LibDBIcon:Hide(WoWForeverRace.Config.LDB)
                    end
                end,
                get = function() return not _self.DB.profile.options.minimap.hide end
            },
            moreoptions = {
                name = "Options",
                type = "group",
                args = {
                    hrNotifications = {
                        order = 10,
                        name = "Notifications",
                        width = "full",
                        type = "header",
                    },
                    maxLevelNotify = {
                        order = 11,
                        name = "Show max level dings",
                        desc = "Notify whenever any player reaches max level",
                        descStyle = "inline",
                        width = "full",
                        type = "toggle",
                        set = function(_, val) _self.DB.profile.options.maxLevelNotify = val end,
                        get = function() return _self.DB.profile.options.maxLevelNotify end,
                    },
                    globalTopN = {
                        order = 12,
                        name = "Global top N",
                        desc = "Notify for rank changes in the top N of the global leaderboard (0 = off)",
                        descStyle = "inline",
                        width = "full",
                        type = "range",
                        step = 1,
                        min = 0,
                        max = WoWForeverRace.Config.MaxLeaderboardSize,
                        set = function(_, val) _self.DB.profile.options.globalTopN = val end,
                        get = function() return _self.DB.profile.options.globalTopN end,
                    },
                    classTopN = {
                        order = 13,
                        name = "Class top N",
                        desc = "Notify for rank changes in the top N of any class leaderboard (0 = off)",
                        descStyle = "inline",
                        width = "full",
                        type = "range",
                        step = 1,
                        min = 0,
                        max = WoWForeverRace.Config.MaxLeaderboardSize,
                        set = function(_, val) _self.DB.profile.options.classTopN = val end,
                        get = function() return _self.DB.profile.options.classTopN end,
                    },
                    raceTopN = {
                        order = 14,
                        name = "Race top N",
                        desc = "Notify for rank changes in the top N of any race leaderboard (0 = off)",
                        descStyle = "inline",
                        width = "full",
                        type = "range",
                        step = 1,
                        min = 0,
                        max = WoWForeverRace.Config.MaxLeaderboardSize,
                        set = function(_, val) _self.DB.profile.options.raceTopN = val end,
                        get = function() return _self.DB.profile.options.raceTopN end,
                    },

                    hr2 = {
                        order = 30,
                        name = "Advanced",
                        width = "full",
                        type = "header",
                    },
                    enableNetworking = {
                        order = 31,
                        name = "Enable Sharing / Receiving Data",
                        desc = "Enables / disables the sharing of data through addon channels",
                        descStyle = "inline",
                        width = "full",
                        type = "toggle",
                        set = function(_, val) _self.DB.profile.options.networking = val end,
                        get = function() return _self.DB.profile.options.networking end,
                    },
                    debugMode = {
                        order = 33,
                        name = "Debug Mode",
                        desc = "Print debug output to chat and show the debug window (message stats, buddies)",
                        descStyle = "inline",
                        width = "full",
                        type = "toggle",
                        set = function(_, val)
                            _self.DB.profile.options.debug = val
                            if val then
                                _self.DebugFrame:Show()
                            else
                                _self.DebugFrame:Hide()
                            end
                        end,
                        get = function() return _self.DB.profile.options.debug end,
                    },
                    reset = {
                        order = 50,
                        name = "Reset Data",
                        type = "execute",
                        func = function()
                            _self:ResetDB()
                        end,
                    },
                }
            }
        }
    }

    AceConfig:RegisterOptionsTable(WoWForeverRace.Config.AceConfig, configOptions, {"wfropts"})
    AceConfigDialog:AddToBlizOptions(WoWForeverRace.Config.AceConfig, WoWForeverRace.Config.AceConfig)

    local ldb = LibDataBroker:NewDataObject(WoWForeverRace.Config.LDB, {
        type = "data source",
        text = WoWForeverRace.Config.Name,
        icon = "Interface\\AddOns\\WoWForeverRace\\media\\icon",
        OnClick = function(_, ...) _self:MinimapIconClick(...) end
    })
    LibDBIcon:Register(WoWForeverRace.Config.LDB, ldb, self.DB.profile.options.minimap)

    local hint = WHITE .. WoWForeverRace.Config.Name .. "\n" ..
                 BROWN .. "Click|r to show the leaderboard. " ..
                 BROWN .. "Right-Click|r to open options dialog."
    function ldb.OnTooltipShow(tt)
        tt:AddLine(hint, 0.2, 1, 0.2, 1)
    end

end

function WoWForeverRace:MinimapIconClick(button)
    if button == "RightButton" then
        AceConfigDialog:Open(WoWForeverRace.Config.AceConfig)
    else
        self.StatusFrame:Show()
        self.scanner:TriggerScan()
    end
end
