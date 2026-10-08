#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// A short explanation in a sheet that stands only as tall as its words: a glyph in the tint, a title, and points
    /// that each lead with a glyph of their own, as Signal explains its safety features. It holds what would otherwise
    /// crowd a screen in long footers: the radio's boundary, what encryption covers, what the content filter does.
    /// Taller than the screen allows, at the accessibility sizes, it opens full height and scrolls.
    internal struct InfoSheet: View {
        let symbol: String
        let title: String
        let points: [InfoPoint]
        /// The UI tests' name for the sheet, if they look for it.
        var identifier: String?
        /// The sheet's content's height, as last measured.
        @State private var height: CGFloat = 0
        @Environment(\.dismiss) private var dismiss
        @ScaledMetric(relativeTo: .title) private var hero = Layout.infoHero

        var body: some View {
            ScrollView {
                VStack(spacing: Layout.large) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: hero, height: hero)
                        .background(Palette.incomingBubble, in: .circle)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: Layout.medium) {
                        ForEach(points) { point in
                            PointRow(point: point)
                        }
                    }
                }
                .padding(.horizontal, Layout.page)
                .padding(.top, Layout.spacious)
                .padding(.bottom, Layout.large)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier ?? "")
            .overlay(alignment: .topTrailing) {
                CloseButton { dismiss() }
            }
            // Until the first measure, a guess that keeps the sheet from opening at full height and then dropping.
            .presentationDetents(height > 0 ? [.height(height)] : [.medium])
            .presentationDragIndicator(.visible)
            // Opaque: text over the glass sheet took its contrast from whatever the screen showed behind it.
            .presentationBackground(.background)
        }
    }

    /// One point: its glyph in the tint, in a column of its own, beside the words.
    internal struct InfoPoint: Identifiable {
        let symbol: String
        let text: String

        var id: String { text }
    }

    private struct PointRow: View {
        let point: InfoPoint
        @ScaledMetric(relativeTo: .body) private var column = Layout.infoGlyph

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: Layout.medium) {
                Image(systemName: point.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: column)
                    .accessibilityHidden(true)
                Text(point.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The sheet's way out at its top trailing corner: a cross, named Done for VoiceOver and the UI tests. From iOS 26 it
    /// is Liquid Glass, as the system draws its own sheets' close buttons; before that, and with Reduce Transparency on, a
    /// gray disc.
    private struct CloseButton: View {
        let close: () -> Void
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

        var body: some View {
            let button = Button(action: close) {
                Label(Copy.Common.done, systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: Layout.hitTarget, height: Layout.hitTarget)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            Group {
                if #available(iOS 26, *), !reduceTransparency {
                    button
                        .glassEffect(.regular.interactive(), in: .circle)
                } else {
                    button
                        .background(Palette.incomingBubble, in: .circle)
                }
            }
            .padding(Layout.medium)
        }
    }

    /// The info glyph that opens an ``InfoSheet``: borderless, so in a list row only the glyph takes the tap, and the row
    /// keeps its own, with the hit area the audit wants. `label` names it for VoiceOver.
    internal struct InfoButton: View {
        let label: String
        let show: () -> Void

        var body: some View {
            Button(action: show) {
                Label(label, systemImage: "info.circle")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: Layout.hitTarget, minHeight: Layout.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            // The hit area stays 44 points tall, but lays out shorter, so a row it sits in keeps the height of its
            // neighbours.
            .padding(.vertical, -Layout.medium)
        }
    }

    extension View {
        /// Shows `sheet` while `isPresented`: the shorthand every info button uses.
        func infoSheet(
            isPresented: Binding<Bool>, symbol: String, title: String, points: [InfoPoint], identifier: String?
        ) -> some View {
            sheet(isPresented: isPresented) {
                InfoSheet(symbol: symbol, title: title, points: points, identifier: identifier)
            }
        }
    }
#endif
