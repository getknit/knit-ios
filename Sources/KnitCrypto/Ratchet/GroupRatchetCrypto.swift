/// The group form's primitive layer (`GroupRatchetCrypto` in knit-next's `mesh/crypto/ratchet/GroupRatchetCrypto.kt`, at
/// `ac491f4c`): each sender's epoch derived from a random seed, and the DM ratchet's chain shape under group labels.
/// There is no DH. A seed's freshness and secrecy come from the pairwise v2 session that carries it (`CTL_GROUP_KEY`),
/// so the group layer is a pure chain. Every label sits under `knit/group/v1/`, apart from the DM's and HPKE's.
///
/// The spool's export (`exportEpochSeal`, `:70-76`) is left out with the spool (ADR 2026-10.5sk9).
public enum GroupRatchetCrypto {
    /// A seed's length (`SEED_BYTES`, `:21`).
    public static let seedByteCount = 32

    private static let labelEpoch = Array("knit/group/v1/epoch".utf8)
    private static let labelMessageKey = Array("knit/group/v1/mk".utf8)
    private static let labelChainKey = Array("knit/group/v1/ck".utf8)

    /// A fresh epoch seed from the system's generator, never an injected one (`newSeed`, `:37-38`): the only secret a
    /// sender distributes for its chain. Whatever mints a seed takes a source that defaults to this, so a test can fix
    /// one, as Kotlin's `GroupRatchetEngine(newSeed)` does.
    public static func newSeed() -> [UInt8] {
        secureRandomBytes(seedByteCount)
    }

    /// One sender's epoch secret from its seed (`deriveEpoch`, `:46-62`): HKDF with the seed as input key material, the
    /// zero salt, and an info that binds the group, the sender and the epoch, so a seed leaked, replayed or reused
    /// cannot be moved to another group, sender or epoch.
    public static func deriveEpoch(seed: [UInt8], groupId: String, senderId: String, epoch: Int) -> RatchetCrypto.EpochKeys {
        let info = epochInfo(groupId: groupId, senderId: senderId, epoch: epoch)
        return RatchetCrypto.EpochKeys(
            okm: RatchetCrypto.hkdf(seed, salt: RatchetCrypto.zeroSalt, info: info, count: RatchetCrypto.epochSecretByteCount)
        )
    }

    /// `"knit/group/v1/epoch" ‖ "{groupId}|{senderId}|" ‖ u32be(epoch)` (`:59`). `|` cannot occur in a base32 node id or
    /// a `g-` hex group id, so the fields cannot alias one another.
    static func epochInfo(groupId: String, senderId: String, epoch: Int) -> [UInt8] {
        labelEpoch + Array("\(groupId)|\(senderId)|".utf8) + RatchetCrypto.u32be(epoch)
    }

    /// The AES-256-GCM key for chain index n, from chain key n (`messageKey`, `:64-65`).
    public static func messageKey(_ chainKey: [UInt8]) -> [UInt8] {
        RatchetCrypto.hkdf(chainKey, salt: RatchetCrypto.zeroSalt, info: labelMessageKey, count: RatchetCrypto.keyByteCount)
    }

    /// Chain key n + 1 from chain key n (`nextChainKey`, `:67-68`): one way, so a spent key can be deleted.
    public static func nextChainKey(_ chainKey: [UInt8]) -> [UInt8] {
        RatchetCrypto.hkdf(chainKey, salt: RatchetCrypto.zeroSalt, info: labelChainKey, count: RatchetCrypto.keyByteCount)
    }
}
