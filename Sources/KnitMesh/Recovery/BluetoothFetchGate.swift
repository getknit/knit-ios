/// Which of our attachments declare their plaintext length, so a receiver's "Ask before large Bluetooth downloads" can
/// hold a large one for a tap (`BluetoothFetchGate.kt:23` and `:48-51` at knit-next `eac3debc`, knit-next ADRs 2026-10.js2p
/// and 2026-10.hmfe). Below the floor nothing is declared, so an ordinary photo frame stays byte for byte what it was.
///
/// Kotlin's `declaresSize` also declares every named file's size. This port sends no named file, so that arm is not
/// ported: every attachment of ours is a photo or a voice note, neither of which carries a name, so each is judged on its
/// length alone. The receiving side, Kotlin's `fastOnly`, is knit-ios #8's.
internal enum BluetoothFetchGate {
    /// The length at and above which a photo or a voice note declares itself (`DECLARE_SIZE_FLOOR`,
    /// `BluetoothFetchGate.kt:18-22` at knit-next `e63f15f4`): the smallest limit an Android user can pick, so every
    /// attachment a limit could hold carries its size. The same on every platform.
    static let declareSizeFloor: Int64 = 1_000_000

    /// Whether an attachment of `sizeBytes`, its plaintext length before any seal, declares that length.
    static func declaresSize(_ sizeBytes: Int64) -> Bool {
        sizeBytes >= declareSizeFloor
    }
}
