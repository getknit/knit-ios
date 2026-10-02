#if os(iOS)
    import AVFoundation
    import KnitAppCore
    import VisionKit

    /// The phone's camera, as the scanner reaches it (ADR 2026-10.65xx): VisionKit says whether this device can scan,
    /// and AVFoundation holds the permission, which the scanner needs before it reports itself available.
    internal struct DeviceCamera: CameraAccess {
        func canScan() async -> Bool {
            await MainActor.run { DataScannerViewController.isSupported }
        }

        func authorization() -> CameraAuthorization {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined:
                .notDetermined
            case .authorized:
                .allowed
            case .denied, .restricted:
                .denied
            @unknown default:
                .denied
            }
        }

        func request() async -> CameraAuthorization {
            await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .denied
        }
    }
#endif
