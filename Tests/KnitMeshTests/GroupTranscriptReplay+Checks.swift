import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

extension GroupTranscriptReplay {
    /// The step's v1 header, the AAD, which the file lists as bytes.
    func aad(
        _ step: RatchetVectors.TranscriptStep,
        from actor: GroupTranscriptParty,
        to peer: GroupTranscriptParty,
        label: String
    ) throws -> [UInt8] {
        let (id, sentAt) = (try #require(step.frameId), try #require(step.sentAt))
        let aad = MessageCrypto.header(id: id, senderId: actor.nodeId.string, sentAt: sentAt, thread: peer.nodeId.string)
        #expect(Hex.encode(aad) == step.aad, "\(label): the v1 header")
        return aad
    }

    /// A sealed DM against what the step lists: the version, the header, the nonce, the ciphertext and the envelope's CBOR.
    func check(_ envelope: EncEnvelope, against step: RatchetVectors.TranscriptStep, label: String) throws {
        #expect(envelope.version == step.version, "\(label): the version")
        #expect(envelope.ratchet == (try #require(step.header)).ratchetHeader, "\(label): the header")
        #expect(Hex.encode(envelope.nonce) == step.nonce, "\(label): the nonce")
        #expect(Hex.encode(envelope.ct) == step.ct, "\(label): the ciphertext")
        #expect(Hex.encode(envelope.encoded) == step.encEnvelope, "\(label): the envelope")
    }

    /// The floors the actor's DM session layer held for `peer` as the step began, against the file's.
    func expectFloors(_ step: RatchetVectors.TranscriptStep, actor: GroupTranscriptParty, peer: GroupTranscriptParty, label: String) {
        guard let stated = step.floorsBefore else {
            return
        }
        let held = actor.dm.floors(for: peer.nodeId)
        let read = RatchetVectors.TranscriptFloors(
            lastReplacementAt: held.lastReplacementAt,
            confirmedAt: held.confirmedAt,
            lastResetSentAtInMemory: held.lastResetSentAt,
            undecryptableIds: held.undecryptableIds
        )
        #expect(read == stated, "\(label): the floors before it")
    }

    /// The actor's DM state for `peer` after the step, as the file digests it.
    func expectState(_ step: RatchetVectors.TranscriptStep, actor: GroupTranscriptParty, peer: GroupTranscriptParty, label: String) throws {
        let stated = try #require(step.state, "\(label) lists a state")
        #expect(stated.of == actor.name && stated.peer == peer.name)
        #expect(StoredStateDigest(actor.dmStore.records(of: peer.nodeId)) == StoredStateDigest(stated), "\(label): the DM state")
    }

    /// A group's holdings as the file digests a group state: send chains newest first, then the receive chains, skipped
    /// keys and outbox by party in node id order, secrets as SHA-256 and a retired chain's as `-`.
    func digest(_ held: GroupRatchetHoldings) -> [[String]] {
        let senders = Set(held.recvChains.keys).union(held.skippedKeys.keys).sorted()
        return [
            held.sendChains.map { "\($0.epoch)/\($0.mintedAt)/\($0.count)/\($0.isRetired)/\(sha($0.seed))/\(sha($0.chainKey))" },
            senders.flatMap { sender in
                (held.recvChains[sender] ?? []).map { chain in
                    "\(name(sender))/\(chain.epoch)/\(chain.mintedAt)/\(chain.next)/\(sha(chain.chainKey))/\(chain.lastUsedAt)"
                }
            },
            senders.flatMap { sender in (held.skippedKeys[sender] ?? []).map { "\(name(sender))/\($0.epoch)/\($0.mintedAt)/\($0.index)" } },
            held.outbox.map { "\(name($0.member))/\($0.sentEpoch)/\($0.sentAt)/\($0.ackedEpoch)/\($0.ackedAt)" },
        ]
    }

    /// The file's group state, digested alike; its roster and root are not compared (``GroupTranscriptReplay``).
    func digest(_ state: RatchetVectors.GroupState) -> [[String]] {
        [
            state.sendChains.map { chain in
                "\(chain.epoch)/\(chain.mintedAt)/\(chain.count)/\(chain.retired)/\(chain.seedSha256 ?? "-")/\(chain.chainKeySha256 ?? "-")"
            },
            state.recvChains.map { "\($0.sender)/\($0.epoch)/\($0.mintedAt)/\($0.next)/\($0.chainKeySha256)/\($0.lastUsedAt)" },
            state.skippedKeys.map { "\($0.sender)/\($0.epoch)/\($0.mintedAt)/\($0.idx)" },
            state.outbox.map { "\($0.member)/\($0.sentEpoch)/\($0.sentAt)/\($0.ackedEpoch)/\($0.ackedAt)" },
        ]
    }

    private func name(_ nodeId: NodeId) -> String {
        names[nodeId] ?? nodeId.string
    }

    /// SHA-256 of a key as lowercase hex, or `-` for the empty key a retired chain holds.
    private func sha(_ bytes: [UInt8]) -> String {
        bytes.isEmpty ? "-" : BlobHash(of: bytes).string
    }

    /// `GroupRatchetEngine.OpenOutcome.Failed`'s Kotlin name.
    static func name(of failure: GroupRatchetEngine.OpenOutcome.Failed) -> String {
        switch failure {
        case .noKey:
            "NO_KEY"
        case .duplicate:
            "DUPLICATE"
        case .badHeader:
            "BAD_HEADER"
        case .aeadFail:
            "AEAD_FAIL"
        }
    }
}

extension RatchetVectors.TranscriptHeader {
    /// The header as KnitWire's type.
    var ratchetHeader: RatchetHeader {
        RatchetHeader(
            se: se,
            ek: Hex.decode(ek) ?? [],
            pe: pe,
            n: n,
            initial: initial.map { RatchetInit(eph: Hex.decode($0.eph) ?? [], pkid: $0.pkid, at: $0.at) },
            flags: flags
        )
    }
}
