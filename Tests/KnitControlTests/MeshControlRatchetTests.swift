import Foundation
import KnitControl
import KnitCrypto
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// `{"cmd":"ratchet"}`: every pinned peer's DM ratchet state under the keys of Android's debug bridge `RATCHET`
/// (`DebugBridgeReceiver.kt:1450-1502`), and with `reset` a forced reset first, sealed, persisted and flooded, as the
/// bridge's `--es reset <peer>` sends one (ADR 2026-10.5sk9, phase P5a).
@Suite(.timeLimit(.minutes(1))) struct MeshControlRatchetTests {
    private let peer = TestKeys(seed: 4)

    @Test func theCommandParsesWithOrWithoutAPeerToReset() throws {
        let id = peer.keys.nodeId
        #expect(try ControlRequest.parse(#"{"cmd":"ratchet"}"#).get().command == .ratchet(reset: nil))
        #expect(try ControlRequest.parse(#"{"cmd":"ratchet","reset":" "}"#).get().command == .ratchet(reset: nil), "blank asks for none")
        #expect(try ControlRequest.parse(#"{"cmd":"ratchet","reset":" \#(id) "}"#).get().command == .ratchet(reset: id))
        #expect(ControlRequest.parse(#"{"cmd":"ratchet","reset":"nobody"}"#) == .failure(.invalidNodeId("nobody")))
        #expect(ControlCommand.ratchet(reset: nil).name == "ratchet")
    }

    @Test func theDumpNamesEveryPinnedPeerInAndroidsKeys() async throws {
        let rig = ControlRig()
        rig.stores.peers.upsert(
            PeerRecord(
                nodeId: peer.keys.nodeId,
                name: "Dana",
                status: "",
                publicKey: peer.keys.bundle.encoded,
                capabilities: 0x15F,
                updatedAt: 1,
                prekey: try peer.prekey(id: 2),
                prekeyProfileAt: 1
            )
        )
        var own = rig.stores.ownProfile.load()
        own.prekeyId = 3
        rig.stores.ownProfile.save(own)
        let reply = try await rig.send(#"{"cmd":"ratchet","tag":"r"}"#)
        #expect(reply["ok"] as? Bool == true && reply["reply"] as? String == "ratchet" && reply["tag"] as? String == "r")
        #expect(reply["prekeyId"] as? Int == 3)
        #expect(reply["forcedReset"] == nil, "no reset was asked for")
        let peers = try #require(reply["peers"] as? [[String: Any]])
        let dana = try #require(peers.first)
        #expect(peers.count == 1)
        #expect(dana["peer"] as? String == peer.keys.nodeId.string && dana["name"] as? String == "Dana")
        #expect(dana["capRatchet"] as? Bool == true && dana["peerPrekeyId"] as? Int == 2 && dana["peerPrekeyPinned"] as? Bool == true)
        #expect(dana["hasSession"] as? Bool == false && dana["confirmed"] as? Bool == false && dana["sendEpoch"] as? Int == 0)
        #expect(dana["rootHash"] is NSNull && (dana["localEpochs"] as? [String])?.isEmpty == true)
        let keys = Set(dana.keys)
        #expect(
            keys == [
                "peer", "name", "capRatchet", "peerPrekeyId", "peerPrekeyPinned", "hasSession", "confirmed", "sendEpoch",
                "lastResetSentAt", "establishedAt", "weAreInitiator", "highestPeAcked", "rootHash", "prevRootExpiresAt",
                "hasPeerInitAnchor", "localEpochs",
            ])
    }

    @Test func aForcedResetIsDeclinedWithTheSwitchOff() async throws {
        let rig = ControlRig()
        pin(peer, in: rig.stores)
        let reply = try await rig.send(#"{"cmd":"ratchet","reset":"\#(peer.keys.nodeId)"}"#)
        #expect(reply["ok"] as? Bool == true)
        #expect(reply["forcedReset"] as? String == peer.keys.nodeId.string)
        #expect(reply["declined"] as? String == "the ratchet is off")
        #expect(reply["prekeyId"] is NSNull)
        let peers = try #require(reply["peers"] as? [[String: Any]])
        #expect(peers.first?["hasSession"] as? Bool == false)
    }

    @Test func aForcedResetIsSentAndShownInTheDumpThatFollows() async throws {
        let rig = ControlRig(configuration: MeshConfiguration(ratchet: true))
        pin(peer, in: rig.stores)
        let reply = try await rig.send(#"{"cmd":"ratchet","reset":"\#(peer.keys.nodeId)"}"#)
        #expect(reply["declined"] is NSNull)
        #expect(reply["reRooted"] as? Bool == true)
        let dana = try #require((reply["peers"] as? [[String: Any]])?.first)
        #expect(dana["hasSession"] as? Bool == true && dana["weAreInitiator"] as? Bool == true && dana["sendEpoch"] as? Int == 1)
        #expect((dana["rootHash"] as? String)?.count == RatchetPeerState.rootHashLength)
        let stamp = try #require(dana["lastResetSentAt"] as? Int)
        #expect(dana["localEpochs"] as? [String] == ["1@\(stamp)"])
        let carried = rig.stores.custody.liveFrames(now: Int64(stamp)).filter { $0.envelope.type == .chat }
        #expect(carried.map(\.envelope.recipientId) == [peer.keys.nodeId.string], "the reset went out, and we carry it as our own")
        let again = try await rig.send(#"{"cmd":"ratchet","reset":"\#(peer.keys.nodeId)"}"#)
        #expect(again["declined"] as? String == "our reset is still on its way")
        #expect(again["reRooted"] == nil)
    }

    /// The reply's `seals`, under Android's metric names (phase P5b): a DM to the pinned peer goes with the ratchet, compact
    /// to a v3 reader, and with the switch off goes v1 and counts nothing.
    @Test func theDumpCountsHowOurDMsWereSealed() async throws {
        for on in [true, false] {
            let rig = ControlRig(configuration: MeshConfiguration(ratchet: on))
            pin(peer, in: rig.stores)
            let sent = try await rig.send(#"{"cmd":"dm","to":"\#(peer.keys.nodeId)","text":"hi"}"#)
            #expect(sent["pendingKey"] as? Bool == false)
            let seals = try #require(try await rig.send(#"{"cmd":"ratchet"}"#)["seals"] as? [String: Int])
            let counted = on ? 1 : 0
            #expect(seals == ["dmSealedV2": counted, "dmSealedV3": counted, "dmSealedV1Fallback": 0], "switch \(on)")
        }
    }

    private func pin(_ peer: TestKeys, in stores: MeshStores) {
        stores.peers.upsert(
            PeerRecord(
                nodeId: peer.keys.nodeId,
                name: "Dana",
                status: "",
                publicKey: peer.keys.bundle.encoded,
                capabilities: 0x15F,
                updatedAt: 1,
                prekey: try? peer.prekey(id: 1),
                prekeyProfileAt: 1
            )
        )
    }
}

/// Fixed keys that sign their own prekeys.
struct TestKeys {
    let keys: IdentityKeys

    init(seed: Int) {
        guard let made = IdentityKeys(signingSeed: fixtureBytes(32, seed: seed), agreementScalar: fixtureBytes(32, seed: seed + 100)) else {
            fatalError("fixed seeds make valid keys")
        }
        keys = made
    }

    /// Prekey `id` as these keys would publish it.
    func prekey(id: Int) throws -> PrekeyInfo {
        try SignedPrekey.mint(id: id, signedBy: keys, createdAt: 0).info
    }
}
