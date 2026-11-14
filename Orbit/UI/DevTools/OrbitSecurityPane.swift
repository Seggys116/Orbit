import AppKit
import SwiftUI

struct OrbitSecurityPane: View {
    var session: OrbitInspectSession

    @State private var filter: Filter = .all

    init(session: OrbitInspectSession) {
        self.session = session
    }

    private var model: OrbitSecurityModel { session.security }

    enum Filter: String, CaseIterable, Identifiable {
        case all, issues, passed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .issues: return "Issues"
            case .passed: return "Passed"
            }
        }

        func includes(_ state: OrbitSecurityState) -> Bool {
            switch self {
            case .all: return true
            case .issues: return state == .warn || state == .fail
            case .passed: return state == .pass
            }
        }
    }

    var body: some View {
        let report = model.report
        VStack(spacing: 0) {
            toolbar(report)
            Divider()
            if report.pageURL.isEmpty {
                InspectEmptyState(
                    symbol: "lock.shield",
                    title: "No page to check",
                    message: "Open a page and its connection, headers, content and cookies are graded here."
                )
            } else {
                content(report)
            }
        }
    }

    // MARK: Toolbar

    private func toolbar(_ report: OrbitSecurityReport) -> some View {
        HStack(spacing: 6) {
            // Chips scroll sideways instead of clipping when the panel is narrow.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Filter.allCases) { option in
                        InspectChip(option.title, selected: filter == option, count: count(option, in: report)) {
                            withOrbitAnimation(OrbitMotion.quick) { filter = option }
                        }
                    }
                }
            }
            InspectIconButton(symbol: "doc.on.doc", help: "Copy security report") { model.copyReport() }
            InspectIconButton(symbol: "arrow.clockwise", help: "Refresh security checks") { model.panelDidAppear(force: true) }
        }
        .padding(.horizontal, InspectChrome.panelPadding)
        .frame(height: 36)
    }

    private func count(_ option: Filter, in report: OrbitSecurityReport) -> Int? {
        switch option {
        case .all: return nil
        case .issues: return report.warnCount + report.failCount
        case .passed: return report.passCount
        }
    }

    // MARK: Content

    private func content(_ report: OrbitSecurityReport) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                OrbitSecuritySummaryCard(report: report)
                    .padding(InspectChrome.panelPadding)
                ForEach(OrbitSecuritySection.allCases) { section in
                    sectionView(section, report: report)
                }
                Text("TLS version and cipher suite are not exposed by WebKit, so they are not graded. Headers are those of the main document response; reload the page with the panel open if they show as not captured.")
                    .font(InspectChrome.caption)
                    .foregroundStyle(OrbitNeutral.muted2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(InspectChrome.panelPadding)
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: OrbitSecuritySection, report: OrbitSecurityReport) -> some View {
        let checks = report.checks(in: section).filter { filter.includes($0.state) }
        let cookieRows = section == .cookies ? report.cookieRows.filter { row in
            filter == .all || filter.includes(OrbitSecurityState.worst([row.secure, row.httpOnly, row.sameSite]))
        } : []
        let showChain = section == .connection && filter == .all && !report.certificates.isEmpty
        if !checks.isEmpty || !cookieRows.isEmpty || showChain {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(OrbitNeutral.muted)
                    InspectSectionHeader(section.title, detail: sectionDetail(section, report: report))
                }
                .padding(.horizontal, InspectChrome.panelPadding)
                .padding(.vertical, 6)

                ForEach(checks) { check in
                    OrbitSecurityCheckRow(
                        check: check,
                        expanded: model.expandedCheckIDs.contains(check.id),
                        session: session
                    ) {
                        withOrbitAnimation(OrbitMotion.quick) { model.toggleExpanded(checkID: check.id) }
                    }
                }

                if showChain {
                    OrbitSecurityCertificateChainView(
                        certificates: report.certificates,
                        expanded: model.expandedCertificateIndexes,
                        now: Date()
                    ) { index in
                        withOrbitAnimation(OrbitMotion.quick) { model.toggleCertificate(index: index) }
                    }
                    .padding(.top, 4)
                }

                if !cookieRows.isEmpty {
                    OrbitSecurityCookieList(rows: cookieRows)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func sectionDetail(_ section: OrbitSecuritySection, report: OrbitSecurityReport) -> String? {
        let checks = report.checks(in: section)
        let problems = checks.filter { $0.state == .warn || $0.state == .fail }.count
        if problems > 0 { return "\(problems) \(problems == 1 ? "issue" : "issues")" }
        return checks.contains { $0.state == .pass } ? "All good" : nil
    }
}
