import Foundation
import Security
import WebKit

extension WebKitWebContents {

    /// The leaf certificate WebKit validated for the current document, nil for a page that was not served over TLS.
    func currentCertificate() -> SiteCertificate? {
        guard let url = webView.url ?? navigationState.url,
              url.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              let trust = webView.serverTrust
        else { return nil }
        return Self.siteCertificate(from: trust, host: url.host ?? "")
    }

    static func siteCertificate(from trust: SecTrust, host: String) -> SiteCertificate? {
        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        guard let leaf = chain.first else { return nil }
        // Subject, issuer, and validity are one certificate read. Separate copies parsed the leaf three times.
        let values = SecCertificateCopyValues(leaf, [
            kSecOIDX509V1SubjectName,
            kSecOIDX509V1IssuerName,
            kSecOIDX509V1ValidityNotBefore,
            kSecOIDX509V1ValidityNotAfter,
        ] as CFArray, nil) as? [String: Any]
        let subject = commonName(values?[kSecOIDX509V1SubjectName as String])
            ?? (SecCertificateCopySubjectSummary(leaf) as String?)
            ?? host
        let issuer = commonName(values?[kSecOIDX509V1IssuerName as String])
            ?? chain.dropFirst().first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
            ?? ""
        return SiteCertificate(
            subject: subject,
            issuer: issuer,
            validFrom: certificateDate(values?[kSecOIDX509V1ValidityNotBefore as String]),
            validUntil: certificateDate(values?[kSecOIDX509V1ValidityNotAfter as String]),
            serialNumber: serialNumber(of: leaf)
        )
    }

    /// Same common-name walk as `distinguishedName`: CN OID, the "CN" label, then a localized "Common Name".
    private static func commonName(_ entry: Any?) -> String? {
        guard let entry = entry as? [String: Any],
              let parts = entry[kSecPropertyKeyValue as String] as? [[String: Any]]
        else { return nil }
        for part in parts {
            let label = (part[kSecPropertyKeyLabel as String] as? String) ?? ""
            if label == "2.5.4.3" || label == "CN" || label.localizedCaseInsensitiveContains("Common Name") {
                return part[kSecPropertyKeyValue as String] as? String
            }
        }
        return nil
    }

    /// Same date walk as the certificate-problem path: a Date, a reference-date interval, or a number.
    private static func certificateDate(_ entry: Any?) -> Date? {
        guard let entry = entry as? [String: Any] else { return nil }
        let value = entry[kSecPropertyKeyValue as String]
        if let date = value as? Date { return date }
        if let interval = value as? TimeInterval { return Date(timeIntervalSinceReferenceDate: interval) }
        if let number = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        return nil
    }

    private static func serialNumber(of certificate: SecCertificate) -> String? {
        guard let data = SecCertificateCopySerialNumberData(certificate, nil) as Data?, !data.isEmpty else { return nil }
        return data.map { String(format: "%02X", $0) }.joined()
    }

    /// Every challenge for the same host shares the first answer until the next main-frame navigation starts.
    /// A refusal stays in that map, so a repeat does not open the interstitial again.
    func trustDecision(for space: URLProtectionSpace, problem: CertificateProblem) async -> Bool {
        let key = Self.trustDecisionKey(for: space)
        if let decided = extras.trustDecisions[key] { return await decided.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            return await self.delegate?.webContents(self, allowCertificateProblem: problem) ?? false
        }
        // Stored before the wait, so a repeat that arrives while the interstitial is up shares this answer.
        extras.trustDecisions[key] = task
        return await task.value
    }

    /// Case and a trailing DNS dot are the same host. The port stays in the key so two ports do not share an answer.
    private static func trustDecisionKey(for space: URLProtectionSpace) -> String {
        var host = space.host.lowercased()
        while host.last == "." {
            host.removeLast()
        }
        return "\(host):\(space.port)"
    }

    /// Re-derives the lock state from WebKit. Mixed content can arrive long after the commit that set it.
    func refreshSecurity() {
        guard !isClosed, let url = webView.url, url == navigationState.url else { return }
        // Only https consults the mixed-content bit; other schemes ignore it.
        let mixedContent = url.scheme?.caseInsensitiveCompare("https") == .orderedSame && !webView.hasOnlySecureContent
        let level = Self.security(for: url, mixedContent: mixedContent)
        guard level != navigationState.security else { return }
        navigationState.security = level
        delegate?.webContentsDidChangeNavigationState(self)
    }
}
