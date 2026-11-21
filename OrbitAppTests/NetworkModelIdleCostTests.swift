//  What every tab pays for the network log that is kept before anyone opens the inspector: the work per request on the main thread, and what the log holds once it is full. Measured with the model alone, no window and no page.

import Darwin
import XCTest
@testable import Orbit

@MainActor
final class NetworkModelIdleCostTests: XCTestCase {

    static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    /// Headers as a busy ad-and-analytics page sends and receives them, with a cookie the size real ones are.
    private static let requestHeaders: [OrbitHeader] = {
        var headers = [
            ("accept", "*/*"), ("accept-encoding", "gzip, deflate, br"), ("accept-language", "en-GB,en;q=0.9"),
            ("origin", "https://www.example.com"), ("referer", "https://www.example.com/some/long/path/to/a/page?with=query&and=more"),
            ("sec-fetch-dest", "script"), ("sec-fetch-mode", "no-cors"), ("sec-fetch-site", "cross-site"),
            ("user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"),
            ("cookie", String(repeating: "session=abcdef0123456789; ", count: 80)),
        ]
        return headers.map { OrbitHeader(name: $0.0, value: $0.1) }
    }()

    private static let responseHeaders: [OrbitHeader] = [
        ("content-type", "application/javascript; charset=utf-8"), ("content-length", "48213"), ("cache-control", "public, max-age=31536000, immutable"),
        ("content-encoding", "br"), ("etag", "\"5d8c72a5edda8d6a-cbb5\""), ("last-modified", "Tue, 12 Nov 2026 08:11:03 GMT"),
        ("server", "cloudflare"), ("cf-ray", "9aa0f3c0cb9a1234-LHR"), ("vary", "Accept-Encoding"), ("access-control-allow-origin", "*"),
        ("strict-transport-security", "max-age=31536000; includeSubDomains; preload"), ("x-content-type-options", "nosniff"),
        ("report-to", "{\"endpoints\":[{\"url\":\"https://a.nel.cloudflare.com/report/v4?s=abcdefghijklmnopqrstuvwxyz\"}],\"group\":\"cf-nel\",\"max_age\":604800}"),
    ].map { OrbitHeader(name: $0.0, value: $0.1) }

    func lifecycle(_ model: OrbitNetworkModel, _ index: Int) {
        let id = String(index + 1000)
        var record = NetRecord(id: id)
        record.url = "https://cdn\(index % 7).example.com/assets/chunk-\(index).js?v=\(index % 13)"
        record.method = "GET"
        record.resourceType = "script"
        record.nativeEventTimestamp = Double(index)
        record.requestHeaderStorage = Self.requestHeaders
        record.requestHeadersUnsorted = true
        record.pending = true
        model.nativeRequestSent(record)
        model.nativeResponseReceived(
            id: id, status: 200, statusText: "OK", headers: Self.responseHeaders, mimeType: "application/javascript",
            url: nil, fromCache: false, expectedBodySize: 48213, headersUnsorted: true)
        model.nativeCompleted(id: id, failed: false, cancelled: false, fromCache: false, completionTimestamp: Double(index) + 0.08, errorMessage: nil)
    }

    struct Measurement {
        var perRequestFillMs: Double
        var perRequestSteadyMs: Double
        var logCount: Int
        var residentAtCapacity: Int
        var residentAfter: Int
        var summary: String {
            let megabytes: (Int) -> String = { String(format: "%.1f", Double($0) / 1_048_576) }
            return "fill \(String(format: "%.3f", perRequestFillMs)) ms/request, steady \(String(format: "%.3f", perRequestSteadyMs)) ms/request, log holds \(logCount), resident +\(megabytes(residentAtCapacity)) MB at capacity, +\(megabytes(residentAfter)) MB after 25000 requests"
        }
    }

    /// Fills the log, then keeps going: the cost per request must not grow once it is full.
    static func measure() -> Measurement {
        let probe = NetworkModelIdleCostTests()
        let model = OrbitNetworkModel()
        model.presentationProbe = { false }
        let baseline = residentBytes()
        let fillStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<5000 { probe.lifecycle(model, index) }
        let fillMs = Double(DispatchTime.now().uptimeNanoseconds - fillStart) / 1_000_000
        let atCapacity = residentBytes()
        let steadyStart = DispatchTime.now().uptimeNanoseconds
        for index in 5000..<25000 { probe.lifecycle(model, index) }
        let steadyMs = Double(DispatchTime.now().uptimeNanoseconds - steadyStart) / 1_000_000
        let after = residentBytes()
        return Measurement(perRequestFillMs: fillMs / 5000, perRequestSteadyMs: steadyMs / 20000, logCount: model.records.count,
                           residentAtCapacity: atCapacity - baseline, residentAfter: after - baseline)
    }

    func testAnIdleTabsNetworkLogCostsLittlePerRequestAndStaysBounded() {
        let result = Self.measure()
        print("NETWORK-IDLE-COST \(result.summary)")

        XCTAssertEqual(result.logCount, 5000, "the log is bounded")
        XCTAssertLessThan(result.perRequestSteadyMs, 0.5, "each request's three callbacks cost under half a millisecond of main thread")
        XCTAssertLessThan(result.perRequestSteadyMs, result.perRequestFillMs * 3, "and the cost per request does not grow with the log")
        XCTAssertLessThan(result.residentAfter - result.residentAtCapacity, 64 * 1_048_576, "a full log does not keep growing")
    }
}
