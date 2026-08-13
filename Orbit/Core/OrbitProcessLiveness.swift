import Foundation

/// Shared by every sweep that reclaims something named after the process that created it.
enum OrbitProcessLiveness {

    /// EPERM means the pid exists and belongs to someone else, so it counts as alive.
    static func isAlive(_ owner: pid_t) -> Bool {
        if owner == getpid() { return true }
        if kill(owner, 0) == 0 { return true }
        return errno == EPERM
    }
}
