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
-- channel member lists, see SetChannelMembers; rosterKnown: the channels whose list the
-- client holds (a SetSelectedDisplayChannel asked for it), rosterRequests: how often
local channelMembers, rosterKnown, rosterRequests

_G.SetChatChannels = function(names)
    chatChannels = {}
    for i, name in ipairs(names or defaultChannels) do
        chatChannels[i] = name
    end
    joinRefused = false
    joinRequests = {}
    channelMembers, rosterKnown, rosterRequests = {}, {}, 0
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

-- the password the last join was made with, see GetLastChannelJoinPassword()
local lastJoinPassword

_G.GetLastChannelJoinPassword = function()
    return lastJoinPassword
end

_G.JoinTemporaryChannel = function(name, password)
    joinRequests[#joinRequests + 1] = name
    lastJoinPassword = password
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

-- The Channels window's list and the member lists of its channels. The display index is
-- the slot here too (the real client puts category headers in between). The member count
-- is nil until SetSelectedDisplayChannel asked the server for that channel's list, like
-- on the client; the CHANNEL_ROSTER_UPDATE it causes there is not fired by the stub.
-- SetChannelMembers(name, names): who is in that channel (names ignore case).
_G.SetChannelMembers = function(name, names)
    channelMembers[string.lower(name)] = names
end

_G.GetChannelRosterRequests = function()
    return rosterRequests
end

_G.GetNumDisplayChannels = function()
    return #chatChannels
end

-- name, header, collapsed, channelNumber, count, active, category, channelType
_G.GetChannelDisplayInfo = function(index)
    local name = chatChannels[index]
    if name == nil then return nil end
    local count = nil
    if rosterKnown[string.lower(name)] then
        count = #(channelMembers[string.lower(name)] or {})
    end
    return name, false, false, index, count, true, "CHANNEL_CATEGORY_CUSTOM", 0
end

_G.SetSelectedDisplayChannel = function(index)
    local name = chatChannels[index]
    if name == nil then return end
    rosterKnown[string.lower(name)] = true
    rosterRequests = rosterRequests + 1
end

-- name, owner, moderator, guid
_G.C_ChatInfo.GetChannelRosterInfo = function(index, rosterIndex)
    local name = chatChannels[index]
    local members = name ~= nil and channelMembers[string.lower(name)] or nil
    if members == nil or members[rosterIndex] == nil then return nil end
    return members[rosterIndex], rosterIndex == 1, false, "Player-1-" .. string.format("%08X", rosterIndex)
end
