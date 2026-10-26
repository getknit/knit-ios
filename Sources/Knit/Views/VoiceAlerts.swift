#if os(iOS)
    import KnitAppCore
    import SwiftUI
    import UIKit

    extension View {
        /// A thread's answer to a press on the mic that kept nothing (knit-next ADR 034's `MicGate` and toasts): the
        /// microphone refused, with the way to Settings, or a recording that didn't come out. A press too short to keep
        /// says so above the composer instead (``VoiceHint``).
        func voiceAlerts(of model: ChatModel) -> some View {
            modifier(VoiceAlerts(voice: model.voice))
        }
    }

    private struct VoiceAlerts: ViewModifier {
        let voice: VoiceRecorder?
        @Environment(\.openURL) private var openURL

        func body(content: Content) -> some View {
            content
                .alert(Copy.Voice.microphoneOffTitle, isPresented: showing(.microphoneOff)) {
                    Button(Copy.Common.openSettings) {
                        if let settings = URL(string: UIApplication.openSettingsURLString) {
                            openURL(settings)
                        }
                    }
                    Button(Copy.Common.cancel, role: .cancel) {
                        // The alert closes itself.
                    }
                } message: {
                    Text(Copy.Voice.microphoneOffMessage)
                }
                .alert(Copy.Voice.unrecorded, isPresented: showing(.unrecorded)) {
                    Button(Copy.Common.done, role: .cancel) {
                        // The alert closes itself, and the mic waits for another press.
                    }
                }
        }

        /// Whether the recorder's last press kept nothing for `failure`; dismissing the alert forgets it.
        private func showing(_ failure: VoiceFailure) -> Binding<Bool> {
            Binding {
                voice?.failure == failure
            } set: { shown in
                if !shown, voice?.failure == failure {
                    voice?.failure = nil
                }
            }
        }
    }
#endif
