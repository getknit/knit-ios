public import Foundation
import KnitSync

/// A saved report, as Diagnostics lists it: what its file name and header say.
public struct CrashReportRef: Sendable, Equatable, Identifiable {
    /// The kind.
    public var kind: CrashDiagnostic.Kind
    /// When it happened, in wall milliseconds.
    public var at: Int64
    /// Its ``CrashReport/fingerprint``.
    public var fingerprint: String
    /// The file's name in the store.
    public var fileName: String
    /// Its ``CrashReport/summary``.
    public var summary: String
    /// The build that failed, with its channel: `1.0.0 (4) TestFlight`.
    public var app: String
    /// The model identifier.
    public var device: String
    /// The system and its build.
    public var system: String

    /// The file's name, which is unique in the store.
    public var id: String { fileName }

    /// The build's version and number alone, as the issue form's version field wants them: `1.0.0 (4)`.
    public var version: String {
        guard let close = app.firstIndex(of: ")") else {
            return app
        }
        return String(app[...close])
    }
}

/// The reports this iPhone has kept (ADR 2026-10.qhsv, after knit-next's ADR 028 and ADR 2026-10.fzsy): one text file
/// per diagnostic in a directory out of every backup, at most ``maxPerKind`` of each kind and ``maxPerFingerprint`` of
/// one failure, so a crash loop or a run of hangs never pushes out a report of something else. Nothing here sends a
/// report anywhere; the user copies it, shares it or files it.
///
/// MetricKit may hand a diagnostic over more than once: as it arrives, and again from its past payloads after a launch
/// before the first unlock, when the store cannot be written. A list of the keys already imported beside the reports
/// (`seen`, which ``clear()`` keeps) makes each one import once, so a report the user deleted never comes back.
public struct CrashStore: Sendable {
    /// The most reports kept of each kind.
    public static let maxPerKind = 5
    /// The most kept of one fingerprint.
    public static let maxPerFingerprint = 2
    /// A hang shorter than this, in seconds, is not kept: MetricKit reports far shorter ones, and a report of each would
    /// push out the hangs a person noticed.
    public static let minimumHangSeconds = 1.0
    /// The most keys `seen` remembers, far more than MetricKit keeps past payloads for.
    public static let maxSeen = 256
    /// The directory's name under Application Support.
    public static let directoryName = "CrashReports"

    private static let seenName = "seen"
    private static let headerBytes = 4096
    private static let stampDigits = 13
    private static let fingerprintDigits = 8

    /// The directory.
    public let root: URL
    // Imports run one at a time: MetricKit's callback and a launch's re-read of past payloads can overlap, and the
    // check against `seen` and the write that follows it must not.
    private let importing = Lock(())

    /// A store in `root`, which it creates on the first import.
    public init(root: URL) {
        self.root = root
    }

    /// Saves each of `diagnostics` not imported before, a hang shorter than ``minimumHangSeconds`` aside, then prunes.
    /// Returns how many it saved. A diagnostic it could not write, before the first unlock, stays unseen, for the next
    /// import to try again.
    @discardableResult
    public func importDiagnostics(_ diagnostics: [CrashDiagnostic]) -> Int {
        importing.withLock { _ in
            let kept = diagnostics.filter { $0.kind == .crash || ($0.hangSeconds ?? 0) >= Self.minimumHangSeconds }
            guard !kept.isEmpty, (try? prepare()) != nil else {
                return 0
            }
            var seen = readSeen()
            var saved = 0
            for report in kept.map(CrashReport.init) where !seen.contains(report.key) && write(report) {
                seen.append(report.key)
                saved += 1
            }
            if saved > 0 {
                writeSeen(Array(seen.suffix(Self.maxSeen)))
                for kind in CrashDiagnostic.Kind.allCases {
                    prune(kind)
                }
            }
            return saved
        }
    }

    /// The newest report of `kind`, or `nil` when none is kept.
    public func latest(_ kind: CrashDiagnostic.Kind) -> CrashReportRef? {
        names(kind).lazy.compactMap(ref).first
    }

    /// Every report of `kind`, newest first.
    public func list(_ kind: CrashDiagnostic.Kind) -> [CrashReportRef] {
        names(kind).compactMap(ref)
    }

    /// The text of `ref`, or `nil` when it is gone.
    public func read(_ ref: CrashReportRef) -> String? {
        (try? Data(contentsOf: file(ref.fileName))).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// `ref` copied into `directory`, emptied first, under a name that says what it is, for the share sheet:
    /// `knit-crash-1.0.0-20261023-0914.txt`. `nil` when it cannot be.
    public func exportForShare(_ ref: CrashReportRef, into directory: URL, timeZone: TimeZone = .current) -> URL? {
        guard let text = read(ref) else {
            return nil
        }
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        guard (try? manager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let version = String(ref.app.prefix { $0 != " " }.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" })
        let name =
            "knit-\(ref.kind.name)-\(version.isEmpty ? "unknown" : version)-\(formatter.string(from: Date(milliseconds: ref.at))).txt"
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        return (try? Data(text.utf8).write(to: url, options: .atomic)).map { url }
    }

    /// Deletes every report. `seen` stays, so none comes back.
    public func clear() {
        for kind in CrashDiagnostic.Kind.allCases {
            for name in names(kind) {
                try? FileManager.default.removeItem(at: file(name))
            }
        }
    }

    // MARK: Files

    private func file(_ name: String) -> URL {
        root.appending(path: name, directoryHint: .notDirectory)
    }

    /// The report files of `kind`, newest first, by their names alone: a file's own dates are an API the privacy
    /// manifest would have to give a reason for.
    private func names(_ kind: CrashDiagnostic.Kind) -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        return all.filter { Self.parse($0)?.kind == kind }.sorted(by: >)
    }

    /// What a report's file name says: `crash-<13 digits>-<8 hex>.txt`.
    struct FileName: Equatable {
        var kind: CrashDiagnostic.Kind
        var at: Int64
        var fingerprint: String
    }

    /// The kind, time and fingerprint in `name`, or `nil` when it is not a report's.
    static func parse(_ name: String) -> FileName? {
        guard name.hasSuffix(".txt") else {
            return nil
        }
        let stem = name.dropLast(".txt".count)
        guard let dash = stem.firstIndex(of: "-"), let kind = CrashDiagnostic.Kind(name: stem[..<dash]) else {
            return nil
        }
        let rest = stem[stem.index(after: dash)...]
        let stamp = rest.prefix(stampDigits)
        let fingerprint = rest.dropFirst(stampDigits + 1)
        guard stamp.count == stampDigits, stamp.allSatisfy(isDigit), let at = Int64(stamp), rest.dropFirst(stampDigits).first == "-",
            fingerprint.count == fingerprintDigits, fingerprint.allSatisfy(isLowerHex)
        else {
            return nil
        }
        return FileName(kind: kind, at: at, fingerprint: String(fingerprint))
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func isLowerHex(_ character: Character) -> Bool {
        isDigit(character) || ("a"..."f").contains(character)
    }

    static func name(_ kind: CrashDiagnostic.Kind, at: Int64, fingerprint: String) -> String {
        let stamp = String(max(0, at))
        return "\(kind.name)-\(String(repeating: "0", count: max(0, stampDigits - stamp.count)))\(stamp)-\(fingerprint).txt"
    }

    /// `name`'s header as a reference, or `nil` when the file is unreadable or holds no header.
    private func ref(_ name: String) -> CrashReportRef? {
        guard let parsed = Self.parse(name), let bytes = head(name) else {
            return nil
        }
        // swiftlint:disable:next optional_data_string_conversion - a 4 KiB read can end inside a character; the header is ASCII
        let header = String(decoding: bytes, as: UTF8.self)
        var fields: [String: String] = [:]
        for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == CrashReport.separator {
                break
            }
            if let colon = line.range(of: ": ") {
                fields[String(line[..<colon.lowerBound])] = String(line[colon.upperBound...])
            }
        }
        guard let summary = fields["summary"] else {
            return nil
        }
        return CrashReportRef(
            kind: parsed.kind,
            at: parsed.at,
            fingerprint: parsed.fingerprint,
            fileName: name,
            summary: summary,
            app: fields["app"] ?? "",
            device: fields["device"] ?? "",
            system: fields["ios"] ?? ""
        )
    }

    /// The first bytes of `name`, enough for its header, or `nil` when it cannot be read.
    private func head(_ name: String) -> Data? {
        let handle = try? FileHandle(forReadingFrom: file(name))
        defer { try? handle?.close() }
        return try? handle?.read(upToCount: Self.headerBytes)
    }

    /// Writes `report` under a name of its own, a millisecond later when two land on one. Returns whether it did.
    private func write(_ report: CrashReport) -> Bool {
        var at = report.at
        while FileManager.default.fileExists(atPath: file(Self.name(report.kind, at: at, fingerprint: report.fingerprint)).path) {
            at += 1
        }
        let url = file(Self.name(report.kind, at: at, fingerprint: report.fingerprint))
        return (try? Data(report.text.utf8).write(to: url, options: Self.writing)) != nil
    }

    /// Keeps the newest ``maxPerKind`` of `kind`, no more than ``maxPerFingerprint`` of one fingerprint among them.
    private func prune(_ kind: CrashDiagnostic.Kind) {
        var kept = 0
        var perFingerprint: [String: Int] = [:]
        for (name, parsed) in names(kind).compactMap({ name in Self.parse(name).map { (name, $0) } }) {
            let same = perFingerprint[parsed.fingerprint, default: 0]
            if kept < Self.maxPerKind, same < Self.maxPerFingerprint {
                kept += 1
                perFingerprint[parsed.fingerprint] = same + 1
            } else {
                try? FileManager.default.removeItem(at: file(name))
            }
        }
    }

    private func readSeen() -> [String] {
        guard let data = try? Data(contentsOf: file(Self.seenName)) else {
            return []
        }
        return (String(bytes: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
    }

    private func writeSeen(_ keys: [String]) {
        try? Data((keys.joined(separator: "\n") + "\n").utf8).write(to: file(Self.seenName), options: Self.writing)
    }

    // MARK: Protection

    /// Creates the directory with the database's protection, and out of every backup (ADR 2026-09.nyya), as
    /// KnitStoreSQL's `StorageDirectory` does for its own: a report written in a pocket must be readable while the phone
    /// stays locked, and must not leave it in a backup.
    private func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path(percentEncoded: false))
        #endif
        #if canImport(Darwin)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = root
            try url.setResourceValues(values)
        #endif
    }

    private static var writing: Data.WritingOptions {
        #if os(iOS)
            [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
            .atomic
        #endif
    }
}
