/// The run's switches for device trials, apart from `PeerCommand.swift` to keep its length in bounds.
extension RunOptions {
    /// What `--seal` takes: the link manager's seal switches, by name.
    static let sealSwitches = ["on", "off", "downgrade", "plain-reply"]
    /// The LE dynamic PSMs `--psm` takes, which a process may bind without privilege.
    static let dynamicPSMs = 0x80...0xFF

    /// `--psm PSM`, or `nil` when not given: the listener binds it, so a trial that switches `--seal` gives a fresh one
    /// and a phone holding the GATT payload from before fails at connect and reads it again (the `link-seal` contract,
    /// revision 2).
    static func psm(_ text: String?) throws(UsageError) -> Int? {
        guard let text else {
            return nil
        }
        guard let psm = Int(text), dynamicPSMs.contains(psm) else {
            throw .invalid(flag: "--psm", value: text)
        }
        return psm
    }

    /// The longest `--stop-reading-after` taken: a day.
    static let longestStopReadingAfter = 86_400

    /// `--receive-mtu` or `--send-mtu`, or `nil` when not given: development knobs (`.agents/context/linux-peer.md`).
    static func mtu(_ text: String?, flag: String) throws(UsageError) -> Int? {
        guard let text else {
            return nil
        }
        guard let mtu = Int(text), Self.mtuRange.contains(mtu) else {
            throw .invalid(flag: flag, value: text)
        }
        return mtu
    }

    /// The most `--flood` writes: 16 MiB a second, far past what an L2CAP channel carries.
    static let largestFlood = 16 << 20

    /// `--flood BYTES_PER_SECOND`, or `nil` when not given: the peer floods every live link with undecodable frames, which
    /// the far end's inbound credit is tried against (ADR 2026-10.f5zs, rule 6).
    static func flood(_ text: String?) throws(UsageError) -> Int? {
        guard let text else {
            return nil
        }
        guard let rate = Int(text), (1...largestFlood).contains(rate) else {
            throw .invalid(flag: "--flood", value: text)
        }
        return rate
    }

    /// `--stop-reading-after SECONDS`, or `nil` when not given: the far end's writes to the peer stall once it stops
    /// reading, which that end's overfull bound and stall close are tried against (ADR 2026-10.f5zs).
    static func stopReadingAfter(_ text: String?) throws(UsageError) -> Int? {
        guard let text else {
            return nil
        }
        guard let seconds = Int(text), (0...longestStopReadingAfter).contains(seconds) else {
            throw .invalid(flag: "--stop-reading-after", value: text)
        }
        return seconds
    }
}
