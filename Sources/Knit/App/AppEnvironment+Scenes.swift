#if os(iOS)
    import KnitAppCore
    import KnitBLE
    import KnitCrypto
    import KnitMesh
    import KnitStore
    import KnitWire

    // The environments that run a scene, apart from the class only to keep its file inside the lint's length.
    extension AppEnvironment {
        #if DEBUG
            static func demo(_ options: LaunchOptions) throws -> AppEnvironment {
                guard let identity = DemoSeed.identity else {
                    throw SecretStoreError.unavailable("the demo identity")
                }
                let clock = SystemClock()
                let log = UnifiedLog(clock: clock)
                // `scripts/check.sh release` fails when a release build holds this line: it would mean the demo ships.
                log.log(.info, "running the demo on seeded stores in memory")
                let stores = MeshStores.inMemory()
                let made = pictures(of: options.demoScene)
                DemoSeed.populate(
                    stores,
                    me: identity.nodeId,
                    now: clock.wallMilliseconds(),
                    scene: options.demoScene,
                    face: DemoPictures.profilePhoto,
                    snap: made.snap
                )
                var parts = Parts(
                    identity: identity,
                    stores: stores,
                    radio: DemoRadio(state: options.demoRadio),
                    log: log,
                    preferences: MemoryPreferences(
                        hasOnboarded: !options.demoOnboarding, acceptedTerms: options.demoOnboarding ? 0 : Terms.version
                    ),
                    classifier: DemoPhotoClassifier(flagsEverything: options.demoSensitive, flagging: made.flagged),
                    textClassifier: DemoTextClassifier(
                        flagsEverything: options.demoSensitive, flagging: options.demoScene.flaggedWords
                    ),
                    staging: DemoSeed.staging(in: options.demoScene),
                    director: DemoDirector(
                        scene: options.demoScene,
                        stores: stores,
                        me: identity.nodeId,
                        snap: made.snap,
                        now: { clock.wallMilliseconds() },
                        wait: { milliseconds in try? await Task.sleep(for: .milliseconds(milliseconds)) }
                    ),
                    camera: options.demoCamera.map(DemoCamera.init),
                    demoPhoto: options.demoPhoto ? DemoPictures.picked(moving: options.demoPhotoMoves) : nil,
                    notification: options.demoNotification ? DemoSeed.notification(in: stores, me: identity.nodeId) : nil
                )
                parts.shareInbox = options.demoShare.map(ShareContainer.demoInbox)
                return compose(parts, ratchet: false, replace: nil) // A demo keeps no prekeys and reaches no one.
            }
        #endif

        /// The sample chats (ADR 2026-11.pydf), which anyone can open in any build, beside `live`, which runs on under them. The
        /// scene's stores are in memory and its radio goes nowhere, so nothing here touches the Keychain, the database or the
        /// air, and nothing of it outlives ``close()``. Its identity is new each time and dies with it, unlike the demo's fixed
        /// one, whose keys anyone can derive from the source: a link or a code that leaves the sample names a key nobody
        /// holds, so nobody can read what is sent to it. Its faces stay initials in every build, as a store build must show
        /// them (ADR 2026-10.2acj). `live`'s filter models go on serving, and `live` keeps looking after them. The log is
        /// silent because `UnifiedLog` can't tell two meshes apart, and the harness reads its lines.
        static func sample(beside live: AppEnvironment) -> AppEnvironment {
            let identity = IdentityKeys.generate()
            let clock = SystemClock()
            let stores = MeshStores.inMemory()
            let scene = DemoScene.sample
            let made = pictures(of: scene)
            DemoSeed.populate(stores, me: identity.nodeId, now: clock.wallMilliseconds(), scene: scene, snap: made.snap)
            var parts = Parts(
                identity: identity,
                stores: stores,
                radio: DemoRadio(state: .on),
                log: SilentLog(),
                preferences: MemoryPreferences(hasOnboarded: true, acceptedTerms: Terms.version),
                classifier: SamplePhotoClassifier(flagging: made.flagged, device: live.model),
                textClassifier: SampleTextClassifier(scene: scene, device: live.textModel),
                staging: DemoSeed.staging(in: scene),
                director: DemoDirector(
                    scene: scene,
                    stores: stores,
                    me: identity.nodeId,
                    snap: made.snap,
                    now: { clock.wallMilliseconds() },
                    wait: { milliseconds in try? await Task.sleep(for: .milliseconds(milliseconds)) }
                )
            )
            parts.isSample = true
            return compose(parts, ratchet: false, replace: nil) // A sample keeps no prekeys and reaches no one.
        }

        /// `scene`'s photos: the ones its filter flags, each made once so the bytes the filter knows are the ones every post
        /// of it carries (ADR 2026-10.yddp), and what makes any of them.
        private static func pictures(of scene: DemoScene) -> (flagged: Set<[UInt8]>, snap: @Sendable (DemoSnapshot) -> [UInt8]?) {
            let flagged = Dictionary(
                uniqueKeysWithValues: scene.flaggedPhotos.compactMap { picture in
                    DemoPictures.chatPhoto(picture).map { (picture, $0) }
                }
            )
            return (Set(flagged.values), { picture in flagged[picture] ?? DemoPictures.chatPhoto(picture) })
        }
    }
#endif
