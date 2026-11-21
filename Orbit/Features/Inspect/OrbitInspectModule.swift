// A tool is one model, one page-agent fragment, one pane; the store routes agent posts by `t` to the module whose `messageTypes` has it.

import Foundation

struct OrbitInspectFrame: Sendable {
    var url: String
    var isMain: Bool
}

@MainActor
protocol OrbitInspectModule: AnyObject {
    var session: OrbitInspectSession? { get set }

    /// The `t` values this module handles. Two modules must never claim the same type.
    var messageTypes: Set<String> { get }

    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame)

    func pageDidReset(preservingLog: Bool)

    /// A Refresh (`force` true) must always do real work and re-request everything the panel shows.
    func panelDidAppear(force: Bool)
    func panelDidDisappear()
}

extension OrbitInspectModule {
    var messageTypes: Set<String> { [] }
    func receive(type: String, object: [String: Any], frame: OrbitInspectFrame) {}
    func pageDidReset(preservingLog: Bool) {}
    func panelDidAppear(force: Bool) {}
    func panelDidDisappear() {}
}

enum OrbitInspectPanel: String, CaseIterable, Identifiable {
    case elements, console, sources, network, performance, animations, application, lighthouse, security, frameworks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .elements: "Elements"
        case .console: "Console"
        case .sources: "Sources"
        case .network: "Network"
        case .performance: "Performance"
        case .animations: "Animations"
        case .application: "Application"
        case .lighthouse: "Lighthouse"
        case .security: "Security"
        case .frameworks: "Frameworks"
        }
    }

    var symbol: String {
        switch self {
        case .elements: "chevron.left.forwardslash.chevron.right"
        case .console: "terminal"
        case .sources: "doc.text"
        case .network: "network"
        case .performance: "gauge.with.dots.needle.67percent"
        case .animations: "play.circle"
        case .application: "internaldrive"
        case .lighthouse: "lightbulb.max"
        case .security: "lock.shield"
        case .frameworks: "shippingbox"
        }
    }
}

enum OrbitInspectDock: String, CaseIterable, Identifiable {
    case right, bottom, left, undocked

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .left: "sidebar.left"
        case .bottom: "rectangle.split.1x2"
        case .right: "sidebar.right"
        case .undocked: "macwindow"
        }
    }

    var help: String {
        switch self {
        case .left: "Dock to the left"
        case .bottom: "Dock to the bottom"
        case .right: "Dock to the right"
        case .undocked: "Open in a window"
        }
    }
}
