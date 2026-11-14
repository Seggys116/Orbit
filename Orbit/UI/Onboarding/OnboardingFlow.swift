import Foundation

// Free of views so the step state machine can be unit tested; OnboardingView mutates its OnboardingFlowState only through these methods.

nonisolated enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, importBrowser, spaces, shortcuts, finish

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .importBrowser: "Import"
        case .spaces: "Spaces"
        case .shortcuts: "Shortcuts"
        case .finish: "Finish"
        }
    }
}

nonisolated enum OnboardingRailStatus: Equatable, Sendable {
    case done, current, upcoming
}

nonisolated enum OnboardingImportPhase: Equatable, Sendable {
    case idle
    case running
    case done
    case failed
}

nonisolated struct OnboardingFlowState: Equatable, Sendable {
    private(set) var step: OnboardingStep
    /// True while an import is running: no navigation is allowed, so a half-finished import is never abandoned.
    var isBusy: Bool

    init(step: OnboardingStep = .welcome, isBusy: Bool = false) {
        self.step = step
        self.isBusy = isBusy
    }

    var isFirst: Bool { step == .welcome }
    var isLast: Bool { step == .finish }
    var canGoBack: Bool { !isFirst && !isBusy }

    func status(of other: OnboardingStep) -> OnboardingRailStatus {
        if other == step { return .current }
        return other.rawValue < step.rawValue ? .done : .upcoming
    }

    @discardableResult
    mutating func advance() -> Bool {
        guard !isBusy, let next = OnboardingStep(rawValue: step.rawValue + 1) else { return false }
        step = next
        return true
    }

    @discardableResult
    mutating func back() -> Bool {
        guard canGoBack, let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return false }
        step = previous
        return true
    }

    /// Forward jumps are refused: later steps commit choices the earlier ones feed.
    @discardableResult
    mutating func go(to target: OnboardingStep) -> Bool {
        guard !isBusy, target.rawValue < step.rawValue else { return false }
        step = target
        return true
    }

    nonisolated enum PrimaryAction: Equatable, Sendable {
        case next
        case startImport
        case finish
    }

    func primaryAction(hasImportSource: Bool, importPhase: OnboardingImportPhase) -> PrimaryAction {
        switch step {
        case .finish:
            return .finish
        case .importBrowser:
            guard hasImportSource else { return .next }
            return importPhase == .done ? .next : .startImport
        case .welcome, .spaces, .shortcuts:
            return .next
        }
    }

    func primaryTitle(importSourceName: String?, importPhase: OnboardingImportPhase) -> String {
        switch step {
        case .welcome:
            return "Get started"
        case .finish:
            return "Finish"
        case .importBrowser:
            guard let importSourceName else { return "Continue" }
            switch importPhase {
            case .idle, .failed: return "Import from \(importSourceName)"
            case .running: return "Importing"
            case .done: return "Continue"
            }
        case .spaces, .shortcuts:
            return "Continue"
        }
    }

    func offersMaybeLater(hasImportSource: Bool, importPhase: OnboardingImportPhase) -> Bool {
        step == .importBrowser && hasImportSource && importPhase != .done
    }
}
