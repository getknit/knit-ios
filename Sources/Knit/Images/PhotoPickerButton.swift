#if os(iOS)
    import Foundation
    import PhotosUI
    import SwiftUI

    /// A button that picks one photo from the library and hands over its bytes, or `nil` when they could not be read.
    /// The system's picker runs outside Knit and shares only what the user picks, so it needs no permission. Under
    /// `-demoPhoto` it hands over `demo` instead, since the Simulator's library and the system's picker are out of a UI
    /// test's reach.
    internal struct PhotoPickerButton<Label: View>: View {
        let demo: Data?
        let picked: (Data?) -> Void
        @ViewBuilder let label: Label
        @State private var item: PhotosPickerItem?

        var body: some View {
            if let demo {
                Button {
                    picked(demo)
                } label: {
                    label
                }
            } else {
                PhotosPicker(selection: $item, matching: .images) {
                    label
                }
                .onChange(of: item) { _, chosen in
                    guard let chosen else {
                        return
                    }
                    item = nil
                    Task { picked(try? await chosen.loadTransferable(type: Data.self)) }
                }
            }
        }
    }
#endif
