// Security.framework helpers for the Security tool: turn WKWebView.serverTrust into plain values.

import Foundation
import Security

// Nonisolated so the chain evaluation can run off the main thread.
nonisolated enum OrbitSecuritySupport {

    nonisolated struct ConnectionSnapshot: Sendable {
        var certificates: [OrbitSecurityCertificate]
        var trust: OrbitSecurityTrust
    }

    /// SecTrust is an immutable, thread-safe CF object once WebKit has handed it over.
    nonisolated struct TrustHandle: @unchecked Sendable {
        let trust: SecTrust
    }

    /// Runs the snapshot on a background queue and calls `completion` on the main queue.
    static func snapshotInBackground(
        _ handle: TrustHandle,
        host: String,
        completion: @escaping @Sendable (ConnectionSnapshot) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = snapshot(trust: handle.trust, host: host)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Network fetches are switched off on the policy copy so the call cannot block on OCSP or AIA lookups.
    static func snapshot(trust: SecTrust, host: String) -> ConnectionSnapshot {
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        return ConnectionSnapshot(
            certificates: describe(chain: chain),
            trust: evaluate(chain: chain, host: host)
        )
    }

    private static func evaluate(chain: [SecCertificate], host: String) -> OrbitSecurityTrust {
        guard !chain.isEmpty else { return .unavailable }
        let policy = SecPolicyCreateSSL(true, host as CFString)
        var fresh: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, policy, &fresh) == errSecSuccess, let fresh else {
            return .unavailable
        }
        SecTrustSetNetworkFetchAllowed(fresh, false)
        var error: CFError?
        if SecTrustEvaluateWithError(fresh, &error) { return .trusted }
        let reason = error.map { CFErrorCopyDescription($0) as String } ?? "The system did not trust this chain."
        return .untrusted(reason)
    }

    static func describe(chain: [SecCertificate]) -> [OrbitSecurityCertificate] {
        chain.enumerated().map { index, certificate in
            let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unknown"
            // A chain lists each certificate's issuer next; the last one is its own issuer.
            let issuer = index + 1 < chain.count
                ? (SecCertificateCopySubjectSummary(chain[index + 1]) as String? ?? "Unknown")
                : subject
            return describe(certificate: certificate, subject: subject, issuer: issuer)
        }
    }

    private static func describe(certificate: SecCertificate, subject: String, issuer: String) -> OrbitSecurityCertificate {
        let keys = [
            kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter,
            kSecOIDSubjectAltName, kSecOIDX509V1SignatureAlgorithm,
        ] as CFArray
        let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any] ?? [:]

        var keyType: String?
        var keyBits: Int?
        if let key = SecCertificateCopyKey(certificate),
           let attributes = SecKeyCopyAttributes(key) as? [String: Any] {
            let raw = attributes[kSecAttrKeyType as String]
            if let type = (raw as? String) ?? (raw as? NSNumber)?.stringValue {
                keyType = OrbitSecurityLogic.keyTypeName(fromAttribute: type)
            }
            keyBits = attributes[kSecAttrKeySizeInBits as String] as? Int
        }

        var serial: String?
        if let data = SecCertificateCopySerialNumberData(certificate, nil) as Data? {
            serial = data.map { String(format: "%02X", $0) }.joined(separator: ":")
        }

        return OrbitSecurityCertificate(
            subject: subject,
            issuer: issuer,
            notBefore: date(from: values[kSecOIDX509V1ValidityNotBefore as String]),
            notAfter: date(from: values[kSecOIDX509V1ValidityNotAfter as String]),
            serialNumber: serial,
            subjectAlternativeNames: alternativeNames(from: values[kSecOIDSubjectAltName as String]),
            keyType: keyType,
            keySizeBits: keyBits,
            signatureAlgorithm: signatureAlgorithm(from: values[kSecOIDX509V1SignatureAlgorithm as String])
        )
    }

    private static func propertyValue(_ entry: Any?) -> Any? {
        (entry as? [String: Any])?[kSecPropertyKeyValue as String]
    }

    private static func date(from entry: Any?) -> Date? {
        let value = propertyValue(entry)
        if let date = value as? Date { return date }
        if let number = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        return nil
    }

    private static func alternativeNames(from entry: Any?) -> [String] {
        guard let list = propertyValue(entry) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            let label = (item[kSecPropertyKeyLabel as String] as? String)?.lowercased() ?? ""
            guard label.contains("dns") || label.contains("ip") else { return nil }
            return item[kSecPropertyKeyValue as String] as? String
        }
    }

    private static func signatureAlgorithm(from entry: Any?) -> String? {
        guard let section = propertyValue(entry) as? [[String: Any]] else { return nil }
        for item in section {
            let label = (item[kSecPropertyKeyLabel as String] as? String)?.lowercased() ?? ""
            if label == "algorithm", let value = item[kSecPropertyKeyValue as String] as? String {
                return OrbitSecurityLogic.signatureAlgorithmName(value)
            }
        }
        return nil
    }
}
