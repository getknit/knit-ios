/// Bytes from hex; malformed hex is a bug in the test, so it traps.
func hexBytes(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        guard let byte = UInt8(string[index..<next], radix: 16) else {
            fatalError("bad hex in a test vector: \(string)")
        }
        bytes.append(byte)
        index = next
    }
    return bytes
}
