#if os(iOS)
    import SwiftUI
    import UIKit

    extension View {
        /// Puts the keyboard away as another screen covers this one, a push or a full-screen cover. UIKit otherwise brings it
        /// back as this screen shows again, and SwiftUI leaves its bars where they were without it: the composer under the
        /// keyboard, and the thread's bottom with it.
        func releasesKeyboardWhenCovered() -> some View {
            background { KeyboardRelease().accessibilityHidden(true) }
        }
    }

    /// A view controller of no size in the screen's, told as it is covered, before UIKit notes what holds the keyboard.
    private struct KeyboardRelease: UIViewControllerRepresentable {
        func makeUIViewController(context _: Context) -> Controller {
            Controller()
        }

        func updateUIViewController(_: Controller, context _: Context) {
            // Nothing to update: it only listens.
        }

        final class Controller: UIViewController {
            override func viewWillDisappear(_ animated: Bool) {
                super.viewWillDisappear(animated)
                view.window?.endEditing(true)
            }
        }
    }
#endif
