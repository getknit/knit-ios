/// What an iPhone's GATT server holds, as the debug bridge's `advert` reports it beside the link manager's ``AdvertStatus``
/// (ADR 2026-11.prsp, "The bridge and the harness"): ``GattServing``'s layout and serials, read on the CoreBluetooth queue by
/// `BLERadio.servingReport()`, with what the radio was asked to serve and what it was handed back at a restoration. It
/// carries serials and flags, never a value: the payload may hold a tag.
///
/// ``applied(blinded:)`` is the radio's half of `advert blind`'s `applied` (Android's `AdvertSwitch.verdict`): the layout the
/// form asks for is up with the wanted value, and advertising started. The probe reads the rest (ADR 2026-11.prsp, "The
/// Phase 3 probe"): `matchedByOrder` counts `ble matched an added service by order, not identity`, which it expects never to
/// see.
public struct GattServingReport: Sendable, Equatable {
    /// The layout the server builds toward, `nil` before the first advert of a radio that expected neither.
    public let layout: GattServing.Layout?
    /// The doorbell's, the payload's and the combined service's serials, while each is served.
    public let doorbellSerial: UInt64?
    public let payloadSerial: UInt64?
    public let combinedSerial: UInt64?
    /// Whether the combined service's `didAdd` landed.
    public let combinedUp: Bool
    /// The split add in flight.
    public let pendingSerial: UInt64?
    /// Whether this process asked to advertise and has not asked to stop since.
    public let advertising: Bool
    /// When a failed split add may be tried again, on the monotonic clock.
    public let retryAt: Int64?
    /// Whether this process's first clear of the server ran.
    public let cleared: Bool
    /// Whether the doorbell's service failed to add.
    public let doorbellFailed: Bool
    /// The kind of the link manager's last advert, `nil` while the radio holds none to serve.
    public let wanted: AdvertStatus.Kind?
    /// Whether the payload served (P, or the combined service) carries that advert's value.
    public let servesWanted: Bool
    /// The PSM the listener holds, and the one the link manager's last advert named.
    public let listenerPSM: UInt16?
    public let wantedPSM: UInt16?
    /// Whether the radio was made expecting to blind (`BLERadio(expectsBlinding:)`).
    public let expectsBlinding: Bool
    /// How many `0xFE30` services a restoration handed back, `nil` when this process was not restored.
    public let restoredServices: Int?
    /// How many `didAdd` answers were matched by order, not identity.
    public let matchedByOrder: Int
    /// Whether both managers are powered on.
    public let poweredOn: Bool

    /// The report of `serving`, asked to serve `wanted` on `wantedPSM` while the listener holds `listenerPSM`.
    public init(
        serving: GattServing,
        wanted: GattServing.Wanted?,
        listenerPSM: UInt16?,
        wantedPSM: UInt16?,
        expectsBlinding: Bool,
        restoredServices: Int?,
        matchedByOrder: Int,
        poweredOn: Bool
    ) {
        layout = serving.layout
        doorbellSerial = serving.doorbell?.serial
        payloadSerial = serving.payload?.serial
        combinedSerial = serving.combined?.serial
        combinedUp = serving.combinedUp
        pendingSerial = serving.pending?.serial
        advertising = serving.advertising
        retryAt = serving.retryAt
        cleared = serving.cleared
        doorbellFailed = serving.doorbellFailed
        self.wanted = wanted.map { $0.blinded ? .tag : .clear }
        if let wanted {
            servesWanted =
                wanted.blinded ? serving.payload?.value == wanted.value : serving.combinedUp && serving.combined?.value == wanted.value
        } else {
            servesWanted = false
        }
        self.listenerPSM = listenerPSM
        self.wantedPSM = wantedPSM
        self.expectsBlinding = expectsBlinding
        self.restoredServices = restoredServices
        self.matchedByOrder = matchedByOrder
        self.poweredOn = poweredOn
    }

    /// Whether the radio airs a form of kind `blinded` as asked: powered on, advertising, and serving the wanted value in its
    /// layout, the doorbell's service and a payload's with no add in flight while blinding, the combined service while clear.
    public func applied(blinded: Bool) -> Bool {
        guard poweredOn, advertising, servesWanted, wanted == (blinded ? .tag : .clear) else {
            return false
        }
        guard blinded else {
            return layout == .combined && combinedUp
        }
        return layout == .split && doorbellSerial != nil && payloadSerial != nil && pendingSerial == nil
    }
}
