public import Foundation
public import Observation

/// A saved report's screen (ADR 2026-10.qhsv, after Android's `CrashLogViewModel`): the newest report of one kind, its
/// text, the link that files it on GitHub, and the file the share sheet hands over. Every file is read off the main
/// actor.
@preconcurrency
@MainActor
@Observable
public final class CrashLogModel {
    /// A report as the screen shows it.
    public struct Loaded: Sendable, Equatable {
        /// The report.
        public var ref: CrashReportRef
        /// Its text.
        public var text: String
        /// The bug form's link, or `nil` when none could be made.
        public var issue: URL?
        /// A copy of it for the share sheet, or `nil` when none could be written.
        public var shareFile: URL?
    }

    /// The kind of report the screen shows.
    public let kind: CrashDiagnostic.Kind
    /// The report, or `nil` when none is saved or it is not read yet.
    public private(set) var report: Loaded?
    /// Whether the store has been read, so an empty screen says so only once it knows.
    public private(set) var isLoaded = false
    @ObservationIgnored private let store: CrashStore
    @ObservationIgnored private let shareDirectory: URL

    /// The screen for the newest report of `kind` in `store`, sharing from `shareDirectory`, which it empties first.
    @preconcurrency
    public init(
        store: CrashStore,
        kind: CrashDiagnostic.Kind,
        shareDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "CrashShare", directoryHint: .isDirectory)
    ) {
        self.store = store
        self.kind = kind
        self.shareDirectory = shareDirectory
    }

    /// Reads the newest report.
    public func load() async {
        report = await Task.detached { [store, kind, shareDirectory] in
            guard let ref = store.latest(kind), let text = store.read(ref) else {
                return nil
            }
            let issue = CrashIssueURL.forReport(ref, text: text)
            return Loaded(ref: ref, text: text, issue: issue, shareFile: store.exportForShare(ref, into: shareDirectory))
        }.value
        isLoaded = true
    }

    /// Deletes every saved report, crashes and hangs alike, and the shared copy.
    public func deleteAll() async {
        await Task.detached { [store, shareDirectory] in
            store.clear()
            try? FileManager.default.removeItem(at: shareDirectory)
        }.value
        report = nil
    }
}
