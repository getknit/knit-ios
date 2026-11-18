import KnitSync

/// A relay's address, or the consent nonce, could not be read, written or deleted now (ADR 2026-11.adrq, P6). It names no
/// address and no reason the store gave: the reason may quote what it was asked.
public struct RelaySecretError: Error, Sendable, Equatable {
    /// A failure.
    public init() {
        // Nothing to carry.
    }
}

/// Where relay addresses live, token and all, and the install's consent nonce: one item per relay, under its handle, and
/// one for the nonce, apart from the identity's store (ADR 2026-11.adrq, P6). The app's is the Keychain, under a service of
/// its own, never synchronised and readable after the first unlock on this phone alone; tests keep them in memory.
public protocol RelaySecretStore: Sendable {
    /// The address kept for `handle`, or `nil` when there is no item. Throws when the store cannot answer now.
    func read(_ handle: Int) throws(RelaySecretError) -> String?
    /// Keeps `address` for `handle`, replacing any.
    func write(_ handle: Int, _ address: String) throws(RelaySecretError)
    /// Removes `handle`'s item; one already gone is no failure.
    func delete(_ handle: Int) throws(RelaySecretError)
    /// The consent nonce kept, or `nil` when there is none. Throws when the store cannot answer now.
    func readConsent() throws(RelaySecretError) -> String?
    /// Keeps `nonce` as the consent nonce, replacing any.
    func writeConsent(_ nonce: String) throws(RelaySecretError)
    /// Removes the consent nonce; one already gone is no failure.
    func deleteConsent() throws(RelaySecretError)
    /// Removes every item, the consent nonce's too: what a fresh install does before it seeds, so no item an earlier install
    /// left is read under a handle this one hands out, and no earlier consent holds.
    func deleteAll() throws(RelaySecretError)
}

/// ``RelaySecretStore`` in memory, for tests and the demo, with failures a test can turn on.
public final class MemoryRelaySecrets: RelaySecretStore {
    /// A call that can be made to fail.
    public enum Call: Hashable, Sendable {
        case reads
        case writes
        case deletes
        /// Every call on the consent nonce.
        case consent
    }

    private struct State {
        var items: [Int: String] = [:]
        var consent: String?
        var failures: Set<Call> = []
        var sweeps = 0
    }

    private let state: Lock<State>

    /// A store holding `items`.
    public init(_ items: [Int: String] = [:]) {
        state = Lock(State(items: items))
    }

    /// Every item, by handle.
    public var items: [Int: String] { state.withLock { $0.items } }

    /// The consent nonce kept.
    public var consent: String? {
        get { state.withLock { $0.consent } }
        set { state.withLock { $0.consent = newValue } }
    }

    /// How many times ``deleteAll()`` swept the store.
    public var sweeps: Int { state.withLock { $0.sweeps } }

    /// The calls that fail from now on.
    public var failures: Set<Call> {
        get { state.withLock { $0.failures } }
        set { state.withLock { $0.failures = newValue } }
    }

    public func read(_ handle: Int) throws(RelaySecretError) -> String? {
        try answer(unless: .reads) { $0.items[handle] }
    }

    public func write(_ handle: Int, _ address: String) throws(RelaySecretError) {
        try answer(unless: .writes) { $0.items[handle] = address }
    }

    public func delete(_ handle: Int) throws(RelaySecretError) {
        try answer(unless: .deletes) { $0.items[handle] = nil }
    }

    public func readConsent() throws(RelaySecretError) -> String? {
        try answer(unless: .consent) { $0.consent }
    }

    public func writeConsent(_ nonce: String) throws(RelaySecretError) {
        try answer(unless: .consent) { $0.consent = nonce }
    }

    public func deleteConsent() throws(RelaySecretError) {
        try answer(unless: .consent) { $0.consent = nil }
    }

    public func deleteAll() throws(RelaySecretError) {
        try answer(unless: .deletes) { held in
            held.items.removeAll()
            held.consent = nil
            held.sweeps += 1
        }
    }

    /// `body`'s answer, or a failure when `call` fails.
    private func answer<T>(unless call: Call, _ body: (inout State) -> T) throws(RelaySecretError) -> T {
        let answer: T? = state.withLock { held in held.failures.contains(call) ? nil : body(&held) }
        guard let answer else {
            throw RelaySecretError()
        }
        return answer
    }
}
