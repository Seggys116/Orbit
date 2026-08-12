//  hitTest(_:) receives its point in the superview's coordinate space, not the receiver's own.
//  Conform to OrbitClickCatching (a declared marker, not a name-suffix check) to be found by click recovery.

import AppKit

protocol OrbitClickCatching: NSView {}

extension NSView {
    func orbitContainsHitTestPoint(_ point: NSPoint) -> Bool {
        guard let superview else { return bounds.contains(point) }
        return bounds.contains(convert(point, from: superview))
    }
}
