#if os(iOS)
    import Foundation
    import KnitAppCore
    import KnitBLE
    import KnitCrypto
    import KnitMesh
    import KnitStore
    import KnitStoreSQL
    import UIKit

    /// Everything a running app holds, built once per launch: the identity, the stores, the radio, the mesh and the
    /// session every screen reads (the composition root). `-seedDemo` builds the same thing over seeded stores in
    /// memory and a radio that goes nowhere.
    @MainActor
    internal final class AppEnvironment {
        let session: AppSession
        let preferences: any AppPreferences
        let notifier: LocalNotifier
        let about: AboutInfo
        /// Stores a minted test identity for the next launch, in a debug build.
        let replaceIdentity: IdentityReplacer?
        private let mesh: Mesh
        private var listening: Task<Void, Never>?

        private init(
            session: AppSession,
            mesh: Mesh,
            preferences: any AppPreferences,
            notifier: LocalNotifier,
            replaceIdentity: IdentityReplacer?
        ) {
            self.session = session
            self.mesh = mesh
            self.preferences = preferences
            self.notifier = notifier
            self.replaceIdentity = replaceIdentity
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
            if preferences.hasOnboarded {
                Task { await running.start() }
            }
        }

        /// The environment `options` ask for. Throws when the Keychain or the database cannot be read yet, before
        /// the first unlock since a reboot: the app then waits for protected data rather than making a new identity.
        static func make(_ options: LaunchOptions) throws -> AppEnvironment {
            options.seedDemo ? try demo(radio: options.demoRadio) : try live()
        }

        private static func live() throws -> AppEnvironment {
            let keyStore = KeychainSecretStore()
            let identity = try IdentityKeys.load(from: keyStore).keys
            let log = UnifiedLog(clock: SystemClock())
            let database = try KnitDatabase.open(in: databaseDirectory()) { error in
                log.log(.warning, "store failed: \(error)")
            }
            let stores = MeshStores(
                custody: SQLCustodyStore(database),
                peers: SQLPeerStore(database),
                messages: SQLMessageStore(database),
                conversations: SQLConversationStore(database),
                ownProfile: SQLOwnProfileStore(database)
            )
            let parts = Parts(identity: identity, stores: stores, radio: BLERadio(log: log), log: log, preferences: DefaultsPreferences())
            #if DEBUG
                return compose(parts) { keys in try keyStore.write(keys.storedForm) }
            #else
                return compose(parts, replace: nil)
            #endif
        }

        private static func demo(radio: RadioState) throws -> AppEnvironment {
            guard let identity = DemoSeed.identity else {
                throw SecretStoreError.unavailable("the demo identity")
            }
            let clock = SystemClock()
            let stores = MeshStores.inMemory()
            DemoSeed.populate(stores, me: identity.nodeId, now: clock.wallMilliseconds())
            let parts = Parts(
                identity: identity,
                stores: stores,
                radio: DemoRadio(state: radio),
                log: UnifiedLog(clock: clock),
                preferences: MemoryPreferences(hasOnboarded: true)
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
        }

        private static func compose(_ parts: Parts, replace: IdentityReplacer?) -> AppEnvironment {
            let node = Mesh(
                identity: parts.identity,
                deviceTag: DeviceTag.derive(UIDevice.current.identifierForVendor?.uuidString),
                stores: parts.stores,
                radio: parts.radio,
                clock: SystemClock(),
                random: SystemRandomNumberGenerator(),
                log: parts.log
            )
            let alerts = LocalNotifier()
            let app = AppSession(identity: OwnIdentity(bundle: parts.identity.bundle), stores: parts.stores, mesh: node, notifier: alerts)
            return AppEnvironment(session: app, mesh: node, preferences: parts.preferences, notifier: alerts, replaceIdentity: replace)
        }

        /// The database's own directory, under Application Support, which is backed up unless told otherwise; the
        /// store excludes it (ADR 2026-09.nyya).
        private static func databaseDirectory() throws -> URL {
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Database", directoryHint: .isDirectory)
        }
    }
#endif
