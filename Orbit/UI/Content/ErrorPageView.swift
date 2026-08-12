import SwiftUI

struct ErrorPageView: View {
    var error: EngineError
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(error.headline)
                .font(.system(size: 20, weight: .semibold))
            if let url = error.url {
                Text(url.absoluteString)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !error.underlyingDescription.isEmpty {
                Text(error.underlyingDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var symbolName: String {
        switch error.code {
        case .networkUnreachable: return "wifi.slash"
        case .hostNotFound: return "questionmark.circle"
        case .connectionRefused, .connectionTimedOut: return "bolt.slash"
        case .certificateInvalid: return "lock.trianglebadge.exclamationmark"
        case .fileNotFound: return "doc.questionmark"
        case .blockedByPolicy: return "hand.raised"
        case .unsupportedScheme: return "questionmark.app"
        case .renderProcessCrashed: return "exclamationmark.triangle"
        case .engineUnavailable: return "gearshape.2"
        case .tooManyRedirects: return "arrow.triangle.2.circlepath"
        case .notImplemented: return "wrench.and.screwdriver"
        case .cancelled, .unknown: return "exclamationmark.circle"
        }
    }
}

struct CrashedTabView: View {
    var onReload: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.orange)
            Text("This tab crashed")
                .font(.system(size: 20, weight: .semibold))
            Text("The page's renderer process quit unexpectedly.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Reload Tab", action: onReload)
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct CertificateInterstitialView: View {
    @Environment(AppEnvironment.self) private var env
    var tabID: TabID
    var problem: CertificateProblem

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.red)
            Text("This connection isn't private")
                .font(.system(size: 20, weight: .semibold))
            Text("Orbit couldn't verify the identity of \(problem.host).")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !problem.reason.isEmpty {
                Text(problem.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !problem.issuer.isEmpty { detailRow("Issuer", problem.issuer) }
                if !problem.subject.isEmpty { detailRow("Subject", problem.subject) }
                if let validUntil = problem.validUntil {
                    detailRow("Valid Until", validUntil.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))

            HStack(spacing: 12) {
                Button("Go Back") { env.resolveCertificateDecision(for: tabID, proceed: false) }
                    .buttonStyle(.bordered)
                // Absent, not disabled, when the engine reported the error as
                // strictly enforced: there is no way through, and the engine
                // refuses a proceed for it regardless of what is clicked.
                if problem.isOverridable {
                    Button("Proceed Anyway") { env.resolveCertificateDecision(for: tabID, proceed: true) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
            .padding(.top, 6)
            if !problem.isOverridable {
                Text("This site requires a valid certificate, so there is no way to continue.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11, weight: .semibold)).frame(width: 80, alignment: .leading)
            Text(value).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
