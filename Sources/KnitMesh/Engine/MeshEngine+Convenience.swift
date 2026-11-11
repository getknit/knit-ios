public import KnitCrypto
import KnitStore

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
}
