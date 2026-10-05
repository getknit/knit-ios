---
id: "2026-10.pkbu"
slug: a-thread-is-a-uikit
title: "A thread is a UIKit collection view"
date: 2026-10-05
topics: [ui, accessibility]
---

# ADR 2026-10.pkbu — A thread is a UIKit collection view

Status: Accepted (2026-10-05)

**Context:** a thread was a SwiftUI `ScrollView` over a `LazyVStack`, anchored to its bottom edge with
`defaultScrollAnchor(.bottom)` and `scrollPosition`. A lazy stack sizes the rows it has not drawn with a guess, about 900
points each where most measure under 150, and SwiftUI sized and anchored the thread on those guesses. On the
maintainer's iPhone 12, the Nearby room (2,167 posts) opened blank until dragged: as the bars settled during the push,
SwiftUI put the offset about 1.7 million points past the content's end, where nothing draws. The Simulator never showed
the blank, even at 2,000 posts, and a reopened room there stopped 150 points short of its newest post instead. Apple's
forums report the blank from iOS 17 on (thread 741406). They also report that iOS 27 no longer keeps a reader's place
when rows are added above them, even when a row identity is bound to `scrollPosition(id:)` (thread 848608).

Four rounds of correcting the guesses from `onScrollGeometryChange` each opened a new edge case: a pull back to the bottom
that fought a tap on the bar, a climb detector that took the bars settling for that tap, and a check for standing past
the edge. Two variants failed on the phone too. One drew the newest 60 messages in a plain stack, below a lazy stack
holding the rest. Scrolling up into the lazy part blanked, then snapped back to the bottom. Loading older pages above
the newest threw the reader to the room's first posts on every page.

**Decision:** `ThreadCollection` puts the thread's rows in a `UICollectionView` subclass, one SwiftUI row per cell
through `UIHostingConfiguration`. The view sets its own offset inside `layoutSubviews`, before anything draws:

- **While pinned, on the bottom edge.** It opens pinned, and stays pinned through the bars settling, the keyboard,
  photos decoding and new messages.
- **Otherwise, UIKit holds what shows still.** As the compositional layout measures a row above the screen, it moves
  the offset by what the row's height differs from its 100-point estimate, from outside `layoutSubviews`, through
  `invalidateLayoutWithContext:`. The thread's first build also held its lowest row still itself, which moved the offset
  a second time. Each row measured on the way up the Nearby room then threw the thread toward its newest post by 20 to
  200 points. A trace in the Simulator paired all 80 of the thread's corrections in 25 drags up the long room with
  UIKit's own for the same amount.
- **Unpinning is exact.** An offset change that leaves the bottom edge outside the view's own layout is someone
  scrolling: a finger, a tap on the bar, VoiceOver. Coming to rest on the edge pins it again. UIKit says which is which.
  SwiftUI reported no scroll phase for a tap on the bar, so the old code had to guess.

The insets come from SwiftUI's own safe area around the thread, because UIKit's left out the composer, which
`safeAreaBar` places. The view names itself the screen's content scroll view, which a tap on the navigation bar needs
to scroll it to the top. A cell's SwiftUI is outside the navigation stack and its environment, so the thread hands
each row the photo cache, the content filter, the calendar, the tint and an `openRoute` action by hand. A
`NavigationLink` to a value in a cell finds no destination, so the bubble's face and name open the profile through
`openRoute`.

The alternatives:

- **SwiftUI `List`.** It gets none of the scroll APIs above, only `ScrollViewReader`.
- **A flipped `LazyVStack`, as knit-next's `reverseLayout`.** The newest row would sit at offset 0 and nothing would
  anchor to a guess. But VoiceOver's order and three-finger scroll would run backwards, and a tap on the bar would
  scroll to the newest message.
- **Every row eager.** The heights are exact, but every decoded photo in the thread stays in memory, about 700 in that
  room.

**Consequences / limits:**

- **UIKit still guesses the rows it has not drawn,** at 100 points each, and corrects the offset as it measures each.
  Nothing on screen moves, but the scroll indicator's length is a guess.
- **The audit often names no element for a cell's text.** Its contrast check reported a reaction chip's emoji, and words
  under the composer's glass, as the screen, where the per-element rules could not exempt them. `AuditPolicy` lets such
  a report pass only while every text on screen passes those rules, each measured from its own pixels where no rule
  exempts it, so text that fails still fails.
- **The trap:** correcting the offset for a row measured above the screen. UIKit already has, and a second correction
  throws the thread by the row's difference from the estimate.
- **A cell's environment is hand-fed.** A row that starts reading an environment value from the app gets the default
  in a thread until `MessageList` passes it in. Navigation from a row goes through `openRoute`.
- **History is not windowed.** Every message is an item in the snapshot. knit-next draws 60 and pages in 100 at a
  time.
- **The guards** are `KnitUITests`:
  - `testALongRoomOpensOnItsNewestPost` opens the `long-room` scene three times.
  - `testALongRoomDraggedUpMovesWithTheFinger` drags it up twelve times and checks that a post moves as far as the
    finger each time, to within the pan's 10-point slop. With the second correction, 10 of 12 drags strayed by 20 to
    200 points.
  - `testAThreadScrolledUpOffersTheWayBackToItsNewestMessage` covers the bar's tap to the top, the way back, and our
    own post taking the thread down.

  The Simulator has never shown the blank, so the phone is its only test.
