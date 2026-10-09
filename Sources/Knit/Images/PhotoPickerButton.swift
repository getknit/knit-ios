#if os(iOS)
    import Foundation
    import PhotosUI
    import SwiftUI

    /// A button that picks one photo from the library and hands over its bytes, or `nil` when they could not be read.
    /// The system's picker runs outside Knit and shares only what the user picks, so it needs no permission. Under
    /// `-demoPhoto` it hands over `demo` instead, since the Simulator's library and the system's picker are out of a UI
    /// test's reach.
    ///
    /// It asks for the file as the library holds it (`.current`), not a version transcoded for compatibility, so a
    /// picture Knit saved is handed back byte for byte and goes as the blob it arrived as (ADR 2026-10.f3mv). The codec
    /// takes whatever comes, HEIC included.
    ///
    /// It is a button that presents the picker, not a `PhotosPicker`: from iOS 27, `PhotosPicker` takes its label as a
    /// `@Sendable` closure, which cannot read this view's `label` on the main actor.
    internal struct PhotoPickerButton<Label: View>: View {
        let demo: Data?
        let picked: (Data?) -> Void
        @ViewBuilder let label: Label
        @State private var picking = false
        @State private var item: PhotosPickerItem?

        var body: some View {
            Button {
                if let demo {
                    picked(demo)
                } else {
                    picking = true
                }
            } label: {
                label
            }
            .photosPicker(isPresented: $picking, selection: $item, matching: .images, preferredItemEncoding: .current)
            .onChange(of: item) { _, chosen in
                guard let chosen else {
                    return
                }
                item = nil
                Task { picked(try? await chosen.loadTransferable(type: Data.self)) }
            }
        }
    }
#endif
