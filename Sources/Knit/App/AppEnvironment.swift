#if os(iOS)
    import Foundation
    import KnitAppCore
    import KnitBLE
    import KnitCrypto
    import KnitMesh
    import KnitStore
    import KnitStoreSQL
    import KnitWire
    import UIKit

    /// Everything a running app holds, built once per launch: the identity, the stores, the radio, the mesh and the
    /// session every screen reads (the composition root). `-seedDemo` builds the same thing over seeded stores in
    /// memory and a radio that goes nowhere.
    @MainActor
    internal final class AppEnvironment {
        let session: AppSession
        let preferences: any AppPreferences
        let notifier: LocalNotifier
        /// The camera a profile's scanner reaches: the phone's, or a demo's that answers what `-demoCamera` says.
        let camera: any CameraAccess
        /// The photos faces draw, decoded from the blob store.
        let photos: BlobImageCache
        /// Where a picked profile photo is decoded and cropped.
        let codec: any ImageCodec = DeviceImageCodec()
        /// What Choose photo picks under `-demoPhoto`: a painted picture, since the system's picker is out of a UI test's
        /// reach. `nil` opens the photo library.
        let demoPhoto: Data?
        let about: AboutInfo
        /// Stores a minted test identity for the next launch, in a debug build.
        let replaceIdentity: IdentityReplacer?
        /// The CoreBluetooth radio, which a demo has none of.
        private let radio: BLERadio?
        /// The mesh, which hears whether Knit is in the background so that its links seek peers there
        /// (ADR 2026-10.mueg).
        private let mesh: Mesh
        /// Knit going to the background and coming back, in order: one task hands each to the mesh, so a quick toggle
        /// cannot overtake the one before it.
        private let phases = AsyncStream<Bool>.makeStream()
        private var listening: Task<Void, Never>?
        #if DEBUG
            /// The debug bridge, which a computer reaches over USB, or over Wi-Fi on a network pinned over USB.
            private var bridge: Bridge?
        #endif

        private init(
            session: AppSession,
            mesh: Mesh,
            radio: BLERadio?,
            preferences: any AppPreferences,
            notifier: LocalNotifier,
            camera: any CameraAccess,
            demoPhoto: Data?,
            replaceIdentity: IdentityReplacer?
        ) {
            self.session = session
            self.mesh = mesh
            self.radio = radio
            self.preferences = preferences
            self.notifier = notifier
            self.camera = camera
            self.demoPhoto = demoPhoto
            self.replaceIdentity = replaceIdentity
            photos = BlobImageCache(session: session)
            let info = Bundle.main.infoDictionary ?? [:]
            about = AboutInfo(
                version: info["CFBundleShortVersionString"] as? String ?? "",
                build: info["CFBundleVersion"] as? String ?? ""
            )
        }

        /// Starts listening to the mesh, and starts the mesh itself once onboarding is behind us. A first run starts
        /// it from onboarding's Bluetooth step instead, which is what makes the system ask.
        func run() {
            guard listening == nil else {
                return
            }
            let running = session
            listening = Task { await running.listen() }
            let node = mesh
            let changes = phases.stream
            Task {
                for await background in changes {
                    await node.setInBackground(background)
                }
            }
            // A relaunch to restore Bluetooth runs in the background, with no scene to say so.
            setInBackground(UIApplication.shared.applicationState == .background)
            #if DEBUG
                bridge?.start()
            #endif
            if preferences.hasOnboarded {
                Task { await running.start() }
            }
        }

        /// Knit came to the front: the radio scans again, since a scan started in the background finds nobody.
        func foregrounded() {
            radio?.foregrounded()
            #if DEBUG
                bridge?.start()
            #endif
        }

        /// Knit went to the background, where iOS may suspend it, or came back. Control Center or an alert over Knit is
        /// neither: Knit is still on screen, and Android still finds it.
        func setInBackground(_ background: Bool) {
            phases.continuation.yield(background)
        }

        /// Knit left the front. Only a debug build's scan probe wants to know.
        func backgrounded() {
            #if DEBUG
                radio?.backgrounded()
            #endif
        }

        /// The environment `options` ask for, on a launch that went as `launch` says. Throws when the Keychain or the
        /// database cannot be read yet, before the first unlock since a reboot: the app then waits for protected data
        /// rather than making a new identity.
        static func make(_ options: LaunchOptions, launch: Launch.History) throws -> AppEnvironment {
            options.seedDemo ? try demo(options) : try live(launch, options: options)
        }

        private static func live(_ launch: Launch.History, options: LaunchOptions) throws -> AppEnvironment {
            let keyStore = KeychainSecretStore()
            let identity = try IdentityKeys.load(from: keyStore).keys
            let log = UnifiedLog(clock: SystemClock())
            let directory = try databaseDirectory()
            let database = try KnitDatabase.open(in: directory) { error in
                log.log(.warning, "store failed: \(error)")
            }
            let stores = MeshStores(
                custody: SQLCustodyStore(database),
                peers: SQLPeerStore(database),
                messages: SQLMessageStore(database),
                conversations: SQLConversationStore(database),
                groups: SQLGroupStore(database),
                ownProfile: SQLOwnProfileStore(database),
                blobs: try SQLBlobStore(
                    database, directory: directory.appending(path: SQLBlobStore.directoryName, directoryHint: .isDirectory))
            )
            let defaults = DefaultsPreferences()
            var parts = Parts(identity: identity, stores: stores, radio: BLERadio(log: log), log: log, preferences: defaults)
            #if DEBUG
                parts.storage = StorageReport(
                    nodeId: identity.nodeId, keyStore: keyStore, directory: directory, preferences: defaults, launch: launch)
                // The device tests pick a painted photo too: the system's picker is out of their reach.
                parts.demoPhoto = options.demoPhoto ? DemoPortraits.pickedPhoto() : nil
                return compose(parts) { keys in try keyStore.write(keys.storedForm) }
            #else
                return compose(parts, replace: nil)
            #endif
        }

        private static func demo(_ options: LaunchOptions) throws -> AppEnvironment {
            guard let identity = DemoSeed.identity else {
                throw SecretStoreError.unavailable("the demo identity")
            }
            let clock = SystemClock()
            let stores = MeshStores.inMemory()
            DemoSeed.populate(
                stores, me: identity.nodeId, now: clock.wallMilliseconds(), scene: options.demoScene, paint: DemoPortraits.profilePhoto)
            let parts = Parts(
                identity: identity,
                stores: stores,
                radio: DemoRadio(state: options.demoRadio),
                log: UnifiedLog(clock: clock),
                preferences: MemoryPreferences(hasOnboarded: !options.demoOnboarding),
                linked: DemoSeed.linked(in: options.demoScene),
                camera: options.demoCamera.map(DemoCamera.init),
                demoPhoto: options.demoPhoto ? DemoPortraits.pickedPhoto() : nil
            )
            return compose(parts, replace: nil)
        }

        /// What an environment is made from.
        private struct Parts {
            let identity: IdentityKeys
            let stores: MeshStores
            let radio: any Radio
            let log: any KnitLog
            let preferences: any AppPreferences
            /// The peers a demo scene shows as linked, which only a demo has.
            var linked: [NodeId] = []
            /// A demo's camera, under `-demoCamera`; otherwise the phone's.
            var camera: (any CameraAccess)?
            /// The picture Choose photo picks, under `-demoPhoto`.
            var demoPhoto: Data?
            #if DEBUG
                /// What the debug bridge's `storage` reply reads, which only a live launch has.
                var storage: StorageReport?
            #endif
        }

        private static func compose(_ parts: Parts, replace: IdentityReplacer?) -> AppEnvironment {
            let clock = SystemClock()
            let node = Mesh(
                identity: parts.identity,
                deviceTag: DeviceTag.derive(UIDevice.current.identifierForVendor?.uuidString),
                stores: parts.stores,
                radio: parts.radio,
                clock: clock,
                random: SystemRandomNumberGenerator(),
                log: parts.log
            )
            let alerts = LocalNotifier()
            let service: any MeshService = parts.linked.isEmpty ? node : DemoMesh(node, linked: parts.linked)
            let app = AppSession(
                identity: OwnIdentity(bundle: parts.identity.bundle), stores: parts.stores, mesh: service, notifier: alerts)
            let environment = AppEnvironment(
                session: app,
                mesh: node,
                radio: parts.radio as? BLERadio,
                preferences: parts.preferences,
                notifier: alerts,
                camera: parts.camera ?? DeviceCamera(),
                demoPhoto: parts.demoPhoto,
                replaceIdentity: replace
            )
            #if DEBUG
                environment.bridge = Bridge(
                    session: app,
                    mesh: node,
                    radio: environment.radio,
                    bundle: parts.identity.bundle,
                    clock: clock,
                    log: parts.log,
                    version: "\(environment.about.version) (\(environment.about.build))",
                    storage: parts.storage
                )
            #endif
            return environment
        }

        /// The database's own directory, under Application Support, which is backed up unless told otherwise; the
        /// store excludes it (ADR 2026-09.nyya).
        private static func databaseDirectory() throws -> URL {
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Database", directoryHint: .isDirectory)
        }
    }
#endif
