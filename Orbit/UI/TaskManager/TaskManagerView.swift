import SwiftUI

struct TaskManagerView: View {

    @Bindable var model: TaskManagerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 260)
        .onDisappear { model.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("Task")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Memory Footprint")
                .frame(width: Layout.memoryColumnWidth, alignment: .trailing)
            Text("CPU")
                .frame(width: Layout.cpuColumnWidth, alignment: .trailing)
        }
        .font(.system(size: Layout.headerFontSize, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.headerVerticalPadding)
    }

    // MARK: Table

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.processes) { process in
                    row(for: process)
                }
            }
        }
    }

    private func row(for process: OrbitProcessInfo) -> some View {
        let isSelected = model.selectedProcessID == process.processID
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(process.role.displayName)
                    .font(.system(size: Layout.rowFontSize))
                Text("PID \(process.processID) · \(process.executableName)")
                    .font(.system(size: Layout.secondaryFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(process.memoryFootprintText)
                .font(.system(size: Layout.rowFontSize).monospacedDigit())
                .frame(width: Layout.memoryColumnWidth, alignment: .trailing)

            Text(model.hasMeasuredCPU ? process.cpuPercentText : "—")
                .font(.system(size: Layout.rowFontSize).monospacedDigit())
                .foregroundStyle(model.hasMeasuredCPU ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: Layout.cpuColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.rowVerticalPadding)
        .background(isSelected ? Color.accentColor.opacity(Layout.selectionOpacity) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedProcessID = process.processID }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Layout.footerSpacing) {
            Text("Renderer processes are shared between tabs and cannot be traced back to one.")
                .font(.system(size: Layout.secondaryFontSize))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("End Process") { model.endSelectedProcess() }
                .disabled(!model.canEndSelectedProcess)
                .orbitTooltip(endProcessHelp)
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.footerVerticalPadding)
    }

    private var endProcessHelp: String {
        switch model.endProcessRefusal {
        case .isBrowserProcess:
            return "Orbit itself cannot be ended here. Quit Orbit instead."
        case .notAnOrbitProcess:
            return model.selectedProcess == nil
                ? "Select a task first."
                : "This process is no longer running."
        case nil:
            return "Ends the selected process immediately. A web page will show Orbit's reload card."
        }
    }

    private enum Layout {
        static let horizontalPadding: CGFloat = 14
        static let headerVerticalPadding: CGFloat = 7
        static let rowVerticalPadding: CGFloat = 5
        static let footerVerticalPadding: CGFloat = 10
        static let footerSpacing: CGFloat = 12
        static let memoryColumnWidth: CGFloat = 120
        static let cpuColumnWidth: CGFloat = 60
        static let headerFontSize: CGFloat = 11
        static let rowFontSize: CGFloat = 12.5
        static let secondaryFontSize: CGFloat = 10.5
        static let selectionOpacity: CGFloat = 0.22
    }
}
