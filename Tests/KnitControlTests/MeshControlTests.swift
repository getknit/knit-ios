import Foundation
import KnitControl
import KnitCrypto
import KnitMesh
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

/// The control surface on its own: what the app's bridge relies on beyond what `PeerNodeTests` covers through the
/// peer, namely changing the node through another front, `stop` and `start`, and the event lines.
@Suite(.timeLimit(.minutes(1))) struct MeshControlTests {
    @Test func readyNamesTheNodeAndItsDetails() throws {
        let rig = ControlRig()
        let ready = try rig.object(rig.control.ready)
        #expect(ready["event"] as? String == "ready")
        #expect(ready["nodeId"] as? String == rig.keys.nodeId.string)
        #expect(ready["host"] as? String == "test")
    }

    @Test func changesGoThroughTheActionsGiven() async throws {
        let actions = RecordingActions(me: fixtureNodeId(1))
        let rig = ControlRig(actions: actions)
        let peer = fixtureNodeId(4)
        let room = try await rig.send(#"{"cmd":"room","text":"hi"}"#)
        #expect(room["id"] as? String == "room-hi")
        let direct = try await rig.send(#"{"cmd":"dm","to":"\#(peer)","text":"psst"}"#)
        #expect(direct["id"] as? String == "dm-psst")
        #expect(direct["pendingKey"] as? Bool == false)
        _ = try await rig.send(#"{"cmd":"accept","conv":"\#(peer)"}"#)
        _ = try await rig.send(#"{"cmd":"name","name":"Near"}"#)
        _ = try await rig.send(#"{"cmd":"avatar","jpeg":"AQID"}"#)
        _ = try await rig.send(#"{"cmd":"avatar","clear":true}"#)
        _ = try await rig.send(#"{"cmd":"stop"}"#)
        _ = try await rig.send(#"{"cmd":"start"}"#)
        #expect(
            actions.calls == [
                "room hi", "dm \(peer) psst", "accept \(peer)", "profile Near  false", "avatar 3 bytes", "avatar cleared", "stop", "start",
            ],
            "the actions heard every change, in order"
        )
        #expect(rig.stores.messages.messages(in: Conversations.nearby).isEmpty, "the mesh itself posted nothing")
    }

    @Test func whatTheActionsRefuseIsRefused() async throws {
        let rig = ControlRig(actions: RecordingActions(me: fixtureNodeId(1), refuses: true))
        let room = try await rig.send(#"{"cmd":"room","text":"hi"}"#)
        #expect(room["ok"] as? Bool == false)
        let direct = try await rig.send(#"{"cmd":"dm","to":"\#(fixtureNodeId(4))","text":"psst"}"#)
        #expect(direct["ok"] as? Bool == false)
        let lines = [
            #"{"cmd":"group-create","members":[]}"#,
            #"{"cmd":"group-send","conv":"g-1","text":"hi"}"#,
            #"{"cmd":"group-rename","conv":"g-1","name":"x"}"#,
            #"{"cmd":"group-leave","conv":"g-1"}"#,
        ]
        for line in lines {
            let reply = try await rig.send(line)
            #expect(reply["ok"] as? Bool == false, "\(line)")
            #expect((reply["error"] as? String)?.isEmpty == false)
        }
    }

    @Test func groupCommandsGoThroughTheActionsGiven() async throws {
        let actions = RecordingActions(me: fixtureNodeId(1))
        let rig = ControlRig(actions: actions)
        let peer = fixtureNodeId(4)
        let made = try await rig.send(#"{"cmd":"group-create","members":["\#(peer)"]}"#)
        #expect(made["id"] as? String == "g-1" && made["reply"] as? String == "group-create")
        let sent = try await rig.send(#"{"cmd":"group-send","conv":"g-1","text":"hi"}"#)
        #expect(sent["id"] as? String == "group-hi" && sent["pendingKey"] as? Bool == false)
        let renamed = try await rig.send(#"{"cmd":"group-rename","conv":"g-1","name":"Pair"}"#)
        #expect(renamed["name"] as? String == "Pair")
        let left = try await rig.send(#"{"cmd":"group-leave","conv":"g-1"}"#)
        #expect(left["conv"] as? String == "g-1")
        #expect(actions.calls == ["group-create \(peer)", "group-send g-1 hi", "group-rename g-1 Pair", "group-leave g-1"])
    }

    @Test func groupsListsEveryGroupHeldAndStatusCountsThem() async throws {
        let rig = ControlRig()
        let me = rig.keys.nodeId.string
        rig.stores.groups.save(GroupRecord(id: "g-2", name: "Two", createdBy: me, createdAt: 1, roster: [GroupMember(nodeId: me)]))
        rig.stores.groups.save(GroupRecord(id: "g-1", createdBy: me, createdAt: 1, hasLeft: true, roster: [GroupMember(nodeId: me)]))
        let listed = try #require(try await rig.send(#"{"cmd":"groups"}"#)["groups"] as? [[String: Any]])
        #expect(listed.map { $0["id"] as? String } == ["g-1", "g-2"])
        #expect(listed.map { $0["left"] as? Bool } == [true, false])
        #expect(try await rig.send(#"{"cmd":"status"}"#)["groups"] as? Int == 2)
    }

    @Test func stopAndStartSayWhetherTheMeshRuns() async throws {
        let rig = ControlRig()
        let started = try await rig.send(#"{"cmd":"start"}"#)
        #expect(started["running"] as? Bool == true)
        #expect(try await rig.send(#"{"cmd":"status"}"#)["running"] as? Bool == true)
        let stopped = try await rig.send(#"{"cmd":"stop","tag":"s"}"#)
        #expect(stopped["reply"] as? String == "stop")
        #expect(stopped["running"] as? Bool == false)
        #expect(stopped["tag"] as? String == "s")
    }

    @Test func quitIsAnsweredAndMarked() async throws {
        let rig = ControlRig()
        let reply = await rig.control.handle(#"{"cmd":"quit"}"#)
        #expect(reply.quits)
        #expect(try rig.object(reply.line)["reply"] as? String == "quit")
        #expect(await rig.control.handle(#"{"cmd":"status"}"#).quits == false)
    }

    @Test func statusCarriesTheDetails() async throws {
        let rig = ControlRig()
        let status = try await rig.send(#"{"cmd":"status"}"#)
        #expect(status["host"] as? String == "test")
        #expect(status["nodeId"] as? String == rig.keys.nodeId.string)
        #expect(status["memoryKb"] == nil, "a host that samples nothing adds nothing")
        #expect(status["seeking"] as? Bool == false, "a peer at the front never seeks")
        #expect(status["seekWakes"] as? Int == 0)
        #expect(status["seekSpells"] as? Int == 0)
    }

    @Test func statusSaysWhenTheLinksSeek() async throws {
        // A radio that cannot seek, like this one, still has the link manager's word for it.
        let rig = ControlRig()
        await rig.mesh.start()
        await rig.mesh.setInBackground(true)
        let status = try await rig.send(#"{"cmd":"status"}"#)
        #expect(status["seeking"] as? Bool == true, "in the background with no link")
        #expect(status["seekSpells"] as? Int == 1)
    }

    @Test func statusReadsTheSampleEachTime() async throws {
        let reads = Lock(0)
        let rig = ControlRig {
            let count = reads.withLock { reads in
                reads += 1
                return reads
            }
            // A sampled field never replaces one the mesh reports.
            return ["memoryKb": .int(Int64(count * 100)), "links": .int(99)]
        }
        #expect(try await rig.send(#"{"cmd":"status"}"#)["memoryKb"] as? Int == 100)
        let again = try await rig.send(#"{"cmd":"status"}"#)
        #expect(again["memoryKb"] as? Int == 200)
        #expect(again["links"] as? Int == 0)
        #expect(try rig.object(rig.control.ready)["memoryKb"] == nil, "ready carries the details alone")
    }

    @Test func linkEventsNameOnlyThePeersThatChanged() async throws {
        let rig = ControlRig()
        let first = Neighbor(nodeId: fixtureNodeId(4))
        let second = Neighbor(nodeId: fixtureNodeId(5))
        let up = try await rig.report(.neighborsChanged([first]))
        #expect(up.map { $0["peer"] as? String } == [first.nodeId.string])
        #expect(up.first?["up"] as? Bool == true)
        let changed = try await rig.report(.neighborsChanged([second]))
        #expect(changed.map { $0["peer"] as? String } == [second.nodeId.string, first.nodeId.string])
        #expect(changed.map { $0["up"] as? Bool } == [true, false])
        #expect(try await rig.report(.neighborsChanged([second])).isEmpty, "nothing changed")
    }

    @Test func everyOtherEventIsALine() async throws {
        let rig = ControlRig()
        let record = MessageRecord(
            id: "m1", senderId: fixtureNodeId(4), recipientId: nil, conversationId: Conversations.nearby, body: "hi", sentAt: 5
        )
        let message = try #require(try await rig.report(.received(record, isRequest: false)).first)
        #expect(message["event"] as? String == "message")
        #expect(message["body"] as? String == "hi")
        #expect(message["request"] as? Bool == false)
        #expect(try await rig.report(.delivered(messageId: "m1")).first?["event"] as? String == "delivered")
        #expect(try await rig.report(.sent(messageId: "m1")).first?["event"] as? String == "sent")
        #expect(try await rig.report(.radioChanged(.off)).first?["state"] as? String == "off")
        #expect(try await rig.report(.peerUpdated(fixtureNodeId(4))).isEmpty, "a peer never pinned has no profile to show")
    }

    @Test func aGroupChangeNamesTheGroupAsHeld() async throws {
        let rig = ControlRig()
        let member = fixtureNodeId(4).string
        let group = GroupRecord(
            id: "g-1",
            name: "Hikers",
            createdBy: member,
            createdAt: 1,
            roster: [GroupMember(nodeId: member), GroupMember(nodeId: "gone", departed: true, leftAt: 2)]
        )
        rig.stores.groups.save(group)
        let line = try #require(try await rig.report(.groupChanged("g-1")).first)
        #expect(line["event"] as? String == "group")
        #expect(line["name"] as? String == "Hikers")
        #expect(line["members"] as? [String] == [member])
        #expect(line["departed"] as? [String] == ["gone"])
        #expect(line["left"] as? Bool == false)
        #expect(try await rig.report(.groupChanged("g-unknown")).isEmpty, "a group not held has nothing to show")
    }
}

/// A control surface over a real ``Mesh`` on a radio that goes nowhere.
private struct ControlRig {
    let keys: IdentityKeys
    let stores = MeshStores.inMemory()
    let mesh: Mesh
    let control: MeshControl

    init(actions: (any ControlActions)? = nil, sample: (@Sendable () -> [String: JSONValue])? = nil) {
        guard let made = IdentityKeys(signingSeed: fixtureBytes(32, seed: 1), agreementScalar: fixtureBytes(32, seed: 101)) else {
            fatalError("fixed seeds make valid keys")
        }
        keys = made
        let clock = StillClock()
        mesh = Mesh(
            identity: made,
            deviceTag: nil,
            stores: stores,
            radio: QuietRadio(),
            clock: clock,
            random: SystemRandomNumberGenerator(),
            log: SilentLog()
        )
        control = MeshControl(
            bundle: made.bundle,
            mesh: mesh,
            actions: actions,
            stores: stores,
            clock: clock,
            details: ["host": "test"],
            sample: sample
        )
    }

    func object(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    func send(_ line: String) async throws -> [String: Any] {
        try object(await control.handle(line).line)
    }

    func report(_ event: MeshEvent) async throws -> [[String: Any]] {
        try await control.report(event).map(object)
    }
}

/// Actions that record what they were asked, as the app's session would take them.
private final class RecordingActions: ControlActions {
    private let me: NodeId
    private let refuses: Bool
    private let recorded = Lock<[String]>([])

    init(me: NodeId, refuses: Bool = false) {
        self.me = me
        self.refuses = refuses
    }

    var calls: [String] { recorded.withLock { $0 } }

    func start() {
        record("start")
    }

    func stop() {
        record("stop")
    }

    func postToRoom(_ text: String) -> MessageRecord? {
        record("room \(text)")
        return refuses
            ? nil
            : MessageRecord(id: "room-\(text)", senderId: me, recipientId: nil, conversationId: Conversations.nearby, body: text, sentAt: 1)
    }

    func sendDirectMessage(_ text: String, to recipient: NodeId) -> MessageRecord? {
        record("dm \(recipient) \(text)")
        return refuses
            ? nil
            : MessageRecord(id: "dm-\(text)", senderId: me, recipientId: recipient, conversationId: recipient.string, body: text, sentAt: 1)
    }

    func accept(_ conversationId: String) {
        record("accept \(conversationId)")
    }

    func updateProfile(name: String, status: String, openToChat: Bool) {
        record("profile \(name) \(status) \(openToChat)")
    }

    func setAvatar(_ jpeg: [UInt8]?) {
        record("avatar \(jpeg.map { "\($0.count) bytes" } ?? "cleared")")
    }

    func createGroup(with others: [NodeId]) -> GroupRecord? {
        record("group-create \(others.map(\.string).joined(separator: ","))")
        return refuses ? nil : group(named: "")
    }

    func sendGroupMessage(_ text: String, to groupId: String) -> MessageRecord? {
        record("group-send \(groupId) \(text)")
        return refuses
            ? nil : MessageRecord(id: "group-\(text)", senderId: me, recipientId: nil, conversationId: groupId, body: text, sentAt: 1)
    }

    func renameGroup(_ groupId: String, to name: String) -> GroupRecord? {
        record("group-rename \(groupId) \(name)")
        return refuses ? nil : group(named: name)
    }

    func leaveGroup(_ groupId: String) -> Bool {
        record("group-leave \(groupId)")
        return !refuses
    }

    private func group(named name: String) -> GroupRecord {
        GroupRecord(id: "g-1", name: name, createdBy: me.string, createdAt: 1, roster: [GroupMember(nodeId: me.string)])
    }

    private func record(_ call: String) {
        recorded.withLock { $0.append(call) }
    }
}

/// Clocks that stand still; a sleeper waits until it is cancelled.
private final class StillClock: MeshClock {
    func wallMilliseconds() -> Int64 {
        1_790_300_000_000
    }

    func monotonicMilliseconds() -> Int64 {
        1000
    }

    func sleep(untilMonotonic _: Int64) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

/// A radio that goes nowhere and reports nothing.
private final class QuietRadio: Radio {
    let advertisesServiceData = true
    let dialsGattPeers = false
    let servesDoorbell = false
    let events = AsyncStream<RadioEvent> { _ in
        // Nothing to report.
    }

    func start() {
        // Nothing to power.
    }

    func stop() {
        // Nothing to power down.
    }

    func advertise(_: AdvertPayload) {
        // Nobody listens.
    }

    func dial(_: RadioAddress, psm _: UInt16) -> ChannelID {
        ChannelID(1)
    }

    func write(_: [UInt8], to _: ChannelID) {
        // Nowhere to write.
    }

    func close(_: ChannelID) {
        // Nothing open.
    }
}
