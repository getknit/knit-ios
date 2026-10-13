#if os(iOS)
    import KnitAppCore
    import SwiftUI
    import UIKit

    /// Starts a reply with a swipe on a message toward the trailing edge, as Messages and WhatsApp do (ADR 2026-10.mn29). The
    /// row follows the finger, slowing as it goes, with a reply glyph showing behind it. Once the finger has gone
    /// ``Layout/swipeStarts``, a tap of the haptics says the reply will start, and letting go there starts it. The row springs
    /// back either way.
    ///
    /// It begins only on a message, and only when the swipe is mostly sideways, so scrolling and the keyboard's pull-down
    /// keep the vertical. The navigation bar's edge swipe still goes back, and from iOS 26 the content's swipe back waits
    /// on this one, which fails at once away from a message. VoiceOver starts a reply from the message's actions.
    @MainActor
    internal final class SwipeToReply: NSObject, UIGestureRecognizerDelegate {
        let recognizer = UIPanGestureRecognizer()
        weak var view: ThreadCollectionView?
        /// The row under the finger, and what letting go past the mark does.
        private var swiping: (cell: UICollectionViewCell, reply: () -> Void)?
        /// Whether the swipe has passed the mark, so the haptics tap once per crossing.
        private var past = false
        private let glyph = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.circle.fill"))
        private let haptics = UIImpactFeedbackGenerator(style: .light)

        override init() {
            super.init()
            recognizer.addTarget(self, action: #selector(swiped))
            recognizer.delegate = self
            glyph.tintColor = UIColor(Palette.secondaryText)
            glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
            glyph.isAccessibilityElement = false
        }

        /// Toward the trailing edge: right, or left in a right-to-left language.
        private var trailing: CGFloat {
            view?.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, let found = target(of: pan) else {
                return false
            }
            swiping = found
            return true
        }

        /// Whether `pan`, this swipe's or the thread's own, is a swipe to reply: mostly sideways, toward the trailing edge,
        /// on a message that takes one. The thread's own pan asks too, and steps aside for one.
        func takes(_ pan: UIPanGestureRecognizer) -> Bool {
            target(of: pan) != nil
        }

        /// The row `pan` swipes, and what letting go past the mark does, or `nil` when it is no swipe to reply.
        private func target(of pan: UIPanGestureRecognizer) -> (cell: UICollectionViewCell, reply: () -> Void)? {
            guard let view, let swipe = view.swipe else {
                return nil
            }
            let velocity = pan.velocity(in: view)
            guard velocity.x * trailing > 0, abs(velocity.x) > abs(velocity.y) * Self.sideways,
                let path = view.indexPathForItem(at: pan.location(in: view)), let item = view.item(path), let reply = swipe(item),
                let cell = view.cellForItem(at: path)
            else {
                return nil
            }
            return (cell, reply)
        }

        @objc private func swiped(_ pan: UIPanGestureRecognizer) {
            guard let view, let swiping else {
                return
            }
            switch pan.state {
            case .began:
                past = false
                haptics.prepare()
                place(on: swiping.cell, in: view)
            case .changed:
                let distance = pan.translation(in: view).x * trailing
                swiping.cell.contentView.transform = CGAffineTransform(translationX: Self.reach(distance) * trailing, y: 0)
                glyph.alpha = min(max(distance, 0) / Layout.swipeStarts, 1)
                if (distance >= Layout.swipeStarts) != past {
                    past.toggle()
                    if past {
                        haptics.impactOccurred()
                    }
                }
            case .ended:
                // A quick swipe may end before a move reports how far it went.
                let went = pan.translation(in: view).x * trailing >= Layout.swipeStarts
                springBack(swiping.cell)
                if past || went {
                    swiping.reply()
                }
            default:
                springBack(swiping.cell)
            }
        }

        /// How far the row moves for `distance` of finger: one for one at first, slowing toward ``Layout/swipeReach``.
        private static func reach(_ distance: CGFloat) -> CGFloat {
            let reach = Layout.swipeReach
            return reach * (1 - exp(-max(distance, 0) / reach))
        }

        /// Puts the glyph behind the row's leading edge, clear.
        private func place(on cell: UICollectionViewCell, in view: UICollectionView) {
            glyph.sizeToFit()
            glyph.alpha = 0
            let inset = Layout.large + glyph.bounds.midX
            let across = trailing > 0 ? cell.frame.minX + inset : cell.frame.maxX - inset
            glyph.center = CGPoint(x: across, y: cell.frame.midY)
            view.insertSubview(glyph, belowSubview: cell)
        }

        private func springBack(_ cell: UICollectionViewCell) {
            let still = UIAccessibility.isReduceMotionEnabled
            UIView.animate(springDuration: Self.spring, bounce: still ? 0 : Self.bounce) {
                cell.contentView.transform = .identity
                self.glyph.alpha = 0
            } completion: { _ in
                // Unless a new swipe has the glyph already.
                if self.swiping == nil {
                    self.glyph.removeFromSuperview()
                }
            }
            swiping = nil
            past = false
        }

        /// How much more sideways than up or down a swipe must start to be one: scrolling keeps the rest.
        private static let sideways: CGFloat = 1.5
        /// The spring back, in seconds, and its bounce, none under Reduce Motion.
        private static let spring: TimeInterval = 0.3
        private static let bounce: CGFloat = 0.25

        func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
            false
        }

        /// The navigation bar's edge swipe goes back before this begins.
        func gestureRecognizer(_: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            other === navigation?.interactivePopGestureRecognizer
        }

        /// A pan above the thread waits for this one to fail: from iOS 26 the content's swipe back starts anywhere, and would
        /// otherwise take a swipe on a message for a way back. This fails at once away from a message, so going back
        /// elsewhere waits for nothing.
        func gestureRecognizer(_: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let view, let host = other.view, host !== view, view.isDescendant(of: host) else {
                return false
            }
            return other is UIPanGestureRecognizer && other !== navigation?.interactivePopGestureRecognizer
        }

        /// The navigation controller the thread is in.
        private var navigation: UINavigationController? {
            sequence(first: view?.next) { $0?.next }.lazy.compactMap { $0 as? UIViewController }.first?.navigationController
        }
    }
#endif
