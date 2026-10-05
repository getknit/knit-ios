#if os(iOS)
    import KnitAppCore
    import SwiftUI
    import UIKit

    /// A row of a thread, by the identity its collection view keeps it by across updates: the header, then each message.
    internal enum ThreadItem: Hashable, Sendable {
        case header
        case message(String)
    }

    /// Jumps a thread's collection view to its newest row, at SwiftUI's asking: the way back, and a message of our own.
    @MainActor
    internal final class ThreadJump {
        weak var view: ThreadCollectionView?

        /// Pins the thread to its bottom edge, and takes it there.
        func toNewest() {
            view?.jumpToNewest()
        }
    }

    /// A thread's rows in a UIKit collection view, each drawn by SwiftUI in its cell (ADR 2026-10.pkbu). UIKit lays the rows
    /// out and scrolls them, and keeps what shows still as it measures rows above the screen. The thread sets its own
    /// offset only while it is pinned to its bottom edge, inside each layout pass, before anything draws. SwiftUI's lazy
    /// stack sized and anchored a long room on its guess at the rows it had yet to draw, and opened it blank or short of
    /// its newest post.
    internal struct ThreadCollection<Row: Equatable, Content: View>: UIViewRepresentable {
        /// The rows in order, the header first.
        let items: [ThreadItem]
        /// What each row shows. A row draws again when what it shows changes.
        let rows: [ThreadItem: Row]
        let jump: ThreadJump
        /// What covers the thread's edges, in SwiftUI's layout: the navigation bar above, and the composer and the keyboard
        /// below. UIKit's own safe area left out the composer, which SwiftUI places.
        let bars: EdgeInsets
        /// Whether the way back to the newest row shows.
        @Binding var offersNewest: Bool
        @ViewBuilder let content: (Row) -> Content

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context: Context) -> ThreadCollectionView {
            let view = ThreadCollectionView()
            context.coordinator.attach(view)
            jump.view = view
            return view
        }

        func updateUIView(_ view: ThreadCollectionView, context: Context) {
            let offers = $offersNewest
            view.offersNewest = { value in
                // Outside the update that laid the rows out, which may be SwiftUI's own.
                Task { @MainActor in
                    if offers.wrappedValue != value {
                        offers.wrappedValue = value
                    }
                }
            }
            view.bars = UIEdgeInsets(top: bars.top, left: 0, bottom: bars.bottom, right: 0)
            context.coordinator.content = content
            context.coordinator.show(items, rows: rows)
        }

        /// Keeps the collection view's rows in step with SwiftUI's.
        @MainActor
        final class Coordinator {
            /// What draws a row, from SwiftUI's latest update.
            var content: ((Row) -> Content)?
            private var items: [ThreadItem] = []
            private var rows: [ThreadItem: Row] = [:]
            private var source: UICollectionViewDiffableDataSource<Int, ThreadItem>?

            /// Draws `view`'s rows with ``content``.
            func attach(_ view: ThreadCollectionView) {
                let cell = UICollectionView.CellRegistration<UICollectionViewCell, ThreadItem> { [weak self] cell, _, item in
                    guard let self, let row = rows[item], let content else {
                        return
                    }
                    cell.contentConfiguration = UIHostingConfiguration { content(row) }
                        .margins(.all, 0)
                    cell.backgroundConfiguration = .clear()
                }
                let diffable = UICollectionViewDiffableDataSource<Int, ThreadItem>(collectionView: view) { collection, path, item in
                    collection.dequeueConfiguredReusableCell(using: cell, for: path, item: item)
                }
                source = diffable
            }

            /// Shows `items`, drawing again each row whose content changed.
            func show(_ items: [ThreadItem], rows: [ThreadItem: Row]) {
                let changed = rows.compactMap { item, row in self.rows[item].map { $0 != row } == true ? item : nil }
                self.rows = rows
                guard let source, items != self.items || !changed.isEmpty else {
                    return
                }
                var snapshot = source.snapshot()
                if items != self.items {
                    self.items = items
                    snapshot = NSDiffableDataSourceSnapshot()
                    snapshot.appendSections([0])
                    snapshot.appendItems(items)
                }
                snapshot.reconfigureItems(changed)
                source.apply(snapshot, animatingDifferences: false)
            }
        }
    }

    /// A thread's collection view, which keeps to its bottom edge while it is pinned there. Up in its history, the
    /// compositional layout keeps what shows still itself: as it measures a row above the screen, it moves the offset by
    /// what the row's height differs from its estimate.
    internal final class ThreadCollectionView: UICollectionView, UICollectionViewDelegate {
        /// The height UIKit lays out a row at until it draws it. UIKit moves the offset by what a row's height differs from
        /// it as the row is measured, so this decides nothing on screen: only how far the scroll indicator guesses the
        /// history goes.
        private static let unmeasuredRow: CGFloat = 100
        /// How far up the thread, in screens, the way back to the newest row shows: by then the newest is out of sight,
        /// and a glance back up a row or two stays clear of it.
        private static let wayBackScreens: CGFloat = 0.5

        /// What covers the thread's top and bottom edges.
        var bars = UIEdgeInsets.zero {
            didSet {
                if bars != oldValue {
                    setNeedsLayout()
                }
            }
        }
        /// Tells SwiftUI whether to show the way back to the newest row.
        var offersNewest: (Bool) -> Void = { _ in
            // Nothing asks until SwiftUI's first update.
        }
        /// Whether the thread keeps to its bottom edge: from opening until someone scrolls it or iOS scrolls it to the top,
        /// and again once it comes to rest there.
        private var pinned = true
        private var offering = false
        /// Whether the thread is laying out its rows, where every offset it moves to is its own.
        private var laying = false

        init() {
            super.init(frame: .zero, collectionViewLayout: Self.layout())
            backgroundColor = .clear
            allowsSelection = false
            alwaysBounceVertical = true
            keyboardDismissMode = .interactive
            contentInsetAdjustmentBehavior = .never
            accessibilityIdentifier = AccessibilityID.chatThread
            delegate = self
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            nil
        }

        private static func layout() -> UICollectionViewCompositionalLayout {
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(unmeasuredRow))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(
                top: Layout.large, leading: Layout.large, bottom: Layout.large, trailing: Layout.large)
            return UICollectionViewCompositionalLayout(section: section)
        }

        override func layoutSubviews() {
            laying = true
            defer { laying = false }
            super.layoutSubviews()
            inset()
            if pinned {
                move(to: bottomOffset)
            }
            offerNewest()
        }

        /// iOS scrolls the screen's content scroll view to the top on a tap on the status bar or the navigation bar's empty
        /// strip, and draws the bars' edges over it. SwiftUI names its own scroll views; this one names itself.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let controller = sequence(first: next) { $0?.next }.lazy.compactMap { $0 as? UIViewController }.first
            controller?.setContentScrollView(self, for: .top)
            controller?.setContentScrollView(self, for: .bottom)
        }

        /// Pins the thread to its bottom edge, and takes it there.
        func jumpToNewest() {
            pinned = true
            setNeedsLayout()
            layoutIfNeeded()
        }

        // MARK: Scrolling

        func scrollViewWillBeginDragging(_: UIScrollView) {
            pinned = false
        }

        func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                settle()
            }
        }

        func scrollViewDidEndDecelerating(_: UIScrollView) {
            settle()
        }

        /// A tap on the status bar, or on the navigation bar's empty strip, scrolls to the top.
        func scrollViewShouldScrollToTop(_: UIScrollView) -> Bool {
            pinned = false
            return true
        }

        func scrollViewDidScrollToTop(_: UIScrollView) {
            settle()
        }

        /// Every offset the thread moves to itself, it moves to while laying out. Any other that leaves its bottom edge is
        /// someone scrolling it: a finger, a tap on the bar, VoiceOver.
        func scrollViewDidScroll(_: UIScrollView) {
            if !laying, pinned, abs(away) > Layout.small {
                pinned = false
            }
            offerNewest()
        }

        func scrollViewDidEndScrollingAnimation(_: UIScrollView) {
            settle()
        }

        // MARK: Geometry

        /// The offset that shows the thread's bottom edge above the composer, or its top when it is all on screen.
        private var bottomOffset: CGFloat {
            max(contentSize.height + adjustedContentInset.bottom - bounds.height, -adjustedContentInset.top)
        }

        /// How far up the thread stands from its bottom edge.
        private var away: CGFloat {
            bottomOffset - contentOffset.y
        }

        /// The thread comes to rest: pinned again if on its bottom edge.
        private func settle() {
            pinned = abs(away) <= Layout.small
            offerNewest()
        }

        private func move(to offset: CGFloat) {
            if abs(contentOffset.y - offset) > 1 / max(traitCollection.displayScale, 1) {
                contentOffset.y = offset
            }
        }

        /// Insets the rows by the bars over them, and a thread shorter than the screen by the room it leaves above it too,
        /// so it stands against its bottom edge as a thread with more rows than the screen holds opens.
        private func inset() {
            let room = max(bounds.height - bars.top - bars.bottom - contentSize.height, 0)
            let insets = UIEdgeInsets(top: bars.top + room, left: 0, bottom: bars.bottom, right: 0)
            if abs(contentInset.top - insets.top) > 1 || abs(contentInset.bottom - insets.bottom) > 1 {
                contentInset = insets
            }
            verticalScrollIndicatorInsets = bars
        }

        /// Shows the way back once the thread is well above its bottom edge, until it is back there.
        private func offerNewest() {
            let screen = bounds.height - bars.top - bars.bottom
            let offers = abs(away) <= Layout.small ? false : (!pinned && away > screen * Self.wayBackScreens) || offering
            if offers != offering {
                offering = offers
                offersNewest(offers)
            }
        }
    }
#endif
