import KnitStore
import KnitTestSupport
import KnitWire
import Testing

// What this port adds to knit-next's `GroupRatchetRepositoryTest`, over both store kinds.
extension GroupRatchetStoreTests {
    @Test(arguments: kinds)
    func anOpensWritesVanishWhenItsUnitFails(kind: RepositoryKind) throws {
        let failures = FailureCount()
        let stores = try kind.make(failures: failures.record)
        let store = stores.groupRatchet
        store.commitSend(sendChain(), in: Self.group)
        store.insertRecvChain(recvChain(next: 2), in: Self.group, from: sender)
        store.applyOpen(
            GroupOpenDelta(recvChain: nil, skippedInserts: [skippedKey(index: 0, fill: 7)]), in: Self.group, from: sender, se: 1, n: 2)
        store.markKeySent(Self.group, to: member, epoch: 1, at: Self.now)
        let before = store.holdings(of: Self.group)
        let outcome = stores.transactor.atomically { () -> String? in
            // An open that spends a key, banks one and advances the chain, a seal's advance, an adoption and an ack: every
            // row a unit of the group form touches.
            store.applyOpen(
                GroupOpenDelta(
                    recvChain: recvChain(next: 5), skippedInserts: [skippedKey(index: 4, fill: 8)], consumedSkippedMintedAt: Self.now),
                in: Self.group,
                from: sender,
                se: 1,
                n: 0
            )
            store.commitSend(sendChain(count: 1), in: Self.group)
            store.insertRecvChain(recvChain(epoch: 2), in: Self.group, from: sender)
            store.markKeyAcked(Self.group, by: member, epoch: 1, at: Self.now + 1)
            // The message row the open carried, which the store refuses.
            failingWrite(kind, stores)
            return "deliver"
        }
        #expect(outcome == .failed)
        #expect(store.holdings(of: Self.group) == before, "the chain did not move past a message nobody holds")
        #expect(failures.value == (kind == .sql ? 1 : 0))
    }

    /// Group ids are wire text, and two ids Swift calls equal are two groups, as on Android (ADR 2026-09.jc2x): a group
    /// spelled with the Kelvin sign shares no row with one spelled with a K.
    @Test(arguments: kinds)
    func groupIdsCompareByTheirBytes(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        let plain = "g-K"
        let kelvin = "g-\u{212A}"
        #expect(plain == kelvin, "Swift calls them equal")
        store.commitSend(sendChain(epoch: 3), in: plain)
        store.insertRecvChain(recvChain(), in: plain, from: sender)
        store.markKeySent(plain, to: member, epoch: 3, at: Self.now)

        #expect(store.sendChain(kelvin) == nil)
        #expect(store.recvChains(kelvin, from: sender, epoch: 1).isEmpty)
        #expect(store.keySend(kelvin, member: member) == nil)
        #expect(store.holdings(of: kelvin) == .empty)
        store.purgeGroup(kelvin)
        store.retireSendChains(kelvin)
        #expect(store.sendChain(plain)?.isRetired == false, "the other group's chain is untouched")
        #expect(store.holdings(of: plain).recvChains[sender]?.count == 1)
    }

    /// A member that never sealed to a group holds only what its senders gave it: a departure's or a rejoin's retirement
    /// there writes no send row, so its first mint is still epoch 1, and leaves the receive state to drain. A group never
    /// held lists no outbox.
    @Test(arguments: kinds)
    func aRetirementWhereWeNeverSealedWritesNoSendRowAndAnUnknownGroupListsNoOutbox(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        store.insertRecvChain(recvChain(next: 3), in: Self.group, from: sender)
        let before = store.holdings(of: Self.group)

        store.retireSendChains(Self.group)
        #expect(store.sendChain(Self.group) == nil)
        #expect(store.holdings(of: Self.group) == before)
        #expect(store.keySends("g-never-held").isEmpty)
    }

    /// The listing the digests read: every send chain newest first, each sender's chains by epoch then mint and its keys
    /// by epoch, mint and index, the outbox in member order. A purge takes one group alone, and a purge or a retirement
    /// of a group never held changes nothing.
    @Test(arguments: kinds)
    func holdingsListEverythingInItsOrderAndAPurgeTakesOneGroup(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        let other = fixtureNodeId(3)
        for epoch in [2, 3, 1] {
            store.commitSend(sendChain(epoch: epoch), in: Self.group)
        }
        for (epoch, mintedAt) in [(2, Self.now), (1, Self.now), (1, Self.now - 5)] {
            store.insertRecvChain(recvChain(epoch: epoch, mintedAt: mintedAt), in: Self.group, from: sender)
        }
        store.insertRecvChain(recvChain(epoch: 7), in: Self.group, from: other)
        let keys = [
            skippedKey(index: 3, fill: 0, epoch: 2), skippedKey(index: 1, fill: 0), skippedKey(index: 1, fill: 0, mintedAt: Self.now - 5),
            skippedKey(index: 0, fill: 0),
        ]
        store.applyOpen(GroupOpenDelta(recvChain: nil, skippedInserts: keys), in: Self.group, from: sender, se: 9, n: 0)
        store.applyOpen(
            GroupOpenDelta(recvChain: nil, skippedInserts: [skippedKey(index: 5, fill: 0)]), in: Self.group, from: other, se: 9, n: 0)
        for peer in [other, member, sender] {
            store.markKeySent(Self.group, to: peer, epoch: 1, at: Self.now)
        }
        store.commitSend(sendChain(epoch: 1), in: "g-elsewhere")

        let held = store.holdings(of: Self.group)
        #expect(held.sendChains.map(\.epoch) == [3, 2, 1])
        #expect(held.recvChains[sender]?.map { [$0.epoch, Int($0.mintedAt - Self.now)] } == [[1, -5], [1, 0], [2, 0]])
        #expect(held.recvChains[other]?.map(\.epoch) == [7])
        #expect(
            held.skippedKeys[sender]?.map { [$0.epoch, Int($0.mintedAt - Self.now), $0.index] } == [
                [1, -5, 1], [1, 0, 0], [1, 0, 1], [2, 0, 3],
            ])
        #expect(held.skippedKeys[other]?.map(\.index) == [5])
        #expect(held.outbox.map(\.member) == [other, member, sender].sorted())
        #expect(store.keySends(Self.group) == held.outbox)

        store.purgeGroup("g-never-held")
        store.retireSendChains("g-never-held")
        #expect(store.holdings(of: "g-never-held") == .empty)
        store.purgeGroup(Self.group)
        let purged = store.holdings(of: Self.group)
        #expect(
            purged
                == GroupRatchetHoldings(
                    sendChains: [GroupRatchetRetention.retired(sendChain(epoch: 3))], recvChains: [:], skippedKeys: [:], outbox: []))
        #expect(store.sendChain("g-elsewhere")?.isRetired == false, "another group's rows stay")
    }

    /// A skipped key is inserted only where none is stored (`GroupRatchetDao.kt:74-75`), and a spent key goes by its full
    /// key: another mint's key at its index stays for that era's frame, where Kotlin's store takes it too (knit-next
    /// #177), and nothing at another sender's, epoch's or index's goes.
    @Test(arguments: kinds)
    func aKeyIsInsertedOnlyWhereNoneIsStoredAndASpendTakesItsOwnMintsKeyAlone(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        let other = fixtureNodeId(3)
        store.applyOpen(
            GroupOpenDelta(recvChain: nil, skippedInserts: [skippedKey(index: 2, fill: 1)]), in: Self.group, from: sender, se: 1, n: 0)
        store.applyOpen(
            GroupOpenDelta(recvChain: nil, skippedInserts: [skippedKey(index: 2, fill: 2)]), in: Self.group, from: sender, se: 1, n: 0)
        #expect(store.skippedKeys(Self.group, from: sender, epoch: 1, index: 2).map(\.messageKey) == [bytes(1)], "the first stays")

        let more = [
            skippedKey(index: 2, fill: 3, mintedAt: Self.now - 1), skippedKey(index: 3, fill: 0), skippedKey(index: 2, fill: 0, epoch: 2),
        ]
        store.applyOpen(GroupOpenDelta(recvChain: nil, skippedInserts: more), in: Self.group, from: sender, se: 1, n: 0)
        store.applyOpen(
            GroupOpenDelta(recvChain: nil, skippedInserts: [skippedKey(index: 2, fill: 0)]), in: Self.group, from: other, se: 1, n: 0)
        #expect(
            store.skippedKeys(Self.group, from: sender, epoch: 1, index: 2).map(\.mintedAt) == [Self.now, Self.now - 1], "newest mint first"
        )

        store.applyOpen(GroupOpenDelta(recvChain: nil, consumedSkippedMintedAt: Self.now), in: Self.group, from: sender, se: 1, n: 2)
        #expect(
            store.skippedKeys(Self.group, from: sender, epoch: 1, index: 2).map(\.mintedAt) == [Self.now - 1], "the older mint's key stays"
        )
        store.applyOpen(GroupOpenDelta(recvChain: nil, consumedSkippedMintedAt: Self.now - 1), in: Self.group, from: sender, se: 1, n: 2)
        #expect(store.skippedKeys(Self.group, from: sender, epoch: 1, index: 2).isEmpty, "then its own spend takes it")
        #expect(store.skippedKeys(Self.group, from: sender, epoch: 1, index: 3).count == 1)
        #expect(store.skippedKeys(Self.group, from: sender, epoch: 2, index: 2).count == 1)
        #expect(store.skippedKeys(Self.group, from: other, epoch: 1, index: 2).count == 1)
    }

    /// A sent epoch only rises and a recorded ack survives a later send (`markKeySent`, `GroupRatchetRepository.kt:117-134`),
    /// and a retired row keeps its number and mint with no key at the cap (`retired`, `GroupRatchetEngine.kt:56`).
    @Test(arguments: kinds)
    func theOutboxNeverLowersASentEpochAndARetiredRowKeepsItsNumberAndMint(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        store.markKeySent(Self.group, to: member, epoch: 3, at: Self.now)
        store.markKeyAcked(Self.group, by: member, epoch: 3, at: Self.now + 1)
        store.markKeySent(Self.group, to: member, epoch: 2, at: Self.now + 2)
        #expect(
            store.keySend(Self.group, member: member)
                == GroupKeySendRecord(
                    member: member, sentEpoch: 3, sentAt: Self.now + 2, ackedEpoch: 3, ackedAt: Self.now + 1))

        store.commitSend(sendChain(epoch: 4, mintedAt: Self.now - 9, count: 17), in: Self.group)
        store.retireSendChains(Self.group)
        #expect(
            store.sendChain(Self.group)
                == GroupSendChainRecord(
                    epoch: 4, seed: [], chainKey: [], count: GroupRatchetRetention.retiredCount, mintedAt: Self.now - 9))
    }

    /// The cap's eviction names a key by its whole key, the mint included: two mints' keys at one index both go when they
    /// are the oldest. The sweep reaches it with enough fresh keys to put the store two over.
    @Test(arguments: kinds)
    func theSkippedKeyCapEvictsByTheWholeKey(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        let filler = (0..<GroupRatchetRetention.maxSkippedKeys - 1).map { skippedKey(index: $0 % 200, fill: 0, epoch: 2 + $0 / 200) }
        let oldest = [
            skippedKey(index: 0, fill: 0, mintedAt: Self.now - 9, createdAt: Self.now - 2),
            skippedKey(index: 0, fill: 0, createdAt: Self.now - 1),
            skippedKey(index: 1, fill: 0),
        ]
        store.applyOpen(GroupOpenDelta(recvChain: nil, skippedInserts: oldest + filler), in: Self.group, from: sender, se: 1, n: 2)

        store.sweep(now: Self.now)

        #expect(store.skippedKeys(Self.group, from: sender, epoch: 1, index: 0).isEmpty)
        #expect(store.skippedKeys(Self.group, from: sender, epoch: 1, index: 1).count == 1)
        #expect(store.holdings(of: Self.group).skippedKeys[sender]?.count == GroupRatchetRetention.maxSkippedKeys)
    }

    /// Android leaves the order of keys banked in one millisecond to SQLite. Here the key decides it, so both stores evict
    /// the same keys: the oldest first whatever its group, then by group, sender, epoch, mint and index. A group id is
    /// ordered and named by every byte it was stored with, a leading U+FEFF included, which a decode that drops it as a
    /// byte order mark would read back as another group's id (ADR 2026-09.jc2x).
    @Test(arguments: kinds)
    func bothStoresEvictTheSameKeysAtTheCap(kind: RepositoryKind) throws {
        let store = try kind.make().groupRatchet
        let peers = [sender, fixtureNodeId(3)].sorted()
        let (low, high) = (peers[0], peers[1])
        let marked = "\u{FEFF}g-a"
        let lows = [
            skippedKey(index: 0, fill: 0, epoch: 2), skippedKey(index: 1, fill: 0, mintedAt: Self.now - 1), skippedKey(index: 0, fill: 0),
        ]
        store.applyOpen(GroupOpenDelta(recvChain: nil, skippedInserts: lows), in: "g-a", from: high, se: 1, n: 0)
        store.applyOpen(GroupOpenDelta(recvChain: nil, skippedInserts: [skippedKey(index: 0, fill: 0)]), in: "g-b", from: low, se: 1, n: 0)
        let highs = (0..<GroupRatchetRetention.maxSkippedKeys - 3).map { skippedKey(index: $0 % 200, fill: 0, epoch: 10 + $0 / 200) }
        store.applyOpen(GroupOpenDelta(recvChain: nil, skippedInserts: highs), in: "g-b", from: high, se: 1, n: 0)
        let older = skippedKey(index: 9, fill: 0, epoch: 99, createdAt: Self.now - 1)
        store.applyOpen(GroupOpenDelta(recvChain: nil, skippedInserts: [older]), in: "g-b", from: high, se: 1, n: 0)
        // Its true bytes, EF BB BF, put it after every "g-" group; read back as "g-a", its older mint would go first.
        let markedKey = skippedKey(index: 0, fill: 0, mintedAt: Self.now - 2)
        store.applyOpen(GroupOpenDelta(recvChain: nil, skippedInserts: [markedKey]), in: marked, from: high, se: 1, n: 0)

        store.sweep(now: Self.now)

        // 2,003 held, three over the cap: the oldest, whatever its group, then group "g-a"'s by mint and epoch.
        #expect(store.skippedKeys("g-b", from: high, epoch: 99, index: 9).isEmpty, "the oldest goes first, whatever its group")
        #expect(store.skippedKeys("g-a", from: high, epoch: 1, index: 1).isEmpty, "then the lower group's oldest mint")
        #expect(store.skippedKeys("g-a", from: high, epoch: 1, index: 0).isEmpty, "then its lowest epoch and index")
        #expect(store.skippedKeys("g-a", from: high, epoch: 2, index: 0).count == 1, "a higher epoch stays")
        #expect(store.skippedKeys("g-b", from: low, epoch: 1, index: 0).count == 1, "the higher group stays")
        #expect(store.skippedKeys(marked, from: high, epoch: 1, index: 0).count == 1, "the U+FEFF group sorts last, by its bytes")
        let held = [store.holdings(of: "g-a"), store.holdings(of: "g-b"), store.holdings(of: marked)].flatMap { holdings in
            holdings.skippedKeys.values.flatMap(\.self)
        }
        #expect(held.count == GroupRatchetRetention.maxSkippedKeys)
    }

    /// A write the store refuses inside the unit: in memory a failing store double's, which fails the unit, and on the
    /// database a roster naming a member twice, which breaks `group_members`' key as a full disk would refuse it.
    private func failingWrite(_ kind: RepositoryKind, _ stores: RepositoryKind.Stores) {
        guard kind == .sql else {
            (stores.transactor as? MemoryTransactor)?.failCurrentUnit()
            return
        }
        let one = GroupMember(nodeId: sender.string)
        stores.groups.save(GroupRecord(id: "g-refused", createdBy: sender.string, createdAt: 1, roster: [one, one]))
    }
}
