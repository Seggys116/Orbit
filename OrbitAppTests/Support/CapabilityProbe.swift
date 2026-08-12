import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Orbit

// MARK: - Capability probes

// The real full preset grid, twice: only unavailable if BOTH attempts miss the budget.
@MainActor
private func probeMetalMeshGradientRenderingIsAvailable(timeout: TimeInterval = 20) -> Bool {
    let themes = SpaceThemePalette.presets
    let size = SpaceThemePalettePreviewGrid.size(forCount: themes.count)
    for _ in 0..<2 {
        let start = Date()
        _ = render(SpaceThemePalettePreviewGrid(themes: themes), size: size)
        if Date().timeIntervalSince(start) <= timeout { return true }
    }
    return false
}

// Each static let is computed at most once per process, the first time it is read.
enum CapabilityProbe {
    @MainActor static let metalMeshGradientRenderingIsAvailable = probeMetalMeshGradientRenderingIsAvailable()
}
