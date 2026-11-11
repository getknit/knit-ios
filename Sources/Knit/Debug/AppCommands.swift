#if os(iOS) && DEBUG
    import KnitAppCore
    import KnitBLE
    import KnitControl

    /// The bridge's commands that only the app answers, past the Wi-Fi gate's and the mesh's own (``Bridge``): each finds
    /// what it reads here, as the bridge was handed it. Apart from `Bridge` only to keep its initializer inside the lint's
    /// length.
    internal struct AppCommands: Sendable {
        let session: AppSession
        let radio: BLERadio?
        let storage: StorageReport?
        let photos: BlobImageCache
        let screening: PhotoScreening
        let classifier: any PhotoClassifier
        let textClassifier: any TextClassifier
        let takes: ScreenRecording
        let door: SampleDoor

        /// The reply to `line`, or `nil` when it is none of these commands.
        func answer(_ line: String) async -> String? {
            if let probe = ScanProbeCommand.parse(line) {
                return await probe.answer(radio)
            }
            if let ask = StorageCommand.parse(line) {
                return await ask.answer(storage)
            }
            if let ask = PhotosCommand.parse(line) {
                return await ask.answer(session, photos: photos, screening: screening)
            }
            if let ask = VoiceCommand.parse(line) {
                return await ask.answer(session)
            }
            if let ask = ScreenCommand.parse(line) {
                return await ask.answer(classifier)
            }
            if let ask = ScreenTextCommand.parse(line) {
                return await ask.answer(textClassifier)
            }
            if let ask = RecordCommand.parse(line) {
                return await ask.answer(takes)
            }
            if let ask = CrashCommand.parse(line) {
                return await ask.answer(.live)
            }
            if let ask = SampleCommand.parse(line) {
                return await ask.answer(door)
            }
            if let ask = LinkPreviewCommand.parse(line) {
                return await ask.answer(session, screening: screening)
            }
            return nil
        }
    }
#endif
