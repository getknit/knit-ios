import Foundation
import KnitCrypto
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitControl
@testable import KnitMesh

/// `advert` and `advert-rotate` (ADR 2026-11.prsp, "The bridge and the harness"): what the app's bridge and knit-peer answer
/// about the blinded advert, the switch they store, the wait for the air, and a forced rotation's refusals.
@Suite(.timeLimit(.minutes(1))) struct MeshControlAdvertTests {
    @Test func theReplyReadsTheGatesAndTheFormBeforeAndAfterTheRadioComesUp() async throws {
        let rig = AdvertRig()
        var reply = try await rig.send(#"{"cmd":"advert"}"#)
        #expect(reply["reply"] as? String == "advert" && reply["ok"] as? Bool == true)
        #expect(reply["build"] as? Bool == true && reply["blindsAdvert"] as? Bool == true)
        #expect(reply["running"] as? Bool == false)
        #expect(reply["form"] is NSNull)
        let held = try #require(reply["switch"] as? [String: Any])
        #expect(held["value"] as? Bool == false && held["stored"] is NSNull && held["default"] as? Bool == false)
        #expect(reply["applied"] == nil, "a read stores nothing and waits for nothing")
        await rig.bringUp()
        reply = try await rig.send(#"{"cmd":"advert"}"#)
        #expect(reply["running"] as? Bool == true && reply["radioUp"] as? Bool == true)
        #expect(reply["form"] as? String == "clear" && reply["lastCause"] as? String == "bringUp")
        #expect(reply["psm"] as? Int == 0x81 && reply["epoch"] as? Int == 1)
        #expect(reply["gatt"] is NSNull, "a radio with no server to report")
        #expect((reply["counters"] as? [String: Any])?["rotationsByFlip"] as? Int == 0)
        #expect((reply["peers"] as? [Any])?.isEmpty == true && (reply["links"] as? [Any])?.isEmpty == true)
    }

    @Test func storingTheSwitchFlipsTheAirAndSaysItApplied() async throws {
        let rig = AdvertRig()
        await rig.bringUp()
        var reply = try await rig.send(#"{"cmd":"advert","blind":"on"}"#)
        #expect(reply["applied"] as? Bool == true && reply["why"] is NSNull)
        #expect(reply["form"] as? String == "tag" && reply["lastCause"] as? String == "flip")
        #expect((reply["switch"] as? [String: Any])?["stored"] as? Bool == true)
        #expect(await rig.host.stored() == .on)
        #expect(rig.radio.advertised.last?.blinded == true)
        reply = try await rig.send(#"{"cmd":"advert","blind":"clear"}"#)
        #expect(reply["applied"] as? Bool == true)
        #expect(reply["form"] as? String == "clear")
        #expect((reply["switch"] as? [String: Any])?["stored"] is NSNull, "the default stands again")
        reply = try await rig.send(#"{"cmd":"advert","blind":"off"}"#)
        #expect((reply["switch"] as? [String: Any])?["stored"] as? Bool == false)
    }

    @Test func aRadioThatNeverServesTheFormTimesOut() async throws {
        let rig = AdvertRig(serving: Self.combinedOnly())
        await rig.bringUp()
        let reply = try await rig.send(#"{"cmd":"advert","blind":"on"}"#)
        #expect(reply["applied"] as? Bool == false && reply["why"] as? String == "timeout")
        let gatt = try #require(reply["gatt"] as? [String: Any])
        #expect(gatt["layout"] as? String == "combined" && gatt["combinedUp"] as? Bool == true)
        #expect(gatt["appliedClear"] as? Bool == true && gatt["appliedTag"] as? Bool == false)
        #expect(gatt["payload"] is NSNull && gatt["matchedByOrder"] as? Int == 0)
    }

    @Test func aStoppedMeshOrADownRadioTakesTheSwitchForLater() async throws {
        let rig = AdvertRig()
        var reply = try await rig.send(#"{"cmd":"advert","blind":"on"}"#)
        #expect(reply["applied"] as? Bool == false && reply["why"] as? String == "transport not running")
        await rig.bringUp()
        #expect(rig.radio.advertised.last?.blinded == true, "the bring-up took the stored switch")
        await rig.mesh.process(.state(.off))
        reply = try await rig.send(#"{"cmd":"advert","blind":"off"}"#)
        #expect(reply["why"] as? String == "radio down")
    }

    @Test func aBuildWithItsGateShutOnlyStores() async throws {
        let rig = AdvertRig(build: false)
        let reply = try await rig.send(#"{"cmd":"advert","blind":"on"}"#)
        #expect(reply["applied"] as? Bool == false && reply["why"] as? String == "build")
        #expect(await rig.host.stored() == .on)
    }

    @Test func aForcedRotationIsRefusedWithItsReason() async throws {
        let rig = AdvertRig()
        await rig.bringUp()
        var reply = try await rig.send(#"{"cmd":"advert-rotate"}"#)
        #expect(reply["reply"] as? String == "advert-rotate")
        #expect(reply["rotated"] as? Bool == false && reply["why"] as? String == "clear")
        #expect(reply["epochBefore"] as? Int == 1 && reply["epochAfter"] as? Int == 1)
        _ = try await rig.send(#"{"cmd":"advert","blind":"on"}"#)
        reply = try await rig.send(#"{"cmd":"advert-rotate"}"#)
        #expect(reply["why"] as? String == "grace", "the flip installed a moment ago")
        #expect(reply["form"] as? String == "tag")
    }

    @Test func theServerReportShowsTheSplitLayoutAndWhatARestorationHandedBack() async throws {
        let rig = AdvertRig(serving: Self.payloadInFlight())
        let gatt = try #require(try await rig.send(#"{"cmd":"advert"}"#)["gatt"] as? [String: Any])
        #expect(gatt["layout"] as? String == "split")
        #expect(gatt["pendingAdd"] as? Int == 1 && gatt["doorbell"] is NSNull)
        #expect(gatt["restoredServices"] as? Int == 2 && gatt["matchedByOrder"] as? Int == 1)
        #expect(gatt["expectsBlinding"] as? Bool == true && gatt["wanted"] as? String == "tag")
        #expect(gatt["listenerPsm"] as? Int == 0x81 && gatt["wantedPsm"] as? Int == 0x81)
    }

    @Test func aNodeWithNoAdvertHostRefusesBoth() async throws {
        let rig = AdvertRig(host: false)
        for line in [#"{"cmd":"advert"}"#, #"{"cmd":"advert-rotate"}"#, #"{"cmd":"advert","blind":"on"}"#] {
            let reply = try await rig.send(line)
            #expect(reply["ok"] as? Bool == false && reply["error"] as? String == "this node has no blinded advert", "\(line)")
        }
        let bad = try await rig.send(#"{"cmd":"advert","blind":"maybe"}"#)
        #expect(bad["error"] as? String == "not a valid blind")
    }

    @Test func theVerdictWaitsForThePendingTagAndNamesWhyItDidNot() {
        let up = Self.status(form: .tag, blinding: true)
        #expect(AdvertSwitch.verdict(running: true, want: true, status: up, serving: nil, timedOut: false).applied)
        let pending = Self.status(form: .clear, blinding: true, pending: true)
        #expect(AdvertSwitch.verdict(running: true, want: true, status: pending, serving: nil, timedOut: false) == .waiting)
        #expect(AdvertSwitch.verdict(running: true, want: true, status: pending, serving: nil, timedOut: true).why == .pending)
        let keyless = Self.status(form: .clear, blinding: false)
        #expect(AdvertSwitch.verdict(running: true, want: true, status: keyless, serving: nil, timedOut: false).why == .noMarkStore)
    }

    @Test func everyFieldRendersUnderItsName() {
        let status = Self.fullStatus()
        let install = status.install
        let fields = ControlLines.fields(of: status)
        #expect(fields["form"] == "tag" && fields["lastCause"] == "forced" && fields["source"] == "slotted")
        #expect(fields["resolvable"] == true && fields["stale"] == false && fields["keyHeld"] == true)
        #expect(fields["keyGeneration"] == 3 && fields["restartsLeft"] == 2 && fields["rotatedAtMs"] == install.map { .int($0.at) })
        guard case .array(let rendered) = fields["links"] else {
            Issue.record("no links")
            return
        }
        let blinded = rendered.map { link -> JSONValue? in
            guard case .object(let entry) = link else {
                return nil
            }
            return entry["blinded"]
        }
        #expect(blinded == [true, false, .null])
        guard case .array(let sighted) = fields["peers"], case .object(let handle) = sighted.first else {
            Issue.record("no peers")
            return
        }
        #expect(handle["peer"] == "~zzzz…3" && handle["linked"] == false && handle["linkedAs"] == .null)
        let none = ControlLines.describe(Self.report(GattServing(), GattServing.Wanted(value: [9], blinded: false)))
        guard case .object(let gatt) = none else {
            Issue.record("no server")
            return
        }
        #expect(gatt["layout"] == .null && gatt["retryAtMs"] == .null && gatt["wanted"] == "clear")
    }

    /// A status with a tag on the air, its install's facts, two sightings and three links of each known kind.
    private static func fullStatus() -> AdvertStatus {
        let install = AdvertStatus.Install(
            cause: "forced", at: 1_790_300_000_000, tag: .init(source: "slotted", resolvable: true, stale: false))
        let peers = [
            AdvertStatus.Peer(peer: "~zzzz…3", resolved: false, blinded: true, iDial: true, linkedAs: nil),
            AdvertStatus.Peer(
                peer: fixtureNodeId(4).string, resolved: true, blinded: false, iDial: false, linkedAs: fixtureNodeId(4).string),
        ]
        let links = [
            AdvertStatus.Link(nodeId: fixtureNodeId(4).string, proven: true, dialedByMe: true, tagAware: true, knownBy: .tag),
            AdvertStatus.Link(nodeId: fixtureNodeId(5).string, proven: false, dialedByMe: false, tagAware: false, knownBy: .clear),
            AdvertStatus.Link(nodeId: fixtureNodeId(6).string, proven: true, dialedByMe: false, tagAware: true, knownBy: nil),
        ]
        return AdvertStatus(
            gate: true,
            switchOn: true,
            blinding: true,
            keyGeneration: 3,
            radioUp: true,
            pending: false,
            form: .tag,
            epoch: 7,
            airedGeneration: 3,
            install: install,
            nextEdgeAt: 1_790_300_900_000,
            announced: true,
            psm: 0x81,
            restartsLeft: 2,
            bringUpsInSlot: 1,
            counters: LinkManager.WriterCounters(),
            peers: peers,
            links: links
        )
    }

    // MARK: Fixtures

    private static func status(form: AdvertStatus.Kind, blinding: Bool, pending: Bool = false) -> AdvertStatus {
        AdvertStatus(
            gate: true,
            switchOn: true,
            blinding: blinding,
            keyGeneration: nil,
            radioUp: true,
            pending: pending,
            form: form,
            epoch: 1,
            airedGeneration: nil,
            install: nil,
            nextEdgeAt: nil,
            announced: false,
            psm: 0x81,
            restartsLeft: nil,
            bringUpsInSlot: 0,
            counters: LinkManager.WriterCounters(),
            peers: [],
            links: []
        )
    }

    /// The report of `serving`, asked to serve `wanted`, as a radio would give it; one that restored `restored` services
    /// also matched an add by order.
    private static func report(_ serving: GattServing, _ wanted: GattServing.Wanted, restored: Int? = nil) -> GattServingReport {
        GattServingReport(
            serving: serving,
            wanted: wanted,
            listenerPSM: 0x81,
            wantedPSM: 0x81,
            expectsBlinding: wanted.blinded,
            restoredServices: restored,
            matchedByOrder: restored == nil ? 0 : 1,
            poweredOn: true
        )
    }

    /// A server that holds the combined service and never builds the split layout.
    private static func combinedOnly() -> @Sendable () -> GattServingReport {
        var serving = GattServing()
        let wanted = GattServing.Wanted(value: [1], blinded: false)
        for step in serving.serve(wanted, now: 0) {
            if case .add(let service) = step {
                _ = serving.added(service.serial, ok: true, wanted: wanted, now: 0)
            }
        }
        let frozen = serving
        return { report(frozen, wanted) }
    }

    /// A server whose payload service's add is in flight.
    private static func payloadInFlight() -> @Sendable () -> GattServingReport {
        var serving = GattServing(expectsBlinding: true)
        let wanted = GattServing.Wanted(value: [2], blinded: true)
        _ = serving.serve(wanted, now: 0)
        let frozen = serving
        return { report(frozen, wanted, restored: 2) }
    }
}

/// A mesh whose links may blind, its switch off at the start, behind a control surface with an in-memory switch.
private struct AdvertRig {
    let mesh: Mesh
    let radio = AdvertRadio()
    let host: MemoryAdvertHost
    let control: MeshControl

    init(build: Bool = true, host attached: Bool = true, serving: (@Sendable () -> GattServingReport)? = nil) {
        guard let keys = IdentityKeys(signingSeed: fixtureBytes(32, seed: 2), agreementScalar: fixtureBytes(32, seed: 102)) else {
            fatalError("fixed seeds make valid keys")
        }
        let stores = MeshStores.inMemory()
        var links = LinkManager.Configuration()
        links.blindsAdvert = build
        links.blindSwitchOn = false
        mesh = Mesh(
            identity: keys,
            deviceTag: nil,
            stores: stores,
            radio: radio,
            clock: MidSlotClock(),
            random: SystemRandomNumberGenerator(),
            linkConfiguration: links
        )
        host = MemoryAdvertHost(build: build, serving: serving)
        control = MeshControl(
            bundle: keys.bundle,
            mesh: mesh,
            stores: stores,
            clock: MidSlotClock(),
            advertHost: attached ? host : nil,
            advertWait: AdvertWait(looks: 2, every: .milliseconds(1))
        )
    }

    /// Starts the mesh and opens its listener, which brings the advert up.
    func bringUp() async {
        await mesh.start()
        await mesh.process(.state(.on))
        await mesh.process(.listening(psm: 0x81))
    }

    func send(_ line: String) async throws -> [String: Any] {
        let reply = await control.handle(line).line
        return try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }
}

/// A clock that stands 100 s into a blinded advert's slot, far from either edge, so no announcement stands, and whose
/// monotonic time never moves, so a forced rotation always meets the grace after an install.
private final class MidSlotClock: MeshClock {
    func wallMilliseconds() -> Int64 {
        1_790_100_100_000
    }

    func monotonicMilliseconds() -> Int64 {
        1000
    }

    func sleep(untilMonotonic _: Int64) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

/// The switch kept in memory, and a server report a test hands in.
private actor MemoryAdvertHost: AdvertHost {
    nonisolated let build: Bool
    nonisolated let defaultSwitch = false
    private let report: (@Sendable () -> GattServingReport)?
    private var value = AdvertSwitchChange.clear

    init(build: Bool, serving: (@Sendable () -> GattServingReport)?) {
        self.build = build
        report = serving
    }

    func stored() -> AdvertSwitchChange {
        value
    }

    func store(_ change: AdvertSwitchChange) {
        value = change
    }

    func serving() -> GattServingReport? {
        report?()
    }
}

/// An iPhone-shaped radio that records what it is asked to advertise and reports nothing of its own.
private final class AdvertRadio: Radio, Sendable {
    let advertisesServiceData = false
    let dialsGattPeers = true
    let servesDoorbell = true
    let events = AsyncStream<RadioEvent> { _ in
        // The test hands the mesh its events.
    }
    private let adverts = Lock<[AdvertPayload]>([])

    var advertised: [AdvertPayload] { adverts.withLock { $0 } }

    func start() {
        // Nothing to power.
    }

    func stop() {
        // Nothing to power down.
    }

    func advertise(_ payload: AdvertPayload) {
        adverts.withLock { $0.append(payload) }
    }

    func dial(_: RadioAddress, psm _: UInt16) -> ChannelID {
        ChannelID(1)
    }

    func write(_: [UInt8], to _: ChannelID) {
        // Nowhere to write.
    }

    func writeKeyShare(_: [UInt8], sealer _: LinkSealer?, to _: ChannelID) {
        // Nowhere to write.
    }

    func seal(_: ChannelID, with _: LinkSealer) {
        // Nowhere to write.
    }

    func close(_: ChannelID) {
        // Nothing open.
    }
}
