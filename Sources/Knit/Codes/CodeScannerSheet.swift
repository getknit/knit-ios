#if os(iOS)
    import KnitAppCore
    import SwiftUI
    import UIKit
    import Vision
    import VisionKit

    /// The sheet that scans another person's verify code and hands back the first one it reads (ADR 2026-10.65xx).
    internal struct CodeScannerSheet: View {
        @State private var model: CodeScannerModel
        @Environment(\.dismiss) private var dismiss
        @Environment(\.scenePhase) private var scenePhase
        private let scanned: (String) -> Void

        /// A scanner over `camera`, which hands the text it reads to `scanned`.
        init(camera: any CameraAccess, scanned: @escaping (String) -> Void) {
            _model = State(initialValue: CodeScannerModel(camera: camera))
            self.scanned = scanned
        }

        var body: some View {
            NavigationStack {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // A container of its own, so the sheet's identifier leaves the state's on the element inside.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AccessibilityID.scanScreen)
                    .navigationTitle(Copy.Profile.scan)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(Copy.Common.cancel) { dismiss() }
                        }
                    }
            }
            .task { await model.prepare() }
            // Back from the permission prompt or the Settings app: the answer may have changed.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await model.prepare() }
                }
            }
            // Opaque, as the other sheets are: text over the glass took its contrast from the screen behind.
            .presentationBackground(.background)
        }

        @ViewBuilder private var content: some View {
            let state = AccessibilityID.scanState(model.accessibilityState)
            switch model.phase {
            case .checking:
                ProgressView()
                    .accessibilityIdentifier(state)
            case .scanning:
                CodeScannerCamera(scanned: scanned) { model.failed() }
                    .ignoresSafeArea(edges: .bottom)
                    .safeAreaInset(edge: .bottom) {
                        Text(model.text ?? "")
                            .padding(Layout.large)
                            .frame(maxWidth: .infinity)
                            // Opaque: text over the camera would take its contrast from whatever it sees.
                            .background(.background)
                            .accessibilityIdentifier(state)
                    }
            case .denied, .unsupported, .unavailable:
                ScrollView {
                    VStack(spacing: Layout.large) {
                        Text(model.text ?? "")
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier(state)
                        if model.offersSettings {
                            OpenSettingsButton()
                        }
                    }
                    .padding(Layout.page)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// VisionKit's scanner, reading QR codes only, which hands back the first payload it reads and then stops, as
    /// Android's scanner latches its first decode (`QrScannerContent.kt`).
    private struct CodeScannerCamera: UIViewControllerRepresentable {
        let scanned: (String) -> Void
        let failed: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(scanned: scanned, failed: failed)
        }

        func makeUIViewController(context: Context) -> UIViewController {
            // A demo camera reaches here on the Simulator, which has no scanner: say so rather than build one.
            guard DataScannerViewController.isSupported else {
                context.coordinator.fail()
                return UIViewController()
            }
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])],
                qualityLevel: .balanced,
                recognizesMultipleItems: false,
                isHighFrameRateTrackingEnabled: false,
                isGuidanceEnabled: true,
                isHighlightingEnabled: true
            )
            scanner.delegate = context.coordinator
            return scanner
        }

        func updateUIViewController(_ controller: UIViewController, context: Context) {
            if let scanner = controller as? DataScannerViewController {
                context.coordinator.start(scanner)
            }
        }

        static func dismantleUIViewController(_ controller: UIViewController, coordinator _: Coordinator) {
            (controller as? DataScannerViewController)?.stopScanning()
        }

        @MainActor
        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            private let scanned: (String) -> Void
            private let failed: () -> Void
            private var started = false
            private var read = false

            init(scanned: @escaping (String) -> Void, failed: @escaping () -> Void) {
                self.scanned = scanned
                self.failed = failed
            }

            /// Starts the camera once, after the update that asked for it: a failure changes the sheet, which an
            /// update must not do mid-pass.
            func start(_ scanner: DataScannerViewController) {
                guard !started else {
                    return
                }
                started = true
                Task {
                    do {
                        try scanner.startScanning()
                    } catch {
                        failed()
                    }
                }
            }

            /// Reports a failure once the current update has finished.
            func fail() {
                Task { failed() }
            }

            func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems _: [RecognizedItem]) {
                guard !read else {
                    return
                }
                for case .barcode(let barcode) in addedItems {
                    guard let text = barcode.payloadStringValue else {
                        continue
                    }
                    read = true
                    dataScanner.stopScanning()
                    scanned(text)
                    return
                }
            }

            func dataScanner(
                _: DataScannerViewController,
                becameUnavailableWithError _: DataScannerViewController.ScanningUnavailable
            ) {
                failed()
            }
        }
    }
#endif
