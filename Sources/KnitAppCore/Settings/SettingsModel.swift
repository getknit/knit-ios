public import Observation

/// A component that ships inside the app, for About's notices (`THIRD-PARTY-NOTICES.md`, "Shipped in the app").
public struct ThirdPartyNotice: Sendable, Equatable, Identifiable {
    /// The SwiftPM package identity.
    public var id: String
    /// The project's name.
    public var name: String
    /// The SPDX licence id.
    public var license: String
    /// The project's home.
    public var url: String

    /// What ships, kept equal to the notices file by a test.
    public static let shipped = [
        Self(id: "grdb.swift", name: "GRDB.swift", license: "MIT", url: "https://github.com/groue/GRDB.swift"),
        Self(id: "swift-crypto", name: "Swift Crypto", license: "Apache-2.0", url: "https://github.com/apple/swift-crypto"),
    ]
}

/// What About shows.
public struct AboutInfo: Sendable, Equatable {
    /// Where the source lives: the public mirror the repo opens as (`.agents/specs/mvp.md`, P0 hosting).
    public static let sourceURL = "https://github.com/getknit/knit-ios"

    /// The marketing version, `CFBundleShortVersionString`.
    public var version: String
    /// The build number, `CFBundleVersion`.
    public var build: String

    /// About for `version` and `build`.
    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    /// The version line.
    public var versionLine: String {
        Copy.About.version(version, build: build)
    }
}

/// Settings' view model: Stop and Start, notifications, and the rows out to the profile, About and Diagnostics.
@preconcurrency
@MainActor
@Observable
public final class SettingsModel {
    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let permission: (any NotificationPermission)?
    /// Whether the app may notify.
    public private(set) var notifications = NotificationAuthorization.notDetermined
    /// What About shows.
    public let about: AboutInfo

    /// Settings over `session`, asking for notifications through `permission`.
    public init(session: AppSession, permission: (any NotificationPermission)?, about: AboutInfo) {
        self.session = session
        self.permission = permission
        self.about = about
    }

    /// Whether the mesh runs.
    public var isRunning: Bool {
        session.isRunning
    }

    /// The profile row's title: our own label.
    public var profileTitle: String {
        session.directory.label(for: session.identity.nodeId).text
    }

    /// Stops a running mesh, or starts a stopped one.
    public func toggleMesh() async {
        if session.isRunning {
            await session.stop()
        } else {
            await session.start()
        }
    }

    /// Reads the notification permission again, as the app returns to the front.
    public func refresh() async {
        notifications = await permission?.authorization() ?? .denied
    }

    /// Asks for notifications, once.
    public func requestNotifications() async {
        notifications = await permission?.request() ?? .denied
    }
}
