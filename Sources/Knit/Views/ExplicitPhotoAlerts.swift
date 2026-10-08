#if os(iOS)
    import KnitAppCore
    import SwiftUI

    extension View {
        /// A thread's answer to an explicit photo just picked for the room, which refuses it (ADR 2026-10.rpmq). A DM or a
        /// group takes any photo unchecked (ADR 2026-10.spcy).
        func answersExplicitPhotos(of model: ChatModel) -> some View {
            modifier(ExplicitPhotoAlerts(model: model))
        }
    }

    private struct ExplicitPhotoAlerts: ViewModifier {
        @Bindable var model: ChatModel

        func body(content: Content) -> some View {
            content
                .alert(Copy.Moderation.explicitTitle, isPresented: $model.photoRefused) {
                    Button(Copy.Common.done, role: .cancel) {
                        // The alert closes itself, and the photo was never held.
                    }
                } message: {
                    Text(Copy.Moderation.roomRefusal)
                }
        }
    }
#endif
