import AppKit

// AppKit clamps an ordered-in window to the visible screen, which silently shortens a test
// window on a small or headless display and moves every hit-test point with it.
final class UnconstrainedTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
