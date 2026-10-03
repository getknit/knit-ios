import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitWire
import Testing

/// The peer's own photo: set by a control line, kept across a restart, and cleared (ADR 2026-10.nh55).
@Suite(.timeLimit(.minutes(1))) struct PeerAvatarTests {
    /// The peer's blobs live in memory, so its own photo is kept beside `profile.json`, which still names it after a
    /// restart (ADR 2026-10.nh55).
    @Test func ourPhotoIsKeptAcrossARestartAndGoesWhenCleared() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "knit-peer-\(ProcessInfo.processInfo.globallyUniqueString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profilePath = directory.appending(path: "profile.json").path(percentEncoded: false)
        let avatarPath = directory.appending(path: "avatar.jpg").path(percentEncoded: false)
        let jpeg = Array("a photo of the peer".utf8)
        let first = PeerRig(ownProfile: FileOwnProfileStore(path: profilePath), avatarPath: avatarPath)
        await first.node.start(name: nil)
        let set = try await first.send(#"{"cmd":"avatar","jpeg":"\#(Base64.encode(jpeg))"}"#)
        #expect(set["avatarHash"] as? String == BlobHash(of: jpeg).string)
        #expect(FileManager.default.contents(atPath: avatarPath) == Data(jpeg))
        await first.node.stop()
        let second = PeerRig(ownProfile: FileOwnProfileStore(path: profilePath), avatarPath: avatarPath)
        await second.node.start(name: nil)
        #expect(second.stores.blobs.bytes(of: BlobHash(of: jpeg)) == jpeg, "served after a restart")
        let status = try await second.send(#"{"cmd":"status"}"#)
        #expect(status["avatarHash"] as? String == BlobHash(of: jpeg).string)
        let cleared = try await second.send(#"{"cmd":"avatar","clear":true}"#)
        #expect(cleared["avatarHash"] is NSNull)
        #expect(!FileManager.default.fileExists(atPath: avatarPath))
    }

    @Test func aPhotoFromAFileIsSetAndOneThatCannotBeReadIsRefused() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "knit-peer-\(ProcessInfo.processInfo.globallyUniqueString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "photo.jpg").path(percentEncoded: false)
        let jpeg = Array("a photo on disk".utf8)
        _ = FileManager.default.createFile(atPath: file, contents: Data(jpeg))
        let rig = PeerRig()
        await rig.node.start(name: nil)
        let set = try await rig.send(#"{"cmd":"avatar","path":"\#(file)"}"#)
        #expect(set["avatarHash"] as? String == BlobHash(of: jpeg).string)
        let missing = try await rig.send(#"{"cmd":"avatar","path":"\#(file).gone"}"#)
        #expect(missing["ok"] as? Bool == false)
    }

    /// PeerRadio reports no writes, so the link manager feeds it a file on the pace alone, through `Radio`'s defaults.
    /// The clock here stands still, so the photo is empty: a header and an END, both out the moment the link comes up.
    /// The next radio event hands the finished push to the engine, which then pushes it no more.
    @Test func ourPhotoGoesToAPeerThatLinksOnceItIsOutWhole() async throws {
        let rig = PeerRig()
        await rig.node.start(name: nil)
        _ = try await rig.send(#"{"cmd":"avatar","jpeg":""}"#)
        try await rig.link()
        var tags = rig.radio.records(on: PeerRig.channel).map(\.tag)
        let header = try #require(tags.firstIndex(of: .fileHeader))
        #expect(tags[header...].contains(.fileEnd) && !tags.contains(.fileChunk))
        let status = try await rig.send(#"{"cmd":"status"}"#)
        #expect((status["files"] as? [String: Int])?["sent"] == 1)
        rig.farEngine.start()
        rig.farEngine.linkUp(Neighbor(nodeId: rig.keys.nodeId, capabilities: .local))
        rig.deliverFromFar()
        _ = try #require(await rig.lines.first { $0["event"] as? String == "profile" })
        rig.radio.emit(.closed(PeerRig.channel))
        _ = try #require(await rig.lines.first { $0["event"] as? String == "link" && $0["up"] as? Bool == false })
        try await rig.link(count: 2)
        tags = rig.radio.records(on: PeerRig.channel).map(\.tag)
        #expect(tags.filter { $0 == .fileHeader }.count == 1, "pushed once per neighbour per photo")
    }

    @Test func aPhotoAFarPeerPushesIsShown() async throws {
        let rig = PeerRig()
        await rig.node.start(name: nil)
        try await rig.link()
        let jpeg = Array("the far peer's photo".utf8)
        rig.farEngine.setAvatar(jpeg)
        rig.deliverFromFar()
        rig.radio.emit(.received(PeerRig.channel, rig.fileRecords(.avatar, jpeg)))
        let shown = try #require(
            await rig.lines.first { $0["event"] as? String == "profile" && $0["avatarHash"] as? String == BlobHash(of: jpeg).string })
        #expect(shown["peer"] as? String == rig.far.nodeId.string)
    }
}
