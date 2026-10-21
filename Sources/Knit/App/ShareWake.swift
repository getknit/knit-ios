#if os(iOS)
    import CoreFoundation
    import Foundation

    /// Hears the Darwin notification the share sheet posts once it leaves a share (ADR 2026-10.z7a8), so a Knit that is
    /// running drains it at once. A suspended Knit hears nothing, and drains at its next wake or at the front instead.
    internal final class ShareWake: Sendable {
        private let heard: @Sendable () -> Void

        /// Calls `heard` each time the notification `name` is posted, until this is released.
        init(name: String, heard: @escaping @Sendable () -> Void) {
            self.heard = heard
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, _, _, _ in
                    guard let observer else {
                        return
                    }
                    // The observer is this object, which removes itself before it goes.
                    Unmanaged<ShareWake>.fromOpaque(observer).takeUnretainedValue().heard()
                },
                name as CFString,
                nil,
                .deliverImmediately
            )
        }

        deinit {
            CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
        }
    }
#endif
