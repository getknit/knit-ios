import Foundation
import Testing

@testable import KnitAppCore

/// The App Group's share inbox: what the share sheet leaves, what the app reads, claims, holds and sweeps, and the
/// bounds that keep it small (ADR 2026-10.z7a8).
@Suite struct ShareInboxTests {
    /// An inbox in a folder of its own, removed when the test ends.
    final class Scratch {
        let root: URL
        let inbox: ShareInbox

        init() {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
            inbox = ShareInbox(container: root)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        /// A picture of `bytes` outside the inbox, as the sheet's provider hands one over.
        func picture(_ bytes: Data = Data("a picked photo".utf8), named name: String = "IMG_0001.HEIC") throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try bytes.write(to: url)
            return url
        }
    }

    @Test func aShareRoundTripsWithItsPicture() throws {
        let scratch = Scratch()
        let manifest = ShareManifest.message("Look at this", to: "nearby", hasPicture: false, at: 1000)
        try scratch.inbox.submit(manifest, picture: try scratch.picture(), id: "A1")
        let pending = scratch.inbox.pending()
        try #require(pending.count == 1)
        #expect(pending[0].id == "A1")
        #expect(
            pending[0].manifest == ShareManifest.message("Look at this", to: "nearby", hasPicture: true, at: 1000), "the picture is noted")
        #expect(scratch.inbox.picture(of: pending[0]) == Data("a picked photo".utf8))
        #expect(scratch.inbox.pendingCount() == 1)
    }

    @Test func sharesComeOutOldestFirst() throws {
        let scratch = Scratch()
        try scratch.inbox.submit(.message("second", to: "nearby", hasPicture: false, at: 2000), picture: nil, id: "B")
        try scratch.inbox.submit(.message("first", to: "nearby", hasPicture: false, at: 1000), picture: nil, id: "C")
        try scratch.inbox.submit(.message("tie", to: "nearby", hasPicture: false, at: 2000), picture: nil, id: "A")
        #expect(scratch.inbox.pending().map(\.manifest.text) == ["first", "tie", "second"], "a tie goes by id")
    }

    /// The app never reads a share the sheet is still writing, and a folder with no readable manifest, or one of
    /// another version, goes.
    @Test func halfWrittenSharesAndStrangeManifestsAreNotRead() throws {
        let scratch = Scratch()
        let manager = FileManager.default
        let writing = scratch.inbox.folder(.incoming, "W")
        try manager.createDirectory(at: writing, withIntermediateDirectories: true)
        try ShareInbox.encode(.message("not yet", to: "nearby", hasPicture: false, at: 1)).write(
            to: writing.appendingPathComponent(ShareInbox.manifestName))

        let empty = scratch.inbox.folder(.inbox, "E")
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)
        var future = ShareManifest.message("from a later build", to: "nearby", hasPicture: false, at: 1)
        future.version = ShareManifest.currentVersion + 1
        let later = scratch.inbox.folder(.inbox, "F")
        try manager.createDirectory(at: later, withIntermediateDirectories: true)
        try ShareInbox.encode(future).write(to: later.appendingPathComponent(ShareInbox.manifestName))

        #expect(scratch.inbox.pending().isEmpty)
        #expect(!manager.fileExists(atPath: empty.path) && !manager.fileExists(atPath: later.path), "both dropped")
        #expect(manager.fileExists(atPath: writing.path), "a share being written is left alone")
        scratch.inbox.sweep(now: 1 + ShareInbox.incomingLifetime)
        #expect(manager.fileExists(atPath: writing.path), "an hour is not yet past")
        scratch.inbox.sweep(now: 2 + ShareInbox.incomingLifetime)
        #expect(!manager.fileExists(atPath: writing.path), "past an hour it was abandoned")
    }

    /// One sheet writes at a time, so a share the last one left half written goes at the next write.
    @Test func theNextShareClearsOneLeftHalfWritten() throws {
        let scratch = Scratch()
        let abandoned = scratch.inbox.folder(.incoming, "X")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try scratch.inbox.submit(.message("new", to: "nearby", hasPicture: false, at: 5), picture: nil, id: "N")
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(scratch.inbox.pending().map(\.id) == ["N"])
    }

    @Test func aNinthShareIsRefused() throws {
        let scratch = Scratch()
        for index in 0..<ShareInbox.maxPending {
            try scratch.inbox.submit(.message("\(index)", to: "nearby", hasPicture: false, at: Int64(index)), picture: nil, id: "S\(index)")
        }
        #expect(throws: ShareInbox.SubmitError.full) {
            try scratch.inbox.submit(.message("one more", to: "nearby", hasPicture: false, at: 99), picture: nil, id: "S99")
        }
    }

    @Test func aPictureTooLargeOrAnIdThatClimbsOutIsRefused() throws {
        let scratch = Scratch()
        let huge = try scratch.picture(Data(count: ShareInbox.maxPictureBytes + 1), named: "huge.jpg")
        #expect(throws: ShareInbox.SubmitError.pictureTooLarge) {
            try scratch.inbox.submit(.message("", to: "nearby", hasPicture: true, at: 1), picture: huge, id: "H")
        }
        #expect(throws: ShareInbox.SubmitError.unwritable) {
            try scratch.inbox.submit(.message("", to: "nearby", hasPicture: false, at: 1), picture: nil, id: "../escape")
        }
        #expect(scratch.inbox.pending().isEmpty)
    }

    /// A claimed share leaves the inbox before it is sent, so a second claim gets nothing and a crash before
    /// ``ShareInbox/finish(_:)`` never sends it again: the next sweep drops it.
    @Test func aClaimedShareIsSentAtMostOnce() throws {
        let scratch = Scratch()
        try scratch.inbox.submit(.message("once", to: "nearby", hasPicture: false, at: 1), picture: try scratch.picture(), id: "O")
        let item = try #require(scratch.inbox.pending().first)
        let claimed = try #require(scratch.inbox.claim(item))
        #expect(scratch.inbox.picture(of: claimed) == Data("a picked photo".utf8), "the picture moves with it")
        #expect(scratch.inbox.claim(item) == nil)
        #expect(scratch.inbox.pending().isEmpty)
        scratch.inbox.sweep(now: 2)
        #expect(!FileManager.default.fileExists(atPath: scratch.inbox.folder(.claimed, "O").path))
    }

    @Test func aHeldShareWaitsForItsThreadThenGoes() throws {
        let scratch = Scratch()
        try scratch.inbox.submit(.message("for Sam", to: "sam", hasPicture: false, at: 1), picture: nil, id: "M")
        let waiting = try #require(scratch.inbox.pending().first)
        let claimed = try #require(scratch.inbox.claim(waiting))
        scratch.inbox.hold(claimed, because: .words)
        #expect(scratch.inbox.held(in: "priya").isEmpty)
        let held = try #require(scratch.inbox.held(in: "sam").first)
        #expect(held.manifest.refusal == .words && held.manifest.text == "for Sam")
        scratch.inbox.release(held)
        #expect(scratch.inbox.held(in: "sam").isEmpty)
    }

    @Test func heldSharesAreBoundedAndExpire() throws {
        let scratch = Scratch()
        for index in 0...ShareInbox.maxHeld {
            try scratch.inbox.submit(.message("\(index)", to: "sam", hasPicture: false, at: Int64(index)), picture: nil, id: "H\(index)")
            let waiting = try #require(scratch.inbox.pending().first)
            let claimed = try #require(scratch.inbox.claim(waiting))
            scratch.inbox.hold(claimed, because: .closed)
        }
        let held = scratch.inbox.held(in: "sam")
        #expect(held.count == ShareInbox.maxHeld)
        #expect(held.first?.manifest.text == "1", "the oldest went")
        scratch.inbox.sweep(now: 4 + ShareInbox.heldLifetime)
        #expect(scratch.inbox.held(in: "sam").map(\.manifest.text) == ["4", "5", "6", "7", "8"], "a week on, the older ones went")
    }

    @Test func theSnapshotRoundTripsAndIsRemovedOnReset() {
        let scratch = Scratch()
        #expect(ChatSnapshot.read(from: scratch.inbox) == nil, "nothing until the app writes one")
        var snapshot = ChatSnapshot(ChatListState(rows: [], requestCount: 0, showsGettingStarted: true))
        snapshot.rows = [
            .init(id: "nearby", title: "Nearby", kind: .room, faceKey: "", initial: ""),
            .init(id: "sam", title: "Sam", kind: .direct, faceKey: "sam", initial: "S"),
        ]
        snapshot.write(to: scratch.inbox)
        #expect(ChatSnapshot.read(from: scratch.inbox) == snapshot)
        #expect(
            ChatSnapshot.read(from: scratch.inbox)?.rows[1].face == Face(kind: .person, key: "sam", initial: "S", photo: nil, members: []))
        ChatSnapshot.remove(from: scratch.inbox)
        #expect(ChatSnapshot.read(from: scratch.inbox) == nil)
    }
}
