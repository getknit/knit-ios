#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// The emoji people reacted with under a message, as Android and Signal draw them (ADR 2026-10.ehe6): a capsule per
    /// emoji, its count once more than one person chose it, ours outlined in the tint, tucked up against the bubble's foot
    /// and wrapping as Android's `FlowRow` does. Each capsule is opaque and ringed in the thread's background, so it reads
    /// where it overlaps the bubble; glass never sits under text (ADR 2026-10.5waw). A tap toggles ours with that emoji
    /// where the thread takes reactions. VoiceOver hears the chips in the bubble's value and reacts through its actions, so
    /// they are hidden from it here.
    internal struct ReactionStrip: View {
        let message: ChatMessage
        /// Toggles our reaction with an emoji, or `nil` where the thread takes none.
        let react: ((String) -> Void)?

        var body: some View {
            ChipFlow(spacing: Layout.tight, trailing: message.isMine) {
                ForEach(message.reactions) { chip in
                    Button {
                        react?(chip.emoji)
                    } label: {
                        ChipLabel(chip: chip)
                    }
                    .buttonStyle(.plain)
                    .disabled(react == nil)
                    .accessibilityIdentifier(AccessibilityID.chatReaction(message.id, chip.emoji))
                }
            }
            .padding(.top, -Layout.small)
            .padding(.horizontal, Layout.small)
            .accessibilityHidden(true)
        }
    }

    /// One chip: the emoji, and how many chose it once that is more than one.
    private struct ChipLabel: View {
        let chip: ReactionChip

        var body: some View {
            HStack(spacing: Layout.hairline) {
                Text(chip.emoji)
                if chip.count > 1 {
                    Text(chip.count, format: .number)
                        .monospacedDigit()
                }
            }
            .font(.footnote)
            .foregroundStyle(.primary)
            .padding(.horizontal, Layout.small)
            .padding(.vertical, Layout.hairline)
            .background(Palette.incomingBubble, in: .capsule)
            .overlay {
                if chip.mine {
                    Capsule().strokeBorder(Palette.accent, lineWidth: Layout.chipOutline)
                }
            }
            .padding(Layout.badgeRing)
            .background(.background, in: .capsule)
            .frame(minHeight: Layout.chipHeight)
            .contentShape(.capsule)
        }
    }

    /// Chips in rows, wrapping as Android's `FlowRow` does, from the leading edge, or the trailing one under our own bubble.
    private struct ChipFlow: SwiftUI.Layout {
        let spacing: CGFloat
        let trailing: Bool

        /// One row: its chips by index, and how wide and tall they stand together.
        private struct Row {
            var indices: [Int] = []
            var width: CGFloat = 0
            var height: CGFloat = 0
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
            let rows = rows(of: subviews, width: proposal.width ?? .infinity)
            let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
            return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
        }

        func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
            var top = bounds.minY
            for row in rows(of: subviews, width: bounds.width) {
                var left = trailing ? bounds.maxX - row.width : bounds.minX
                for index in row.indices {
                    let size = subviews[index].sizeThatFits(.unspecified)
                    subviews[index].place(at: CGPoint(x: left, y: top), proposal: ProposedViewSize(size))
                    left += size.width + spacing
                }
                top += row.height + spacing
            }
        }

        /// `subviews` cut into rows no wider than `width`, each holding at least one chip.
        private func rows(of subviews: Subviews, width: CGFloat) -> [Row] {
            var rows: [Row] = []
            var row = Row()
            for index in subviews.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                if !row.indices.isEmpty, row.width + spacing + size.width > width {
                    rows.append(row)
                    row = Row()
                }
                row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
                row.height = max(row.height, size.height)
                row.indices.append(index)
            }
            if !row.indices.isEmpty {
                rows.append(row)
            }
            return rows
        }
    }
#endif
