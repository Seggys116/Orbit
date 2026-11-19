//  Says what the main thread was doing during a stall. A watchdog thread notices the run loop has been busy for
//  longer than a threshold, then repeatedly suspends the main thread for a few microseconds and walks its frame
//  pointers. Nothing is allocated or symbolicated while the main thread is suspended.

import Darwin
import Foundation

#if arch(arm64)
final class MainThreadStallSampler: @unchecked Sendable {

    struct Stall {
        var milliseconds: Double
        var stacks: [[UInt]]
    }

    private let lock = NSLock()
    private var busySince: CFAbsoluteTime = 0
    private var isBusy = false
    private var observer: CFRunLoopObserver?
    private var watchdog: Thread?
    private var running = false
    private var stalls: [Stall] = []

    private let mainMach: mach_port_t
    private let stackLow: UInt
    private let stackHigh: UInt
    private let threshold: Double

    init(thresholdMilliseconds: Double = 25) {
        precondition(Thread.isMainThread)
        mainMach = pthread_mach_thread_np(pthread_self())
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        let size = UInt(pthread_get_stacksize_np(pthread_self()))
        stackHigh = top
        stackLow = top - size
        threshold = thresholdMilliseconds / 1000
    }

    func start() {
        lock.lock()
        running = true
        stalls = []
        lock.unlock()
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let created = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, Int.min) { [weak self] _, activity in
            guard let self else { return }
            self.lock.lock()
            if activity.contains(.afterWaiting) {
                self.isBusy = true
                self.busySince = CFAbsoluteTimeGetCurrent()
            } else {
                self.isBusy = false
            }
            self.lock.unlock()
        }
        observer = created
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
        let thread = Thread { [weak self] in self?.watch() }
        thread.qualityOfService = .userInteractive
        watchdog = thread
        thread.start()
    }

    func stop() -> [Stall] {
        lock.lock()
        running = false
        lock.unlock()
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock()
        defer { lock.unlock() }
        return stalls
    }

    private func watch() {
        var buffer = [UInt](repeating: 0, count: 64)
        var episodeStart: CFAbsoluteTime = 0
        var episode: [[UInt]] = []
        while true {
            Thread.sleep(forTimeInterval: 0.003)
            lock.lock()
            let stillRunning = running
            let busy = isBusy
            let since = busySince
            lock.unlock()
            guard stillRunning else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if busy, now - since > threshold {
                if episode.isEmpty { episodeStart = since }
                var depth = 0
                buffer.withUnsafeMutableBufferPointer { pointer in
                    depth = sampleMainThread(into: pointer)
                }
                if depth > 0 { episode.append(Array(buffer[0..<depth])) }
            } else if !episode.isEmpty {
                let finished = Stall(milliseconds: (now - episodeStart) * 1000, stacks: episode)
                episode = []
                lock.lock()
                stalls.append(finished)
                lock.unlock()
            }
        }
    }

    /// Between suspend and resume this reads memory and writes into the caller's buffer, nothing else.
    private func sampleMainThread(into buffer: UnsafeMutableBufferPointer<UInt>) -> Int {
        guard thread_suspend(mainMach) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(mainMach) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainMach, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        var depth = 0
        buffer[depth] = UInt(state.__pc)
        depth += 1
        let lr = UInt(state.__lr)
        if lr != 0, depth < buffer.count {
            buffer[depth] = lr & 0x0000_007F_FFFF_FFFF
            depth += 1
        }
        var frame = UInt(state.__fp)
        while depth < buffer.count, frame % 16 == 0, frame >= stackLow, frame + 16 <= stackHigh {
            let next = UnsafePointer<UInt>(bitPattern: frame)!
            let returnAddress = next[1] & 0x0000_007F_FFFF_FFFF
            guard returnAddress != 0 else { break }
            buffer[depth] = returnAddress
            depth += 1
            let previous = next[0]
            guard previous > frame else { break }
            frame = previous
        }
        return depth
    }

    // MARK: - Symbols

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    private static let demangle: Demangle? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangle.self)
    }()

    static func name(for address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let rawName = info.dli_sname else {
            return String(format: "0x%lx", address)
        }
        let mangled = String(cString: rawName)
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
        if let demangle = Self.demangle, let demangled = mangled.withCString({ demangle($0, mangled.utf8.count, nil, nil, 0) }) {
            defer { free(demangled) }
            return "\(String(cString: demangled)) [\(image)]"
        }
        return "\(mangled) [\(image)]"
    }

    /// For each stall: how long, the innermost Orbit frame most samples were in, and the innermost frame overall.
    static func describe(_ stalls: [Stall], topFrames: Int = 3) -> [String] {
        stalls.map { stall in
            var innermostOrbit: [String: Int] = [:]
            var leaf: [String: Int] = [:]
            for stack in stall.stacks {
                if let first = stack.first { leaf[String(Self.name(for: first).prefix(90)), default: 0] += 1 }
                for address in stack {
                    let name = Self.name(for: address)
                    guard name.contains("[Orbit.debug.dylib]") || name.contains("[Orbit]") else { continue }
                    innermostOrbit[String(name.prefix(130)), default: 0] += 1
                    break
                }
            }
            let orbit = innermostOrbit.sorted { $0.value > $1.value }.prefix(topFrames)
                .map { "\($0.value)/\(stall.stacks.count) \($0.key)" }.joined(separator: " | ")
            let leaves = leaf.sorted { $0.value > $1.value }.prefix(2)
                .map { "\($0.value) \($0.key)" }.joined(separator: " | ")
            // What was calling a blocking Mach message: the frames above the trap, most common chain first.
            var chains: [String: Int] = [:]
            for stack in stall.stacks where stack.count > 3 {
                guard Self.name(for: stack[0]).hasPrefix("mach_msg") else { continue }
                let chain = stack.dropFirst().prefix(14)
                    .map { Self.name(for: $0) }
                    .filter { !$0.hasPrefix("mach_msg") && !$0.contains("[libsystem") && !$0.contains("[CoreFoundation]") }
                    .prefix(7)
                    .map { String($0.prefix(70)) }
                    .joined(separator: " < ")
                chains[chain, default: 0] += 1
            }
            let blocked = chains.sorted { $0.value > $1.value }.prefix(1).map { "BLOCKED \($0.value)x: \($0.key)" }.joined()
            return String(format: "stall %.0fms (%d samples) orbit: %@  leaf: %@  %@", stall.milliseconds, stall.stacks.count, orbit, leaves, blocked)
        }
    }
}
#endif
