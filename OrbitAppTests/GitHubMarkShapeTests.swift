import XCTest
import SwiftUI
@testable import Orbit

@MainActor
final class GitHubMarkShapeTests: XCTestCase {

    // MARK: - A known path in, a known bounding box out

    func test_parser_absoluteLinesProduceTheExactBoundingBox() {
        guard let path = SVGPathData.path(from: "M0 0 H10 V10 H0 Z") else {
            XCTFail("Expected 'M0 0 H10 V10 H0 Z' to parse; it uses only the absolute line commands.")
            return
        }
        XCTAssertEqual(path.boundingRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxX, 10, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxY, 10, accuracy: 0.001)
    }

    func test_parser_relativeCommandsAccumulateFromTheCurrentPoint() {
        guard let path = SVGPathData.path(from: "M2 3 l10 0 l0 10 l-10 0 z") else {
            XCTFail("Expected the relative-lineto form to parse.")
            return
        }
        XCTAssertEqual(path.boundingRect.minX, 2, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.minY, 3, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxX, 12, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxY, 13, accuracy: 0.001)
    }

    func test_parser_aSecondDotStartsANewNumber() {
        guard let path = SVGPathData.path(from: "M12.5.75L20 30") else {
            XCTFail("Expected 'M12.5.75L20 30' to parse as a move to (12.5, 0.75) then a line to (20, 30).")
            return
        }
        XCTAssertEqual(path.boundingRect.minX, 12.5, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.minY, 0.75, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxX, 20, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxY, 30, accuracy: 0.001)
    }

    func test_parser_aMinusSignSeparatesNumbersWithNoWhitespace() {
        guard let path = SVGPathData.path(from: "M0 0L5-3") else {
            XCTFail("Expected 'M0 0L5-3' to parse as a line to (5, -3).")
            return
        }
        XCTAssertEqual(path.boundingRect.minY, -3, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxX, 5, accuracy: 0.001)
    }

    func test_parser_repeatedMoveCoordinatesAreLinesNotMoves() {
        guard let path = SVGPathData.path(from: "M0 0 4 0 4 4 0 4 Z") else {
            XCTFail("Expected implicit-lineto-after-moveto to parse.")
            return
        }
        XCTAssertEqual(
            describe(path),
            ["move(0.0, 0.0)", "line(4.0, 0.0)", "line(4.0, 4.0)", "line(0.0, 4.0)", "close"],
            "Only the first coordinate pair after `M` is a move; the rest are lines."
        )
    }

    func test_parser_smoothCubicReflectsThePreviousControlPoint() {
        guard let path = SVGPathData.path(from: "M0 0 C0 10 10 10 10 0 S20 -10 20 0") else {
            XCTFail("Expected the smooth-cubic form to parse.")
            return
        }
        XCTAssertEqual(
            describe(path),
            [
                "move(0.0, 0.0)",
                "curve(10.0, 0.0; 0.0, 10.0; 10.0, 10.0)",
                "curve(20.0, 0.0; 10.0, -10.0; 20.0, -10.0)",
            ],
            "The second segment's first control must be the reflection of (10, 10) through (10, 0), i.e. (10, -10)."
        )
    }

    func test_parser_smoothQuadraticReflectsThePreviousControlPoint() {
        guard let path = SVGPathData.path(from: "M0 0 Q5 10 10 0 T20 0") else {
            XCTFail("Expected the quadratic/smooth-quadratic form to parse.")
            return
        }
        XCTAssertEqual(
            describe(path),
            [
                "move(0.0, 0.0)",
                "quad(10.0, 0.0; 5.0, 10.0)",
                "quad(20.0, 0.0; 15.0, -10.0)",
            ]
        )
    }

    // MARK: - Failure cases return nil, never a partial shape

    func test_parser_ellipticalArcIsAFailureAndNotASilentSkip() {
        XCTAssertNil(
            SVGPathData.path(from: "M0 0 A5 5 0 0 0 10 10 Z"),
            "An unsupported arc command must make the whole parse fail. Returning a path with the arc dropped would draw a silently wrong mark."
        )
        XCTAssertNil(SVGPathData.path(from: "M0 0 a5 5 0 0 0 10 10 Z"))
    }

    func test_parser_rejectsDataThatDoesNotStartWithAMove() {
        XCTAssertNil(SVGPathData.path(from: "L10 10"), "A path must open with a move.")
        XCTAssertNil(SVGPathData.path(from: "10 10"), "Numbers with no command at all are malformed.")
    }

    func test_parser_rejectsTruncatedAndEmptyData() {
        XCTAssertNil(SVGPathData.path(from: ""))
        XCTAssertNil(SVGPathData.path(from: "M0 0"), "A move alone draws nothing, so there is no shape to return.")
        XCTAssertNil(SVGPathData.path(from: "M0 0 C1 1 2 2"), "A cubic missing its final coordinate pair is malformed.")
        XCTAssertNil(SVGPathData.path(from: "M0 0 Q1"), "A quadratic missing coordinates is malformed.")
    }

    // MARK: - The mark itself

    func test_gitHubMark_pathDataParses() {
        XCTAssertTrue(
            GitHubMarkShape.isDrawable,
            "GitHubMarkShape.pathData (Primer Octicons mark-github-24, v19.14.0) failed to parse. Check it against SVGPathData's supported command set — the current Octicons `main` marks use elliptical arcs, which are deliberately unsupported."
        )
    }

    func test_gitHubMark_occupiesItsViewBox() {
        let bounds = GitHubMarkShape.markPath.boundingRect
        let box = GitHubMarkShape.viewBox
        XCTAssertGreaterThan(bounds.width, box.width * 0.85, "The mark should span nearly the full viewBox width; got \(bounds).")
        XCTAssertGreaterThan(bounds.height, box.height * 0.85, "The mark should span nearly the full viewBox height; got \(bounds).")
        XCTAssertGreaterThanOrEqual(bounds.minX, -1, "The mark must not extend left of its viewBox; got \(bounds).")
        XCTAssertGreaterThanOrEqual(bounds.minY, -1, "The mark must not extend above its viewBox; got \(bounds).")
        XCTAssertLessThanOrEqual(bounds.maxX, box.width + 1, "The mark must not extend right of its viewBox; got \(bounds).")
        XCTAssertLessThanOrEqual(bounds.maxY, box.height + 1, "The mark must not extend below its viewBox; got \(bounds).")
    }

    // MARK: - Scaling into a destination rectangle

    func test_gitHubMark_scalesIntoAnOffsetRectangle() {
        let rect = CGRect(x: 30, y: 12, width: 40, height: 40)
        let bounds = GitHubMarkShape().path(in: rect).boundingRect

        XCTAssertTrue(
            rect.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
            "The scaled mark (\(bounds)) must sit inside the rectangle it was asked to draw in (\(rect))."
        )
        XCTAssertGreaterThan(bounds.width, rect.width * 0.85, "The scaled mark should nearly fill its slot; got \(bounds) in \(rect).")
    }

    func test_gitHubMark_preservesAspectRatioInANonSquareRectangle() {
        let rect = CGRect(x: 0, y: 0, width: 80, height: 20)
        let bounds = GitHubMarkShape().path(in: rect).boundingRect
        let markAspect = GitHubMarkShape.markPath.boundingRect.width / GitHubMarkShape.markPath.boundingRect.height

        XCTAssertEqual(
            bounds.width / bounds.height, markAspect, accuracy: 0.02,
            "Scaling into a 4:1 slot must keep the mark's own aspect ratio (\(markAspect)); got \(bounds)."
        )
        XCTAssertLessThanOrEqual(bounds.height, rect.height + 0.5, "The mark must fit within the shorter axis.")
    }

    func test_gitHubMark_degenerateRectangleDrawsNothing() {
        XCTAssertTrue(GitHubMarkShape().path(in: .zero).isEmpty)
    }
}

// MARK: - Test-only helper

@MainActor
private func describe(_ path: Path) -> [String] {
    func point(_ p: CGPoint) -> String {
        "\((p.x * 1000).rounded() / 1000), \((p.y * 1000).rounded() / 1000)"
    }
    var elements: [String] = []
    path.forEach { element in
        switch element {
        case .move(let to):
            elements.append("move(\(point(to)))")
        case .line(let to):
            elements.append("line(\(point(to)))")
        case .quadCurve(let to, let control):
            elements.append("quad(\(point(to)); \(point(control)))")
        case .curve(let to, let control1, let control2):
            elements.append("curve(\(point(to)); \(point(control1)); \(point(control2)))")
        case .closeSubpath:
            elements.append("close")
        }
    }
    return elements
}
