//  Traced from Primer Octicons v19.14.0 file-directory-fill-24 / file-directory-open-fill-24, normalized to a 1x1 unit square.
//  SwiftUI's Path.addArc operates in y-down space, inverting the intuitive clockwise flag; the flags below are the visually-correct ones.

import SwiftUI

// MARK: - Closed

struct FolderClosedGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        func radius(_ value: CGFloat) -> CGFloat { value * min(rect.width, rect.height) }

        var path = Path()
        path.move(to: point(0.0833, 0.1979))
        path.addCurve(to: point(0.1562, 0.1250), control1: point(0.0833, 0.1577), control2: point(0.1160, 0.1250))
        path.addLine(to: point(0.3634, 0.1250))
        path.addCurve(to: point(0.4237, 0.1569), control1: point(0.3875, 0.1250), control2: point(0.4100, 0.1369))
        path.addLine(to: point(0.4822, 0.2428))
        path.addCurve(to: point(0.4908, 0.2474), control1: point(0.4841, 0.2457), control2: point(0.4873, 0.2474))
        path.addLine(to: point(0.8438, 0.2474))
        path.addCurve(to: point(0.9167, 0.3203), control1: point(0.8840, 0.2474), control2: point(0.9167, 0.2800))
        path.addLine(to: point(0.9167, 0.8021))
        path.addArc(center: point(0.8438, 0.8021), radius: radius(0.0729), startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: point(0.1562, 0.8750))
        path.addArc(center: point(0.1562, 0.8021), radius: radius(0.0729), startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - Open

struct FolderOpenGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        func radius(_ value: CGFloat) -> CGFloat { value * min(rect.width, rect.height) }

        var path = Path()
        path.move(to: point(0.0833, 0.1979))
        path.addCurve(to: point(0.1562, 0.1250), control1: point(0.0833, 0.1577), control2: point(0.1160, 0.1250))
        path.addLine(to: point(0.3634, 0.1250))
        path.addCurve(to: point(0.4237, 0.1569), control1: point(0.3875, 0.1250), control2: point(0.4100, 0.1369))
        path.addLine(to: point(0.4822, 0.2428))
        path.addCurve(to: point(0.4908, 0.2474), control1: point(0.4841, 0.2457), control2: point(0.4873, 0.2474))
        path.addLine(to: point(0.7501, 0.2474))
        path.addCurve(to: point(0.8230, 0.3203), control1: point(0.7904, 0.2474), control2: point(0.8230, 0.2800))
        path.addLine(to: point(0.8230, 0.3252))
        path.addLine(to: point(0.2253, 0.3252))
        path.addArc(center: point(0.2265, 0.3605), radius: radius(0.0353), startAngle: .degrees(-91.97), endAngle: .degrees(91.97), clockwise: true)
        path.addLine(to: point(0.8705, 0.3958))
        path.addArc(center: point(0.8705, 0.4375), radius: radius(0.0417), startAngle: .degrees(-90.01), endAngle: .degrees(5.85), clockwise: false)
        path.addLine(to: point(0.8750, 0.8021))
        path.addCurve(to: point(0.8021, 0.8750), control1: point(0.8706, 0.8458), control2: point(0.8423, 0.8750))
        path.addLine(to: point(0.1562, 0.8750))
        path.addArc(center: point(0.1562, 0.8021), radius: radius(0.0729), startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: point(0.0833, 0.1979))
        path.closeSubpath()
        return path
    }
}

// MARK: - The toggle

struct FolderToggleGlyph: View {
    var isOpen: Bool

    var body: some View {
        ZStack {
            if isOpen {
                FolderOpenGlyphShape()
                    .fill(.foreground)
            } else {
                FolderClosedGlyphShape()
                    .fill(.foreground)
            }
        }
        .frame(width: OrbitMetrics.sidebarFolderToggleSize, height: OrbitMetrics.sidebarFolderToggleSize)
        .animation(OrbitMotion.quick, value: isOpen)
    }
}

#Preview("Folder toggle — closed vs open") {
    HStack(spacing: 24) {
        FolderToggleGlyph(isOpen: false)
        FolderToggleGlyph(isOpen: true)
    }
    .foregroundStyle(.black.opacity(0.75))
    .padding(40)
    .background(Color.white)
}
