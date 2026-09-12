--[[
This file contains development-only things that aren't pretty but don't need to be ... xD
--]]
-- Addon global
local WoWForeverRace = _G.WoWForeverRace

--[[
The /wfr handler, overwrites with a more advanced development mode /wfr
--]]
function WoWForeverRace:slashwfr(input)
    local action, arg1, arg2, arg3 = self:GetArgs(input, 4)

    --[[SCAN]]--
    if action == "scan" then
        self.scanner:TriggerScan()

    --[[RESET]]--
    elseif action == "reset" then
        self.DB:ResetDB()

    --[[SHOW FRAME]]--
    elseif action == "show" then
        self.StatusFrame:Show()

    --[[DEBUG FRAME]]--
    elseif action == "debug" then
        self.DebugFrame:Show()

    --[[UPDATE FRAME]]--
    elseif action == "render" then
        self.StatusFrame:Render()

    --[[REQUEST UPDATE]]--
    elseif action == "update" then
        self.Sync:InitSync()

    --[[WHOAMI]]--
    elseif action == "whoami" then
        self.Core:InitMe(arg1, self.Core:MyRealm())

    --[[DING name level]]--
    elseif action == "ding" then
        WoWForeverRace:DebugPrint("Forced Ding [" .. arg1 .. "] lvl" .. arg2 .. ".")
        self.EventBus:PublishEvent(self.Config.Events.SlashWhoResult, {{
            name = arg1,
            level = tonumber(arg2),
            class = arg3 or "DRUID",
        }})
    else
        self:PPrint("Unknown action: " .. tostring(action))
    end
end
