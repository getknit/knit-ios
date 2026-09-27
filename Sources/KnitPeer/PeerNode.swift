import KnitControl
public import KnitCrypto
public import KnitMesh
import KnitStore
public import KnitWire

/// The headless node: a ``Mesh`` on a radio, answering control commands and reporting what the mesh did, each as
/// one JSON line through `output` (``MeshControl`` has the protocol).
public actor PeerNode {
    /// This node's id.
    nonisolated public let nodeId: NodeId
    private let mesh: Mesh
    private let stores: MeshStores
    private let control: MeshControl
    private let output: @Sendable (String) -> Void
    private var forwarding: Task<Void, Never>?

    /// A node for `identity` on `radio`. Nothing runs until ``start(name:)``.
    @preconcurrency
    public init(
        identity: IdentityKeys,
        stores: MeshStores,
        radio: any Radio,
        radioProfile: String,
        clock: any MeshClock,
        random: some RandomNumberGenerator & Sendable,
        linkConfiguration: LinkManager.Configuration = LinkManager.Configuration(),
        log: any KnitLog,
        output: @escaping @Sendable (String) -> Void
    ) {
        nodeId = identity.nodeId
        self.stores = stores
        self.output = output
        mesh = Mesh(
            identity: identity,
            deviceTag: nil,
            stores: stores,
            radio: radio,
            clock: clock,
            random: random,
            linkConfiguration: linkConfiguration,
            log: log
        )
        control = MeshControl(
            bundle: identity.bundle,
            mesh: mesh,
            stores: stores,
            clock: clock,
            details: ["radioProfile": .string(radioProfile)]
        )
    }

    /// Starts the mesh, publishes `name` if it is new, and reports `ready`.
    public func start(name: String?) async {
        guard forwarding == nil else {
            return
        }
        let events = mesh.events
        let reporter = control
        let write = output
        forwarding = Task {
            for await event in events {
                for line in await reporter.report(event) {
                    write(line)
                }
            }
        }
        await mesh.start()
        let own = stores.ownProfile.load()
        if let name, name != own.name {
            await mesh.updateProfile(name: name, status: own.status, openToChat: own.openToChat)
        }
        output(control.ready)
    }

    /// Stops the mesh and the event reports.
    public func stop() async {
        await mesh.stop()
        forwarding?.cancel()
        forwarding = nil
    }

    /// Answers one control line, and whether to keep reading: `false` after `quit`, which stops the node first.
    @discardableResult
    public func handle(_ line: String) async -> Bool {
        let reply = await control.handle(line)
        if reply.quits {
            await stop()
        }
        output(reply.line)
        return !reply.quits
    }
}
