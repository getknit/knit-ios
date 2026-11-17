import KnitCrypto
import KnitStore
import KnitWire

@testable import KnitMesh

/// What ``SpoolLab``'s tests read: the records each node sent, its table, its heal, the spool's digest, and what the spool
/// holds opened.
extension SpoolLab {
    /// How many `list` records node `index` sent.
    func lists(_ index: Int) -> Int {
        sent[index].count { if case .list = $0 { true } else { false } }
    }

    /// How many records of any scope operation (`sub`, `list`, `pull`, `push`) node `index` sent naming `scope`.
    func operations(_ index: Int, on scope: SpoolID) -> Int {
        sent[index].count { record in
            switch record {
            case .sub(let sub):
                sub.subs.contains { $0.scope == scope.bytes }
            case .list(let list):
                list.scope == scope.bytes
            case .pull(let pull):
                pull.scope == scope.bytes
            case .push(let push):
                push.scope == scope.bytes
            default:
                false
            }
        }
    }

    /// The scopes node `index`'s table carries, live ones first.
    func scopes(_ index: Int) -> [SpoolScope] {
        planes[index].table.scopes
    }

    /// Node `index`'s heal loop.
    func heal(_ index: Int) -> ScopeHeal? {
        planes[index].relays[relay]?.heal
    }

    /// The spool's digest of `scope`.
    func spoolDigest(_ scope: SpoolID) -> UInt64 {
        ScopeCrypto.digest(of: spool.liveIds(scope).map(\.bytes))
    }

    /// The live frames node `index`'s custody holds between it and node `peer`, as the scope's rule admits them, by id.
    func pairIds(_ index: Int, with peer: Int) -> Set<String> {
        let me = radio[index].me.nodeId
        let other = radio[peer].me.nodeId
        let frames = radio[index].stores.custody.liveFrames(now: radio[index].clock.wallMilliseconds())
        return Set(frames.filter { ScopeFrames.eligible($0.envelope, me: me, peer: other) }.map(\.envelope.id))
    }

    /// Every blob the spool holds in `scope`, opened under `keys`.
    func opened(_ scope: SpoolScope) -> [(sig: [UInt8], envelope: RelayEnvelope)] {
        guard let held = spool.scopes[scope.id]?.live else {
            return []
        }
        return held.compactMap { blob in
            guard let opened = ScopeCrypto.open(scope.keys, blobId: blob.id.bytes, blob: blob.data),
                let envelope = try? RelayEnvelope(decoding: opened.signed)
            else {
                return nil
            }
            return (opened.sig, envelope)
        }
    }
}
