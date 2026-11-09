#if canImport(CoreBluetooth)
    import Foundation
    @testable import KnitBLE
    import KnitCrypto
    import KnitMesh
    import KnitWire
    import Testing

    /// A sealed link over bound stream pairs (the `link-seal` contract, §4 and §5): the KEY_SHARE goes out alone, what is
    /// written behind it waits for the sealer, and then only frames reach the stream, each one write at most.
    @Suite(.timeLimit(.minutes(1))) struct L2CAPLinkSealTests {
        private static func halves() throws -> (sealer: LinkSealer, opener: LinkOpener) {
            let ours = LinkSeal.Ephemeral()
            let theirs = LinkSeal.Ephemeral()
            let sealing = try LinkSeal.derive(ours, peerShare: theirs.keyShare, role: .dialer)
            let opening = try LinkSeal.derive(theirs, peerShare: ours.keyShare, role: .responder)
            return (sealing.sealer, opening.opener)
        }

        @Test func nothingBehindTheKeyShareLeavesUntilTheSealerAndThenOnlyFrames() async throws {
            let (sealer, opener) = try Self.halves()
            let rig = try LinkRig()
            let share = LinkRecord(.keyShare, payload: [UInt8](repeating: 0x5E, count: 32)).encoded ?? []
            let hello = LinkRecord(.hello, payload: [UInt8](repeating: 0x48, count: 40)).encoded ?? []
            let big = LinkRecord(.frame, payload: [UInt8](repeating: 0x07, count: 20_000)).encoded ?? []
            rig.link.writeKeyShare(share, sealer: nil)
            rig.link.write(hello)
            #expect(try await rig.far.read(share.count) == share, "the KEY_SHARE alone")
            rig.link.seal(with: sealer)
            rig.link.write(big)
            let frames = 1 + (big.count + 8170) / 8171
            let expected = hello.count + big.count + frames * LinkSealer.overheadBytes
            var outer = LinkRecordReader()
            outer.append(try await rig.far.read(expected))
            var inner = LinkRecordReader()
            while let record = try outer.next() {
                #expect(record.tag == .sealed)
                inner.append(try #require(opener.open(sealedPayload: record.payload)))
            }
            #expect(try inner.next()?.encoded == hello)
            #expect(try inner.next()?.encoded == big)
            #expect(rig.log.all.compactMap(LinkRig.written).allSatisfy { $0 <= 8192 }, "a frame is one write at most")
        }
    }
#endif
