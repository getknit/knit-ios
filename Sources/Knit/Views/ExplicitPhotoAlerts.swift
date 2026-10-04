#if os(iOS)
    import KnitAppCore
    import SwiftUI

    extension View {
        /// A thread's answers to an explicit photo just picked (ADR 2026-10.rpmq): the room refuses it, and a DM or a group
        /// asks whether to send it anyway.
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
                .alert(Copy.Moderation.explicitTitle, isPresented: $model.asksAboutExplicitPhoto) {
                    Button(Copy.Moderation.sendAnyway) { Task { await model.keepExplicitPhoto() } }
                    Button(Copy.Common.cancel, role: .cancel, action: model.dropExplicitPhoto)
                } message: {
                    Text(Copy.Moderation.explicitAsk)
                }
        }
    }
#endif
