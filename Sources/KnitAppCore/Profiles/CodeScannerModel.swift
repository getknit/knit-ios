public import Observation

/// Whether the app may use the camera.
public enum CameraAuthorization: Sendable, Equatable {
    /// Not asked yet.
    case notDetermined
    /// Allowed.
    case allowed
    /// Refused or restricted: only the Settings app can change it.
    case denied
}

/// Where the scanner reaches the camera: VisionKit and AVFoundation in the app, a stand-in in tests and `-seedDemo`.
public protocol CameraAccess: Sendable {
    /// Whether this device can scan codes at all. VisionKit's scanner needs an A12 or later, and the Simulator has none.
    func canScan() async -> Bool
    /// The current answer.
    func authorization() async -> CameraAuthorization
    /// Asks, when not asked yet, and answers the result.
    func request() async -> CameraAuthorization
}

/// The scanner sheet's view model: whether the camera can run, and what to say when it cannot (ADR 2026-10.65xx).
@preconcurrency
@MainActor
@Observable
public final class CodeScannerModel {
    /// What the sheet shows.
    public enum Phase: Sendable, Equatable, CaseIterable {
        /// Finding out whether it can scan.
        case checking
        /// The camera is up.
        case scanning
        /// The camera permission is refused.
        case denied
        /// This device cannot scan.
        case unsupported
        /// The camera failed to start.
        case unavailable
    }

    /// What the sheet shows now.
    public private(set) var phase = Phase.checking

    @ObservationIgnored private let camera: any CameraAccess
    @ObservationIgnored private var preparing = false

    /// A scanner over `camera`.
    public init(camera: any CameraAccess) {
        self.camera = camera
    }

    /// Finds out whether the camera can run, asking for it the first time. It checks the device first, so a device that
    /// cannot scan never asks; and it asks before the camera starts, since VisionKit's scanner reads as unavailable until
    /// the user answers. A second call while one runs does nothing: the prompt itself makes the app inactive, and
    /// coming back would otherwise ask again.
    public func prepare() async {
        guard !preparing else {
            return
        }
        preparing = true
        defer { preparing = false }
        guard await camera.canScan() else {
            phase = .unsupported
            return
        }
        var answer = await camera.authorization()
        if answer == .notDetermined {
            answer = await camera.request()
        }
        phase = answer == .allowed ? .scanning : .denied
    }

    /// The camera failed to start, or stopped.
    public func failed() {
        phase = .unavailable
    }

    /// The words the sheet shows: the hint over the camera, or why there is no camera. Nothing while it checks.
    public var text: String? {
        switch phase {
        case .checking:
            nil
        case .scanning:
            Copy.Scan.hint
        case .denied:
            Copy.Scan.denied
        case .unsupported:
            Copy.Scan.unsupported
        case .unavailable:
            Copy.Scan.unavailable
        }
    }

    /// Whether the sheet offers Knit's page in the Settings app.
    public var offersSettings: Bool {
        phase == .denied
    }

    /// The phase as the sheet's identifier names it.
    public var accessibilityState: AccessibilityID.ScanState {
        Self.accessibilityState(phase)
    }

    /// `phase` as the sheet's identifier names it.
    static func accessibilityState(_ phase: Phase) -> AccessibilityID.ScanState {
        switch phase {
        case .checking:
            .checking
        case .scanning:
            .scanning
        case .denied:
            .notAllowed
        case .unsupported:
            .unsupported
        case .unavailable:
            .unavailable
        }
    }
}
