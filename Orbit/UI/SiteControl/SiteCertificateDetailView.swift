import Foundation
import SwiftUI

struct SiteCertificateDetailView: View {
    let certificate: SiteCertificate
    let host: String

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Certificate").font(.system(size: 15, weight: .semibold))
                    Text(host).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                field("Subject", value: certificate.subject)
                field("Issuer", value: certificate.issuer)
                field("Valid From", value: certificate.validFrom.map(Self.dateFormatter.string(from:)))
                field("Valid Until", value: certificate.validUntil.map(Self.dateFormatter.string(from:)))
                field("Serial Number", value: certificate.serialNumber)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    @ViewBuilder
    private func field(_ label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
