import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The ratchet's store over every store kind: knit-next's `RatchetRepositoryTest`, case by case
/// (`app/src/test/java/app/getknit/knit/data/RatchetRepositoryTest.kt`, at `ac491f4c`), for row fidelity, `applyOpen`'s
/// delta with the skipped-key lifecycle and the replacement purge, and the retention sweep that enforces the
/// forward-secrecy window. Then what this port adds: an open's writes go with a unit that fails, and both stores evict the
/// same keys at the cap (ADR 2026-10.5sk9).
@Suite struct RatchetStoreTests {
    private static let kinds = RepositoryKind.allCases
    private static let tag: Int64 = 0x7EA2_D2A5
    private static let oldTag: Int64 = -0x1051_E503
    private static let now: Int64 = 1_700_000_000_000
    /// Just past the 48 h retention windows.
    private static let stale: Int64 = 49 * 60 * 60_000

    private let peer = fixtureNodeId(1)

    @Test(arguments: kinds)
    func sessionRoundTripsEveryField(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        var full = session()
        full.prevRoot = bytes(9)
        full.prevRootWeAreInitiator = true
        full.prevRootExpiresAt = Self.now + 1
        full.initEphPub = bytes(4)
        full.initPkid = 7
        full.peerInitEphPub = bytes(5)
        full.peerBasePub = bytes(6)
        full.peerBaseEpoch = 3
        full.sendCount = 42
        full.sendEpochBaseEpoch = 2
        full.highestPeAcked = 2
        full.lastResetSentAt = Self.now - 5
        ratchet.upsertSession(full)
        #expect(ratchet.session(peer) == full)
        // Every flag the other way and every optional absent, so no column reads another's value or a default. Kotlin's
        // `sendEpochExport` is the spool's, and is not kept (ADR 2026-10.5sk9).
        let other = fixtureNodeId(2)
        let bare = RatchetSessionRecord(
            peerId: other, confirmed: false, weAreInitiator: false, root: bytes(10), establishedAt: Self.now - 9)
        ratchet.upsertSession(bare)
        #expect(ratchet.session(other) == bare)
        #expect(ratchet.session(peer) == full, "one peer's row is not another's")
    }

    @Test(arguments: kinds)
    func applyOpenPersistsChainAdvanceSkippedKeysAndConsumption(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        let banked = [skippedKey(index: 0, fill: 10), skippedKey(index: 1, fill: 11)]
        ratchet.applyOpen(
            RatchetOpenDelta(session: session(), recvEpoch: recvEpoch(next: 3), skippedInserts: banked), from: peer, se: 1, n: 2)
        let stored = ratchet.recvEpochs(peer, epoch: 1)
        #expect(stored.map(\.next) == [3])
        #expect(stored.map(\.rootTag) == [Self.tag])
        #expect(ratchet.skippedKeys(peer, epoch: 1, index: 0).map(\.messageKey) == [bytes(10)])
        #expect(ratchet.skippedKeys(peer, epoch: 1, index: 0).map(\.rootTag) == [Self.tag])

        // Consuming skipped key (1, 0) deletes exactly that row.
        ratchet.applyOpen(
            RatchetOpenDelta(session: session(), recvEpoch: recvEpoch(next: 3), consumedSkippedTag: Self.tag), from: peer, se: 1, n: 0)
        #expect(ratchet.skippedKeys(peer, epoch: 1, index: 0).isEmpty)
        #expect(ratchet.skippedKeys(peer, epoch: 1, index: 1).count == 1)
    }

    /// #135 (knit-next ADR 2026-10.gcrd): a reset restarts the peer's numbering, so two roots' chains can share an epoch
    /// number and a skipped index. Both rows are kept side by side, each lookup returns both, and consuming one root's key
    /// leaves the other root's alone.
    @Test(arguments: kinds)
    func twoRootsKeepTheirOwnChainAndKeysForOneEpochNumber(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        ratchet.applyOpen(
            RatchetOpenDelta(
                session: session(),
                recvEpoch: recvEpoch(next: 4, tag: Self.oldTag),
                skippedInserts: [skippedKey(index: 0, fill: 20, tag: Self.oldTag)]
            ),
            from: peer,
            se: 1,
            n: 3
        )
        ratchet.applyOpen(
            RatchetOpenDelta(session: session(), recvEpoch: recvEpoch(next: 2), skippedInserts: [skippedKey(index: 0, fill: 10)]),
            from: peer,
            se: 1,
            n: 1
        )
        let chains = ratchet.recvEpochs(peer, epoch: 1)
        #expect(Dictionary(uniqueKeysWithValues: chains.map { ($0.rootTag, $0.next) }) == [Self.oldTag: 4, Self.tag: 2])
        #expect(Set(ratchet.skippedKeys(peer, epoch: 1, index: 0).map(\.rootTag)) == [Self.oldTag, Self.tag])

        ratchet.applyOpen(
            RatchetOpenDelta(session: session(), recvEpoch: recvEpoch(next: 2), consumedSkippedTag: Self.tag), from: peer, se: 1, n: 0)
        let left = ratchet.skippedKeys(peer, epoch: 1, index: 0)
        #expect(left.map(\.rootTag) == [Self.oldTag])
        #expect(left.map(\.messageKey) == [bytes(20)])
    }

    @Test(arguments: kinds)
    func aReplacementPurgeDropsRecvStateButKeepsLocalEpochs(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        ratchet.commitSend(session(), newLocalEpoch: localEpoch(1, createdAt: Self.now))
        ratchet.applyOpen(
            RatchetOpenDelta(
                session: session(),
                recvEpoch: recvEpoch(next: 1, tag: Self.oldTag),
                skippedInserts: [skippedKey(index: 5, fill: 0, tag: Self.oldTag)]
            ),
            from: peer,
            se: 1,
            n: 0
        )
        ratchet.applyOpen(
            RatchetOpenDelta(session: session(), recvEpoch: recvEpoch(next: 1), purgePeerRecvState: true), from: peer, se: 1, n: 0)
        // The purge dropped the old skipped key; the new-era chain, written after the purge, and our own epochs survive.
        #expect(ratchet.skippedKeys(peer, epoch: 1, index: 5).isEmpty)
        #expect(ratchet.recvEpochs(peer, epoch: 1).map(\.rootTag) == [Self.tag])
        #expect(ratchet.localEpochPrivateKey(peer, epoch: 1) != nil)
    }

    @Test(arguments: kinds)
    func sweepEnforcesTtlsAndTheSkippedKeyCap(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        ratchet.applyOpen(
            RatchetOpenDelta(
                session: session(),
                recvEpoch: recvEpoch(next: 1, lastUsedAt: Self.now - Self.stale),
                skippedInserts: [skippedKey(index: 0, fill: 0, createdAt: Self.now - Self.stale), skippedKey(index: 1, fill: 0)]
            ),
            from: peer,
            se: 1,
            n: 2
        )

        ratchet.sweep(now: Self.now)

        #expect(ratchet.skippedKeys(peer, epoch: 1, index: 0).isEmpty, "past the 48 h TTL")
        #expect(ratchet.skippedKeys(peer, epoch: 1, index: 1).count == 1, "fresh")
        #expect(ratchet.recvEpochs(peer, epoch: 1).isEmpty, "past the 48 h TTL")
        #expect(ratchet.session(peer) == session(), "sessions are never swept")
    }

    /// The global cap's eviction names a row by its whole key, root tag included: two roots' keys at one index both go.
    /// Kotlin calls the eviction directly; here the sweep reaches it with enough fresh keys to put the store two over.
    @Test(arguments: kinds)
    func theSkippedKeyCapEvictsByTheWholeKey(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        let filler = (0..<RatchetRetention.maxSkippedKeys - 1).map { skippedKey(index: $0 % 200, fill: 0, epoch: 2 + $0 / 200) }
        let oldest = [
            skippedKey(index: 0, fill: 0, tag: Self.oldTag, createdAt: Self.now - 2),
            skippedKey(index: 0, fill: 0, createdAt: Self.now - 1),
            skippedKey(index: 1, fill: 0),
        ]
        ratchet.applyOpen(RatchetOpenDelta(session: session(), recvEpoch: nil, skippedInserts: oldest + filler), from: peer, se: 1, n: 2)

        ratchet.sweep(now: Self.now)

        #expect(ratchet.skippedKeys(peer, epoch: 1, index: 0).isEmpty)
        #expect(ratchet.skippedKeys(peer, epoch: 1, index: 1).count == 1)
        #expect(ratchet.records(of: peer).skippedKeys.count == RatchetRetention.maxSkippedKeys)
    }

    @Test(arguments: kinds)
    func sweepRetiresAckedLocalEpochsButKeepsTheNewestThree(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        ratchet.upsertSession(session(sendEpoch: 6, highestPeAcked: 6))
        for epoch in 1...6 {
            ratchet.commitSend(session(sendEpoch: 6, highestPeAcked: 6), newLocalEpoch: localEpoch(epoch, createdAt: Self.now - Self.stale))
        }

        ratchet.sweep(now: Self.now)

        // Epochs 1 to 3 are superseded, acked and past 48 h, so they retire: the window closing. The newest three stay.
        #expect(ratchet.localEpochPrivateKey(peer, epoch: 1) == nil)
        #expect(ratchet.localEpochPrivateKey(peer, epoch: 3) == nil)
        #expect(ratchet.localEpochPrivateKey(peer, epoch: 4) != nil)
        #expect(ratchet.localEpochPrivateKey(peer, epoch: 6) != nil)
    }

    @Test(arguments: kinds)
    func aNumberingRestartDoesNotLetDeadEraRowsStarveTheLiveEra(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        // A long-lived session banked 16 high-numbered epochs, the per-peer cap, then reset: numbering restarted at 1.
        // Recent enough that no TTL or acked retirement applies; the cap is the only rule in play.
        ratchet.upsertSession(session(sendEpoch: 3, highestPeAcked: 0))
        for epoch in 47...62 {
            ratchet.commitSend(session(sendEpoch: 3), newLocalEpoch: localEpoch(epoch, createdAt: Self.now - 3_600_000))
        }
        for epoch in 1...3 {
            ratchet.commitSend(session(sendEpoch: 3), newLocalEpoch: localEpoch(epoch, createdAt: Self.now))
        }

        ratchet.sweep(now: Self.now)

        // Ranked by number, the dead era's 47 to 62 would outrank the live era's 1 to 3 for good, and the cap would delete
        // each fresh epoch within a cycle (knit-next ADR 027). Ranked by mint time, the live rows survive and the cap
        // trims the oldest dead rows instead.
        for epoch in [1, 2, 3, 50, 62] {
            #expect(ratchet.localEpochPrivateKey(peer, epoch: epoch) != nil, "epoch \(epoch)")
        }
        #expect(ratchet.localEpochPrivateKey(peer, epoch: 47) == nil)
        #expect(ratchet.localEpochPrivateKey(peer, epoch: 49) == nil)
    }

    @Test(arguments: kinds)
    func reMintingACollidingEpochNumberReplacesTheDeadErasKey(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        // Epoch 5 of the era being abandoned survives, inside its retention window, and the fresh era's numbering climbs
        // back to 5. The live key must win: keeping the dead one makes every peer frame based on the fresh epoch fail its
        // AEAD with nothing in the header to show why.
        ratchet.commitSend(session(sendEpoch: 5), newLocalEpoch: localEpoch(5, fill: 1, createdAt: Self.now - 3_600_000))
        ratchet.commitSend(session(sendEpoch: 5), newLocalEpoch: localEpoch(5, fill: 2, createdAt: Self.now))

        #expect(ratchet.localEpochPrivateKey(peer, epoch: 5) == bytes(2))
    }

    @Test(arguments: kinds)
    func deletePeerDropsEverything(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        ratchet.upsertSession(session())
        ratchet.commitSend(session(), newLocalEpoch: localEpoch(1, createdAt: Self.now))
        ratchet.applyOpen(
            RatchetOpenDelta(session: session(), recvEpoch: recvEpoch(next: 2), skippedInserts: [skippedKey(index: 0, fill: 1)]),
            from: peer,
            se: 1,
            n: 1
        )
        ratchet.deletePeer(peer)
        #expect(ratchet.session(peer) == nil)
        #expect(ratchet.localEpochPrivateKey(peer, epoch: 1) == nil)
        #expect(ratchet.records(of: peer) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
    }
}

// What this port adds, apart from the suite's body only to keep it inside the lint's length.
extension RatchetStoreTests {
    @Test(arguments: kinds)
    func recordsListWhatIsHeldInTheirOrderAndThePurgeKeepsTheSessionAndOurEpochs(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        let other = fixtureNodeId(2)
        ratchet.commitSend(session(), newLocalEpoch: localEpoch(2, createdAt: Self.now))
        ratchet.commitSend(session(), newLocalEpoch: localEpoch(1, createdAt: Self.now))
        ratchet.commitSend(session(), newLocalEpoch: localEpoch(3, createdAt: Self.now - 1))
        ratchet.commitSend(session(other), newLocalEpoch: localEpoch(9, createdAt: Self.now))
        let keys = [
            skippedKey(index: 1, fill: 0, epoch: 2), skippedKey(index: 0, fill: 0, epoch: 2),
            skippedKey(index: 0, fill: 0, tag: Self.oldTag, epoch: 2), skippedKey(index: 7, fill: 0, epoch: 1),
        ]
        ratchet.applyOpen(
            RatchetOpenDelta(session: session(), recvEpoch: recvEpoch(next: 2), skippedInserts: keys), from: peer, se: 1, n: 1)
        ratchet.applyOpen(RatchetOpenDelta(session: session(), recvEpoch: recvEpoch(next: 5, tag: Self.oldTag)), from: peer, se: 1, n: 4)
        let chain = RatchetRecvEpochRecord(epoch: 2, rootTag: Self.tag, chainKey: bytes(8), next: 1, lastUsedAt: Self.now)
        ratchet.applyOpen(RatchetOpenDelta(session: session(), recvEpoch: chain), from: peer, se: 2, n: 0)
        ratchet.applyOpen(RatchetOpenDelta(session: session(other), recvEpoch: recvEpoch(next: 1)), from: other, se: 1, n: 0)

        let held = ratchet.records(of: peer)
        #expect(held.session == session())
        #expect(held.localEpochs.map(\.epoch) == [2, 1, 3], "the most recently minted first, then the higher number")
        #expect(held.recvEpochs.map { [$0.epoch, Int($0.rootTag)] } == [[1, Int(Self.oldTag)], [1, Int(Self.tag)], [2, Int(Self.tag)]])
        #expect(
            held.skippedKeys.map { [$0.epoch, Int($0.rootTag), $0.index] } == [
                [1, Int(Self.tag), 7], [2, Int(Self.oldTag), 0], [2, Int(Self.tag), 0], [2, Int(Self.tag), 1],
            ])
        #expect(ratchet.recvEpochs(peer, epoch: 1).map(\.rootTag) == [Self.oldTag, Self.tag], "by root tag")
        #expect(ratchet.skippedKeys(peer, epoch: 2, index: 0).map(\.rootTag) == [Self.oldTag, Self.tag], "by root tag")

        ratchet.purgeReceiveState(peer)
        ratchet.purgeReceiveState(fixtureNodeId(3))
        let purged = ratchet.records(of: peer)
        #expect(purged.session == session())
        #expect(purged.localEpochs.map(\.epoch) == [2, 1, 3])
        #expect(purged.recvEpochs.isEmpty && purged.skippedKeys.isEmpty)
        #expect(ratchet.records(of: other).recvEpochs.count == 1, "another peer's rows stay")
        #expect(ratchet.records(of: other).localEpochs.map(\.epoch) == [9])
    }

    @Test(arguments: kinds)
    func anOpensWritesVanishWhenItsUnitFails(kind: RepositoryKind) throws {
        let failures = FailureCount()
        let stores = try kind.make(failures: failures.record)
        stores.ratchet.commitSend(session(), newLocalEpoch: localEpoch(1, createdAt: Self.now))
        stores.ratchet.applyOpen(
            RatchetOpenDelta(
                session: session(),
                recvEpoch: recvEpoch(next: 2, tag: Self.oldTag),
                skippedInserts: [skippedKey(index: 0, fill: 7, tag: Self.oldTag)]
            ),
            from: peer,
            se: 1,
            n: 1
        )
        let before = stores.ratchet.records(of: peer)
        let outcome = stores.transactor.atomically { () -> String? in
            // A replacement adopted, a key banked and the old era's spent: every row a delta touches.
            stores.ratchet.applyOpen(
                RatchetOpenDelta(
                    session: session(sendEpoch: 2),
                    recvEpoch: recvEpoch(next: 3),
                    skippedInserts: [skippedKey(index: 1, fill: 8)],
                    consumedSkippedTag: Self.oldTag,
                    purgePeerRecvState: true
                ),
                from: peer,
                se: 1,
                n: 0
            )
            // The message row the open carried, which the store refuses.
            failingWrite(kind, stores)
            return "deliver"
        }
        #expect(outcome == .failed)
        #expect(stores.ratchet.records(of: peer) == before, "the chain did not move past a message nobody holds")
        #expect(failures.value == (kind == .sql ? 1 : 0))
    }

    /// Android leaves the order of keys minted in one millisecond to SQLite. Here the key decides it, so both stores
    /// evict the same keys: the oldest first whatever its peer, then by peer, epoch, index and root tag.
    @Test(arguments: kinds)
    func bothStoresEvictTheSameKeysAtTheCap(kind: RepositoryKind) throws {
        let ratchet = try kind.make().ratchet
        let peers = [fixtureNodeId(1), fixtureNodeId(2)].sorted()
        let low = peers[0]
        let high = peers[1]
        let lows = [
            skippedKey(index: 0, fill: 0, epoch: 2), skippedKey(index: 1, fill: 0, tag: Self.oldTag),
            skippedKey(index: 0, fill: 0), skippedKey(index: 0, fill: 0, tag: Self.oldTag),
        ]
        ratchet.applyOpen(RatchetOpenDelta(session: session(low), recvEpoch: nil, skippedInserts: lows), from: low, se: 1, n: 0)
        let highs = (0..<RatchetRetention.maxSkippedKeys - 1).map { skippedKey(index: $0 % 200, fill: 0, epoch: 1 + $0 / 200) }
        let older = skippedKey(index: 199, fill: 0, epoch: 50, createdAt: Self.now - 1)
        ratchet.applyOpen(
            RatchetOpenDelta(session: session(high), recvEpoch: nil, skippedInserts: highs + [older]), from: high, se: 1, n: 0)

        ratchet.sweep(now: Self.now)

        // 2,004 held, four over the cap.
        #expect(ratchet.skippedKeys(high, epoch: 50, index: 199).isEmpty, "the oldest goes first, whatever its peer")
        #expect(ratchet.skippedKeys(low, epoch: 1, index: 0).isEmpty, "then the lower peer's lowest epoch and index, both tags")
        #expect(ratchet.skippedKeys(low, epoch: 1, index: 1).isEmpty)
        #expect(ratchet.skippedKeys(low, epoch: 2, index: 0).count == 1, "a higher epoch stays")
        #expect(ratchet.skippedKeys(high, epoch: 1, index: 0).count == 1, "the higher peer stays")
        #expect(ratchet.records(of: low).skippedKeys.count + ratchet.records(of: high).skippedKeys.count == RatchetRetention.maxSkippedKeys)
    }
}

// The fixtures, apart from the suite only to keep its body inside the lint's length.
extension RatchetStoreTests {
    private func bytes(_ fill: UInt8) -> [UInt8] {
        [UInt8](repeating: fill, count: 32)
    }

    private func session(_ peer: NodeId? = nil, sendEpoch: Int = 1, highestPeAcked: Int = 0) -> RatchetSessionRecord {
        RatchetSessionRecord(
            peerId: peer ?? self.peer,
            confirmed: true,
            weAreInitiator: true,
            root: bytes(1),
            establishedAt: Self.now,
            sendEpoch: sendEpoch,
            sendEpochPub: bytes(2),
            sendChainKey: bytes(3),
            sendEpochStartedAt: Self.now,
            highestPeAcked: highestPeAcked
        )
    }

    private func recvEpoch(next: Int, tag: Int64 = Self.tag, lastUsedAt: Int64 = Self.now) -> RatchetRecvEpochRecord {
        RatchetRecvEpochRecord(epoch: 1, rootTag: tag, chainKey: bytes(8), next: next, lastUsedAt: lastUsedAt)
    }

    private func skippedKey(
        index: Int,
        fill: UInt8,
        tag: Int64 = Self.tag,
        epoch: Int = 1,
        createdAt: Int64 = Self.now
    ) -> RatchetSkippedKeyRecord {
        RatchetSkippedKeyRecord(epoch: epoch, rootTag: tag, index: index, messageKey: bytes(fill), createdAt: createdAt)
    }

    private func localEpoch(_ epoch: Int, fill: UInt8 = 0, createdAt: Int64) -> RatchetLocalEpochRecord {
        RatchetLocalEpochRecord(epoch: epoch, privateKey: bytes(fill), publicKey: bytes(0), createdAt: createdAt)
    }

    /// A write the store refuses inside the unit: in memory a failing store double's, which fails the unit, and on the
    /// database a roster naming a member twice, which breaks `group_members`' key as a full disk would refuse it.
    private func failingWrite(_ kind: RepositoryKind, _ stores: RepositoryKind.Stores) {
        guard kind == .sql else {
            (stores.transactor as? MemoryTransactor)?.failCurrentUnit()
            return
        }
        let member = GroupMember(nodeId: peer.string)
        stores.groups.save(GroupRecord(id: "g-ratchet", createdBy: peer.string, createdAt: 1, roster: [member, member]))
    }
}
