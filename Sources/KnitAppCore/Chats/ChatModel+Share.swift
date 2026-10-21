public import Foundation

// A share the drain held back, taken into the composer when its thread opens (ADR 2026-10.z7a8), apart so `ChatModel`
// stays under the lint's length.
extension ChatModel {
    /// Takes a held share's words into the composer, in place of any draft, as Android's share prefill wins over a saved
    /// draft (`ChatScreen.kt:479-486`), and its picture through ``choosePhoto(_:)``, which says again why a picture was
    /// refused. Words the room refused say so too, and stay for an edit.
    public func adopt(_ share: ShareManifest, picture: Data?) async {
        text = Composer.clamp(share.text)
        selection = text.utf16.count..<text.utf16.count
        if share.hasPicture {
            await choosePhoto(picture)
        }
        if share.refusal == .words {
            wordsRefused = true
        }
    }
}
