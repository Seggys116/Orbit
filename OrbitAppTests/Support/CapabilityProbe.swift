import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Orbit

// MARK: - Capability probes

// One real-size swatch, twice: only unavailable if BOTH attempts miss the budget.
@MainActor
private func probeMetalMeshGradientRenderingIsAvailable(timeout: TimeInterval = 20) -> Bool {
    let theme = SpaceTheme(style: .mesh, colors: SpaceTheme.defaultPalette)
    for _ in 0..<2 {
        let start = Date()
        _ = render(ThemeBackgroundView(theme: theme), size: CGSize(width: 320, height: 190))
        if Date().timeIntervalSince(start) <= timeout { return true }
    }
    return false
}

// Each static let is computed at most once per process, the first time it is read.
enum CapabilityProbe {
    @MainActor static let metalMeshGradientRenderingIsAvailable = probeMetalMeshGradientRenderingIsAvailable()
}
