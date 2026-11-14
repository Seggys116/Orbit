import AppKit
import SwiftUI

// MARK: - Style

/// State colours always travel with a distinct symbol and a word, so colour is never the only signal.
enum OrbitSecurityStyle {
    static func color(_ state: OrbitSecurityState) -> Color {
        switch state {
        case .pass: return OrbitNeutral.good
        case .warn: return OrbitNeutral.warn
        case .fail: return OrbitNeutral.bad
        case .info: return OrbitNeutral.muted
        }
    }

    static func symbol(_ state: OrbitSecurityState) -> String {
        switch state {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .info: return "info.circle"
        }
    }

    static func word(_ state: OrbitSecurityState) -> String {
        switch state {
        case .pass: return "Pass"
        case .warn: return "Warning"
        case .fail: return "Fail"
        case .info: return "Info"
        }
    }

    static func color(_ overall: OrbitSecurityOverall) -> Color {
        switch overall {
        case .secure: return OrbitNeutral.good
        case .issues: return OrbitNeutral.warn
        case .notSecure: return OrbitNeutral.bad
        }
    }
}

// Stable identities for lists, so rows keep their state when the report is recomputed.
extension OrbitSecurityFinding: Identifiable {
    var id: String { "\(text)|\(selector ?? "")|\(nodeID ?? 0)" }
}

extension OrbitSecurityCertificate: Identifiable {
    var id: String { "\(subject)|\(issuer)|\(serialNumber ?? "")" }
}

extension OrbitSecurityRow: Identifiable {
    var id: String { label }
}

/// A raised card: neutral hairline, an inset top highlight and a small black drop, with concentric inner radii.
struct OrbitSecurityCard<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: OrbitRadius.lg, style: .continuous).fill(OrbitNeutral.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OrbitRadius.lg, style: .continuous)
                    .strokeBorder(OrbitNeutral.line, lineWidth: 1)
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: OrbitRadius.lg, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                    .mask(alignment: .top) { Rectangle().frame(height: 2) }
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 1)
    }
}

/// A flag with a symbol, a word and a tinted symbol, for cookie attributes and counts.
struct OrbitSecurityPill: View {
    var text: String
    var state: OrbitSecurityState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: OrbitSecurityStyle.symbol(state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OrbitSecurityStyle.color(state))
            Text(text)
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.ink2)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: OrbitRadius.concentric(outer: OrbitRadius.lg, inset: 8), style: .continuous)
                .fill(OrbitNeutral.chip)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(text), \(OrbitSecurityStyle.word(state))")
    }
}

// MARK: - Summary

struct OrbitSecuritySummaryCard: View {
    var report: OrbitSecurityReport

    var body: some View {
        OrbitSecurityCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: report.overall.symbol)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(OrbitSecurityStyle.color(report.overall))
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.overall.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OrbitNeutral.ink)
                        Text(report.headline)
                            .font(InspectChrome.label)
                            .foregroundStyle(OrbitNeutral.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(report.pageURL)
                            .font(InspectChrome.monoSmall)
                            .foregroundStyle(OrbitNeutral.muted2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { pills }
                    VStack(alignment: .leading, spacing: 6) { pills }
                }
            }
            .padding(12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(report.overall.title). \(report.headline) \(report.passCount) passed, \(report.warnCount) warnings, \(report.failCount) failed.")
    }

    @ViewBuilder
    private var pills: some View {
        OrbitSecurityPill(text: "\(report.passCount) passed", state: .pass)
        OrbitSecurityPill(text: "\(report.warnCount) \(report.warnCount == 1 ? "warning" : "warnings")", state: .warn)
        OrbitSecurityPill(text: "\(report.failCount) failed", state: .fail)
        if report.infoCount > 0 {
            OrbitSecurityPill(text: "\(report.infoCount) not graded", state: .info)
        }
    }
}

// MARK: - Check row

struct OrbitSecurityCheckRow: View {
    var check: OrbitSecurityCheck
    var expanded: Bool
    var session: OrbitInspectSession
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                detail
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .orbitAnimation(OrbitMotion.quick, value: expanded)
        .background(expanded ? OrbitNeutral.sunk : Color.clear)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: OrbitSecurityStyle.symbol(check.state))
                .font(.system(size: 12))
                .foregroundStyle(OrbitSecurityStyle.color(check.state))
                .frame(width: 16, height: InspectChrome.rowHeight)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OrbitNeutral.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(check.summary)
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 3)
            Spacer(minLength: 4)
            Text(OrbitSecurityStyle.word(check.state))
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitSecurityStyle.color(check.state))
                .frame(height: InspectChrome.rowHeight)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(OrbitNeutral.muted2)
                .frame(height: InspectChrome.rowHeight)
        }
        .frame(minHeight: InspectChrome.rowHeight)
        .padding(.horizontal, InspectChrome.panelPadding)
        .contentShape(Rectangle())
        .overlay(InspectHitTarget(action: onToggle))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(check.title), \(OrbitSecurityStyle.word(check.state)). \(check.summary)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let value = check.value, !value.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Observed value")
                        .font(InspectChrome.sectionTitle)
                        .foregroundStyle(OrbitNeutral.muted)
                    Text(value)
                        .font(InspectChrome.monoSmall)
                        .foregroundStyle(OrbitNeutral.ink2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: OrbitRadius.sm, style: .continuous).fill(OrbitNeutral.sunk)
                        )
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Why it matters and how to fix it")
                    .font(InspectChrome.sectionTitle)
                    .foregroundStyle(OrbitNeutral.muted)
                Text(check.advice)
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !check.findings.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(check.findings) { finding in
                        findingRow(finding)
                    }
                }
            }
        }
        .padding(.leading, InspectChrome.panelPadding + 24)
        .padding(.trailing, InspectChrome.panelPadding)
        .padding(.bottom, 10)
    }

    private func findingRow(_ finding: OrbitSecurityFinding) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: OrbitSecurityStyle.symbol(finding.state))
                .font(.system(size: 10))
                .foregroundStyle(OrbitSecurityStyle.color(finding.state))
                .frame(width: 14, height: 18)
            Text(finding.text)
                .font(InspectChrome.caption)
                .foregroundStyle(OrbitNeutral.ink2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let nodeID = finding.nodeID, nodeID > 0 {
                InspectTextButton("Reveal") { session.reveal(nodeID: nodeID) }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy") { session.copy(finding.text) }
            if let url = finding.url, !url.isEmpty {
                Button("Copy URL") { session.copy(url) }
            }
        }
    }
}

// MARK: - Certificate chain

struct OrbitSecurityCertificateChainView: View {
    var certificates: [OrbitSecurityCertificate]
    var expanded: Set<Int>
    var now: Date
    var onToggle: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Certificate chain")
                .font(InspectChrome.sectionTitle)
                .foregroundStyle(OrbitNeutral.muted)
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.vertical, 4)
            ForEach(Array(certificates.enumerated()), id: \.element.id) { index, certificate in
                row(index: index, certificate: certificate)
            }
        }
    }

    private func role(_ index: Int, _ certificate: OrbitSecurityCertificate) -> String {
        if index == 0 { return "Leaf" }
        return index == certificates.count - 1 && certificate.issuer == certificate.subject ? "Root" : "Intermediate"
    }

    private func row(index: Int, certificate: OrbitSecurityCertificate) -> some View {
        let isExpanded = expanded.contains(index)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: index == 0 ? "doc.badge.gearshape" : "link")
                    .font(.system(size: 11))
                    .foregroundStyle(OrbitNeutral.muted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(certificate.subject)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OrbitNeutral.ink)
                        .lineLimit(1)
                    Text("\(role(index, certificate)). \(OrbitSecurityLogic.expiryDescription(notAfter: certificate.notAfter, now: now))")
                        .font(InspectChrome.caption)
                        .foregroundStyle(OrbitNeutral.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(OrbitNeutral.muted2)
            }
            .frame(minHeight: InspectChrome.rowHeight + 6)
            .padding(.horizontal, InspectChrome.panelPadding)
            .contentShape(Rectangle())
            .overlay(InspectHitTarget { onToggle(index) })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(certificate.subject), \(role(index, certificate)) certificate")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(OrbitSecurityLogic.certificateRows(certificate, now: now)) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text(item.label)
                                .font(InspectChrome.caption)
                                .foregroundStyle(OrbitNeutral.muted)
                                .frame(width: 96, alignment: .leading)
                            Text(item.value)
                                .font(InspectChrome.monoSmall)
                                .foregroundStyle(OrbitNeutral.ink2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, InspectChrome.panelPadding + 24)
                .padding(.trailing, InspectChrome.panelPadding)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .orbitAnimation(OrbitMotion.quick, value: isExpanded)
        .background(isExpanded ? OrbitNeutral.sunk : Color.clear)
    }
}

// MARK: - Cookies

struct OrbitSecurityCookieList: View {
    var rows: [OrbitSecurityCookieRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Cookies on this page")
                .font(InspectChrome.sectionTitle)
                .foregroundStyle(OrbitNeutral.muted)
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.vertical, 4)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    cookie(row)
                    Divider()
                }
            }
        }
    }

    private func cookie(_ row: OrbitSecurityCookieRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.name)
                    .font(InspectChrome.mono)
                    .foregroundStyle(OrbitNeutral.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.domain)
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.muted2)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { flags(row) }
                VStack(alignment: .leading, spacing: 4) { flags(row) }
            }
            ForEach(row.issues, id: \.self) { issue in
                Text(issue)
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func flags(_ row: OrbitSecurityCookieRow) -> some View {
        OrbitSecurityPill(text: "Secure", state: row.secure)
        OrbitSecurityPill(text: "HttpOnly", state: row.httpOnly)
        OrbitSecurityPill(text: "SameSite: \(row.sameSiteValue)", state: row.sameSite)
    }
}
