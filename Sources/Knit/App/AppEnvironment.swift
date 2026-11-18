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

    /// Everything a running app holds: the identity, the stores, the radio, the mesh and the session every screen reads (the
    /// composition root). A launch builds one, the live one, which lasts as long as the process. `-seedDemo` builds the same
    /// thing over seeded stores in memory and a radio that goes nowhere, and so do the sample chats, beside the live one,
    /// for as long as they stay open (ADR 2026-11.pydf).
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
        let model: DevicePhotoClassifier?
        /// The filter's text model, which lets go soon after its last message in the background; a demo's has none.
        let textModel: DeviceTextClassifier?
        /// What Choose photo picks under `-demoPhoto`: a demo photo, since the system's picker is out of a UI test's
        /// reach. `nil` opens the photo library.
        let demoPhoto: Data?
        /// What `-demoNotification` posts each time Knit goes to the background, since nothing reaches the demo that
        /// would: a UI test taps it to open its thread.
        let demoNotification: LocalNotification?
        let about: AboutInfo
        /// The share sheet's side of the App Group (ADR 2026-10.z7a8), or `nil` when Knit has no container to share.
        let shares: ShareHost?
        // periphery:ignore - held, never read: the Darwin observer goes with its last reference
        /// The share sheet's call that it left a share, heard while Knit runs.
        private var shareWake: ShareWake?
        /// Stores a minted test identity for the next launch, in a debug build.
        let replaceIdentity: IdentityReplacer?
        /// The saved crash and hang reports (ADR 2026-10.qhsv): none in a demo but `-demoCrash`'s.
        private(set) var crashes: CrashStore?
        /// The CoreBluetooth radio, which a demo has none of.
        private let radio: BLERadio?
        /// The mesh, which hears whether Knit is in the background so its links seek peers there (ADR 2026-10.mueg).
        private let mesh: Mesh
        /// The one serial stream into the mesh: Knit going to the background and coming back, and the relays' gate and list,
        /// in order, so a quick toggle cannot overtake the one before it (ADR 2026-11.adrq, P6).
        let phases: MeshPhases
        /// Internet relays' settings, in a debug build's live launch, or a demo's under `-demoRelays`; `nil` everywhere else,
        /// a store build's always (ADR 2026-11.adrq, P6).
        var relays: InternetRelays?
        private var listening: Task<Void, Never>?
        /// The mesh's first start, which ``close()`` waits for: a stop that overtook it would leave the mesh running.
        private var starting: Task<Void, Never>?
        /// The scene's mesh, in a demo or the sample chats, which ``close()`` ends.
        private var demoMesh: DemoMesh?
        #if DEBUG
            /// The debug bridge, which a computer reaches over USB, or over Wi-Fi on a network pinned over USB.
            private var bridge: Bridge?
        #endif

        private init(
            session: AppSession,
            mesh: Mesh,
            phases: MeshPhases,
            radio: BLERadio?,
            preferences: any AppPreferences,
            notifier: LocalNotifier,
            camera: any CameraAccess,
            classifier: any PhotoClassifier,
            textClassifier: any TextClassifier,
            demoPhoto: Data?,
            demoNotification: LocalNotification?,
            shareInbox: ShareInbox?,
            replaceIdentity: IdentityReplacer?
        ) {
            self.session = session
            self.mesh = mesh
            self.phases = phases
            self.radio = radio
            self.preferences = preferences
            self.notifier = notifier
            self.camera = camera
            self.demoPhoto = demoPhoto
            self.demoNotification = demoNotification
            self.replaceIdentity = replaceIdentity
            photos = BlobImageCache(session: session)
            let screener = PhotoScreening(classifier: classifier, session: session)
            screening = screener
            model = classifier as? DevicePhotoClassifier
            shares = shareInbox.map { ShareContainer.host(inbox: $0, session: session, filter: screener, settings: preferences) }
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
            // A relaunch to restore Bluetooth runs in the background, with no scene to say so. The links hear it; the spool
            // waits for the scene's own `.active` (``SpoolLifecycle``).
            phases.send(.launched(background: UIApplication.shared.applicationState == .background))
            #if DEBUG
                bridge?.start()
            #endif
            if preferences.hasOnboarded {
                starting = Task { await running.start() }
            }
            shareWake = shares.flatMap(ShareContainer.start)
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

        /// The environment `options` ask for, on a launch that went as `launch` says, with `crashes` the saved reports.
        /// Throws when the Keychain or the database cannot be read yet, before the first unlock since a reboot: the app
        /// then waits for protected data rather than making a new identity. Only a debug build runs the demo.
        static func make(_ options: LaunchOptions, launch: Launch.History, crashes: CrashStore) throws -> AppEnvironment {
            #if DEBUG
                if options.seedDemo {
                    let environment = try demo(options)
                    environment.crashes = options.demoCrash ? DemoCrash.store(now: SystemClock().wallMilliseconds()) : nil
                    return environment
                }
            #endif
            let environment = try live(launch, options: options)
            environment.crashes = crashes
            return environment
        }

        private static func live(_ launch: Launch.History, options: LaunchOptions) throws -> AppEnvironment {
            let keyStore = KeychainSecretStore()
            let identity = try IdentityKeys.load(from: keyStore).keys
            let log = UnifiedLog(clock: SystemClock())
            let directory = try AppStorage.databaseDirectory()
            let database = try KnitDatabase.open(in: directory) { error in log.log(.warning, "store failed: \(error)") }
            let stores = MeshStores(
                custody: SQLCustodyStore(database),
                peers: SQLPeerStore(database),
                messages: SQLMessageStore(database),
                conversations: SQLConversationStore(database),
                blocks: SQLBlockStore(database),
                groups: SQLGroupStore(database),
                ownProfile: SQLOwnProfileStore(database),
                blobs: try SQLBlobStore(
                    database, directory: directory.appending(path: SQLBlobStore.directoryName, directoryHint: .isDirectory)),
                ratchet: SQLRatchetStore(database),
                groupRatchet: SQLGroupRatchetStore(database),
                presenceKeys: SQLPresenceKeyStore(database),
                transactor: database // The store unit is the database itself, under every SQL store above (ADR 2026-10.5sk9).
            )
            let defaults = DefaultsPreferences()
            // One switch, read once, sets the writer and the radio's expectation of the doorbell's own service (ADR 2026-11.prsp).
            let blind = blindAdvert(options, log: log)
            var parts = Parts(
                identity: identity,
                // The ratchet's, kept in the identity's own item (ADR 2026-10.5sk9): read, never written, throwing as above.
                prekeys: try PrekeyRing.load(for: identity, from: keyStore),
                stores: stores,
                radio: BLERadio(log: log, expectsBlinding: blind.switchOn),
                log: log,
                preferences: defaults,
                classifier: DevicePhotoClassifier(log: log),
                textClassifier: DeviceTextClassifier(log: log)
            )
            parts.links = blind.links
            parts.shareInbox = ShareContainer.inbox()
            parts.partials = AppStorage.partials(in: directory, database: database, log: log)
            #if DEBUG
                parts.storage = StorageReport(
                    nodeId: identity.nodeId, keyStore: keyStore, directory: directory, preferences: defaults, launch: launch)
                // The device tests pick a demo photo too: the system's picker is out of their reach.
                parts.demoPhoto = options.demoPhoto ? DemoPictures.picked(moving: options.demoPhotoMoves) : nil
                parts.demoVoice = options.demoVoice ? DemoVoice.reply() : nil
                // The live environment alone dials relays (ADR 2026-11.adrq, P6), and reads their list here, after the identity.
                return liveWithRelays(parts, ratchet: options.ratchet, preferences: defaults) { keys in try keyStore.write(keys.storedForm)
                }
            #else
                return compose(parts, ratchet: options.ratchet, replace: nil)
            #endif
        }

        /// What an environment is made from.
        struct Parts {
            let identity: IdentityKeys
            /// The ratchet prekeys kept beside the identity; a demo keeps none.
            var prekeys: PrekeyRing?
            let stores: MeshStores
            let radio: any Radio
            let log: any KnitLog
            let preferences: any AppPreferences
            /// The content filter's models: the bundled ones, or the demo's stand-ins under `-seedDemo`.
            let classifier: any PhotoClassifier
            let textClassifier: any TextClassifier
            /// Who a demo scene shows linked and typing, and its photos on their way, which only a demo has.
            var staging = DemoMesh.Staging()
            /// What plays a demo scene's script, under `-demoScene trailer`.
            var director: DemoDirector?
            /// A demo's camera, under `-demoCamera`; otherwise the phone's.
            var camera: (any CameraAccess)?
            /// The picture Choose photo picks, under `-demoPhoto`.
            var demoPhoto: Data?
            /// The clip the mic records, under `-demoVoice`; a release build has none.
            var demoVoice: [UInt8]?
            /// What the demo posts as Knit goes to the background, under `-demoNotification`.
            var notification: LocalNotification?
            /// The share sheet's inbox: the App Group's in a live launch, or a folder of the demo's own under `-demoShare`.
            var shareInbox: ShareInbox?
            /// Where cut attachments' prefixes are kept: on disk beside the blobs in a live launch, in memory otherwise.
            var partials: (any PartialBlobStore)?
            /// The links' configuration: the blinded advert's gate and switch in a live launch (``blindAdvert(_:log:)``), the
            /// defaults otherwise.
            var links = LinkManager.Configuration()
            /// Whether this is the sample chats, which run beside the live environment (ADR 2026-11.pydf): they take no
            /// device tag, post no notification, set no badge and open no debug bridge, each of which is the live one's.
            var isSample = false
            /// What opens relays' sockets: a debug build's live launch alone has one (ADR 2026-11.adrq, P6).
            var spoolSockets: (any SpoolSocketFactory)?
            /// Whether relays run over ``DemoRelays``, which opens nothing, under `-demoRelays`.
            var demoRelays = false
            #if DEBUG
                /// What the debug bridge's `storage` reply reads, which only a live launch has.
                var storage: StorageReport?
            #endif
        }

        static func compose(_ parts: Parts, ratchet: Bool, replace: IdentityReplacer?) -> AppEnvironment {
            let clock = SystemClock()
            // The session draws cards only where the profile promises it, so one switch sets both.
            let previews = linkPreviews(log: parts.log)
            let node = mesh(parts, ratchet: ratchet, linkPreviews: previews != nil, clock: clock)
            let alerts = LocalNotifier()
            let shows = !parts.staging.isEmpty || parts.director != nil
            let shown = shows ? DemoMesh(node, staging: parts.staging, director: parts.director) : nil
            let service: any MeshService = shown ?? node as any MeshService
            let app = session(parts, over: service, notifying: parts.isSample ? nil : alerts, linkPreviews: previews)
            app.director = parts.director
            let environment = AppEnvironment(
                session: app,
                mesh: node,
                phases: MeshPhases(target: parts.demoRelays ? DemoRelays(over: node) : node),
                radio: parts.radio as? BLERadio,
                preferences: parts.preferences,
                notifier: alerts,
                camera: parts.camera ?? DeviceCamera(),
                classifier: parts.classifier,
                textClassifier: parts.textClassifier,
                demoPhoto: parts.demoPhoto,
                demoNotification: parts.notification,
                shareInbox: parts.shareInbox,
                replaceIdentity: replace
            )
            environment.demoMesh = shown
            #if DEBUG
                if !parts.isSample {
                    environment.bridge = bridge(of: environment, parts, mesh: node, clock: clock)
                }
            #endif
            return environment
        }
    }

    // Apart from the class only to keep its body inside the lint's length.
    extension AppEnvironment {
        #if DEBUG
            /// The debug bridge of `environment`, which only the live environment or a demo opens.
            private static func bridge(of environment: AppEnvironment, _ parts: Parts, mesh: Mesh, clock: SystemClock) -> Bridge {
                Bridge(
                    session: environment.session,
                    mesh: mesh,
                    radio: environment.radio,
                    bundle: parts.identity.bundle,
                    clock: clock,
                    log: parts.log,
                    version: "\(environment.about.version) (\(environment.about.build))",
                    storage: parts.storage,
                    photos: environment.photos,
                    screening: environment.screening,
                    classifier: parts.classifier,
                    textClassifier: parts.textClassifier,
                    advert: AdvertSwitchDefaults(build: parts.links.blindsAdvert, radio: environment.radio)
                )
            }
        #endif

        #if DEBUG
            /// Gives the debug bridge `launch`'s ways to the sample chats (``SampleCommand``) and to a thread (``ThreadCommand``).
            func offerSample(_ launch: Launch) {
                bridge?.threads.open = { [weak launch] conversation in launch?.open(conversation: conversation) }
                bridge?.sample.isOpen = { [weak launch] in launch?.sample != nil }
                bridge?.sample.set = { [weak launch] open in
                    if open {
                        launch?.openSample()
                    } else {
                        launch?.closeSample()
                    }
                }
            }
        #endif

        /// Ends the sample chats' environment, which closes while Knit runs on (ADR 2026-11.pydf): the mesh stops, the session
        /// stops listening, and the director's task, which holds the scene's mesh, ends with it. The live environment never
        /// comes here: it lasts as long as the process.
        func close() {
            let started = starting
            let running = session
            listening?.cancel()
            phases.finish()
            demoMesh?.end()
            Task {
                await started?.value
                await running.stop()
            }
        }
    }
#endif
