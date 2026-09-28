import KnitCrypto
import KnitMesh
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitAppCore

/// Diagnostics: links, sightings, counters, clocks, and the debug build's test identities.
@MainActor
@Suite struct DiagnosticsTests {
    private func sighting(_ person: Person, rssi: Double, agoMilliseconds: Int64) -> PresenceTracker.Snapshot {
        PresenceTracker.Snapshot(
            advert: AdvertPayload(capabilities: 0x9, nodeId: person.nodeId, digestCue: 0, psm: 0x81),
            smoothedRssi: rssi,
            dwellMilliseconds: 0,
            lastSeenAgoMilliseconds: agoMilliseconds
        )
    }

    @Test func linksSightingsAndTheRestAreListedApart() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        await rig.pin(AppRig.priya, name: "Priya")
        await rig.pin(AppRig.stranger, name: "")
        let mesh = MeshDiagnostics(
            neighbors: [Neighbor(nodeId: AppRig.sam.nodeId, protocolVersion: 3, capabilities: Capabilities(rawValue: 0x9))],
            sightings: [
                sighting(AppRig.sam, rssi: -60.4, agoMilliseconds: 500), sighting(AppRig.priya, rssi: -71.6, agoMilliseconds: 3200),
            ],
            dropped: [.badSignature: 2],
            discardedFileRecords: 3
        )
        let state = DiagnosticsModel.state(mesh, directory: rig.session.directory, stores: rig.stores, radio: .on, running: true)
        #expect(state.radio == Copy.Diagnostics.radio(.on))
        #expect(state.isRunning)
        #expect(state.linked.map(\.title) == ["Sam"])
        #expect(state.linked.first?.detail == "v3, caps 9")
        #expect(state.sighted.map(\.title) == ["Priya"], "a linked peer is listed once, under its link")
        #expect(state.sighted.first?.detail == "-72 dBm, 3 s ago")
        #expect(state.known.map(\.id) == [AppRig.stranger.nodeId])
        #expect(state.counters.map(\.count) == [3, 2])
        #expect(state.counters.last?.id == Copy.Drops.reason(.badSignature))
    }

    @Test func aPeersClockIsJudgedByItsFastestArrival() async {
        let rig = AppRig()
        await rig.pin(AppRig.sam, name: "Sam")
        // Their clock runs 30 s behind ours; the room post took 4 s longer to arrive than the DM.
        await rig.receive("Room", from: AppRig.sam.nodeId, sentAt: 10_000, arrivedAt: 44_000)
        await rig.receive("DM", from: AppRig.sam.nodeId, to: rig.me, sentAt: 20_000, arrivedAt: 50_000)
        let mesh = MeshDiagnostics(neighbors: [Neighbor(nodeId: AppRig.sam.nodeId)])
        let state = DiagnosticsModel.state(mesh, directory: rig.session.directory, stores: rig.stores, radio: nil, running: false)
        #expect(state.linked.first?.clock == Copy.Diagnostics.clockBehind(seconds: 30))
        #expect(state.radio == Copy.Diagnostics.radio(nil))
    }

    @Test func aClockAheadInStepOrBehindReadsSo() {
        #expect(ClockSkew.estimate([]) == nil)
        let mine = MessageRecord(id: "m", senderId: AppRig.me.nodeId, recipientId: nil, conversationId: "nearby", body: "", sentAt: 5)
        #expect(ClockSkew.estimate([mine]) == nil, "our own messages have no arrival")
        #expect(ClockSkew.label(1500) == Copy.Diagnostics.clockInStep)
        #expect(ClockSkew.label(-2000) == Copy.Diagnostics.clockInStep)
        #expect(ClockSkew.label(-90_000) == Copy.Diagnostics.clockAhead(seconds: 90))
        #expect(ClockSkew.label(12_500) == Copy.Diagnostics.clockBehind(seconds: 12))
    }

    @Test func refreshingReadsTheMeshThroughTheSession() async {
        let rig = AppRig()
        let model = DiagnosticsModel(session: rig.session)
        #expect(model.state == nil)
        await model.refresh()
        #expect(model.state?.linked.isEmpty == true)
        #expect(model.state?.counters.map(\.count) == [0])
        #expect(model.nodeId == rig.me.string)
        #expect(model.alias == rig.session.identity.alias)
        #expect(!model.mintsIdentities, "a release build offers no test identities")
        await model.mint(above: "", below: "")
        #expect(model.mintOutcome == nil)
    }

    @Test func aMintedIdentitySortsInsideTheBoundsAndIsStored() async throws {
        let rig = AppRig()
        let stored = Lock<IdentityKeys?>(nil)
        let model = DiagnosticsModel(session: rig.session) { keys in stored.withLock { $0 = keys } }
        #expect(model.mintsIdentities)
        await model.mint(above: " \(AppRig.sam.nodeId) ", below: "")
        let keys = try #require(stored.withLock { $0 })
        #expect(keys.nodeId > AppRig.sam.nodeId)
        #expect(model.mintOutcome == Copy.TestIdentity.minted(keys.nodeId.string))
    }

    @Test func badBoundsAnEmptyWindowAndAFailedStoreEachSayWhy() async {
        let rig = AppRig()
        struct Refused: Error, CustomStringConvertible {
            var description: String { "the Keychain said no" }
        }
        let model = DiagnosticsModel(session: rig.session) { _ in throw Refused() }
        await model.mint(above: "not a node id", below: "")
        #expect(model.mintOutcome == Copy.TestIdentity.invalidNodeId)
        let low = min(AppRig.sam.nodeId, AppRig.priya.nodeId)
        await model.mint(above: low.string, below: low.string)
        #expect(model.mintOutcome == Copy.TestIdentity.noRoom)
        await model.mint(above: "", below: "")
        #expect(model.mintOutcome == "the Keychain said no")
    }

    @Test func aWindowTakesBlankBoundsAsOpen() throws {
        let window = try #require(DiagnosticsModel.window(above: "", below: AppRig.sam.nodeId.string))
        #expect(window == KeyGen.Window(above: nil, below: AppRig.sam.nodeId))
        #expect(DiagnosticsModel.window(above: "", below: "nope") == nil)
    }
}
