import Foundation
import Testing

@testable import KnitAppCore

/// Knit's mark, parsed from Android's path data, and the parser's arcs and commands (ADR 2026-10.5waw).
@Suite struct KnitMarkPathTests {
    private typealias Point = KnitMarkPath.Point

    /// How far two computed coordinates may differ and still agree.
    private static let tolerance = 1e-6

    @Test func theMarkIsSevenClosedStitchesFitToTheUnitSquare() {
        let stitches = KnitMarkPath.stitches
        #expect(stitches.count == 7)
        #expect(stitches.allSatisfy { $0.last == .close })
        // The node carries its hole, a second subpath wound the other way.
        #expect(stitches[1].filter { if case .move = $0 { true } else { false } }.count == 2)
        let points = stitches.flatMap { $0.compactMap(Self.endpoint) }
        #expect(points.allSatisfy { (-Self.tolerance...1 + Self.tolerance).contains($0.x) })
        #expect(points.allSatisfy { (-Self.tolerance...1 + Self.tolerance).contains($0.y) })
        // The K is taller than it is wide, so its height fills the square.
        #expect((points.map(\.y).min() ?? 1) < 0.05 && (points.map(\.y).max() ?? 0) > 0.95)
        #expect((points.map(\.x).min() ?? 0) > 0.05 && (points.map(\.x).max() ?? 1) < 0.95)
    }

    @Test func aQuarterTurnIsOneCurveWithTheCirclesHandle() throws {
        let steps = KnitMarkPath.arc(
            from: Point(x: 1, y: 0), to: Point(x: 0, y: 1), radii: (1, 1), rotation: 0, flags: .init(large: false, sweep: true))
        let handle = 4.0 / 3.0 * tan(Double.pi / 8)
        #expect(steps.count == 1)
        guard case .curve(let end, let control1, let control2) = try #require(steps.first) else {
            Issue.record("not a curve")
            return
        }
        #expect(end == Point(x: 0, y: 1))
        #expect(Self.near(control1, Point(x: 1, y: handle)) && Self.near(control2, Point(x: handle, y: 1)))
    }

    @Test func theLargeArcGoesTheLongWayRound() {
        let small = KnitMarkPath.arc(
            from: Point(x: 1, y: 0), to: Point(x: 0, y: 1), radii: (1, 1), rotation: 0, flags: .init(large: false, sweep: true))
        let large = KnitMarkPath.arc(
            from: Point(x: 1, y: 0), to: Point(x: 0, y: 1), radii: (1, 1), rotation: 0, flags: .init(large: true, sweep: true))
        let back = KnitMarkPath.arc(
            from: Point(x: 1, y: 0), to: Point(x: 0, y: 1), radii: (1, 1), rotation: 0, flags: .init(large: false, sweep: false))
        #expect(small.count == 1 && large.count == 3 && back.count == 1)
    }

    @Test func radiiTooSmallGrowToSpanTheEnds() {
        let steps = KnitMarkPath.arc(
            from: Point(x: 0, y: 0), to: Point(x: 4, y: 0), radii: (1, 1), rotation: 90, flags: .init(large: false, sweep: true))
        #expect(steps.count == 2)
        // Half way round a circle of radius two about (2, 0).
        if case .curve(let middle, _, _) = steps.first {
            #expect(abs(abs(middle.y) - 2) < Self.tolerance && abs(middle.x - 2) < Self.tolerance)
        }
        #expect(Self.endpoint(steps[1]) == Point(x: 4, y: 0))
    }

    @Test func anArcWithNoRadiusIsALineAndOneToItsStartIsNothing() {
        let line = KnitMarkPath.arc(
            from: Point(x: 0, y: 0), to: Point(x: 1, y: 1), radii: (0, 1), rotation: 0, flags: .init(large: false, sweep: true))
        #expect(line == [.line(Point(x: 1, y: 1))])
        #expect(
            KnitMarkPath.arc(
                from: Point(x: 1, y: 1), to: Point(x: 1, y: 1), radii: (1, 1), rotation: 0, flags: .init(large: false, sweep: true)
            ).isEmpty)
    }

    @Test func relativeAndAbsoluteCommandsDrawTheSamePath() throws {
        let relative = try KnitMarkPath.parse("M0,0 l10,0 h5 v5 c1,1 2,2 3,3 a1,1 0 0 1 1,1 z")
        let absolute = try KnitMarkPath.parse("M0,0 L10,0 H15 V5 C16,6 17,7 18,8 A1,1 0 0 1 19,9 Z")
        #expect(relative == absolute)
        #expect(relative.count == 1 && relative[0].last == .close)
    }

    @Test func numbersAfterAMoveAreLinesAndCloseReturnsToTheStart() throws {
        #expect(
            try KnitMarkPath.parse("M0,0 10,0 10,10Z l1,1")
                == [[.move(Point(x: 0, y: 0)), .line(Point(x: 10, y: 0)), .line(Point(x: 10, y: 10)), .close, .line(Point(x: 1, y: 1))]]
        )
        #expect(try KnitMarkPath.parse("m1,1 2,0") == [[.move(Point(x: 1, y: 1)), .line(Point(x: 3, y: 1))]])
    }

    @Test func aSignOrASecondPointStartsANumber() throws {
        #expect(try KnitMarkPath.tokens("1.5-2 1.5.5 1e-2,+3") == [1.5, -2, 1.5, 0.5, 0.01, 3].map { .number($0) })
    }

    @Test func dataTheParserCannotDrawThrows() {
        #expect(throws: KnitMarkPath.PathDataError.unsupported("Q")) { try KnitMarkPath.parse("M0,0 Q1,1 2,2") }
        #expect(throws: KnitMarkPath.PathDataError.unsupported(nil)) { try KnitMarkPath.parse("10,10") }
        #expect(throws: KnitMarkPath.PathDataError.unsupported(nil)) { try KnitMarkPath.parse("L1,1") }
        #expect(throws: KnitMarkPath.PathDataError.unsupported(nil)) { try KnitMarkPath.parse("z") }
        #expect(throws: KnitMarkPath.PathDataError.missingNumber) { try KnitMarkPath.parse("M0") }
        #expect(throws: KnitMarkPath.PathDataError.unexpected("#")) { try KnitMarkPath.parse("M0,0 #") }
    }

    @Test func nothingToFitStaysAsItIs() {
        #expect(KnitMarkPath.fitted([]).isEmpty)
        #expect(KnitMarkPath.fitted([[.move(Point(x: 3, y: 3)), .close]]) == [[.move(Point(x: 3, y: 3)), .close]])
    }

    private static func endpoint(_ step: KnitMarkPath.Step) -> Point? {
        switch step {
        case .move(let point), .line(let point), .curve(let point, _, _):
            point
        case .close:
            nil
        }
    }

    private static func near(_ first: Point, _ second: Point) -> Bool {
        abs(first.x - second.x) < tolerance && abs(first.y - second.y) < tolerance
    }
}
