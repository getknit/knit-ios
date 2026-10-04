#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// What a DM's or a group's encryption covers, and the limit v1 has.
    internal struct EncryptionSheet: View {
        let text: String
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                ScrollView {
                    Text(text)
                        .padding()
                }
                .navigationTitle(Copy.Chat.encrypted)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Copy.Common.done) { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            // Opaque: text over the glass sheet took its contrast from whatever the thread showed behind it.
            .presentationBackground(.background)
        }
    }
#endif
