import KnitCrypto
import KnitSync

/// A ``SecretStore`` in memory, which can be told to refuse, to refuse writes alone, or to answer a write and keep
/// nothing of it, and which counts the writes it kept.
final class MemorySecretStore: SecretStore {
    private struct State {
        var secret: [UInt8]?
        var refuses: Bool
        var refusesWrites = false
        var dropsWrites = false
        var writes = 0
    }

    private let state: Lock<State>

    init(secret: [UInt8]?, refuses: Bool) {
        state = Lock(State(secret: secret, refuses: refuses))
    }

    var contents: [UInt8]? { state.withLock { $0.secret } }

    /// How many writes were kept.
    var writes: Int { state.withLock { $0.writes } }

    /// Whether reads and writes both throw, as the Keychain does before the first unlock.
    var refuses: Bool {
        get { state.withLock { $0.refuses } }
        set { state.withLock { $0.refuses = newValue } }
    }

    /// Whether writes alone throw, as a full disk would.
    var refusesWrites: Bool {
        get { state.withLock { $0.refusesWrites } }
        set { state.withLock { $0.refusesWrites = newValue } }
    }

    /// Whether a write answers as if kept and changes nothing.
    var dropsWrites: Bool {
        get { state.withLock { $0.dropsWrites } }
        set { state.withLock { $0.dropsWrites = newValue } }
    }

    func read() throws(SecretStoreError) -> [UInt8]? {
        let (secret, locked) = state.withLock { ($0.secret, $0.refuses) }
        guard !locked else {
            throw .unavailable("locked")
        }
        return secret
    }

    func write(_ secret: [UInt8]) throws(SecretStoreError) {
        let refusal = state.withLock { current -> String? in
            guard !current.refuses else {
                return "locked"
            }
            guard !current.refusesWrites else {
                return "full"
            }
            if !current.dropsWrites {
                current.secret = secret
                current.writes += 1
            }
            return nil
        }
        if let reason = refusal {
            throw .unavailable(reason)
        }
    }
}
