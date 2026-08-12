import SwiftUI

// MARK: - SVG path data

// Supports M m L l H h V v C c S s Q q T t Z z. Elliptical arcs (A/a) are not supported and are a
// parse failure, never a skip, so a missing segment never silently produces a wrong-looking shape.
enum SVGPathData {

    static func path(from data: String) -> Path? {
        var scanner = NumberScanner(data)
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character?
        var didMove = false
        var didDrawAnything = false

        while true {
            scanner.skipSeparators()
            if scanner.isAtEnd { break }

            if let letter = scanner.commandLetter() {
                scanner.advance()
                command = letter
            } else {
                // A number where a command letter could have been: repeat the previous command.
                switch command {
                case nil: return nil
                case "M": command = "L"
                case "m": command = "l"
                case "Z", "z": return nil
                default: break
                }
            }

            guard let cmd = command else { return nil }
            let isRelative = cmd.isLowercase

            func absolute(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                isRelative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch cmd {
            case "M", "m":
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                let point = absolute(x, y)
                path.move(to: point)
                current = point
                subpathStart = point
                lastCubicControl = nil
                lastQuadControl = nil
                didMove = true

            case "L", "l":
                guard didMove, let x = scanner.number(), let y = scanner.number() else { return nil }
                let point = absolute(x, y)
                path.addLine(to: point)
                current = point
                lastCubicControl = nil
                lastQuadControl = nil
                didDrawAnything = true

            case "H", "h":
                guard didMove, let x = scanner.number() else { return nil }
                let point = CGPoint(x: isRelative ? current.x + x : x, y: current.y)
                path.addLine(to: point)
                current = point
                lastCubicControl = nil
                lastQuadControl = nil
                didDrawAnything = true

            case "V", "v":
                guard didMove, let y = scanner.number() else { return nil }
                let point = CGPoint(x: current.x, y: isRelative ? current.y + y : y)
                path.addLine(to: point)
                current = point
                lastCubicControl = nil
                lastQuadControl = nil
                didDrawAnything = true

            case "C", "c":
                guard didMove,
                      let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return nil }
                let control1 = absolute(x1, y1)
                let control2 = absolute(x2, y2)
                let point = absolute(x, y)
                path.addCurve(to: point, control1: control1, control2: control2)
                current = point
                lastCubicControl = control2
                lastQuadControl = nil
                didDrawAnything = true

            case "S", "s":
                guard didMove,
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return nil }
                let control1 = SVGPathData.reflect(lastCubicControl, through: current)
                let control2 = absolute(x2, y2)
                let point = absolute(x, y)
                path.addCurve(to: point, control1: control1, control2: control2)
                current = point
                lastCubicControl = control2
                lastQuadControl = nil
                didDrawAnything = true

            case "Q", "q":
                guard didMove,
                      let cx = scanner.number(), let cy = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return nil }
                let control = absolute(cx, cy)
                let point = absolute(x, y)
                path.addQuadCurve(to: point, control: control)
                current = point
                lastQuadControl = control
                lastCubicControl = nil
                didDrawAnything = true

            case "T", "t":
                guard didMove, let x = scanner.number(), let y = scanner.number() else { return nil }
                let control = SVGPathData.reflect(lastQuadControl, through: current)
                let point = absolute(x, y)
                path.addQuadCurve(to: point, control: control)
                current = point
                lastQuadControl = control
                lastCubicControl = nil
                didDrawAnything = true

            case "Z", "z":
                guard didMove else { return nil }
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil
                didDrawAnything = true

            default:
                return nil
            }
        }

        guard didDrawAnything else { return nil }
        return path
    }

    private static func reflect(_ control: CGPoint?, through point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    // Not Foundation.Scanner: it reads "12.5.75" as 12.5 and then stalls on the ".", which SVG's
    // compressed notation depends on being split into two numbers.
    private struct NumberScanner {
        private let characters: [Character]
        private var index: Int

        init(_ string: String) {
            characters = Array(string)
            index = 0
        }

        var isAtEnd: Bool { index >= characters.count }

        mutating func advance() { index += 1 }

        mutating func skipSeparators() {
            while index < characters.count, characters[index] == " " || characters[index] == ","
                || characters[index] == "\n" || characters[index] == "\r" || characters[index] == "\t" {
                index += 1
            }
        }

        // e/E excluded: inside a number they introduce an exponent, consumed by number() itself.
        func commandLetter() -> Character? {
            guard index < characters.count else { return nil }
            let character = characters[index]
            guard character.isLetter, character != "e", character != "E" else { return nil }
            return character
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var sign = ""
            if let character = peek(), character == "+" || character == "-" {
                sign = String(character)
                advance()
            }

            var integerDigits = ""
            while let character = peek(), character.isASCIIDigit {
                integerDigits.append(character)
                advance()
            }

            var fractionDigits: String?
            if let character = peek(), character == "." {
                advance()
                var digits = ""
                while let next = peek(), next.isASCIIDigit {
                    digits.append(next)
                    advance()
                }
                fractionDigits = digits
            }

            guard !integerDigits.isEmpty || !(fractionDigits ?? "").isEmpty else { return nil }

            var exponent = ""
            if let character = peek(), character == "e" || character == "E" {
                // Only consume the "e" if a real exponent follows; it may be the next command letter.
                let saved = index
                advance()
                var candidate = "e"
                if let signCharacter = peek(), signCharacter == "+" || signCharacter == "-" {
                    candidate.append(signCharacter)
                    advance()
                }
                var digits = ""
                while let next = peek(), next.isASCIIDigit {
                    digits.append(next)
                    advance()
                }
                if digits.isEmpty {
                    index = saved
                } else {
                    exponent = candidate + digits
                }
            }

            let text = sign
                + (integerDigits.isEmpty ? "0" : integerDigits)
                + (fractionDigits.map { ".\($0.isEmpty ? "0" : $0)" } ?? "")
                + exponent
            guard let value = Double(text) else { return nil }
            return CGFloat(value)
        }

        private func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }
    }
}

private extension Character {
    // Not isNumber, which is true for non-ASCII digits Double(_:) cannot parse.
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - The mark

struct GitHubMarkShape: Shape {

    static let viewBox = CGSize(width: 24, height: 24)

    static let pathData = "M12.5.75C6.146.75 1 5.896 1 12.25c0 5.089 3.292 9.387 7.863 10.91.575.101.79-.244.79-.546 0-.273-.014-1.178-.014-2.142-2.889.532-3.636-.704-3.866-1.35-.13-.331-.69-1.352-1.18-1.625-.402-.216-.977-.748-.014-.762.906-.014 1.553.834 1.769 1.179 1.035 1.74 2.688 1.25 3.349.948.1-.747.402-1.25.733-1.538-2.559-.287-5.232-1.279-5.232-5.678 0-1.25.445-2.285 1.178-3.09-.115-.288-.517-1.467.115-3.048 0 0 .963-.302 3.163 1.179.92-.259 1.897-.388 2.875-.388.977 0 1.955.13 2.875.388 2.2-1.495 3.162-1.179 3.162-1.179.633 1.581.23 2.76.115 3.048.733.805 1.179 1.825 1.179 3.09 0 4.413-2.688 5.39-5.247 5.678.417.36.776 1.05.776 2.128 0 1.538-.014 2.774-.014 3.162 0 .302.216.662.79.547C20.709 21.637 24 17.324 24 12.25 24 5.896 18.854.75 12.5.75Z"

    static let markPath: Path = SVGPathData.path(from: GitHubMarkShape.pathData) ?? Path()

    static var isDrawable: Bool { !markPath.isEmpty }

    func path(in rect: CGRect) -> Path {
        GitHubMarkShape.scaled(GitHubMarkShape.markPath, fromViewBox: GitHubMarkShape.viewBox, into: rect)
    }

    static func scaled(_ path: Path, fromViewBox viewBox: CGSize, into rect: CGRect) -> Path {
        guard viewBox.width > 0, viewBox.height > 0, rect.width > 0, rect.height > 0 else { return Path() }
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let offsetX = rect.minX + (rect.width - viewBox.width * scale) / 2
        let offsetY = rect.minY + (rect.height - viewBox.height * scale) / 2
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
        return path.applying(transform)
    }
}
