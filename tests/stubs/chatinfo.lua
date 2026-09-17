-- Enum table is required by newer ChatThrottleLib versions
_G.Enum = _G.Enum or {}

_G.C_ChatInfo = {}
_G.C_ChatInfo.RegisterAddonMessagePrefix = function()
end
_G.C_ChatInfo.SendAddonMessage = function()
end
-- chat messaging lockdown (encounters, dungeons and raids on modern clients),
-- see SetChatLockdown(lockedDown)
local chatLockdown = false
_G.C_ChatInfo.InChatMessagingLockdown = function()
    return chatLockdown
end
_G.SetChatLockdown = function(lockedDown)
    chatLockdown = lockedDown or false
end
