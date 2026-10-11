/// How `knit-peer stranger` stands in for a device that advertises the `0xFE30` UUID but is no Knit node, the
/// stimulus knit-next #154's GATT read budget is trialled against (knit-ios #3). It advertises the UUID alone, as an
/// iPhone does, so a phone that reads payloads connects to read it. It runs no link manager and hangs up on any dialer
/// before a HELLO, so it never links. With LE privacy on its adapter, each fresh registration goes out from a new
/// address, and a phone takes it for a new device each time.
public struct StrangerOptions: Equatable, Sendable {
    /// What its GATT service serves.
    public enum Payload: String, Equatable, Sendable, CaseIterable {
        /// The doorbell alone, so a reader files it as a stranger (`--payload none`).
        case withheld = "none"
        /// A valid payload naming ``StrangerOptions/forgedNodeText``, which sorts above every real node, so no phone
        /// ever dials it and no link ever vouches for what it read.
        case forged = "forged"
    }

    /// The node id a forged payload names: the highest canonical id. Ids sort as ASCII text, so the top is every
    /// character `z` but the last, which a canonical id pins to one of `a e i m q u y 4`; `0xFF…` bytes would spell
    /// `777…`, which sorts below every letter.
    public static let forgedNodeText = "zzzzzzzzzzzzzzzzzzzzzzzzzy"

    /// The address of the adapter to advertise on, or `nil` when neither the flag nor the environment names one.
    public var adapterAddress: String?
    /// Whether other devices use the adapter too, which a reserved one needs (`AdapterSelection.shared`).
    public var sharedAdapter = false
    /// The adapters refused unless shared, from `PeerCommand.reservedVariable`.
    public var reservedAdapters: [String] = []
    /// What the GATT service serves.
    public var payload = Payload.withheld
    /// How often the advert is registered afresh, in seconds.
    public var rotateSeconds = 20
    /// How long to advertise before stopping.
    public var seconds = 1800
    /// The lowest level logged to standard error.
    public var logLevel = "info"

    static let longest = 7200

    init(flags: inout Flags, environment: [String: String]) throws(UsageError) {
        logLevel = try flags.take("--log", oneOf: ["debug", "info", "warning"]) ?? logLevel
        adapterAddress = flags.take("--adapter-address") ?? AdapterEnvironment.address(environment)
        sharedAdapter = flags.take(switch: "--shared-adapter")
        reservedAdapters = AdapterEnvironment.reserved(environment)
        payload = try flags.take("--payload", oneOf: Payload.allCases.map(\.rawValue)).flatMap(Payload.init(rawValue:)) ?? payload
        rotateSeconds = try Self.seconds(flags.take("--rotate"), flag: "--rotate") ?? rotateSeconds
        seconds = try Self.seconds(flags.take("--seconds"), flag: "--seconds") ?? seconds
    }

    private static func seconds(_ text: String?, flag: String) throws(UsageError) -> Int? {
        guard let text else {
            return nil
        }
        guard let parsed = Int(text), (1...Self.longest).contains(parsed) else {
            throw .invalid(flag: flag, value: text)
        }
        return parsed
    }
}
