local WoWForeverRace = require("testbase")

local Events = WoWForeverRace.Config.Events
local NetworkEvents = WoWForeverRace.Config.Network.Events
local Serializer = LibStub("AceSerializer-3.0")
local LibCompress = LibStub("LibCompress")
local EncodeTable = LibCompress:GetAddonEncodeTable()

describe("Network", function()
    it("does not publish local events received over the wire", function()
        local core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
        local eventbus = WoWForeverRace.EventBus()
        local network = WoWForeverRace.Network(core, eventbus)
        local eventBusSpy = spy.on(eventbus, "PublishEvent")
        local serialized = Serializer:Serialize({Events.ScanFinished, {true}})
        local message = EncodeTable:Encode(LibCompress:CompressHuffman(serialized))

        network:HandleAddonMessage(WoWForeverRace.Config.Network.Prefix, message,
                "WHISPER", "Dude-NubVille")

        assert.spy(eventBusSpy).called_at_most(0)
    end)

    it("accepts configured network events", function()
        local core = WoWForeverRace.Core(WoWForeverRace.Config, "Nub", "NubVille")
        local eventbus = WoWForeverRace.EventBus()
        local network = WoWForeverRace.Network(core, eventbus)
        local eventBusSpy = spy.on(eventbus, "PublishEvent")
        local serialized = Serializer:Serialize({NetworkEvents.SyncPayload, {"data"}})
        local message = EncodeTable:Encode(LibCompress:CompressHuffman(serialized))

        network:HandleAddonMessage(WoWForeverRace.Config.Network.Prefix, message,
                "WHISPER", "Dude-NubVille")

        assert.spy(eventBusSpy).was_called_with(match.is_ref(eventbus),
                NetworkEvents.SyncPayload, {"data"}, "Dude-NubVille")
    end)
end)
