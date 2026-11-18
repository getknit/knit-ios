// Internet relays (ADR 2026-11.adrq, P6), apart from `AccessibilityID.swift` only to keep that file under the lint's length.
// A relay's controls are named by its handle, never its host, so no identifier carries an address. Android has no tag for
// any of these.
extension AccessibilityID {
    /// Settings' Internet relays switch, in a debug build.
    public static let settingsInternetRelays = "settings_internet_relays"
    /// Settings' Paste, which adds a relay from an invite link.
    public static let relaysPaste = "relays_paste"
    /// The consent sheet, for the switch or an invite.
    public static let relaysConsent = "relays_consent"
    /// The consent sheet's Turn on or Add relay.
    public static let relaysConsentAccept = "relays_consent_accept"
    /// The consent sheet's Not now.
    public static let relaysConsentDecline = "relays_consent_decline"

    /// The relay `handle`'s row.
    public static func relayRow(_ handle: Int) -> String {
        "relay_row_\(handle)"
    }

    /// The relay `handle`'s Stop using, or Use again.
    public static func relayPark(_ handle: Int) -> String {
        "relay_park_\(handle)"
    }

    /// The relay `handle`'s Remove.
    public static func relayRemove(_ handle: Int) -> String {
        "relay_remove_\(handle)"
    }
}
