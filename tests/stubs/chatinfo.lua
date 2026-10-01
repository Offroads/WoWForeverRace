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

-- Chat channels, see SetChatChannels(names): the channels the player is in, in slot
-- order (default: General and Trade; nil restores it). JoinTemporaryChannel adds one
-- at the end, unless SetChannelJoinRefused makes the server ignore the join: true for
-- every channel, or a list of the channel names that are refused.
-- GetChannelJoinRequests() lists the names passed to JoinTemporaryChannel since
-- SetChatChannels. The state is shared by every addon stack of a test.
local defaultChannels = {"General", "Trade"}
local chatChannels, joinRefused, joinRequests

_G.SetChatChannels = function(names)
    chatChannels = {}
    for i, name in ipairs(names or defaultChannels) do
        chatChannels[i] = name
    end
    joinRefused = false
    joinRequests = {}
end
_G.SetChatChannels(nil)

_G.SetChannelJoinRefused = function(refused)
    joinRefused = refused or false
end

_G.GetChannelJoinRequests = function()
    return joinRequests
end

-- id1, name1, disabled1, id2, ...
_G.GetChannelList = function()
    local list = {}
    for i, name in ipairs(chatChannels) do
        list[#list + 1] = i
        list[#list + 1] = name
        list[#list + 1] = false
    end
    return unpack(list)
end

-- id, name, instanceID; id 0 when the player is not in that channel (names ignore case)
_G.GetChannelName = function(name)
    for i, channel in ipairs(chatChannels) do
        if string.lower(channel) == string.lower(tostring(name)) then
            return i, channel, 0
        end
    end
    return 0, nil, 0
end

_G.JoinTemporaryChannel = function(name)
    joinRequests[#joinRequests + 1] = name
    local refused = joinRefused == true
    if type(joinRefused) == "table" then
        for _, refusedName in ipairs(joinRefused) do
            if string.lower(refusedName) == string.lower(name) then refused = true end
        end
    end
    if not refused and _G.GetChannelName(name) == 0 then
        chatChannels[#chatChannels + 1] = name
    end
    return 0, nil
end

_G.LeaveChannelByName = function(name)
    local id = _G.GetChannelName(name)
    if id > 0 then
        table.remove(chatChannels, id)
    end
end
