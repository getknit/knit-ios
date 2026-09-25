extension String {
    /// A string from bytes the caller built from an ASCII alphabet, so they are always valid UTF-8.
    init(ascii bytes: [UInt8]) {
        self.init(decoding: bytes, as: UTF8.self)
    }
}
