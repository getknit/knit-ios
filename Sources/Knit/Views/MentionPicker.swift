#if os(iOS)
    import KnitAppCore
    import SwiftUI

    /// The people an "@" in the composer offers, above the field (ADR 2026-10.nbhj): a row for each, with their face and
    /// their label, as every list here names people. Every match is here. Past five, the list shows four and a half rows
    /// and scrolls, as Signal's does, where Android cuts the list at five. A tap mentions the person. It opens with a light
    /// tap of the haptics, as Signal's does, and VoiceOver says how many people it offers, since the keyboard keeps focus.
    internal struct MentionPicker: View {
        let candidates: [MentionCandidate]
        let pick: (MentionCandidate) -> Void
        /// A row's height at the reader's text size: the hit target at the default size, growing with the words.
        @ScaledMetric(relativeTo: .body) private var row: CGFloat = Layout.hitTarget
        /// Whether the picker has come on screen, which plays the haptic once.
        @State private var shown = false

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(candidates) { candidate in
                        Button {
                            pick(candidate)
                        } label: {
                            MentionRow(candidate: candidate)
                                .frame(maxWidth: .infinity, minHeight: row, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(candidate.label.text)
                        .accessibilityIdentifier(AccessibilityID.chatMention(candidate.id))
                    }
                }
                .padding(.horizontal, Layout.small)
            }
            .frame(height: row * rows)
            .scrollBounceBehavior(.basedOnSize)
            // The screen's own color, opaque: the background style turns translucent inside the composer's glass.
            .background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: Layout.quoteCorner, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Copy.Mentions.picker)
            .accessibilityIdentifier(AccessibilityID.chatMentions)
            .sensoryFeedback(.impact(weight: .light), trigger: shown) { _, now in now }
            .onAppear {
                shown = true
                AccessibilityNotification.Announcement(Copy.Mentions.offered(candidates.count)).post()
            }
        }

        /// How many rows show: all of them up to five, and four and a half past that.
        private var rows: CGFloat {
            candidates.count > Layout.mentionRowsWhole ? Layout.mentionRowsShown : CGFloat(candidates.count)
        }
    }

    /// One person the picker offers: their face and their label.
    private struct MentionRow: View {
        let candidate: MentionCandidate

        var body: some View {
            HStack(spacing: Layout.small) {
                AvatarView(face: candidate.face, size: Layout.faceMention)
                Text(verbatim: candidate.label.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
#endif
