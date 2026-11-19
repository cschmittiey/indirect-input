import Combine
import XCTest
import IndirectInputCore
import MX2Feedback
import MX2Native
@testable import IndirectInputApp

/// Guards the hot paths the bridge owns: the diagnostic log append, the hex
/// encoding, and the redundant-work elimination in state mirroring.
///
/// These are timing assertions with generous headroom — they are here to catch a
/// regression of the order-of-magnitude kind (a formatter allocated per line, a
/// file reopened per line, an LED frame rendered per event), not to police
/// microsecond noise on a loaded machine.
@MainActor
final class BridgeHotPathTests: XCTestCase {

    // MARK: - Hex encoding

    func testHexMatchesFormatSpecifierOutput() {
        let report: [UInt8] = [0x01, 0x00, 0xFF, 0xAB, 0x7E]
        let expected = report.map { String(format: "%02X", $0) }.joined(separator: " ")
        XCTAssertEqual(BridgeModel.hexForTesting(report), expected)
        XCTAssertEqual(BridgeModel.hexForTesting(report), "01 00 FF AB 7E")
        XCTAssertEqual(BridgeModel.hexForTesting([]), "")
        XCTAssertEqual(BridgeModel.hexForTesting([0x00]), "00")
    }

    func testHexIsFasterThanFormatStringPerByte() {
        let report: [UInt8] = Array(0...14)
        let iterations = 20_000

        let tableStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { _ = BridgeModel.hexForTesting(report) }
        let tablePerCall = Double(DispatchTime.now().uptimeNanoseconds - tableStart) / Double(iterations)

        let formatStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<(iterations / 10) {
            _ = report.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        let formatPerCall = Double(DispatchTime.now().uptimeNanoseconds - formatStart) / Double(iterations / 10)

        print("hex: table \(String(format: "%.2f", tablePerCall / 1000)) µs vs format \(String(format: "%.2f", formatPerCall / 1000)) µs per call")
        XCTAssertLessThan(tablePerCall, formatPerCall,
                          "table hex must beat a format string per byte")
    }

    // MARK: - Log append

    /// A scratch log per test, so the suite never appends to the user's diagnostic
    /// file and never races another test over one descriptor.
    private func makeModel() -> (BridgeModel, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("indirect-input-tests")
            .appendingPathComponent("log-\(UUID().uuidString).log")
        return (BridgeModel(startServices: false, logURL: url), url)
    }

    /// The log used to construct an `ISO8601DateFormatter` and open/seek/close the
    /// file on every line, which measured ~129 µs per line. One thousand lines is a
    /// plausible platter burst; at the old cost that was ~130 ms of main-thread work.
    func testLogAppendThousandLinesStaysWithinBudget() {
        let (model, url) = makeModel()

        let before = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let iterations = 1_000
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            model.logNativeForTesting("BENCH \(index) 01 02 03")
        }
        let totalMicroseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000
        let perLine = totalMicroseconds / Double(iterations)
        print("log append: \(String(format: "%.2f", perLine)) µs/line, \(String(format: "%.1f", totalMicroseconds / 1000)) ms for \(iterations) lines")

        model.flushLogForTesting()
        let after = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(after, before, "lines must actually be appended")

        // Old implementation was ~129 µs/line. Budget leaves room for slow disks
        // while still failing if a per-line formatter or file reopen returns.
        XCTAssertLessThan(perLine, 60, "log append must not regress to per-line formatter/file setup")
    }

    func testLogLinesKeepISO8601PrefixAndAppendInOrder() throws {
        let (model, url) = makeModel()
        let marker = "ORDER-MARKER-\(UInt32.random(in: 0...UInt32.max))"
        model.logNativeForTesting("\(marker) first")
        model.logNativeForTesting("\(marker) second")
        model.flushLogForTesting()

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n").filter { $0.contains(marker) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("\(marker) first"), "append order must be preserved")
        // Same shape as before: an ISO-8601 timestamp, one space, then the message.
        let prefix = String(lines[0].prefix(20))
        XCTAssertNotNil(ISO8601DateFormatter().date(from: prefix),
                        "line must still start with an ISO-8601 timestamp: \(lines[0])")
    }

    // MARK: - Redundant render elimination

    /// Without the change, mirroring native state published unconditionally, and each
    /// publish costs three LED renders plus an output report. Renders are observed
    /// through the client's own `onRGB` hook, which fires once per composed frame.
    func testMirroringUnchangedStateDoesNotRender() {
        let (model, _) = makeModel()
        model.feedback.shift = [false, false]
        model.feedback.banks = [.hotcues, .hotcues]

        let renders = Counter()
        model.feedback.onRGB = { _ in renders.value += 1 }

        for _ in 0..<50 {
            model.applyNativeStateForTesting()
        }
        XCTAssertEqual(renders.value, 0, "unchanged native state must not republish the feedback client")
    }

    func testMirroringChangedStateStillPropagates() {
        let (model, _) = makeModel()
        let renders = Counter()
        model.feedback.onRGB = { _ in renders.value += 1 }

        model.native.shift = [true, false]
        model.applyNativeStateForTesting()

        XCTAssertEqual(model.feedback.shift, [true, false], "shift must still mirror")
        XCTAssertGreaterThan(renders.value, 0)
    }

    // MARK: - Flash timer

    /// The old code spawned a `Task` per message just to clear one flag; a burst
    /// left them all alive for 120 ms. The model now keeps a single timer.
    func testFlashBurstUsesOneResetAndSettles() async throws {
        let (model, _) = makeModel()
        for _ in 0..<200 {
            model.sendForTesting(OSCMessage(address: "/Syndicate/Deck/1/PhaseBend", integer: 1))
        }
        XCTAssertTrue(model.flash, "flash must be on during the burst")
        XCTAssertEqual(model.eventCount, 200)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(model.flash, "flash must clear after the reset window")
    }
}

private final class Counter: @unchecked Sendable {
    var value = 0
}
