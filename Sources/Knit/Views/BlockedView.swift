#if os(iOS)
    import KnitAppCore
    import KnitWire
    import SwiftUI

    extension View {
        /// Asks before blocking `name` (ADR 2026-10.5wgg): what a block does, Block and Cancel. Unblock never asks. An
        /// alert, not a confirmation dialog: iOS 27 draws the dialog as a popover off the whole screen, too narrow for
        /// the message, and still growing when the accessibility audit reads it.
        func confirmsBlock(of name: String, isPresented: Binding<Bool>, block: @escaping () -> Void) -> some View {
            alert(Copy.Block.confirmTitle(name), isPresented: isPresented) {
                Button(Copy.Block.block, role: .destructive, action: block)
                Button(Copy.Common.cancel, role: .cancel) {
                    // The alert closes itself.
                }
            } message: {
                Text(Copy.Block.confirmBody)
            }
        }
    }

    /// Everyone blocked, each with Unblock (`BlockedUsersScreen` in knit-next). A row opens the person's profile.
    internal struct BlockedView: View {
        @State private var model: BlockedModel
        @Environment(\.dynamicTypeSize) private var typeSize

        init(session: AppSession) {
            _model = State(initialValue: BlockedModel(session: session))
        }

        var body: some View {
            List {
                Section {
                    if model.rows.isEmpty {
                        Text(Copy.Block.empty)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    ForEach(model.rows) { row in
                        // At the accessibility sizes, Unblock goes under the name rather than squeezing it.
                        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
                        layout {
                            NavigationLink(value: Route.peer(row.id)) {
                                BlockedLabel(row: row)
                            }
                            .accessibilityIdentifier(AccessibilityID.blockedRow(row.id.string))
                            Button(Copy.Block.unblock) {
                                Task { await model.unblock(row.id) }
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(AccessibilityID.blockedUnblock(row.id.string))
                        }
                    }
                } footer: {
                    SectionNote(Copy.Block.listFooter)
                }
            }
            .navigationTitle(Copy.Block.listTitle)
            .accessibilityIdentifier(AccessibilityID.blockedScreen)
        }
    }

    /// A blocked person's face and name.
    private struct BlockedLabel: View {
        let row: BlockedRow
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            HStack(spacing: Layout.medium) {
                // At the accessibility sizes the face would squeeze the name, which says who.
                if !typeSize.isAccessibilitySize {
                    AvatarView(face: row.face, size: Layout.faceRequest)
                }
                Text(row.title)
                    .font(.headline)
            }
        }
    }

    /// A blocked person's DM: Unblock in the composer's place. Android keeps the composer; here the bar says why nothing
    /// can be sent, and how to write again (ADR 2026-10.5wgg).
    internal struct BlockedBar: View {
        let name: String
        let unblock: () -> Void

        var body: some View {
            VStack(spacing: Layout.small) {
                Text(Copy.Block.barTitle(name))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(Copy.Block.barBody)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                Button(Copy.Block.unblock, action: unblock)
                    .prominentButton()
                    .accessibilityIdentifier(AccessibilityID.chatUnblock)
            }
            .padding()
            .frame(maxWidth: .infinity)
            // Opaque, as the request bar is: a material let the thread through.
            .background(.background.secondary)
        }
    }
#endif
