import KnitCrypto
import KnitSync

/// The identity's store in memory, as the Keychain or knit-peer's file keeps it, which can be told to refuse writes.
final class KeptSecretStore: SecretStore {
    private struct State {
        var secret: [UInt8]?
        var refusesWrites = false
    }

    private let state: Lock<State>

    /// A store holding `secret`, as `IdentityKeys.load` leaves it.
    init(_ secret: [UInt8]?) {
        state = Lock(State(secret: secret))
    }

    var contents: [UInt8]? { state.withLock { $0.secret } }

    /// Whether writes throw, as the Keychain's do before the first unlock.
    var refusesWrites: Bool {
        get { state.withLock { $0.refusesWrites } }
        set { state.withLock { $0.refusesWrites = newValue } }
    }

    func read() -> [UInt8]? {
        state.withLock { $0.secret }
    }

    func write(_ secret: [UInt8]) throws(SecretStoreError) {
        let refused = state.withLock { current in
            guard !current.refusesWrites else {
                return true
            }
            current.secret = secret
            return false
        }
        if refused {
            throw .unavailable("refused")
        }
    }
}
