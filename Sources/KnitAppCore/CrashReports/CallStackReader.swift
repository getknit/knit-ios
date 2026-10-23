/// Reads MetricKit's call-stack JSON into a ``CallStackTree`` in one pass, without recursion.
///
/// Foundation's `JSONDecoder` and `JSONSerialization` refuse JSON nested past 512 levels (measured on Linux 2026-10-23;
/// Darwin's decoder is the same swift-foundation code), and every frame nests an object in an array, so a stack past 255
/// frames would not decode, and a stack overflow is a crash worth reporting. This reader tracks where it is with a
/// stack of its own, builds each frame as its object closes, and skips any frame deeper than ``maxFrameDepth``: the
/// innermost frames are the roots, so what it drops is the outermost, `main` and below. It keeps only the keys
/// ``CallStackTree`` names and reads past every other.
internal struct CallStackReader {
    /// The deepest frame kept. Apple's own crash reports keep 512 frames, and the frames destroyed at the end of a read
    /// recurse once per level.
    static let maxFrameDepth = 512

    /// The tree in `bytes`, or `nil` when they are not JSON whose top level is an object.
    static func read(_ bytes: [UInt8]) -> CallStackTree? {
        var reader = Self(scanner: JSONScanner(bytes: bytes))
        return reader.run() ? CallStackTree(callStacks: reader.stacks) : nil
    }

    private enum ObjectKind {
        case root, stack, frame, other
    }

    private enum ArrayKind {
        case callStacks, rootFrames, subFrames, other
    }

    private enum Container {
        case object(ObjectKind)
        case array(ArrayKind)
    }

    /// What may come next.
    private enum Expect {
        case value, valueOrClose, keyOrClose, key, colon, commaOrClose, end
    }

    private var scanner: JSONScanner
    private var containers: [Container] = []
    /// The key last read. A value in an object comes straight after its key, so this is the key of the value being
    /// read, or of the array being opened, whenever the innermost container is an object.
    private var key: String?
    private var expect = Expect.value
    private var stacks: [CallStackTree.Stack] = []
    private var stack: CallStackTree.Stack?
    /// The frames whose objects are open, innermost last.
    private var frames: [CallStackTree.Frame] = []

    private init(scanner: JSONScanner) {
        self.scanner = scanner
    }

    private var expectsValue: Bool { expect == .value || expect == .valueOrClose }

    private mutating func run() -> Bool {
        guard case .beginObject = scanner.next() else {
            return false
        }
        open(.beginObject)
        while expect != .end {
            guard let token = scanner.next(), take(token) else {
                return false
            }
        }
        return scanner.next() == nil && scanner.atEnd
    }

    private mutating func take(_ token: JSONScanner.Token) -> Bool {
        switch token {
        case .beginObject, .beginArray:
            guard expectsValue else {
                return false
            }
            open(token)
        case .endObject:
            guard case .object(let kind) = containers.last, expect == .keyOrClose || expect == .commaOrClose else {
                return false
            }
            containers.removeLast()
            close(kind)
            done()
        case .endArray:
            guard case .array = containers.last, expect == .valueOrClose || expect == .commaOrClose else {
                return false
            }
            containers.removeLast()
            done()
        case .colon:
            guard expect == .colon else {
                return false
            }
            expect = .value
        case .comma:
            guard expect == .commaOrClose, let last = containers.last else {
                return false
            }
            if case .object = last {
                expect = .key
            } else {
                expect = .value
            }
        case .string(let text) where expect == .keyOrClose || expect == .key:
            key = text
            expect = .colon
        case .string, .number, .literal:
            guard expectsValue else {
                return false
            }
            keep(token)
            done()
        }
        return true
    }

    private mutating func open(_ token: JSONScanner.Token) {
        if case .beginArray = token {
            var kind = ArrayKind.other
            if case .object(let parent) = containers.last {
                switch (parent, key) {
                case (.root, "callStacks"):
                    kind = .callStacks
                case (.stack, "callStackRootFrames"):
                    kind = .rootFrames
                case (.frame, "subFrames"):
                    kind = .subFrames
                default:
                    break
                }
            }
            containers.append(.array(kind))
            expect = .valueOrClose
            return
        }
        var kind = ObjectKind.other
        switch containers.last {
        case nil:
            kind = .root
        case .array(.callStacks):
            kind = .stack
            stack = CallStackTree.Stack()
        case .array(.rootFrames), .array(.subFrames):
            if frames.count < Self.maxFrameDepth {
                kind = .frame
                frames.append(CallStackTree.Frame())
            }
        default:
            break
        }
        containers.append(.object(kind))
        expect = .keyOrClose
    }

    private mutating func close(_ kind: ObjectKind) {
        switch kind {
        case .frame:
            let frame = frames.removeLast()
            if frames.isEmpty {
                stack?.callStackRootFrames.append(frame)
            } else {
                frames[frames.count - 1].subFrames.append(frame)
            }
        case .stack:
            if let stack {
                stacks.append(stack)
            }
            stack = nil
        case .root, .other:
            break
        }
    }

    private mutating func done() {
        expect = containers.isEmpty ? .end : .commaOrClose
    }

    /// A value under a key ``CallStackTree`` keeps; any other is read past.
    private mutating func keep(_ token: JSONScanner.Token) {
        guard case .object(let kind) = containers.last, let key else {
            return
        }
        switch (kind, key, token) {
        case (.stack, "threadAttributed", .literal(let literal)):
            stack?.threadAttributed = literal == .true
        case (.frame, "binaryName", .string(let text)):
            frames[frames.count - 1].binaryName = text
        case (.frame, "binaryUUID", .string(let text)):
            frames[frames.count - 1].binaryUUID = text
        case (.frame, "address", .number(let text)):
            frames[frames.count - 1].address = Self.unsigned(text)
        case (.frame, "offsetIntoBinaryTextSegment", .number(let text)):
            frames[frames.count - 1].offsetIntoBinaryTextSegment = Self.unsigned(text)
        case (.frame, "sampleCount", .number(let text)):
            frames[frames.count - 1].sampleCount = Int(clamping: Self.unsigned(text))
        default:
            break
        }
    }

    /// A number's text as a whole number: an address above 2^53 would lose its low bits through a `Double`.
    private static func unsigned(_ text: String) -> UInt64 {
        UInt64(text) ?? Double(text).flatMap { UInt64(exactly: $0) } ?? 0
    }
}

/// JSON's tokens, one at a time.
internal struct JSONScanner {
    /// `true`, `false` or `null`.
    enum Literal: Equatable {
        case `true`, `false`, null
    }

    /// A token.
    enum Token: Equatable {
        case beginObject, endObject, beginArray, endArray, colon, comma
        case string(String)
        /// A number as its text, which the reader turns into the width it needs.
        case number(String)
        case literal(Literal)
    }

    private static let whitespace = Set(" \t\n\r".utf8)
    private static let punctuation: [UInt8: Token] = [
        UInt8(ascii: "{"): .beginObject, UInt8(ascii: "}"): .endObject, UInt8(ascii: "["): .beginArray, UInt8(ascii: "]"): .endArray,
        UInt8(ascii: ":"): .colon, UInt8(ascii: ","): .comma,
    ]
    /// A literal's first byte, the rest of its spelling, and the literal.
    private static let literals: [UInt8: (rest: String, literal: Literal)] = [
        UInt8(ascii: "t"): ("rue", .true), UInt8(ascii: "f"): ("alse", .false), UInt8(ascii: "n"): ("ull", .null),
    ]
    private static let numberStarts = Set("-0123456789".utf8)
    private static let numberBytes = Set("0123456789+-.eE".utf8)
    private static let escapes: [UInt8: Unicode.Scalar] = [
        UInt8(ascii: "\""): "\"", UInt8(ascii: "\\"): "\\", UInt8(ascii: "/"): "/", UInt8(ascii: "b"): "\u{08}",
        UInt8(ascii: "f"): "\u{0C}",
        UInt8(ascii: "n"): "\n", UInt8(ascii: "r"): "\r", UInt8(ascii: "t"): "\t",
    ]
    /// Below this, a byte is a control character, which a string must escape.
    private static let firstPrintable: UInt8 = 0x20
    private static let hexDigits = 4
    private static let hexRadix = 16
    private static let highSurrogates: Range<UInt32> = 0xD800..<0xDC00
    private static let lowSurrogates: Range<UInt32> = 0xDC00..<0xE000
    private static let surrogateBits: UInt32 = 10
    private static let firstSupplementary: UInt32 = 0x10000

    private let bytes: [UInt8]
    private var index = 0
    /// Whether the scanner stopped at the end of its input rather than at something it could not read.
    private(set) var atEnd = false

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// The next token, or `nil` at the end or at anything that is not JSON.
    mutating func next() -> Token? {
        while index < bytes.count, Self.whitespace.contains(bytes[index]) {
            index += 1
        }
        guard index < bytes.count else {
            atEnd = true
            return nil
        }
        let byte = bytes[index]
        index += 1
        if let token = Self.punctuation[byte] {
            return token
        }
        if let literal = Self.literals[byte] {
            return word(literal.rest) ? .literal(literal.literal) : nil
        }
        if byte == UInt8(ascii: "\"") {
            return string().map(Token.string)
        }
        return Self.numberStarts.contains(byte) ? number(from: index - 1) : nil
    }

    private mutating func word(_ rest: String) -> Bool {
        let tail = Array(rest.utf8)
        guard bytes.count - index >= tail.count, Array(bytes[index..<index + tail.count]) == tail else {
            return false
        }
        index += tail.count
        return true
    }

    private mutating func number(from start: Int) -> Token? {
        while index < bytes.count, Self.numberBytes.contains(bytes[index]) {
            index += 1
        }
        guard let text = String(validating: bytes[start..<index], as: UTF8.self), Double(text) != nil else {
            return nil
        }
        return .number(text)
    }

    /// A string's contents after its opening quote, escapes decoded.
    private mutating func string() -> String? {
        var scalars = String.UnicodeScalarView()
        var run = index
        func flush(_ end: Int) -> Bool {
            guard end > run else {
                return true
            }
            guard let text = String(validating: bytes[run..<end], as: UTF8.self) else {
                return false
            }
            scalars.append(contentsOf: text.unicodeScalars)
            return true
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                guard flush(index) else {
                    return nil
                }
                index += 1
                return String(scalars)
            }
            guard byte >= Self.firstPrintable else {
                return nil
            }
            guard byte == UInt8(ascii: "\\") else {
                index += 1
                continue
            }
            guard flush(index), let scalar = escape() else {
                return nil
            }
            scalars.append(scalar)
            run = index
        }
        return nil
    }

    /// The character a backslash escape stands for, the index past it.
    private mutating func escape() -> Unicode.Scalar? {
        index += 1
        guard index < bytes.count else {
            return nil
        }
        let byte = bytes[index]
        index += 1
        if let scalar = Self.escapes[byte] {
            return scalar
        }
        guard byte == UInt8(ascii: "u"), let high = hex4() else {
            return nil
        }
        guard Self.highSurrogates.contains(high) else {
            return Unicode.Scalar(high) ?? "\u{FFFD}"
        }
        // A surrogate pair: the low half must follow as an escape of its own.
        guard word("\\u"), let low = hex4(), Self.lowSurrogates.contains(low) else {
            return nil
        }
        let offset = ((high - Self.highSurrogates.lowerBound) << Self.surrogateBits) + (low - Self.lowSurrogates.lowerBound)
        return Unicode.Scalar(Self.firstSupplementary + offset)
    }

    private mutating func hex4() -> UInt32? {
        guard bytes.count - index >= Self.hexDigits,
            let text = String(validating: bytes[index..<index + Self.hexDigits], as: UTF8.self),
            let value = UInt32(text, radix: Self.hexRadix)
        else {
            return nil
        }
        index += Self.hexDigits
        return value
    }
}
