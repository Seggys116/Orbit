//  Resolves an EngineStorage to a profile directory. `.persistent` answers nil,
//  not a path, so the engine's own production default is never overridden.

import Foundation
import OSLog

@MainActor
enum EngineStorageDirectory {

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "EngineStorageDirectory")

    /// `Orbit-Engine-<mode>-<pid>-<uuid>`. Both halves matter: the mode makes
    /// a stray directory identifiable, the pid is what lets a later launch
    /// tell an abandoned directory from one a live process is still using.
    private static let namePrefix = "Orbit-Engine-"
    private static let privateModeNames: Set<String> = ["ephemeral", "isolated"]

    private static var privateDirectory: URL?

    /// `nil` means "leave the engine on its own default", i.e. the production
    /// profile. Every other mode gets one private directory per process,
    /// created on first use and reused for the rest of the process's life.
    static func directory(for storage: EngineStorage) -> URL? {
        switch storage {
        case .persistent:
            return nil
        case .ephemeral, .isolated:
            if let privateDirectory { return privateDirectory }
            let root = privateRoot
            removeAbandonedDirectories(in: root)
            let created = makePrivateDirectory(for: storage, in: root)
            privateDirectory = created
            return created
        }
    }

    /// Never used to configure the engine; only to assert a private directory
    /// is genuinely outside it.
    static var productionProfile: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Orbit", isDirectory: true)
    }

    /// Its own subdirectory rather than the temporary directory itself: the
    /// sweep below enumerates this on every engine start, and the per-user
    /// temporary directory runs to six figures of entries on a working Mac.
    static var privateRoot: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OrbitEngineProfiles", isDirectory: true)
    }

    static func makePrivateDirectory(for storage: EngineStorage, in root: URL) -> URL {
        let mode: String
        switch storage {
        case .persistent: mode = "persistent"
        case .ephemeral: mode = "ephemeral"
        case .isolated: mode = "isolated"
        }
        let name = "\(namePrefix)\(mode)-\(getpid())-\(UUID().uuidString)"
        let directory = root.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            // Never fall back to the default: that default is the real user's
            // profile, and silently writing a demo or test run into it is the
            // exact failure this type exists to prevent.
            logger.fault("could not create the engine's private profile directory at \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
            fatalError("could not create the engine's private profile directory at \(directory.path): \(error)")
        }
        return directory
    }

    /// Removes only directories this type created whose owning process is
    /// gone. A recycled pid belonging to some unrelated live process just
    /// means the directory is kept -- the safe direction.
    static func removeAbandonedDirectories(in root: URL) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names {
            guard let owner = ownerProcessID(ofDirectoryNamed: name), !isProcessAlive(owner) else { continue }
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            do {
                try fileManager.removeItem(at: candidate)
            } catch {
                logger.error("could not remove abandoned engine profile \(candidate.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `nil` for anything this type did not create: the name has to be the
    /// exact prefix, a known mode, a positive pid and a well-formed UUID.
    static func ownerProcessID(ofDirectoryNamed name: String) -> pid_t? {
        guard name.hasPrefix(namePrefix) else { return nil }
        let fields = name.dropFirst(namePrefix.count).split(
            separator: "-", maxSplits: 2, omittingEmptySubsequences: false
        )
        guard fields.count == 3,
              privateModeNames.contains(String(fields[0])),
              let owner = pid_t(fields[1]), owner > 0,
              UUID(uuidString: String(fields[2])) != nil
        else { return nil }
        return owner
    }

    static func isProcessAlive(_ owner: pid_t) -> Bool {
        if owner == getpid() { return true }
        if kill(owner, 0) == 0 { return true }
        return errno == EPERM
    }
}
