import Foundation

struct OrbitInspectAttachPolicy: Equatable {
    private(set) var isDetached = false

    mutating func didDetach() {
        isDetached = true
    }

    mutating func didHello(agentAttached: Bool) {
        isDetached = !agentAttached
    }

    mutating func takeAttachRequest() -> Bool {
        guard isDetached else { return false }
        isDetached = false
        return true
    }
}
