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
        /// The content filter: what a picked photo is checked against, and what someone else's photo or face hides behind
        /// (ADR 2026-10.rpmq).
        let screening: PhotoScreening
        /// The filter's photo model, which lets go of its memory when Knit leaves the front; a demo's has none to let go.
        private let model: DevicePhotoClassifier?
        /// The filter's text model, which lets go soon after its last message in the background; a demo's has none.
        private let textModel: DeviceTextClassifier?
        /// What Choose photo picks under `-demoPhoto`: a painted picture, since the system's picker is out of a UI test's
        /// reach. `nil` opens the photo library.
        let demoPhoto: Data?
        /// What `-demoNotification` posts each time Knit goes to the background, since nothing reaches the demo that
        /// would: a UI test taps it to open its thread.
        private let demoNotification: LocalNotification?
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
            classifier: any PhotoClassifier,
            textClassifier: any TextClassifier,
            demoPhoto: Data?,
            demoNotification: LocalNotification?,
            replaceIdentity: IdentityReplacer?
        ) {
            self.session = session
            self.mesh = mesh
            self.radio = radio
            self.preferences = preferences
            self.notifier = notifier
            self.camera = camera
            self.demoPhoto = demoPhoto
            self.demoNotification = demoNotification
            self.replaceIdentity = replaceIdentity
            photos = BlobImageCache(session: session)
            screening = PhotoScreening(classifier: classifier, session: session)
            model = classifier as? DevicePhotoClassifier
            textModel = textClassifier as? DeviceTextClassifier
            let info = Bundle.main.infoDictionary ?? [:]
            about = AboutInfo(
                version: info["CFBundleShortVersionString"] as? String ?? "",
                build: info["CFBundleVersion"] as? String ?? ""
            )
        }

        /// Starts listening to the mesh, and starts the mesh itself once onboarding is behind us. A first run starts
        /// it from onboarding's Bluetooth step instead, which is what makes the system ask. Under `-demoNotification`
        /// it asks to notify.
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
            phases.continuation.yield(UIApplication.shared.applicationState == .background)
            #if DEBUG
                bridge?.start()
            #endif
            if preferences.hasOnboarded {
                Task { await running.start() }
            }
            if let demoNotification {
                let alerts = notifier
                Task {
                    // One left from an earlier run would make the next one quiet, with no banner to tap.
                    await alerts.withdraw(threadId: demoNotification.threadId)
                    _ = await alerts.request()
                }
            }
        }

        /// Knit came to the front: the radio scans again, since a scan started in the background finds nobody.
        func foregrounded() {
            radio?.foregrounded()
            #if DEBUG
                bridge?.start()
            #endif
        }

        /// Knit left the front. Only a debug build's scan probe wants to know.
        func backgrounded() {
            #if DEBUG
                radio?.backgrounded()
            #endif
        }

        /// The environment `options` ask for, on a launch that went as `launch` says. Throws when the Keychain or the
        /// database cannot be read yet, before the first unlock since a reboot: the app then waits for protected data
        /// rather than making a new identity. Only a debug build runs the demo.
        static func make(_ options: LaunchOptions, launch: Launch.History) throws -> AppEnvironment {
            #if DEBUG
                if options.seedDemo {
                    return try demo(options)
                }
            #endif
            return try live(launch, options: options)
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
                blocks: SQLBlockStore(database),
                groups: SQLGroupStore(database),
                ownProfile: SQLOwnProfileStore(database),
                blobs: try SQLBlobStore(
                    database, directory: directory.appending(path: SQLBlobStore.directoryName, directoryHint: .isDirectory))
            )
            let defaults = DefaultsPreferences()
            var parts = Parts(
                identity: identity,
                stores: stores,
                radio: BLERadio(log: log),
                log: log,
                preferences: defaults,
                classifier: DevicePhotoClassifier(log: log),
                textClassifier: DeviceTextClassifier(log: log)
            )
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

        #if DEBUG
            private static func demo(_ options: LaunchOptions) throws -> AppEnvironment {
                guard let identity = DemoSeed.identity else {
                    throw SecretStoreError.unavailable("the demo identity")
                }
                let clock = SystemClock()
                let log = UnifiedLog(clock: clock)
                // `scripts/check.sh release` fails when a release build holds this line: it would mean the demo ships.
                log.log(.info, "running the demo on seeded stores in memory")
                let stores = MeshStores.inMemory()
                DemoSeed.populate(
                    stores,
                    me: identity.nodeId,
                    now: clock.wallMilliseconds(),
                    scene: options.demoScene,
                    paint: DemoPortraits.profilePhoto,
                    snap: DemoPortraits.chatPhoto
                )
                let parts = Parts(
                    identity: identity,
                    stores: stores,
                    radio: DemoRadio(state: options.demoRadio),
                    log: log,
                    preferences: MemoryPreferences(hasOnboarded: !options.demoOnboarding),
                    classifier: DemoPhotoClassifier(flagsEverything: options.demoSensitive),
                    textClassifier: DemoTextClassifier(flagsEverything: options.demoSensitive),
                    linked: DemoSeed.linked(in: options.demoScene),
                    camera: options.demoCamera.map(DemoCamera.init),
                    demoPhoto: options.demoPhoto ? DemoPortraits.pickedPhoto() : nil,
                    notification: options.demoNotification ? DemoSeed.notification(in: stores, me: identity.nodeId) : nil
                )
                return compose(parts, replace: nil)
            }
        #endif

        /// What an environment is made from.
        private struct Parts {
            let identity: IdentityKeys
            let stores: MeshStores
            let radio: any Radio
            let log: any KnitLog
            let preferences: any AppPreferences
            /// The content filter's models: the bundled ones, or the demo's stand-ins under `-seedDemo`.
            let classifier: any PhotoClassifier
            let textClassifier: any TextClassifier
            /// The peers a demo scene shows as linked, which only a demo has.
            var linked: [NodeId] = []
            /// A demo's camera, under `-demoCamera`; otherwise the phone's.
            var camera: (any CameraAccess)?
            /// The picture Choose photo picks, under `-demoPhoto`.
            var demoPhoto: Data?
            /// What the demo posts as Knit goes to the background, under `-demoNotification`.
            var notification: LocalNotification?
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
                identity: OwnIdentity(bundle: parts.identity.bundle),
                stores: parts.stores,
                mesh: service,
                notifier: alerts,
                textScreening: TextScreening(classifier: parts.textClassifier, words: wordList(log: parts.log)),
                preferences: parts.preferences
            )
            let environment = AppEnvironment(
                session: app,
                mesh: node,
                radio: parts.radio as? BLERadio,
                preferences: parts.preferences,
                notifier: alerts,
                camera: parts.camera ?? DeviceCamera(),
                classifier: parts.classifier,
                textClassifier: parts.textClassifier,
                demoPhoto: parts.demoPhoto,
                demoNotification: parts.notification,
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
                    storage: parts.storage,
                    photos: environment.photos,
                    screening: environment.screening,
                    classifier: parts.classifier,
                    textClassifier: parts.textClassifier
                )
            #endif
            return environment
        }
    }

    // Apart from the class only to keep its body inside the lint's length.
    extension AppEnvironment {
        /// Knit went to the background, where iOS may suspend it, or came back. Control Center or an alert over Knit is
        /// neither: Knit is still on screen, and Android still finds it. Going posts `-demoNotification`'s notification.
        func setInBackground(_ background: Bool) {
            phases.continuation.yield(background)
            if background, let model {
                Task { await model.release() }
            }
            if let textModel {
                Task { await textModel.setInBackground(background) }
            }
            if background, let demoNotification {
                let alerts = notifier
                Task { await alerts.post(demoNotification) }
            }
        }

        /// Lets the filter's models go: memory runs low. The next photo or message screened loads its model again.
        func releaseModel() {
            if let model {
                Task { await model.release() }
            }
            if let textModel {
                Task { await textModel.release() }
            }
        }

        /// The Nearby room's word list, bundled as `Profanity.txt` (knit-next's `profanity_en.txt`). Without it the room
        /// screens with the model alone, and says so.
        private static func wordList(log: any KnitLog) -> WordFilter {
            guard let url = Bundle.main.url(forResource: "Profanity", withExtension: "txt"),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else {
                log.log(.warning, "text filter: Profanity.txt is not in the app, so Nearby is screened by the model alone")
                return WordFilter(words: [])
            }
            return WordFilter(list: text)
        }

        /// The database's own directory, under Application Support, which is backed up unless told otherwise; the
        /// store excludes it (ADR 2026-09.nyya).
        private static func databaseDirectory() throws -> URL {
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Database", directoryHint: .isDirectory)
        }
    }
#endif
