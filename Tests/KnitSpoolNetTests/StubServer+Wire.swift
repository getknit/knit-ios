import Foundation

#if canImport(Compression)
    import Compression
#endif

/// What the stub writes and reads on the wire: RFC 6455's frames, an HTTP answer, and a request head's headers.
extension StubServer {
    /// A server frame, unmasked, RSV1 set when `compressed`.
    static func frame(opcode: UInt8, _ payload: [UInt8], fin: Bool = true, compressed: Bool = false) -> [UInt8] {
        var frame: [UInt8] = [(fin ? 0x80 : 0) | (compressed ? 0x40 : 0) | opcode]
        switch payload.count {
        case ..<126:
            frame.append(UInt8(payload.count))
        case ..<65_536:
            frame += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default:
            frame.append(127)
            frame += (0..<8).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) }
        }
        return frame + payload
    }

    #if canImport(Compression)
        /// `bytes` as `permessage-deflate` sends them (RFC 7692 §7.2.1): raw DEFLATE, here ending in a final block, then the
        /// first byte of the empty stored block whose last four bytes the sender drops (§8.2.3.4's form).
        static func deflate(_ bytes: [UInt8]) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: bytes.count + 1024)
            let size = out.withUnsafeMutableBufferPointer { destination in
                bytes.withUnsafeBufferPointer { source in
                    guard let to = destination.baseAddress, let from = source.baseAddress else {
                        return 0
                    }
                    return compression_encode_buffer(to, destination.count, from, source.count, nil, COMPRESSION_ZLIB)
                }
            }
            return Array(out[..<size]) + [0x00]
        }
    #endif

    /// One client frame's payload, unmasked, or `nil`.
    static func readFrame(_ descriptor: Int32) -> [UInt8]? {
        guard let head = Loopback.read(descriptor, exactly: 2) else {
            return nil
        }
        var length = Int(head[1] & 0x7F)
        if length == 126, let more = Loopback.read(descriptor, exactly: 2) {
            length = Int(more[0]) << 8 | Int(more[1])
        } else if length == 127, let more = Loopback.read(descriptor, exactly: 8) {
            length = more.reduce(0) { $0 << 8 | Int($1) }
        }
        let mask = head[1] & 0x80 != 0 ? Loopback.read(descriptor, exactly: 4) ?? [0, 0, 0, 0] : [0, 0, 0, 0]
        guard let payload = Loopback.read(descriptor, exactly: length) else {
            return nil
        }
        return payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
    }

    static func response(status: Int, headers: [(String, [UInt8])]) -> [UInt8] {
        var bytes = Array("HTTP/1.1 \(status) \(reason(status))\r\n".utf8)
        for (name, value) in headers {
            bytes += Array("\(name): ".utf8) + value + Array("\r\n".utf8)
        }
        if status != 101 {
            bytes += Array("Content-Length: 0\r\n".utf8)
        }
        return bytes + Array("\r\n".utf8)
    }

    static func upgradeHeaders(accept: String) -> [(String, [UInt8])] {
        [("Upgrade", Array("websocket".utf8)), ("Connection", Array("Upgrade".utf8)), ("Sec-WebSocket-Accept", Array(accept.utf8))]
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 101:
            "Switching Protocols"
        case 302:
            "Found"
        case 503:
            "Service Unavailable"
        default:
            "Status"
        }
    }

    /// The value of the header `name` in `head`, matched ignoring case, or `nil`.
    static func header(_ name: String, in head: String) -> String? {
        for line in head.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == name.lowercased() else {
                continue
            }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
