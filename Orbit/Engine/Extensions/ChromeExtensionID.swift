import CryptoKit
import Foundation

nonisolated public enum ChromeExtensionID {

    public static func id(fromPublicKeyBase64 key: String) -> String? {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let keyData = Data(base64Encoded: cleaned) else {
            return nil
        }
        return id(hashing: keyData)
    }

    // Chromium hashes realpath(3), symlinks fully resolved (/var -> /private/var);
    // URL.standardizedFileURL strips that prefix instead, so it can't be used here.
    public static func id(forUnpackedPath path: URL) -> String {
        id(hashing: Data(canonicalPath(path).utf8))
    }

    private static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        // realpath fails on a path that does not exist yet -- an install
        // destination resolved before it is staged. Resolve the deepest
        // existing ancestor instead and re-append what does not exist.
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        let name = url.standardizedFileURL.lastPathComponent
        guard !name.isEmpty, parent.path != path, !parent.path.isEmpty else { return path }
        let resolvedParent = canonicalPath(parent)
        return resolvedParent.hasSuffix("/") ? resolvedParent + name : resolvedParent + "/" + name
    }

    public static func isValid(_ id: String) -> Bool {
        guard id.utf8.count == 32, id.count == 32 else { return false }
        return id.allSatisfy { $0 >= "a" && $0 <= "p" }
    }

    // MARK: - Shared derivation

    private static func id(hashing input: Data) -> String {
        let digest = SHA256.hash(data: input)
        var result = ""
        result.reserveCapacity(32)
        for byte in digest.prefix(16) {
            result.append(letter(forNibble: byte >> 4))
            result.append(letter(forNibble: byte & 0x0F))
        }
        return result
    }

    private static func letter(forNibble nibble: UInt8) -> Character {
        Character(UnicodeScalar(97 + nibble))
    }
}
