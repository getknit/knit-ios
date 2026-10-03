/// Seeking: a node that iOS may suspend scans for Knit's UUID while it holds no link, and dials whom it finds
/// (ADR 2026-10.mueg).
///
/// A backgrounded iPhone's UUID sits in Apple's overflow area, which only an iOS scan for that UUID reads, so neither an
/// Android phone, nor a BlueZ peer, nor an iPhone at the front can find it, and its own scan for every advert goes quiet
/// there. Once its last link dropped, nothing linked it again until someone opened Knit. Seeking asks the radio to
/// scan for the UUID, which iOS keeps running there and which resumes Knit for about 10 s at each match. In that window
/// the iPhone dials what it found, on one sighting and whatever the order: the 12 s dwell outlasts the wake, and the
/// peer that would dial it cannot see it. Each wake costs battery, so one spell of seeking spends at most
/// ``Configuration/seekWakeBudget`` wakes without a link, then waits for the front.
extension LinkManager {
    /// The wakes one spell of seeking has spent.
    struct SeekSpell {
        /// Wakes spent.
        var wakes = 0
        /// When the current wake began.
        var wakeStartedAt: Int64?
        /// Whether every wake is spent, so seeking waits for the front, a held link's loss, or Bluetooth.
        var spent = false
    }

    /// A deadline found later than this in the background passed while iOS had the app suspended: a timer that fires
    /// while the app runs is late by a few milliseconds at most.
    static let suspendedLatenessMilliseconds: Int64 = 1000

    /// Tells the manager whether the app is in the background, where iOS may suspend it. Coming to the front ends the
    /// spell, so the next one has every wake. Kept while stopped. Answers the links that went down, which is none.
    public func setInBackground(_ background: Bool) -> [Event] {
        guard background != inBackground else {
            return []
        }
        inBackground = background
        if !background {
            spell = SeekSpell()
        }
        log.log(.info, "link \(background ? "in the background" : "at the front")")
        return reconsiderSeeking(now: clock.monotonicMilliseconds())
    }

    /// Seeks while the app is in the background with no link and wakes left, stops otherwise, and tells the radio only
    /// of a change. It runs at the end of every public entry, never inside `retire` or `register`: replacing a stale
    /// link retires one and registers the next, and seeking must not flicker between them.
    func reconsiderSeeking(now: Int64) -> [Event] {
        let wanted = running && inBackground && liveLinks.isEmpty && !spell.spent
        guard wanted != isSeeking else {
            return []
        }
        isSeeking = wanted
        radio.seekPeers(wanted)
        guard wanted else {
            log.log(.info, "link seeking off (\(whySeekingStopped))")
            return []
        }
        seekSpells += 1
        log.log(.info, "link seeking on (background, no links)")
        // A peer heard moments ago, at the front, is dialed now on seeking's rules.
        return promote(now: now)
    }

    private var whySeekingStopped: String {
        if !running {
            return "stopped"
        }
        if !inBackground {
            return "front"
        }
        if !liveLinks.isEmpty {
            return "link up"
        }
        return "budget spent after \(spell.wakes) wakes"
    }

    /// A sighting while seeking. The first in ``Configuration/seekWakeMilliseconds`` begins a wake, counted from its start
    /// so that wakes iOS chains one after another count too. The wake that spends the budget still dials what it found,
    /// and seeking stops after it.
    func countSeekWake(now: Int64) {
        if let started = spell.wakeStartedAt, now - started < configuration.seekWakeMilliseconds {
            return
        }
        spell.wakeStartedAt = now
        spell.wakes += 1
        seekWakes += 1
        log.log(.info, "link seek wake \(spell.wakes) of \(configuration.seekWakeBudget)")
        if spell.wakes >= configuration.seekWakeBudget {
            spell.spent = true
        }
    }

    /// The promotion rules in force. While seeking, a peer is dialed on its first sighting: iOS reports a peer rarely in
    /// the background and resumes Knit for about 10 s, so a 12 s dwell could never end. The floor, the silence limit and
    /// backoff still hold.
    var promotionConfiguration: PromotionPolicy.Configuration {
        guard isSeeking else {
            return configuration.promotion
        }
        var promotion = configuration.promotion
        promotion.dwellMilliseconds = 0
        return promotion
    }

    /// Whether promotion dials a peer whatever the order. While seeking, a radio that cannot advertise service data is
    /// found by no one: its UUID sits in the overflow area, which only an iOS scan for it reads. The peer that the order
    /// says should dial, `FLAG_DIALS_GATT_PEERS` or not, cannot see it. Admission keeps the order (``weDial(_:flags:)``),
    /// so a cross-dial still settles: the larger side refuses a dialer it sighted, and the smaller admits it.
    var dialsWhateverTheOrder: Bool {
        isSeeking && !radio.advertisesServiceData
    }

    /// Puts off `id`'s deadline once when it passed while iOS had the app suspended, and answers whether it did. Timers
    /// do not fire in suspension, so on resume the timer and the radio's news, a dial opened or a HELLO waiting, reach
    /// the manager in no fixed order, and the timer winning would close a link that has just come up.
    func putOffLateDeadline(of id: ChannelID, now: Int64) -> Bool {
        guard inBackground, let channel = channels[id], !channel.putOff, let deadline = channel.deadline,
            now - deadline > Self.suspendedLatenessMilliseconds
        else {
            return false
        }
        channels[id]?.deadline = now + configuration.lateDeadlineGraceMilliseconds
        channels[id]?.putOff = true
        log.log(
            .info,
            "link \(id) found its deadline \(now - deadline) ms late, and waits \(configuration.lateDeadlineGraceMilliseconds) ms more")
        return true
    }
}
