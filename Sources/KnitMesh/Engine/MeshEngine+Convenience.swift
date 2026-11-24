public import KnitCrypto
import KnitStore
import KnitWire

extension MeshEngine {
    /// A node with `identity` and the prekeys it keeps, its repositories, and the transport, clock and randomness it runs
    /// on. A ring another identity signs is not this node's, and is left out.
    public convenience init(
        identity: IdentityKeys,
        prekeys: PrekeyRing? = nil,
        deviceTag: String?,
        stores: MeshStores,
        transport: any MeshTransport,
        clock: any MeshClock,
        random: some RandomNumberGenerator,
        configuration: MeshConfiguration = MeshConfiguration(),
        log: any KnitLog = SilentLog()
    ) {
        self.init(
            identity: identity,
            prekeys: prekeys,
            deviceTag: deviceTag,
            stores: stores,
            transport: transport,
            clock: clock,
            random: random,
            configuration: configuration,
            log: log,
            ratchetEngine: RatchetEngine(),
            groupRatchetEngine: GroupRatchetEngine(),
            partials: MemoryPartialBlobStore()
        )
    }

    // Kept out of `MeshEngine.swift`, whose class body is at the lint's limit.

    /// A relay's jitter, uniform in `0..<jitterWindowMilliseconds`.
    func drawJitter() -> Int64 {
        let window = UInt64(max(1, configuration.router.jitterWindowMilliseconds))
        return Int64(random.next(upperBound: window))
    }

    /// A fresh frame id from the injected generator.
    func newFrameId() -> String {
        FrameId.generate(using: &random)
    }
}
