import AppKit
import OSLog
import WebKit

/// One in-flight main-actor hop per download. WKDownload's progress observer fires per buffer;
/// queueing a task for each one backs up the main actor and keeps the download object alive longer.
nonisolated private final class DownloadProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false
    private var completed: Int64 = 0
    private var total: Int64 = 0

    /// Latest counts win. Returns whether the caller must schedule the hop.
    func note(completed: Int64, total: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.completed = completed
        self.total = total
        if scheduled { return false }
        scheduled = true
        return true
    }

    func drain() -> (completed: Int64, total: Int64) {
        lock.lock()
        defer { lock.unlock() }
        scheduled = false
        return (completed, total)
    }
}

nonisolated private enum SettledDownloadFile: Sendable {
    case replaced(Int64?)
    case failed(String)
}

/// Finishes used to run on the main actor, so two replacements of one path could not overlap.
nonisolated private final class DownloadFileSettleLock: @unchecked Sendable {
    static let shared = DownloadFileSettleLock()
    private let lock = NSLock()

    func perform<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

struct WebKitDownloadError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Owns every live WKDownload and reports it through the WebContentsDelegate download callbacks.
@MainActor
final class WebKitDownloads: NSObject, WKDownloadDelegate {
    static let shared = WebKitDownloads()

    private static let logger = Logger(subsystem: "com.orbit.browser", category: "WebKitDownloads")

    enum ConflictAction: String {
        case uniquify
        case overwrite
        case prompt
    }

    struct ExtensionOptions {
        var filename: String?
        var saveAs = false
        var conflictAction = ConflictAction.uniquify
    }

    private enum Intent {
        case none
        case pause
        case cancel
    }

    private final class Entry {
        let id: UUID
        weak var owner: WebKitWebContents?
        let dataStore: WKWebsiteDataStore
        let userAgent: String?
        let options: ExtensionOptions?
        var sourceURL: URL?
        var download: WKDownload?
        var destination: URL?
        var partialURL: URL?
        var resumeData: Data?
        var intent = Intent.none
        /// Set once the bytes are on disk and only the rename/stat remains. Cancel and pause
        /// after this point observe the same outcome as a transfer that has already finished.
        var finalizing = false
        var observation: NSKeyValueObservation?
        var state = DownloadState.pending
        var receivedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var bytesPerSecond: Int64 = 0
        var lastReport = Date.distantPast
        var speedSampleTime = Date()
        var speedSampleBytes: Int64 = 0
        var started: CheckedContinuation<UUID, Error>?

        init(id: UUID, owner: WebKitWebContents?, dataStore: WKWebsiteDataStore, userAgent: String?, options: ExtensionOptions?) {
            self.id = id
            self.owner = owner
            self.dataStore = dataStore
            self.userAgent = userAgent
            self.options = options
        }
    }

    private var entries: [UUID: Entry] = [:] {
        didSet { releaseIdleScratchViews() }
    }
    private var byDownload: [ObjectIdentifier: Entry] = [:]
    private var scratchViews: [ObjectIdentifier: WKWebView] = [:]

    static let mustBeInProgress = "Download must be in progress"
    static let cannotResume = "DownloadItem.canResume must be true"

    // MARK: - Queries

    func isTracking(_ id: UUID) -> Bool { entries[id] != nil }

    func canPause(_ id: UUID) -> Bool {
        guard let entry = entries[id], entry.download != nil, entry.intent == .none, !entry.finalizing else { return false }
        return entry.state == .inProgress || entry.state == .pending
    }

    func canResume(_ id: UUID) -> Bool {
        guard let entry = entries[id], entry.resumeData != nil, !entry.finalizing else { return false }
        return entry.state == .paused || entry.state == .interrupted
    }

    // MARK: - Adoption

    func adopt(_ download: WKDownload, owner: WebKitWebContents, sourceURL: URL?) {
        let entry = Entry(
            id: UUID(), owner: owner, dataStore: owner.webView.configuration.websiteDataStore,
            userAgent: owner.webView.customUserAgent, options: nil
        )
        entry.sourceURL = sourceURL ?? download.originalRequest?.url
        attach(download, to: entry)
    }

    private func attach(_ download: WKDownload, to entry: Entry) {
        entry.download = download
        entries[entry.id] = entry
        byDownload[ObjectIdentifier(download)] = entry
        download.delegate = self
        let id = entry.id
        let gate = DownloadProgressGate()
        entry.observation = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            guard gate.note(completed: completed, total: total) else { return }
            Task { @MainActor in
                let sample = gate.drain()
                self?.progressed(id: id, completed: sample.completed, total: sample.total)
            }
        }
    }

    // MARK: - Extension downloads

    func startExtensionDownload(_ request: URLRequest, session: WebKitSession, options: ExtensionOptions) async throws -> UUID {
        let webView = scratchWebView(for: session)
        let entry = Entry(
            id: UUID(), owner: nil, dataStore: session.dataStore, userAgent: session.userAgent, options: options
        )
        entry.sourceURL = request.url
        entries[entry.id] = entry
        return try await withCheckedThrowingContinuation { continuation in
            entry.started = continuation
            Task { @MainActor in
                let download = await webView.startDownload(using: request)
                self.attach(download, to: entry)
            }
        }
    }

    private func scratchWebView(for session: WebKitSession) -> WKWebView {
        scratchWebView(dataStore: session.dataStore, userAgent: session.userAgent)
    }

    private func scratchWebView(dataStore: WKWebsiteDataStore, userAgent: String?) -> WKWebView {
        let key = ObjectIdentifier(dataStore)
        if let existing = scratchViews[key] { return existing }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = WebKitProduct.applicationNameForUserAgent
        let view = WKWebView(frame: .zero, configuration: configuration)
        if let userAgent { view.customUserAgent = userAgent }
        scratchViews[key] = view
        return view
    }

    /// The scratch view is its own web process. Drop it once nothing in that data store is downloading,
    /// including a paused item that still needs the store to resume.
    private func releaseIdleScratchViews() {
        guard !scratchViews.isEmpty else { return }
        let live = Set(entries.values.map { ObjectIdentifier($0.dataStore) })
        scratchViews = scratchViews.filter { live.contains($0.key) }
    }

    // MARK: - Control

    func cancel(id: UUID) {
        guard let entry = entries[id], entry.intent != .cancel, !entry.finalizing else { return }
        entry.intent = .cancel
        guard let download = entry.download, byDownload[ObjectIdentifier(download)] != nil else {
            finishCancel(entry)
            return
        }
        Task { @MainActor in
            _ = await download.cancel()
            // didFail can run before cancel() returns and WebKit may still flush the
            // partial onto the destination afterwards. Delete again once it has stopped.
            self.finishCancel(entry)
            self.discardIncompleteFile(entry)
        }
    }

    /// nil on success, otherwise the chrome.downloads error text.
    func pause(id: UUID) async -> String? {
        guard canPause(id), let entry = entries[id], let download = entry.download else { return Self.mustBeInProgress }
        entry.intent = .pause
        let data = await download.cancel()
        if let data { entry.resumeData = data }
        byDownload.removeValue(forKey: ObjectIdentifier(download))
        entry.observation = nil
        // The resume blob is the only piece still required. Dropping the WKDownload releases
        // its progress source and any buffers it was holding for the partial file.
        entry.download = nil
        guard entry.resumeData != nil else {
            entry.intent = .none
            entries.removeValue(forKey: entry.id)
            report(entry, state: .interrupted, force: true)
            Self.logger.error("pause: no resume data for \(entry.sourceURL?.absoluteString ?? "unknown", privacy: .public)")
            return "Unable to pause: the server does not allow this download to be resumed"
        }
        report(entry, state: .paused, force: true)
        return nil
    }

    func resume(id: UUID) async -> String? {
        guard canResume(id), let entry = entries[id], let data = entry.resumeData else { return Self.cannotResume }
        let webView: WKWebView
        if let owner = entry.owner, !owner.isClosed {
            webView = owner.webView
        } else {
            webView = scratchWebView(dataStore: entry.dataStore, userAgent: entry.userAgent)
        }
        let download = await webView.resumeDownload(fromResumeData: data)
        entry.intent = .none
        entry.resumeData = nil
        speedReset(entry)
        attach(download, to: entry)
        report(entry, state: .inProgress, force: true)
        return nil
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        Task { @MainActor in
            guard let entry = self.byDownload[ObjectIdentifier(download)] else {
                completionHandler(nil)
                return
            }
            if let destination = entry.destination {
                completionHandler(entry.partialURL ?? destination)
                return
            }
            completionHandler(await self.decideDestination(entry, response: response, suggestedFilename: suggestedFilename))
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = byDownload[ObjectIdentifier(download)] else { return }
        // pause() is awaiting cancel() and owns the resume data. Completing here would
        // publish a finished download for a transfer the caller asked to pause.
        if entry.intent == .pause { return }
        byDownload.removeValue(forKey: ObjectIdentifier(download))
        entry.observation = nil
        entry.download = nil
        if entry.intent == .cancel {
            discardIncompleteFile(entry)
            finishCancel(entry)
            return
        }
        let destination = entry.destination
        let partial = entry.partialURL
        entry.finalizing = true
        let entryID = entry.id
        Task { @MainActor in
            let settled = await Self.settleFinishedFile(destination: destination, partial: partial)
            self.applySettledFile(entryID: entryID, destination: destination, settled: settled)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let entry = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        entry.observation = nil
        entry.download = nil
        if let resumeData { entry.resumeData = resumeData }
        switch entry.intent {
        case .pause:
            return
        case .cancel:
            finishCancel(entry)
        case .none:
            if let continuation = entry.started {
                entry.started = nil
                entries.removeValue(forKey: entry.id)
                continuation.resume(throwing: WebKitDownloadError("Download failed: \(error.localizedDescription)"))
                return
            }
            guard entry.destination != nil else {
                entries.removeValue(forKey: entry.id)
                return
            }
            Self.logger.error("download failed: \(error.localizedDescription, privacy: .public)")
            if entry.resumeData == nil { entries.removeValue(forKey: entry.id) }
            report(entry, state: .interrupted, force: true)
        }
    }

    // MARK: - Destination

    private func decideDestination(_ entry: Entry, response: URLResponse, suggestedFilename: String) async -> URL? {
        let sourceURL = entry.sourceURL ?? response.url ?? URL(fileURLWithPath: "/")
        entry.sourceURL = sourceURL
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : 0
        entry.totalBytes = total
        let mime = response.mimeType ?? ""

        if let options = entry.options {
            return await decideExtensionDestination(
                entry, options: options, response: response, suggestedFilename: suggestedFilename, mime: mime, total: total
            )
        }
        guard let owner = entry.owner, let delegate = owner.delegate else {
            entries.removeValue(forKey: entry.id)
            return nil
        }
        let destination = await delegate.webContents(
            owner, willBeginDownload: suggestedFilename, mimeType: mime, totalBytes: total, sourceURL: sourceURL, downloadID: entry.id
        )
        guard let destination else {
            entries.removeValue(forKey: entry.id)
            return nil
        }
        return commit(entry, destination: destination)
    }

    private func decideExtensionDestination(
        _ entry: Entry, options: ExtensionOptions, response: URLResponse, suggestedFilename: String, mime: String, total: Int64
    ) async -> URL? {
        func abort(_ message: String) -> URL? {
            entries.removeValue(forKey: entry.id)
            if let continuation = entry.started {
                entry.started = nil
                continuation.resume(throwing: WebKitDownloadError(message))
            }
            return nil
        }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            return abort("Download failed: SERVER_BAD_CONTENT (HTTP \(http.statusCode))")
        }
        let root = Self.downloadsDirectory
        var directory = root
        var leaf = suggestedFilename
        if let requested = options.filename, !requested.isEmpty {
            guard let parts = Self.relativeComponents(requested) else { return abort("Invalid filename") }
            for component in parts.dropLast() { directory.appendPathComponent(component, isDirectory: true) }
            leaf = parts.last ?? suggestedFilename
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return abort("Download failed: \(error.localizedDescription)")
        }

        var destination: URL
        switch options.conflictAction {
        case .uniquify:
            destination = DownloadStore.uniqueDestination(in: directory, suggestedName: leaf)
        case .overwrite, .prompt:
            destination = directory.appendingPathComponent(Self.sanitizedLeaf(leaf))
        }
        let conflicts = FileManager.default.fileExists(atPath: destination.path)
        if options.saveAs || (options.conflictAction == .prompt && conflicts) {
            guard let chosen = await promptForDestination(directory: directory, name: destination.lastPathComponent) else {
                return abort("Download canceled by the user")
            }
            destination = chosen
        }
        return commit(entry, destination: destination, mime: mime, total: total, suggestedFilename: leaf)
    }

    // Registers the record and hands WebKit a path that does not exist yet.
    private func commit(
        _ entry: Entry, destination: URL, mime: String? = nil, total: Int64? = nil, suggestedFilename: String? = nil
    ) -> URL {
        entry.destination = destination
        entry.state = .inProgress
        speedReset(entry)
        var target = destination
        if FileManager.default.fileExists(atPath: destination.path) {
            let partial = destination.deletingLastPathComponent().appendingPathComponent(".orbit-\(entry.id.uuidString).download")
            entry.partialURL = partial
            target = partial
        }
        if entry.options != nil {
            let env = AppEnvironment.processRoot
            _ = env.addDownload(
                id: entry.id, sourceURL: entry.sourceURL ?? destination, destinationURL: destination,
                suggestedFileName: suggestedFilename ?? destination.lastPathComponent,
                mimeType: mime ?? "", totalBytes: total ?? 0
            )
        }
        if let continuation = entry.started {
            entry.started = nil
            continuation.resume(returning: entry.id)
        }
        return target
    }

    private func promptForDestination(directory: URL, name: String) async -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = directory
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    // MARK: - Progress

    private func speedReset(_ entry: Entry) {
        entry.speedSampleTime = Date()
        entry.speedSampleBytes = entry.receivedBytes
        entry.bytesPerSecond = 0
    }

    private func progressed(id: UUID, completed: Int64, total: Int64) {
        guard let entry = entries[id], entry.intent == .none, !entry.finalizing, entry.state == .inProgress else { return }
        entry.receivedBytes = max(0, completed)
        if total > 0 { entry.totalBytes = total }
        let now = Date()
        let elapsed = now.timeIntervalSince(entry.speedSampleTime)
        if elapsed >= 0.5 {
            entry.bytesPerSecond = Int64(Double(entry.receivedBytes - entry.speedSampleBytes) / elapsed)
            entry.speedSampleTime = now
            entry.speedSampleBytes = entry.receivedBytes
        }
        report(entry, state: .inProgress, force: false)
    }

    private func finishCancel(_ entry: Entry) {
        entry.observation = nil
        if let download = entry.download { byDownload.removeValue(forKey: ObjectIdentifier(download)) }
        // A transfer written straight to its final name looks finished if the partial
        // bytes stay behind. An overwrite writes beside the existing file; only the
        // partial is ours to remove.
        discardIncompleteFile(entry)
        guard entries.removeValue(forKey: entry.id) != nil else { return }
        if let continuation = entry.started {
            entry.started = nil
            continuation.resume(throwing: WebKitDownloadError("Download canceled by the user"))
            return
        }
        guard entry.destination != nil else { return }
        entry.resumeData = nil
        report(entry, state: .cancelled, force: true)
    }

    /// Rename and stat run off the main actor. Callers report state only after this returns,
    /// so a completed record still means the bytes are at the destination.
    @concurrent
    private nonisolated static func settleFinishedFile(destination: URL?, partial: URL?) async -> SettledDownloadFile {
        DownloadFileSettleLock.shared.perform {
            if let destination, let partial {
                do {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            guard let destination else { return .replaced(nil) }
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber
            return .replaced(size?.int64Value)
        }
    }

    private func applySettledFile(entryID: UUID, destination: URL?, settled: SettledDownloadFile) {
        guard let entry = entries[entryID] else { return }
        switch settled {
        case .failed(let message):
            if let destination {
                Self.logger.error("download: replacing \(destination.path, privacy: .public) failed: \(message, privacy: .public)")
            }
            entry.partialURL = nil
            entries.removeValue(forKey: entry.id)
            report(entry, state: .interrupted, force: true)
        case .replaced(let size):
            if let size {
                entry.receivedBytes = size
                entry.totalBytes = max(entry.totalBytes, size)
            }
            entry.partialURL = nil
            entries.removeValue(forKey: entry.id)
            report(entry, state: .completed, force: true)
        }
    }

    private func discardIncompleteFile(_ entry: Entry) {
        if let partial = entry.partialURL {
            try? FileManager.default.removeItem(at: partial)
            return
        }
        if let destination = entry.destination {
            try? FileManager.default.removeItem(at: destination)
        }
    }

    private func report(_ entry: Entry, state: DownloadState, force: Bool) {
        let now = Date()
        if !force, now.timeIntervalSince(entry.lastReport) < 0.2 { return }
        entry.lastReport = now
        entry.state = state
        let progress = DownloadProgress(
            receivedBytes: entry.receivedBytes, totalBytes: entry.totalBytes,
            bytesPerSecond: state == .inProgress ? entry.bytesPerSecond : 0, state: state
        )
        if let owner = entry.owner, !owner.isClosed, let delegate = owner.delegate {
            delegate.webContents(owner, download: entry.id, didUpdate: progress)
            return
        }
        let env = AppEnvironment.processRoot
        env.updateDownload(id: entry.id, progress: progress)
        if state == .completed {
            TidyDownloadsCoordinator.shared.downloadDidComplete(id: entry.id, pageTitle: nil, env: env)
        }
    }

    // MARK: - Naming

    /// Lets a test keep its files out of the user's Downloads folder.
    static var downloadsDirectoryOverride: URL?

    static var downloadsDirectory: URL {
        if let downloadsDirectoryOverride { return downloadsDirectoryOverride }
        return (try? FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    // savePage calls sanitizedBaseName, then createWebArchiveData, then uniqueFileURL.
    // A second save must not start an archive until the first has finished: WebKit rejects
    // the overlapping operation and the page is torn down.
    private static var saveSlotTaken = false

    static func uniqueFileURL(inDirectory directory: URL, baseName: String, pathExtension: String) -> URL {
        defer { saveSlotTaken = false }
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(pathExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(counter)").appendingPathExtension(pathExtension)
            counter += 1
        }
        return candidate
    }

    static func sanitizedBaseName(from title: String) -> String {
        let name = cleanedPageName(from: title)
        let deadline = Date().addingTimeInterval(20)
        while saveSlotTaken, Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, false)
        }
        saveSlotTaken = true
        for contents in WebKitLiveContents.all where !contents.isClosed {
            let raw = contents.navigationState.title.isEmpty
                ? (contents.navigationState.url?.host ?? "page")
                : contents.navigationState.title
            if cleanedPageName(from: raw) == name {
                // An off-screen view has no window, and createWebArchiveData never calls back.
                contents.setVisible(true)
            }
        }
        return name
    }

    private static func cleanedPageName(from title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "page" : trimmed
    }

    private static func sanitizedLeaf(_ name: String) -> String {
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return "download" }
        return leaf
    }

    // chrome.downloads filenames are relative to Downloads and may not climb out of it.
    private static func relativeComponents(_ path: String) -> [String]? {
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts
    }
}
