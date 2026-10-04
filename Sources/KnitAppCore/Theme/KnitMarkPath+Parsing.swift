extension KnitMarkPath {
    /// Why path data did not parse.
    public enum PathDataError: Error, Equatable {
        /// A character that is no command, number or separator.
        case unexpected(Character)
        /// A command this parser does not draw, or numbers before any command.
        case unsupported(Character?)
        /// A command whose numbers ran out.
        case missingNumber
    }

    /// `data`'s subpaths in its own coordinates. It reads the commands Android's vectors use, absolute and relative:
    /// move, line, horizontal, vertical, cubic, arc and close.
    static func parse(_ data: String) throws(PathDataError) -> [[Step]] {
        var reader = Reader(tokens: try tokens(data))
        var paths: [[Step]] = []
        var current = zero
        var start = current
        var command: Character?
        while !reader.isAtEnd {
            if case .command(let next) = reader.peek {
                reader.skip()
                command = next
            }
            guard let command else {
                throw .unsupported(nil)
            }
            let relative = command.isLowercase
            switch command.lowercased() {
            case "m":
                current = try reader.point(from: relative ? current : zero)
                start = current
                paths.append([.move(current)])
                // Numbers after a move's first pair are lines.
                while reader.hasNumber {
                    current = try reader.point(from: relative ? current : zero)
                    paths[paths.count - 1].append(.line(current))
                }
            case "l", "h", "v", "c", "a":
                repeat {
                    let from = current
                    let steps = try step(command.lowercased(), reader: &reader, from: from, origin: relative ? from : zero)
                    current = endpoint(steps.last) ?? from
                    try append(steps, to: &paths)
                } while reader.hasNumber
            case "z":
                try append([.close], to: &paths)
                current = start
            default:
                throw .unsupported(command)
            }
        }
        return paths
    }

    /// One drawing command's steps from `from`, its numbers read relative to `origin`.
    private static func step(_ command: String, reader: inout Reader, from: Point, origin: Point) throws(PathDataError) -> [Step] {
        switch command {
        case "l":
            return try [.line(reader.point(from: origin))]
        case "h":
            return try [.line(Point(x: origin.x + reader.number(), y: from.y))]
        case "v":
            return try [.line(Point(x: from.x, y: origin.y + reader.number()))]
        case "c":
            let control1 = try reader.point(from: origin)
            let control2 = try reader.point(from: origin)
            return try [.curve(reader.point(from: origin), control1: control1, control2: control2)]
        default:
            let radiusX = try reader.number()
            let radii = (radiusX, try reader.number())
            let rotation = try reader.number()
            let large = try reader.number() != 0
            let flags = ArcFlags(large: large, sweep: try reader.number() != 0)
            return try arc(from: from, to: reader.point(from: origin), radii: radii, rotation: rotation, flags: flags)
        }
    }

    private static func append(_ steps: [Step], to paths: inout [[Step]]) throws(PathDataError) {
        guard !paths.isEmpty else {
            throw .unsupported(nil)
        }
        paths[paths.count - 1].append(contentsOf: steps)
    }

    enum Token: Equatable {
        case command(Character)
        case number(Double)
    }

    /// `data` as commands and numbers. A sign, or a second decimal point, starts a new number, as in "1.5-2" and "1.5.5".
    static func tokens(_ data: String) throws(PathDataError) -> [Token] {
        var tokens: [Token] = []
        var number = ""
        let flush = { (number: inout String, tokens: inout [Token]) in
            if let value = Double(number) {
                tokens.append(.number(value))
            }
            number = ""
        }
        for character in data {
            switch character {
            case "0"..."9", "e", "E":
                number.append(character)
            case "-", "+":
                if number.last != "e", number.last != "E" {
                    flush(&number, &tokens)
                }
                number.append(character)
            case ".":
                if number.contains(".") || number.contains("e") || number.contains("E") {
                    flush(&number, &tokens)
                }
                number.append(character)
            case ",", " ", "\n", "\t", "\r":
                flush(&number, &tokens)
            case _ where character.isLetter:
                flush(&number, &tokens)
                tokens.append(.command(character))
            default:
                throw .unexpected(character)
            }
        }
        flush(&number, &tokens)
        return tokens
    }

    /// Reads tokens in order.
    struct Reader {
        let tokens: [Token]
        var index = 0

        var isAtEnd: Bool {
            index >= tokens.count
        }

        var peek: Token? {
            isAtEnd ? nil : tokens[index]
        }

        var hasNumber: Bool {
            if case .number = peek {
                return true
            }
            return false
        }

        mutating func skip() {
            index += 1
        }

        mutating func number() throws(PathDataError) -> Double {
            guard case .number(let value) = peek else {
                throw .missingNumber
            }
            index += 1
            return value
        }

        mutating func point(from origin: Point) throws(PathDataError) -> Point {
            let along = try number()
            let down = try number()
            return Point(x: origin.x + along, y: origin.y + down)
        }
    }
}
