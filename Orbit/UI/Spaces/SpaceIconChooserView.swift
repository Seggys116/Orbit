import AppKit
import SwiftUI

struct SpaceIconChooserView: View {
    var onPick: (SpaceIcon) -> Void

    private enum Kind: String, CaseIterable {
        case symbol = "Symbols"
        case emoji = "Emoji"
        case image = "Image"
    }

    @State private var kind: Kind = .symbol
    @State private var importErrorMessage: String?

    @Environment(AppEnvironment.self) private var injectedEnvironment: AppEnvironment?

    private var imageStore: SpaceIconImageStore {
        injectedEnvironment?.spaceIconImages ?? AppEnvironment.processRoot.spaceIconImages
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)

            switch kind {
            case .symbol:
                SFSymbolPickerView { onPick(.symbol($0)) }
            case .emoji:
                EmojiPickerView { onPick(.emoji($0)) }
            case .image:
                imageImportPane
            }

            Divider()
                .padding(.horizontal, 16)

            Button {
                importErrorMessage = nil
                onPick(.none)
            } label: {
                Label("No Icon (Dot)", systemImage: "circle.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Image import

    private var imageImportPane: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)

            Text("Upload a PNG or SVG to use as this Space's icon.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)

            Button("Choose Image…") { presentImagePanel() }
                .buttonStyle(.bordered)

            if let importErrorMessage {
                Text(importErrorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .frame(height: 220)
        .frame(width: 300)
    }

    private func presentImagePanel() {
        importErrorMessage = nil
        let panel = NSOpenPanel()
        panel.title = "Choose a Space Icon"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = SpaceIconImageStore.acceptedContentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let id = try imageStore.importImage(fromFileAt: url)
            onPick(.image(id))
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }
}
