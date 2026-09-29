import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The peer end to end: control lines in, JSON lines out, through a real ``Mesh`` on a scripted radio, with a second
/// engine signing and sealing the far side's frames.
@Suite(.timeLimit(.minutes(1))) struct PeerNodeTests {
    @Test func startingReportsReadyAndPublishesTheName() async throws {
        let rig = PeerRig()
        await rig.node.start(name: "Near")
        await rig.node.start(name: "Again")
        #expect(rig.radio.started)
        let ready = try #require(await rig.lines.first { $0["event"] as? String == "ready" })
        #expect(ready["nodeId"] as? String == rig.keys.nodeId.string)
        #expect(ready["radioProfile"] as? String == "android")
        #expect(rig.stores.ownProfile.load().name == "Near")
        #expect(rig.lines.objects.filter { $0["event"] as? String == "ready" }.count == 1, "starting twice starts once")
    }

    @Test func aNameAlreadyPublishedIsNotPublishedAgain() async {
        let rig = PeerRig()
        rig.stores.ownProfile.save(OwnProfile(name: "Near", version: 3, publishedAt: 3))
        await rig.node.start(name: "Near")
        #expect(rig.stores.ownProfile.load().version == 3)
    }

    @Test func statusSaysWhoWeAreAndEchoesTheTag() async throws {
        let rig = PeerRig()
        await rig.node.start(name: nil)
        let status = try await rig.send(#"{"cmd":"status","tag":"s1"}"#)
        #expect(status["reply"] as? String == "status")
        #expect(status["ok"] as? Bool == true)
        #expect(status["tag"] as? String == "s1")
        #expect(status["nodeId"] as? String == rig.keys.nodeId.string)
        #expect(status["displayName"] as? String == Alias.alias(for: rig.keys.nodeId.string), "no name, so the alias")
        #expect(status["links"] as? Int == 0)
        #expect(status["custody"] as? Int == 1, "our own profile")
        #expect(status["fileRecords"] as? Int == 0)
    }

    @Test func statusCountsWhatTheMeshHoldsInMemory() async throws {
        let rig = PeerRig()
        await rig.node.start(name: nil)
        let before = try #require(try await rig.send(#"{"cmd":"status"}"#)["footprint"] as? [String: Any])
        _ = try await rig.send(#"{"cmd":"room","text":"counted"}"#)
        let status = try await rig.send(#"{"cmd":"status"}"#)
        let footprint = try #require(status["footprint"] as? [String: Any])
        let tables = [
            "cachedProfiles", "channels", "crossings", "earlyReceipts", "missingKeys", "owedTicks", "parked", "pendingRelays", "seen",
            "tombstones",
        ]
        #expect(footprint.keys.sorted() == tables)
        #expect(footprint["seen"] as? Int == (before["seen"] as? Int).map { $0 + 1 }, "our own post is marked seen")
        #expect(footprint["channels"] as? Int == 0)
        let router = try #require(status["router"] as? [String: Any])
        #expect(router.keys.sorted() == ["admitted", "deduplicated", "handedOn", "refused", "relayed", "suppressed"])
        #expect(router["admitted"] as? Int == 0, "nothing came off a link")
    }

    @Test func aBadLineIsAnswered() async throws {
        let rig = PeerRig()
        let reply = try await rig.send("hello?")
        #expect(reply["reply"] as? String == "error")
        #expect(reply["ok"] as? Bool == false)
        let unknown = try await rig.send(#"{"cmd":"fly"}"#)
        #expect(unknown["error"] as? String == "unknown command fly")
    }

    @Test func aRoomPostIsKeptAndItsIdAnswered() async throws {
        let rig = PeerRig()
        await rig.node.start(name: nil)
        let post = try await rig.send(#"{"cmd":"room","text":"hello, nearby"}"#)
        let id = try #require(post["id"] as? String)
        let thread = try await rig.send(#"{"cmd":"messages","conv":"nearby"}"#)
        let messages = try #require(thread["messages"] as? [[String: Any]])
        #expect(messages.map { $0["id"] as? String } == [id])
        #expect(messages.first?["to"] is NSNull)
    }

    @Test func blankMessagesAreRefused() async throws {
        let rig = PeerRig()
        await rig.node.start(name: nil)
        let room = try await rig.send(#"{"cmd":"room","text":"   "}"#)
        #expect(room["ok"] as? Bool == false)
        let dm = try await rig.send(#"{"cmd":"dm","to":"\#(rig.keys.nodeId)","text":"to myself"}"#)
        #expect(dm["ok"] as? Bool == false)
    }

    @Test func aDMToAPeerWithNoKeyWaitsForIt() async throws {
        let rig = PeerRig()
        await rig.node.start(name: nil)
        let dm = try await rig.send(#"{"cmd":"dm","to":"\#(rig.far.nodeId)","text":"hello"}"#)
        #expect(dm["ok"] as? Bool == true)
        #expect(dm["pendingKey"] as? Bool == true)
    }

    @Test func theRadiosStateIsReported() async throws {
        let rig = PeerRig()
        await rig.node.start(name: nil)
        rig.radio.emit(.state(.off))
        let radio = try #require(await rig.lines.first { $0["event"] as? String == "radio" })
        #expect(radio["state"] as? String == "off")
    }

    @Test func aLinkIsReportedListedAndCutByDenyLink() async throws {
        let rig = PeerRig()
        await rig.node.start(name: nil)
        try await rig.link()
        let links = try await rig.send(#"{"cmd":"links"}"#)
        let linked = try #require(links["links"] as? [[String: Any]])
        #expect(linked.first?["peer"] as? String == rig.far.nodeId.string)
        #expect(linked.first?["capabilities"] as? String == "fff")
        #expect((links["sightings"] as? [Any])?.isEmpty == true)
        let deny = try await rig.send(#"{"cmd":"deny-link","peer":"\#(rig.far.nodeId)"}"#)
        #expect(deny["ok"] as? Bool == true)
        let down = try #require(await rig.lines.first { $0["event"] as? String == "link" && $0["up"] as? Bool == false })
        #expect(down["peer"] as? String == rig.far.nodeId.string)
        #expect(rig.radio.closed == [PeerRig.channel])
        let allow = try await rig.send(#"{"cmd":"allow-link","peer":"\#(rig.far.nodeId)"}"#)
        #expect(allow["peer"] as? String == rig.far.nodeId.string)
    }

    @Test func aSightedPeerIsListed() async throws {
        let rig = PeerRig()
        await rig.node.start(name: nil)
        let advert = AdvertPayload(capabilities: 0xFFF, nodeId: rig.far.nodeId, digestCue: 0, psm: 0x80, flags: 1)
        rig.radio.emit(.sighted(RadioSighting(address: RadioAddress("/dev"), advert: advert, rssi: -61)))
        var sightings: [[String: Any]] = []
        for _ in 0..<1000 where sightings.isEmpty {
            await Task.yield()
            sightings = try await rig.send(#"{"cmd":"links"}"#)["sightings"] as? [[String: Any]] ?? []
        }
        #expect(sightings.first?["peer"] as? String == rig.far.nodeId.string)
        #expect(sightings.first?["rssi"] as? Int == -61)
        #expect(sightings.first?["psm"] as? Int == 0x80)
    }

    @Test func aFarPeersProfilePostsAndDMsReachTheNodeAndOurDMIsDelivered() async throws {
        let rig = PeerRig()
        await rig.node.start(name: "Near")
        try await rig.link()
        rig.farEngine.start()
        rig.farEngine.linkUp(Neighbor(nodeId: rig.keys.nodeId, capabilities: .local))
        rig.deliverFromFar()

        let profile = try #require(await rig.lines.first { $0["event"] as? String == "profile" })
        #expect(profile["peer"] as? String == rig.far.nodeId.string)
        #expect(profile["name"] as? String == "Far")
        let peers = try #require(try await rig.send(#"{"cmd":"peers"}"#)["peers"] as? [[String: Any]])
        let safety = SafetyNumber.compute(mine: rig.keys.bundle, theirs: rig.far.bundle)
        #expect(peers.first?["safetyNumber"] as? String == safety)
        #expect(peers.first?["alias"] as? String == Alias.alias(for: rig.far.nodeId.string))

        rig.farEngine.postToRoom("hello from far")
        rig.deliverFromFar()
        let post = try #require(await rig.lines.first { $0["event"] as? String == "message" && $0["conv"] as? String == "nearby" })
        #expect(post["body"] as? String == "hello from far")
        #expect(post["request"] as? Bool == false)

        rig.deliverToFar()
        rig.farEngine.sendDirectMessage("psst", to: rig.keys.nodeId)
        rig.deliverFromFar()
        let request = try #require(await rig.lines.first { $0["event"] as? String == "message" && $0["body"] as? String == "psst" })
        #expect(request["request"] as? Bool == true)
        #expect(request["conv"] as? String == rig.far.nodeId.string)
        let accepted = try await rig.send(#"{"cmd":"accept","conv":"\#(rig.far.nodeId)"}"#)
        #expect(accepted["conv"] as? String == rig.far.nodeId.string)

        let sent = try await rig.send(#"{"cmd":"dm","to":"\#(rig.far.nodeId)","text":"back at you"}"#)
        #expect(sent["pendingKey"] as? Bool == false)
        let ours = try #require(sent["id"] as? String)
        rig.deliverToFar()
        rig.deliverFromFar()
        let delivered = try #require(await rig.lines.first { $0["event"] as? String == "delivered" })
        #expect(delivered["id"] as? String == ours)

        let thread = try await rig.send(#"{"cmd":"messages","conv":"\#(rig.far.nodeId)","limit":5}"#)
        let messages = try #require(thread["messages"] as? [[String: Any]])
        #expect(messages.map { $0["body"] as? String } == ["psst", "back at you"])
        #expect(messages.last?["delivered"] as? Bool == true)
        #expect(messages.last?["to"] as? String == rig.far.nodeId.string)

        let digest = try await rig.send(#"{"cmd":"digest"}"#)
        let ids = try #require(digest["ids"] as? [String])
        #expect(ids.contains { $0.hasPrefix("profile-\(rig.keys.nodeId)-") })
        #expect(ids.contains { $0.hasPrefix("profile-\(rig.far.nodeId)-") })
        #expect(digest["count"] as? Int == ids.count)
        #expect((digest["fingerprint"] as? String)?.isEmpty == false)
    }

    @Test func custodyDescribesEveryFrameTheDigestLists() async throws {
        let rig = PeerRig()
        await rig.node.start(name: "Near")
        try await rig.link()
        rig.farEngine.start()
        rig.farEngine.linkUp(Neighbor(nodeId: rig.keys.nodeId, capabilities: .local))
        rig.farEngine.postToRoom("hello from far")
        rig.deliverFromFar()
        _ = try #require(await rig.lines.first { $0["event"] as? String == "message" })

        let ids = try #require(try await rig.send(#"{"cmd":"digest"}"#)["ids"] as? [String])
        let frames = try #require(try await rig.send(#"{"cmd":"custody"}"#)["frames"] as? [[String: Any]])
        #expect(frames.compactMap { $0["id"] as? String } == ids)
        let ownProfile = try #require(frames.first { ($0["id"] as? String)?.hasPrefix("profile-\(rig.keys.nodeId)-") == true })
        #expect(ownProfile["type"] as? String == "profile")
        #expect(ownProfile["from"] as? String == rig.keys.nodeId.string)
        #expect(ownProfile["to"] is NSNull)
        #expect(ownProfile["group"] is NSNull)
        let post = try #require(frames.first { $0["type"] as? String == "chat" })
        #expect(post["from"] as? String == rig.far.nodeId.string)
        #expect((post["sentAt"] as? Int ?? 0) > 0)
    }

    @Test func aSealedDMWaitingForItsKeyIsReportedSentWhenTheKeyPins() async throws {
        let rig = PeerRig()
        await rig.node.start(name: nil)
        let pending = try await rig.send(#"{"cmd":"dm","to":"\#(rig.far.nodeId)","text":"later"}"#)
        let id = try #require(pending["id"] as? String)
        try await rig.link()
        rig.farEngine.start()
        rig.farEngine.linkUp(Neighbor(nodeId: rig.keys.nodeId, capabilities: .local))
        rig.deliverFromFar()
        let sent = try #require(await rig.lines.first { $0["event"] as? String == "sent" })
        #expect(sent["id"] as? String == id)
    }

    @Test func nameChangesWhatIsGivenAndKeepsTheRest() async throws {
        let rig = PeerRig()
        await rig.node.start(name: nil)
        _ = try await rig.send(#"{"cmd":"name","name":"Near","status":"testing"}"#)
        let reply = try await rig.send(#"{"cmd":"name","openToChat":true}"#)
        #expect(reply["name"] as? String == "Near")
        #expect(reply["status"] as? String == "testing")
        #expect(reply["openToChat"] as? Bool == true)
        #expect(rig.stores.ownProfile.load().openToChat)
    }

    @Test func quitStopsTheNodeAndSaysSo() async {
        let rig = PeerRig()
        await rig.node.start(name: nil)
        let keepGoing = await rig.node.handle(#"{"cmd":"quit"}"#)
        #expect(!keepGoing)
        #expect(rig.radio.stopped)
        #expect(rig.lines.objects.last?["reply"] as? String == "quit")
    }
}
