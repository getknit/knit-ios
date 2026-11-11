/// The writer's counts (ADR 2026-11.prsp, "Counts, never dated causes").
extension LinkManager {
    /// What the writer did, counts only, never a tag, a key, a slot or a time (ADR 2026-11.prsp, "Counts, never dated
    /// causes"): what `status` reports.
    public struct WriterCounters: Sendable, Equatable {
        /// Rotations, by cause (`bleRotations`).
        public var rotationsBySlot = 0
        public var rotationsByBringUp = 0
        public var rotationsByKeyChange = 0
        public var rotationsByFlip = 0
        public var rotationsForced = 0
        /// Rotations that aired a tag nobody was told of.
        public var unannounced = 0
        /// Random tags, by why: no key, a key the engine moved past, a mark write that failed, a slot out of restarts.
        public var randomNoKey = 0
        public var randomKeyMoved = 0
        public var randomMarkFailed = 0
        public var randomScheduled = 0
        /// Slotted tags that resolve, and answers that found the mark stale.
        public var resolvable = 0
        public var stale = 0
        /// Passes asked of the engine for a stale mark, at most one per generation.
        public var staleMarkPasses = 0
        /// `TAG_NEXT` records sent, by kind.
        public var tagNextAnnounced = 0
        public var tagNextCurrent = 0
        public var tagNextResent = 0
        /// `TAG_NEXT` sends refused, by why.
        public var tagNextNoKey = 0
        public var tagNextIneligible = 0
        public var tagNextThrottled = 0
        public var tagNextBeforeAnnounce = 0
        /// `TAG_NEXT` records written behind bytes the link still held: Android's first-in-first-out parity, which a back-fill
        /// can carry past the edge.
        public var tagNextBehindQueue = 0
        /// Dialers refused for lacking `CAP_BLIND_ADVERT` while we blind (`RefuseLegacy`).
        public var refusedLegacy = 0
        /// Dialers refused over a held link they missed a rotation on (`RefuseHeld`).
        public var refusedHeld = 0
        /// Advert payloads dropped because they did not carry the snapshot's form alone.
        public var droppedPayloads = 0
        /// Announced forms that became their link's at the edge.
        public var linkFormsApplied = 0

        mutating func rotated(_ cause: AdvertRotation.Cause) {
            switch cause {
            case .slot:
                rotationsBySlot += 1
            case .bringUp:
                rotationsByBringUp += 1
            case .fresh:
                rotationsByKeyChange += 1
            case .flip:
                rotationsByFlip += 1
            case .forced:
                rotationsForced += 1
            }
        }

        mutating func chose(_ choice: TagChoice.Choice) {
            switch choice.source {
            case .noKey:
                randomNoKey += 1
            case .keyMoved:
                randomKeyMoved += 1
            case .markFailed:
                randomMarkFailed += 1
            case .slotted, .announced:
                if choice.resolvable {
                    resolvable += 1
                } else {
                    randomScheduled += 1
                }
                stale += choice.stale ? 1 : 0
            }
        }

        mutating func sent(_ kind: TagNextSends<ChannelID>.Kind, _ outcome: TagNextSends<ChannelID>.Outcome) {
            switch (outcome, kind) {
            case (.sent, .announce):
                tagNextAnnounced += 1
            case (.sent, .current):
                tagNextCurrent += 1
            case (.sent, .resend):
                tagNextResent += 1
            case (.noKey, _):
                tagNextNoKey += 1
            case (.ineligible, _):
                tagNextIneligible += 1
            case (.throttled, _):
                tagNextThrottled += 1
            case (.beforeAnnounce, _):
                tagNextBeforeAnnounce += 1
            }
        }
    }
}
