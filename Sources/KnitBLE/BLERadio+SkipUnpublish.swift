#if canImport(CoreBluetooth) && DEBUG
    import Foundation
    // Public here alone: the rest of KnitBLE's listener imports KnitMesh internally, and a release build has none of this.
    public import KnitMesh

    extension BLERadio {
        /// Leaves the next unpublish unsent while still arming its deadline, so the wait runs out as in run `3a7576`
        /// (knit/knit-ios#53) and the peripheral manager is recycled: the device probe for whether iOS takes a second
        /// manager under the same restore identifier. Answers the listener as it then stands, its recycles counted.
        public func skipNextUnpublish() async -> ListenerPublication {
            await withCheckedContinuation { continuation in
                core.onQueue { core in
                    core.skipsNextUnpublish = true
                    // `check.sh`'s release check reads this line as a debug path that shipped; keep the two in step.
                    core.log.log(.info, "ble will skip the next unpublish, as the debug bridge asked")
                    continuation.resume(returning: core.listener)
                }
            }
        }
    }
#endif
