import Testing

extension RatchetSessionLabTests {
    /// How the two resets of ``bothResetWithinASecondAndEachAnswersTheOthersFlaggedInit(_:)`` meet.
    struct Meeting: Sendable, CustomTestStringConvertible {
        /// Apart, then meeting: the first reset comes by back-fill, and the second, written just before, crosses the new
        /// link live (``EngineLab/link(_:_:holding:)`` carries what is undrained). Linked, every frame is in flight in order.
        let apart: Bool
        /// The smaller id resets first.
        let smallerFirst: Bool
        /// The larger id's frames to the smaller are held at the meeting, then released with its reset last (#89's order).
        let largerResetLast: Bool
        /// With ``largerResetLast``, both back-fills go as a build before the paced rounds serves them, profiles first and then
        /// newest first (the `custody-carry-policy` contract, §9); without it, as this port serves them, the smaller id's
        /// unheld, a recipient's own DMs oldest first (§1).
        let olderCarrier: Bool

        var testDescription: String {
            let held = largerResetLast ? ", the larger id's reset last\(olderCarrier ? " behind an older carrier" : "")" : ""
            return "\(apart ? "apart" : "linked"), the \(smallerFirst ? "smaller" : "larger") id first\(held)"
        }

        /// The four plain meetings, then #89's behind an older carrier, then the same behind this port's own order.
        static let all =
            [true, false].flatMap { apart in
                [true, false].map { Self(apart: apart, smallerFirst: $0, largerResetLast: false, olderCarrier: false) }
            }
            + [true, false].map { Self(apart: true, smallerFirst: true, largerResetLast: true, olderCarrier: $0) }
    }
}
