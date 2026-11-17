// Every file in KnitSpoolNet compiles into a debug build alone while the spool plane does (ADR 2026-11.adrq): a store build
// reaches none of it.
#if DEBUG
    import Foundation
    import KnitWire

    /// The address check a relay's dial runs before any socket opens (ADR 2026-11.adrq, P5). It reads the text once more and
    /// refuses unless every reading agrees:
    ///
    /// - the whole factory again: ``AcceptedSpoolURL/init(_:allowCleartext:)`` on ``AcceptedSpoolURL/socketURLText`` with
    ///   the build's cleartext flag takes it and gives back an equal address, and ``SpoolURL/isAcceptable(_:allowCleartext:)``
    ///   takes its scheme (C-7.1-2);
    /// - one parse of the host: Foundation's `URLComponents` reads the scheme `wss`, or `ws` where the build dials cleartext,
    ///   no user info and no fragment, a host that is not empty, and a port, if any, of 1 to 65535; and its
    ///   `percentEncodedHost` and `port`, written as `host[:port]`, are the bytes ``SpoolURL/host(_:)`` reads from the same
    ///   text;
    /// - the URL Foundation builds prints as the text, byte for byte, so the socket dials exactly what was accepted.
    ///
    /// ``AcceptedSpoolURL`` already refuses a `%` in the authority, so no reading decodes a host into another one.
    internal enum SpoolDialCheck {
        /// The secure scheme, which every build dials.
        private static let secureScheme = "wss"
        /// The cleartext scheme, which a debug build dials to this phone or its network.
        private static let cleartextScheme = "ws"
        /// The ports a URL may name.
        private static let ports = 1...65_535

        /// The URL to dial for `url`, or `nil` when any reading disagrees. `cleartext` is the build's compile-time flag.
        static func target(for url: AcceptedSpoolURL, cleartext: Bool) -> URL? {
            let text = url.socketURLText
            guard AcceptedSpoolURL(text, allowCleartext: cleartext) == url, SpoolURL.isAcceptable(text, allowCleartext: cleartext),
                let parsed = URLComponents(string: text), let scheme = parsed.scheme,
                scheme == secureScheme || (cleartext && scheme == cleartextScheme),
                parsed.percentEncodedUser == nil, parsed.percentEncodedPassword == nil, parsed.percentEncodedFragment == nil,
                let host = parsed.percentEncodedHost, !host.isEmpty, parsed.port.map(ports.contains) != false
            else {
                return nil
            }
            let authority = host + (parsed.port.map { ":\($0)" } ?? "")
            guard authority.utf8.elementsEqual(SpoolURL.host(text).utf8), let built = parsed.url,
                built.absoluteString.utf8.elementsEqual(text.utf8)
            else {
                return nil
            }
            return built
        }
    }
#endif
