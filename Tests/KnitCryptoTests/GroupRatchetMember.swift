import Foundation
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitCrypto

/// One member's group-ratchet state for one group, as a store would hold it (`Member`, knit-next's
/// `GroupRatchetEngineTest.kt:27-111` and `GroupRatchetSoakTest.kt:40-117`): its send chain, every sender's receive
/// chains by sender, epoch and mint, and the skipped keys by sender, epoch and index, every mint's together. A wipe loses
/// all three; a retirement leaves the send chain key-less, as a departure's rekey does.
final class GroupRatchetMember {
    static let group = "g-0123456789abcdef01234567"

    /// A group frame as it flies: who sealed it, its header and its bytes.
    struct Frame {
        let id: String
        let sender: NodeId
        let header: GroupRatchetHeader
        let nonce: [UInt8]
        let ct: [UInt8]
    }

    struct ChainId: Hashable {
        let sender: NodeId
        let epoch: Int
        let mintedAt: Int64
    }

    struct KeyId: Hashable {
        let sender: NodeId
        let epoch: Int
        let index: Int
    }

    let nodeId: NodeId
    let engine: GroupRatchetEngine
    var send: GroupRatchetEngine.SendChain?
    var recv: [ChainId: GroupRatchetEngine.RecvChain] = [:]
    var skipped: [KeyId: [GroupRatchetEngine.SkippedKey]] = [:]

    init(_ seed: Int, engine: GroupRatchetEngine = GroupRatchetEngine()) {
        nodeId = fixtureNodeId(seed)
        self.engine = engine
    }

    static func aad(_ id: String) -> [UInt8] {
        Array("\(id)|\(group)".utf8)
    }

    /// Mints the next send epoch at `now`, past whatever the send chain was.
    @discardableResult
    func mint(now: Int64) -> GroupRatchetEngine.SendChain {
        let chain = engine.mint(groupId: Self.group, selfId: nodeId, previousEpoch: send?.epoch ?? 0, now: now)
        send = chain
        return chain
    }

    /// `from`'s seed for `chain`, against the newest mint held for its epoch: stored when the engine adopts it.
    @discardableResult
    func adopt(from: GroupRatchetMember, _ chain: GroupRatchetEngine.SendChain, now: Int64) -> GroupRatchetEngine.AdoptOutcome {
        adopt(sender: from.nodeId, epoch: chain.epoch, seed: chain.seed, mintedAt: chain.mintedAt, now: now)
    }

    /// A seed by its parts, against the newest mint held for its epoch.
    @discardableResult
    func adopt(sender: NodeId, epoch: Int, seed: [UInt8], mintedAt: Int64, now: Int64) -> GroupRatchetEngine.AdoptOutcome {
        let newest = recv.filter { $0.key.sender == sender && $0.key.epoch == epoch }.max { $0.key.mintedAt < $1.key.mintedAt }?.value
        let outcome = engine.adoptSeed(
            existing: newest, groupId: Self.group, senderId: sender, epoch: epoch, seed: seed, mintedAt: mintedAt, now: now)
        if case .adopt(let chain) = outcome {
            recv[ChainId(sender: sender, epoch: epoch, mintedAt: mintedAt)] = chain
        }
        return outcome
    }

    /// One frame of `body`, minting first when the advance rules call for it.
    func seal(_ id: String, _ body: String, now: Int64) throws -> Frame {
        if GroupRatchetEngine.needsNewEpoch(send, now: now) {
            mint(now: now)
        }
        let chain = try #require(send)
        let sealing = try engine.seal(chain, plaintext: Array(body.utf8), aad: Self.aad(id))
        let result = try #require(sealing)
        send = result.chain
        return Frame(id: id, sender: nodeId, header: result.header, nonce: result.nonce, ct: result.ct)
    }

    /// Opens `frame` against what is held for its sender, and applies the delta when it opens.
    func open(_ frame: Frame, now: Int64) -> GroupRatchetEngine.OpenOutcome {
        let chains = recv.filter { $0.key.sender == frame.sender && $0.key.epoch == frame.header.se }.map(\.value)
        let keyId = KeyId(sender: frame.sender, epoch: frame.header.se, index: frame.header.n)
        let context = GroupRatchetEngine.OpenContext(chains: chains, skippedKeys: skipped[keyId] ?? [])
        let outcome = engine.open(context, header: frame.header, nonce: frame.nonce, ct: frame.ct, aad: Self.aad(frame.id), now: now)
        if case .opened(let opened) = outcome {
            apply(opened.delta, from: frame.sender, at: keyId)
        }
        return outcome
    }

    /// The plaintext of `frame`, which must open.
    func openedText(_ frame: Frame, now: Int64) throws -> String {
        guard case .opened(let opened) = open(frame, now: now) else {
            Issue.record("\(frame.id) did not open")
            throw GroupRatchetEngineTests.Unopened()
        }
        return try #require(String(bytes: opened.plaintext, encoding: .utf8))
    }

    /// Everything lost, as a database wipe loses it.
    func wipe() {
        send = nil
        recv = [:]
        skipped = [:]
    }

    /// A departure's or a rejoin's rekey, as `GroupRatchetStore.retireSendChains` leaves the newest chain.
    func retire() {
        send = send?.retired()
    }

    private func apply(_ delta: GroupRatchetEngine.OpenDelta, from sender: NodeId, at keyId: KeyId) {
        if let chain = delta.recvChain {
            recv[ChainId(sender: sender, epoch: chain.epoch, mintedAt: chain.mintedAt)] = chain
        }
        for key in delta.skippedInserts {
            skipped[KeyId(sender: sender, epoch: key.epoch, index: key.index), default: []].append(key)
        }
        if let mintedAt = delta.consumedSkippedMintedAt {
            // The spent key alone, by its mint: another era's key at the index stays for that era's frame.
            skipped[keyId]?.removeAll { $0.mintedAt == mintedAt }
            if skipped[keyId]?.isEmpty == true {
                skipped[keyId] = nil
            }
        }
    }
}
