import KnitCrypto
import Synchronization

/// A ``SecretStore`` in memory, which can be told to refuse.
final class MemorySecretStore: SecretStore {
    private struct State {
        var secret: [UInt8]?
        var refuses: Bool
    }

    private let state: Mutex<State>

    init(secret: [UInt8]?, refuses: Bool) {
        state = Mutex(State(secret: secret, refuses: refuses))
    }

    var contents: [UInt8]? { state.withLock { $0.secret } }

    func read() throws(SecretStoreError) -> [UInt8]? {
        let (secret, refuses) = state.withLock { ($0.secret, $0.refuses) }
        guard !refuses else {
            throw .unavailable("locked")
        }
        return secret
    }

    func write(_ secret: [UInt8]) throws(SecretStoreError) {
        let refused = state.withLock { current in
            guard !current.refuses else {
                return true
            }
            current.secret = secret
            return false
        }
        if refused {
            throw .unavailable("locked")
        }
    }
}
