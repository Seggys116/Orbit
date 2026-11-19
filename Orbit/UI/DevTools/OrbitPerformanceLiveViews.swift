import SwiftUI

struct PerfLiveTab: View {
    var session: OrbitInspectSession
    private var live: OrbitPerformanceLiveModel { session.performance.live }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                InspectSectionHeader("Live metrics", detail: "Updated every second")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8, alignment: .top)], spacing: 8) {
                    memoryCard
                    cpuCard
                    gpuCard
                    fpsCard
                    nodesCard
                    stallCard
                    if live.jsHeap.hasData { heapCard }
                }
                notes
            }
            .padding(InspectChrome.panelPadding)
        }
        .task(id: ObjectIdentifier(session)) { await live.run(session: session) }
    }

    private var memoryCard: some View {
        PerfLiveCard(
            title: "Memory",
            value: live.memory.current.map(PerfLiveFormat.bytes) ?? "n/a",
            peak: live.memory.peak > 0 ? "peak \(PerfLiveFormat.bytes(live.memory.peak))" : nil,
            detail: live.webProcessID.map { "Web content process \($0), memory footprint" }
                ?? "The page's web content process could not be identified",
            series: live.memory
        )
    }

    private var cpuCard: some View {
        PerfLiveCard(
            title: "CPU",
            value: live.cpu.current.map(PerfLiveFormat.percent) ?? "n/a",
            peak: live.cpu.hasData ? "peak \(PerfLiveFormat.percent(live.cpu.peak))" : nil,
            detail: "Web content process; 100% is one core",
            series: live.cpu,
            minimumScale: 100
        )
    }

    private var gpuCard: some View {
        let useDevice = live.gpuDevice.hasData
        let series = useDevice ? live.gpuDevice : live.gpuProcessCPU
        var detail = useDevice ? "System GPU device utilisation" : "WebKit GPU process CPU; device utilisation unavailable"
        if let pid = live.gpuProcessID, let memory = live.gpuProcessMemory.current {
            detail += ". GPU process \(pid): \(PerfLiveFormat.bytes(memory))"
        }
        return PerfLiveCard(
            title: "GPU",
            value: series.current.map(PerfLiveFormat.percent) ?? "n/a",
            peak: series.hasData ? "peak \(PerfLiveFormat.percent(series.peak))" : nil,
            detail: detail,
            series: series,
            minimumScale: 100
        )
    }

    private var fpsCard: some View {
        PerfLiveCard(
            title: "Frame rate",
            value: live.fps.current.map { String(format: "%.0f fps", $0) } ?? (live.pageHidden ? "paused" : "n/a"),
            peak: live.fps.hasData ? String(format: "peak %.0f fps", live.fps.peak) : nil,
            detail: live.pageHidden ? "The page is hidden, so it is not rendering frames" : "requestAnimationFrame callbacks per second",
            series: live.fps,
            minimumScale: 60
        )
    }

    private var nodesCard: some View {
        PerfLiveCard(
            title: "DOM nodes",
            value: live.domNodes.current.map { PerfLiveFormat.count($0) } ?? "n/a",
            peak: live.domNodes.hasData ? "peak \(PerfLiveFormat.count(live.domNodes.peak))" : nil,
            detail: "Elements in the main document",
            series: live.domNodes
        )
    }

    private var stallCard: some View {
        var detail = "Longest main thread delay in the last second"
        if let tasks = live.longTasks {
            detail += ". \(tasks) long tasks, \(String(format: "%.0f", live.longTaskMs)) ms in total"
        }
        return PerfLiveCard(
            title: "Main thread stall",
            value: live.stall.current.map { String(format: "%.0f ms", $0) } ?? "n/a",
            peak: live.stall.hasData ? String(format: "peak %.0f ms", live.stall.peak) : nil,
            detail: detail,
            series: live.stall,
            minimumScale: 50
        )
    }

    private var heapCard: some View {
        var detail = "JavaScript heap in use"
        if let limit = live.jsHeapLimit { detail += " of \(PerfLiveFormat.bytes(limit)) limit" }
        return PerfLiveCard(
            title: "JS heap",
            value: live.jsHeap.current.map(PerfLiveFormat.bytes) ?? "n/a",
            peak: live.jsHeap.peak > 0 ? "peak \(PerfLiveFormat.bytes(live.jsHeap.peak))" : nil,
            detail: detail,
            series: live.jsHeap
        )
    }

    @ViewBuilder
    private var notes: some View {
        if !live.pageReachable {
            Text("The page did not answer, so frame rate, DOM and stall figures are unavailable.")
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.warnColor)
        }
        Text("A web content process can be shared by several tabs, so memory and CPU describe the whole process. The GPU process is shared by every tab.")
            .font(InspectChrome.caption)
            .foregroundStyle(InspectChrome.muted2)
    }
}

enum PerfLiveFormat {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter
    }()

    static func bytes(_ value: Double) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: UInt64(max(0, value))))
    }

    static func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }

    static func count(_ value: Double) -> String { Int(value).formatted() }
}

struct PerfLiveCard: View {
    var title: String
    var value: String
    var peak: String?
    var detail: String
    var series: OrbitLiveSeries
    var minimumScale: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(InspectChrome.sectionTitle).foregroundStyle(InspectChrome.muted)
                Spacer(minLength: 4)
                if let peak {
                    Text(peak).font(InspectChrome.caption).foregroundStyle(InspectChrome.muted2)
                }
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(InspectChrome.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            PerfSparkline(values: series.values, minimumScale: minimumScale)
                .frame(height: 36)
            Text(detail)
                .font(InspectChrome.caption)
                .foregroundStyle(InspectChrome.muted2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: InspectChrome.controlRadius, style: .continuous)
                .fill(InspectChrome.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: InspectChrome.controlRadius, style: .continuous)
                .strokeBorder(InspectChrome.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

struct PerfSparkline: View {
    var values: [Double?]
    var minimumScale: Double

    var body: some View {
        GeometryReader { proxy in
            let top = max(minimumScale, values.compactMap { $0 }.max() ?? 0)
            let scale = top > 0 ? top : 1
            let step = proxy.size.width / CGFloat(max(OrbitLiveSeries.capacity - 1, 1))
            let offset = OrbitLiveSeries.capacity - values.count
            let points: [CGPoint?] = values.enumerated().map { index, value in
                guard let value else { return nil }
                return CGPoint(
                    x: CGFloat(index + offset) * step,
                    y: proxy.size.height - CGFloat(value / scale) * proxy.size.height
                )
            }
            ZStack {
                Rectangle().fill(InspectChrome.hairline).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Path { path in
                    var drawing = false
                    for point in points {
                        guard let point else { drawing = false; continue }
                        if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
                    }
                }
                .stroke(InspectChrome.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
