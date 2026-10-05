#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// What a delete asks before it deletes (ADR 2026-10.u7cq): its title, what it does, and the word on its button.
    internal struct DeleteQuestion {
        let title: String
        let body: String
        let action: String

        /// Deleting a message, from its bubble's menu.
        static func message(_: ChatMessage) -> Self {
            Self(title: Copy.Delete.messageTitle, body: Copy.Delete.messageBody, action: Copy.Delete.delete)
        }

        /// Deleting a request, from its swipe.
        static func request(_: RequestRow) -> Self {
            Self(title: Copy.Delete.requestTitle, body: Copy.Delete.requestBody, action: Copy.Delete.delete)
        }

        /// Deleting `row`'s chat, from its swipe: the room is cleared, and a group's membership stays.
        static func chat(_ row: ChatRow) -> Self {
            if row.isRoom {
                return Self(title: Copy.Delete.roomTitle, body: Copy.Delete.roomBody, action: Copy.Delete.clear)
            }
            return Self(
                title: Copy.Delete.chatTitle, body: row.isGroup ? Copy.Delete.groupBody : Copy.Delete.directBody, action: Copy.Delete.delete
            )
        }
    }

    extension View {
        /// Asks before deleting `item`, in the words `question` gives it, and hands it to `delete` on yes; Cancel keeps it.
        /// An alert, not a confirmation dialog, as ``confirmsBlock(of:isPresented:block:)`` is: iOS 27 draws the dialog as a
        /// popover off the whole screen, too narrow for the message, and still growing when the accessibility audit reads
        /// it.
        func confirmsDelete<Item>(
            _ item: Binding<Item?>,
            asking question: @escaping (Item) -> DeleteQuestion,
            delete: @escaping (Item) -> Void
        ) -> some View {
            alert(
                item.wrappedValue.map(question)?.title ?? "",
                isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
                presenting: item.wrappedValue
            ) { shown in
                Button(question(shown).action, role: .destructive) { delete(shown) }
                Button(Copy.Common.cancel, role: .cancel) {
                    // The alert closes itself.
                }
            } message: { shown in
                Text(question(shown).body)
            }
        }
    }
#endif
