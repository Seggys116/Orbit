import AppKit
import XCTest
@testable import Orbit

@MainActor
final class ClickCatcherHitTestCoordinateSpaceTests: XCTestCase {

    private var allCatcherTypes: [(name: String, make: @MainActor (NSRect) -> NSView)] {
        [
            ("OrbitActionButtonClickCatchingView", { OrbitActionButtonClickCatchingView(frame: $0) }),
            ("SidebarResizeHandleNSView", { SidebarResizeHandleNSView(frame: $0) }),
            ("ToolbarAddressCopyClickCatchingNSView", { ToolbarAddressCopyClickCatchingNSView(frame: $0) }),
            ("ToolbarNavButtonClickCatchingView", { ToolbarNavButtonClickCatchingView(frame: $0) }),
            ("OrbitMenuButtonClickCatchingView", { OrbitMenuButtonClickCatchingView(frame: $0) }),
        ]
    }

    private func makeContainer() -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    // MARK: - 1. A catcher away from its superview's origin claims its own frame

    func test_everyClickCatcherClaimsItsOwnFrameWhenItIsNotAtItsSuperviewsOrigin() {
        for catcherType in allCatcherTypes {
            let container = makeContainer()
            let catcher = catcherType.make(NSRect(x: 40, y: 40, width: 22, height: 22))
            container.addSubview(catcher)

            for point in [NSPoint(x: 40, y: 40), NSPoint(x: 51, y: 51), NSPoint(x: 61.5, y: 61.5)] {
                XCTAssertTrue(
                    container.hitTest(point) === catcher,
                    """
                    \(catcherType.name) at \(catcher.frame) declined \(point), a point genuinely on it. \
                    `hitTest(_:)` receives its point in the *superview's* coordinate space, so a check \
                    against the catcher's own `bounds` (\(catcher.bounds)) only agrees with the truth \
                    while the catcher happens to sit at its superview's origin — which is the accident \
                    that hid this for five separate controls. See \
                    Orbit/UI/Window/ClickCatcherHitTesting.swift.
                    """
                )
            }
        }
    }

    func test_noClickCatcherClaimsAPointOutsideItsOwnFrame() {
        for catcherType in allCatcherTypes {
            let container = makeContainer()
            let catcher = catcherType.make(NSRect(x: 40, y: 40, width: 22, height: 22))
            container.addSubview(catcher)

            for point in [NSPoint(x: 10, y: 10), NSPoint(x: 39, y: 51), NSPoint(x: 63, y: 51), NSPoint(x: 51, y: 200)] {
                XCTAssertTrue(
                    container.hitTest(point) === container,
                    "\(catcherType.name) at \(catcher.frame) claimed \(point), which is not on it — a catcher that over-claims steals clicks from its neighbours, the inverse of the bug this file guards."
                )
            }
        }
    }

    // MARK: - 2. Conversion holds through more than one level

    func test_everyClickCatcherIsReachableThroughNestedOffsetSuperviews() {
        for catcherType in allCatcherTypes {
            let container = makeContainer()
            let host = NSView(frame: NSRect(x: 30, y: 25, width: 200, height: 150))
            container.addSubview(host)
            let catcher = catcherType.make(NSRect(x: 12, y: 8, width: 22, height: 22))
            host.addSubview(catcher)

            // Catcher centre in container space: 30 + 12 + 11 = 53, 25 + 8 + 11 = 44.
            let onTheCatcher = NSPoint(x: 53, y: 44)
            XCTAssertTrue(
                container.hitTest(onTheCatcher) === catcher,
                "\(catcherType.name) was unreachable at \(onTheCatcher) through a superview offset by \(host.frame.origin) — the point must be converted once per level, which is what `NSView`'s own walk plus `orbitContainsHitTestPoint(_:)` do together."
            )

            // Just outside the catcher, still inside the host: the catcher
            // spans y 33...55 in container space (25 + 8 up to 25 + 8 + 22),
            // so 32 is one point below its bottom edge.
            XCTAssertTrue(
                container.hitTest(NSPoint(x: 53, y: 32)) === host,
                "\(catcherType.name) claimed a point below its own frame once superview offsets were involved — the conversion must not be applied twice, or in the wrong direction."
            )
        }
    }

    // MARK: - 3. The standalone case every other test in this repo relies on

    func test_aParentlessCatcherStillClaimsPointsInItsOwnBounds() {
        for catcherType in allCatcherTypes {
            let catcher = catcherType.make(NSRect(x: 0, y: 0, width: 22, height: 22))
            XCTAssertNil(catcher.superview, "Harness error: this case is specifically about a catcher with no superview.")
            XCTAssertTrue(
                catcher.hitTest(NSPoint(x: 11, y: 11)) === catcher,
                "\(catcherType.name) declined a point in its own bounds while parentless — the fallback every direct-hitTest test in this repo depends on has been dropped."
            )
            XCTAssertNil(
                catcher.hitTest(NSPoint(x: 40, y: 40)),
                "\(catcherType.name) claimed a point outside its own bounds while parentless."
            )
        }
    }

    // MARK: - 4. Existing extra conditions must survive the conversion

    func test_resizeHandleGuardStillRunsBeforeGeometryAtANonZeroOrigin() {
        let container = makeContainer()
        let handle = SidebarResizeHandleNSView(frame: NSRect(x: 40, y: 40, width: 22, height: 220))
        container.addSubview(handle)
        let onTheHandle = NSPoint(x: 51, y: 100)

        XCTAssertTrue(container.hitTest(onTheHandle) === handle, "Precondition: with the guard satisfied, this point is on the handle.")

        handle.isHidden = true
        XCTAssertNil(handle.hitTest(onTheHandle), "A hidden resize handle must claim nothing — the `!isHidden` guard must still run ahead of the geometry check.")

        handle.isHidden = false
        handle.alphaValue = 0
        XCTAssertNil(handle.hitTest(onTheHandle), "A fully transparent resize handle must claim nothing — the `alphaValue > 0` guard must still run ahead of the geometry check.")
    }

    // MARK: - 5. The window's recovery walk can now actually recover

    func test_theWindowsRecoveryWalkFindsEveryCatcherTypeItRecognisesAtANonZeroOrigin() {
        for catcherType in allCatcherTypes {
            let content = OrbitWindowContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let catcher = catcherType.make(NSRect(x: 40, y: 40, width: 22, height: 22))
            content.addSubview(catcher)
            XCTAssertTrue(
                OrbitWindowContentView.isClickCatcher(catcher),
                "\(catcherType.name) is not recognised as a click-catcher, so the assertions below would be measuring nothing — see test_everyClickCatcherIsRecognisedByTheRecoveryWalksFamilyMatcher."
            )

            XCTAssertTrue(
                OrbitWindowContentView.topmostClickCatcher(in: content, atPointInWindow: NSPoint(x: 51, y: 51)) === catcher,
                "The recovery walk could not find \(catcherType.name) at \(catcher.frame) — this walk is the app's last line of defence when NSHostingView claims a click for SwiftUI, and it returns whatever the catcher's own `hitTest` says about a point in the catcher's superview's space."
            )
            XCTAssertNil(
                OrbitWindowContentView.topmostClickCatcher(in: content, atPointInWindow: NSPoint(x: 10, y: 10)),
                "The recovery walk returned \(catcherType.name) for a point it does not occupy — the walk must never reach past a control's real frame."
            )
        }
    }

    func test_everyClickCatcherIsRecognisedByTheRecoveryWalksFamilyMatcher() {
        var recognised: [String] = []
        var unrecognised: [String] = []
        for catcherType in allCatcherTypes {
            let catcher = catcherType.make(NSRect(x: 0, y: 0, width: 22, height: 22))
            if OrbitWindowContentView.isClickCatcher(catcher) {
                recognised.append(catcherType.name)
            } else {
                unrecognised.append(catcherType.name)
            }
        }

        XCTAssertEqual(
            recognised.sorted(),
            allCatcherTypes.map(\.name).sorted(),
            """
            A click-catcher has dropped out of the family OrbitWindowContentView's recovery can \
            return: \(unrecognised.sorted()). Conformance to `OrbitClickCatching` is what admits a \
            view to that walk, and a catcher outside it loses the window's only defence against \
            NSHostingView swallowing its clicks — silently, since nothing else in the app consults \
            the protocol. Restore the conformance rather than relaxing this assertion.
            """
        )
        XCTAssertTrue(
            unrecognised.isEmpty,
            "These catchers are not recognised by the recovery walk: \(unrecognised.sorted())."
        )

        XCTAssertFalse(
            OrbitWindowContentView.isClickCatcher(NSView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))),
            "A plain NSView must never be treated as a click-catcher — the recovery would then be able to hand back views that never claimed the point, reaching past real AppKit controls such as the web view."
        )
    }

    func test_aSubclassOfACatcherIsRecognisedByTheRecoveryWalkToo() {
        let popupHost = OrbitPopupButtonMenuHostView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        XCTAssertTrue(
            OrbitWindowContentView.isClickCatcher(popupHost),
            "OrbitPopupButtonMenuHostView inherits every hit-testing behaviour of OrbitMenuButtonClickCatchingView and must inherit its recoverability too."
        )
    }

    // MARK: - 6. The end-to-end case: a click SwiftUI swallowed, recovered

    func test_everyCatcherIsRecoveredFromUnderASwiftUIContainerThatSwallowedTheClick() {
        for catcherType in allCatcherTypes {
            let content = OrbitWindowContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let swiftUIStandIn = NSHostingViewFamilyClaimingStandIn(frame: content.bounds)
            content.addSubview(swiftUIStandIn)
            let catcher = catcherType.make(NSRect(x: 100, y: 80, width: 22, height: 22))
            swiftUIStandIn.addSubview(catcher)

            XCTAssertTrue(
                swiftUIStandIn.hitTest(NSPoint(x: 111, y: 91)) === swiftUIStandIn,
                "Harness error: the SwiftUI stand-in must swallow this point, otherwise \(catcherType.name) would be reached by the ordinary walk and nothing here would be measured."
            )
            XCTAssertTrue(
                content.hitTest(NSPoint(x: 111, y: 91)) === catcher,
                """
                A click over \(catcherType.name) at \(catcher.frame) was lost: the content view \
                handed back the SwiftUI container that swallowed it instead of the control \
                underneath. That is what the recovery walk exists to prevent, and it can only \
                do so for views its family matcher recognises — see \
                test_everyClickCatcherIsRecognisedByTheRecoveryWalksFamilyMatcher.
                """
            )

            XCTAssertTrue(
                content.hitTest(NSPoint(x: 300, y: 20)) === swiftUIStandIn,
                "Off \(catcherType.name), the SwiftUI container must keep the point — the recovery must never reach into a region no Orbit control occupies."
            )
        }
    }

    func test_noCatcherIsRecoveredWhileHiddenOrFullyTransparent() {
        for catcherType in allCatcherTypes {
            let content = OrbitWindowContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let swiftUIStandIn = NSHostingViewFamilyClaimingStandIn(frame: content.bounds)
            content.addSubview(swiftUIStandIn)

            let hidden = catcherType.make(NSRect(x: 100, y: 80, width: 22, height: 22))
            hidden.isHidden = true
            swiftUIStandIn.addSubview(hidden)

            let transparent = catcherType.make(NSRect(x: 200, y: 80, width: 22, height: 22))
            transparent.alphaValue = 0
            swiftUIStandIn.addSubview(transparent)

            XCTAssertTrue(
                content.hitTest(NSPoint(x: 111, y: 91)) === swiftUIStandIn,
                "A hidden \(catcherType.name) was recovered — an invisible control must not take clicks."
            )
            XCTAssertTrue(
                content.hitTest(NSPoint(x: 211, y: 91)) === swiftUIStandIn,
                "A fully transparent \(catcherType.name) was recovered — an invisible control must not take clicks."
            )
        }
    }
}

/// The `NSHostingView` prefix in the class name is load-bearing: `OrbitWindowContentView.isSwiftUIContainer(_:)` gates the recovery walk on the resolved view's class name, so a differently-named stand-in would make this file measure nothing.
private final class NSHostingViewFamilyClaimingStandIn: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
}
