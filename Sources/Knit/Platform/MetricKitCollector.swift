#if os(iOS)
    import Foundation
    import KnitAppCore
    import MetricKit

    /// Hands MetricKit's crash and hang diagnostics to the saved reports (ADR 2026-10.qhsv). MetricKit gives a diagnostic
    /// to the launch after the one that crashed or hung: once as it arrives, and again among its past payloads at every
    /// launch, so a diagnostic that came before the first unlock, when the store cannot be written, is saved at the next
    /// import instead. The store sees each diagnostic once whichever way it came.
    ///
    /// The metadata is read through MetricKit's typed API; only the call-stack tree goes over as its JSON. An Objective-C
    /// exception's arguments and the message composed from them are never read: they are the one place a runtime value,
    /// a name for one, could ride into a report.
    internal final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, Sendable {
        private static let millisecondsPerSecond = 1000.0

        private let store: CrashStore

        init(store: CrashStore) {
            self.store = store
        }

        /// Subscribes, and imports what MetricKit already holds, off the main thread: this runs at every launch, the
        /// background ones that restore Bluetooth among them.
        func start() {
            MXMetricManager.shared.add(self)
            importPast()
        }

        /// Imports MetricKit's past payloads again: called once protected data is available, for whatever a launch before
        /// the first unlock could not write.
        func importPast() {
            Task.detached(priority: .utility) { [store] in
                store.importDiagnostics(MXMetricManager.shared.pastDiagnosticPayloads.flatMap(Self.diagnostics))
            }
        }

        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            store.importDiagnostics(payloads.flatMap(Self.diagnostics))
        }

        /// `payload`'s crashes and hangs as plain values.
        private static func diagnostics(_ payload: MXDiagnosticPayload) -> [KnitAppCore.CrashDiagnostic] {
            let at = Int64(payload.timeStampEnd.timeIntervalSince1970 * millisecondsPerSecond)
            let crashes = (payload.crashDiagnostics ?? []).map { crash in
                var diagnostic = base(crash, kind: .crash, at: at)
                diagnostic.exceptionType = crash.exceptionType?.intValue
                diagnostic.exceptionCode = crash.exceptionCode?.intValue
                diagnostic.signal = crash.signal?.intValue
                diagnostic.terminationReason = crash.terminationReason
                diagnostic.regionInfo = crash.virtualMemoryRegionInfo
                diagnostic.objectiveC = crash.exceptionReason.map { reason in
                    KnitAppCore.CrashDiagnostic.ObjectiveCException(
                        name: reason.exceptionName, className: reason.className, format: reason.formatString)
                }
                return diagnostic
            }
            let hangs = (payload.hangDiagnostics ?? []).map { hang in
                var diagnostic = base(hang, kind: .hang, at: at)
                diagnostic.hangSeconds = hang.hangDuration.converted(to: .seconds).value
                return diagnostic
            }
            return crashes + hangs
        }

        private static func base<Diagnostic: MXDiagnostic & MXCallStackHolding>(
            _ diagnostic: Diagnostic, kind: KnitAppCore.CrashDiagnostic.Kind, at: Int64
        ) -> KnitAppCore.CrashDiagnostic {
            let meta = diagnostic.metaData
            #if DEBUG
                let channel = KnitAppCore.CrashDiagnostic.Channel.debug
            #else
                let channel: KnitAppCore.CrashDiagnostic.Channel = meta.isTestFlightApp ? .testFlight : .appStore
            #endif
            return KnitAppCore.CrashDiagnostic(
                kind: kind,
                at: at,
                appVersion: diagnostic.applicationVersion,
                appBuild: meta.applicationBuildVersion,
                channel: channel,
                device: meta.deviceType,
                system: meta.osVersion,
                architecture: meta.platformArchitecture,
                callStacks: diagnostic.callStacks.jsonRepresentation()
            )
        }
    }

    extension CrashStore {
        /// The app's own reports, in Application Support, which the collector fills and Diagnostics reads.
        static let live = CrashStore(root: URL.applicationSupportDirectory.appending(path: directoryName, directoryHint: .isDirectory))
    }

    /// The two diagnostics that carry a call-stack tree, under one name.
    private protocol MXCallStackHolding {
        var callStacks: MXCallStackTree { get }
    }

    extension MXCrashDiagnostic: MXCallStackHolding {
        fileprivate var callStacks: MXCallStackTree { callStackTree }
    }

    extension MXHangDiagnostic: MXCallStackHolding {
        fileprivate var callStacks: MXCallStackTree { callStackTree }
    }
#endif
