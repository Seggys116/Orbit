import Darwin
import Foundation

/// How the helper process ended, and whether it ended the way macOS ends a helper whose parent is not on its allowlist:
/// SIGKILL moments after launch, before it has said anything.
nonisolated struct SystemPasswordsTermination: Sendable, Equatable {
    nonisolated enum Cause: Sendable, Equatable {
        case exited(Int32)
        case signal(Int32)
    }

    var cause: Cause
    var uptime: TimeInterval
    var receivedAnyMessage: Bool

    static let launchRefusalWindow: TimeInterval = 5

    var looksLikeLaunchRefusal: Bool {
        cause == .signal(SIGKILL) && !receivedAnyMessage && uptime <= Self.launchRefusalWindow
    }
}

/// One helper process: framed JSON in over its stdin, framed JSON out of its stdout. Closing stdin ends it.
nonisolated final class SystemPasswordsTransport: @unchecked Sendable {

    nonisolated enum Event: Sendable {
        case message(Data)
        case malformedStream
        case terminated(SystemPasswordsTermination)
    }

    nonisolated enum Failure: Error, Equatable {
        case notRunning
        case writeFailed(Int32)
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var decoder = NativeMessageFraming.Decoder()
    private var launchedAt: TimeInterval = 0
    private var receivedAnyMessage = false
    private var reachedEndOfOutput = false
    private var termination: SystemPasswordsTermination?
    private var finished = false
    private var inputClosed = false

    init(executable: URL, arguments: [String]) {
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func launch() throws {
        // A helper that dies at once closes its end of the pipe; writing then must fail with EPIPE, not kill Orbit with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receive(data)
        }
        process.terminationHandler = { [weak self] process in
            let cause: SystemPasswordsTermination.Cause = process.terminationReason == .uncaughtSignal
                ? .signal(process.terminationStatus)
                : .exited(process.terminationStatus)
            self?.processEnded(cause)
        }
        lock.withLock { launchedAt = ProcessInfo.processInfo.systemUptime }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            continuation.finish()
            throw error
        }
    }

    func send(_ payload: Data) throws {
        let framed = NativeMessageFraming.encode(payload)
        let closed = lock.withLock { inputClosed || termination != nil }
        guard !closed, process.isRunning else { throw Failure.notRunning }
        let descriptor = input.fileHandleForWriting.fileDescriptor
        try framed.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Failure.writeFailed(errno)
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    /// Closes stdin, which the helper takes as the end of the session.
    func close() {
        let shouldClose: Bool = lock.withLock {
            guard !inputClosed else { return false }
            inputClosed = true
            return true
        }
        guard shouldClose else { return }
        try? input.fileHandleForWriting.close()
    }

    func terminate() {
        close()
        if process.isRunning { process.terminate() }
    }

    private func receive(_ data: Data) {
        if data.isEmpty {
            output.fileHandleForReading.readabilityHandler = nil
            lock.withLock { self.reachedEndOfOutput = true }
            finishIfDone()
            return
        }
        let messages: [Data]
        do {
            messages = try lock.withLock { try decoder.append(data) }
        } catch {
            continuation.yield(.malformedStream)
            terminate()
            return
        }
        if !messages.isEmpty { lock.withLock { receivedAnyMessage = true } }
        for message in messages { continuation.yield(.message(message)) }
    }

    private func processEnded(_ cause: SystemPasswordsTermination.Cause) {
        lock.withLock {
            termination = SystemPasswordsTermination(
                cause: cause,
                uptime: ProcessInfo.processInfo.systemUptime - launchedAt,
                receivedAnyMessage: receivedAnyMessage
            )
        }
        close()
        // A killed child never closes stdout cleanly in every case; stop waiting for the end of it a moment after the exit.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            lock.withLock { self.reachedEndOfOutput = true }
            output.fileHandleForReading.readabilityHandler = nil
            finishIfDone()
        }
        finishIfDone()
    }

    private func finishIfDone() {
        let ended: SystemPasswordsTermination? = lock.withLock {
            guard !finished, reachedEndOfOutput, let termination else { return nil }
            finished = true
            return termination
        }
        guard let ended else { return }
        continuation.yield(.terminated(ended))
        continuation.finish()
    }

    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        continuation.finish()
    }
}
