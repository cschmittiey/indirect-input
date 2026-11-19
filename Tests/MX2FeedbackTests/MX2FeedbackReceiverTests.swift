import XCTest
@testable import MX2Feedback
@testable import IndirectInputCore

@MainActor
final class MX2FeedbackReceiverTests: XCTestCase {

    /// Picks a port unlikely to be taken, so tests do not fight Syndicate on 9096.
    private func ephemeralPort() -> UInt16 {
        UInt16.random(in: 20_000...60_000)
    }

    private func send(_ packet: Data, to port: UInt16) {
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(socketFD, 0)
        defer { close(socketFD) }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        destination.sin_addr.s_addr = inet_addr("127.0.0.1")
        let sent = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, raw.baseAddress, raw.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        XCTAssertEqual(sent, packet.count)
    }

    /// Waits for `condition` on the main actor, pumping the run loop.
    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    // MARK: Defaults and lifecycle

    func testDefaultPortIsSyndicateFeedbackPort() {
        XCTAssertEqual(MX2FeedbackReceiver.defaultPort, 9096)
        XCTAssertEqual(MX2FeedbackReceiver(port: 12_345).port, 12_345)
    }

    func testStartBindsAndStopsReleases() {
        let port = ephemeralPort()
        let receiver = MX2FeedbackReceiver(port: port)
        XCTAssertTrue(receiver.start())
        XCTAssertEqual(receiver.status, .listening(port: port))
        receiver.stop()
        XCTAssertEqual(receiver.status, .idle)
        // Port must be free again for a second receiver.
        let second = MX2FeedbackReceiver(port: port)
        XCTAssertTrue(second.start())
        second.stop()
    }

    func testStartIsIdempotent() {
        let port = ephemeralPort()
        let receiver = MX2FeedbackReceiver(port: port)
        XCTAssertTrue(receiver.start())
        XCTAssertTrue(receiver.start())
        XCTAssertEqual(receiver.status, .listening(port: port))
        receiver.stop()
    }

    func testStopBeforeStartIsSafe() {
        let receiver = MX2FeedbackReceiver(port: ephemeralPort())
        receiver.stop()
        receiver.stop()
        XCTAssertEqual(receiver.status, .idle)
    }

    // MARK: Port conflict

    func testOccupiedPortFailsGracefullyWithoutCrashing() {
        let port = ephemeralPort()
        let first = MX2FeedbackReceiver(port: port)
        XCTAssertTrue(first.start())
        defer { first.stop() }

        let second = MX2FeedbackReceiver(port: port)
        var errors: [String] = []
        second.onError = { errors.append($0) }

        XCTAssertFalse(second.start())
        guard case let .failed(failedPort, message) = second.status else {
            return XCTFail("expected .failed, got \(second.status)")
        }
        XCTAssertEqual(failedPort, port)
        XCTAssertTrue(message.contains("in use"), "message was: \(message)")
        XCTAssertEqual(errors.count, 1)
        // Failed receiver keeps working as a pure state machine.
        second.ingest(oscMessage("/Syndicate/Deck/1/Playing") { $0.int(1) })
        XCTAssertTrue(second.state[deck: 1].playing)
    }

    // MARK: End-to-end UDP

    func testReceivesRealDatagramAndUpdatesState() {
        let port = ephemeralPort()
        let receiver = MX2FeedbackReceiver(port: port)
        var changes: [MX2FeedbackState] = []
        receiver.onStateChange = { changes.append($0) }
        XCTAssertTrue(receiver.start())
        defer { receiver.stop() }

        send(oscMessage("/Syndicate/Deck/2/Playing") { $0.int(1) }, to: port)
        XCTAssertTrue(waitUntil { receiver.state[deck: 2].playing })
        XCTAssertEqual(receiver.status, .listening(port: port))
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(receiver.receivedPacketCount, 1)
    }

    func testReceivesBundleOverUDP() {
        let port = ephemeralPort()
        let receiver = MX2FeedbackReceiver(port: port)
        XCTAssertTrue(receiver.start())
        defer { receiver.stop() }

        let bundle = oscBundle([
            oscMessage("/Syndicate/Deck/1/Playing") { $0.int(1) },
            oscMessage("/Syndicate/Deck/1/Sync") { $0.int(1) },
            oscMessage("/Syndicate/Deck/2/Cues") { builder in
                builder.int(6); builder.string("Drop")
            }
        ])
        send(bundle, to: port)
        XCTAssertTrue(waitUntil { receiver.state[deck: 1].sync
            && receiver.state[deck: 2].cues[0].color == 6 })
        XCTAssertTrue(receiver.state[deck: 1].playing)
        XCTAssertEqual(receiver.state[deck: 2].cues[0].name, "Drop")
    }

    func testMalformedDatagramIsIgnoredAndReported() {
        let port = ephemeralPort()
        let receiver = MX2FeedbackReceiver(port: port)
        var errors: [String] = []
        receiver.onError = { errors.append($0) }
        XCTAssertTrue(receiver.start())
        defer { receiver.stop() }

        send(Data([0xDE, 0xAD, 0xBE, 0xEF]), to: port)
        XCTAssertTrue(waitUntil { receiver.rejectedPacketCount == 1 })
        XCTAssertEqual(receiver.state, MX2FeedbackState())
        XCTAssertEqual(errors.count, 1)

        // The socket keeps working after garbage.
        send(oscMessage("/Syndicate/Loaded") { $0.int(1) }, to: port)
        XCTAssertTrue(waitUntil { receiver.state.loaded })
    }

    func testMultipleDatagramsInSequenceAreAllApplied() {
        let port = ephemeralPort()
        let receiver = MX2FeedbackReceiver(port: port)
        XCTAssertTrue(receiver.start())
        defer { receiver.stop() }

        for deck in 1...4 {
            send(oscMessage("/Syndicate/Deck/\(deck)/Playing") { $0.int(1) }, to: port)
        }
        XCTAssertTrue(waitUntil { receiver.state.deckNumbers.count == 4 })
        XCTAssertTrue((1...4).allSatisfy { receiver.state[deck: $0].playing })
        XCTAssertEqual(receiver.receivedPacketCount, 4)
    }

    // MARK: Callbacks and ingest

    func testStateChangeOnlyFiresWhenSomethingChanged() {
        let receiver = MX2FeedbackReceiver(port: 0)
        var count = 0
        receiver.onStateChange = { _ in count += 1 }

        receiver.ingest(oscMessage("/Syndicate/Deck/1/Sync") { $0.int(1) })
        XCTAssertEqual(count, 1)
        receiver.ingest(oscMessage("/Syndicate/Deck/1/Sync") { $0.int(1) })
        XCTAssertEqual(count, 1)
        receiver.ingest(oscMessage("/Unrelated") { $0.int(1) })
        XCTAssertEqual(count, 1)
        receiver.ingest(Data([1, 2, 3]))
        XCTAssertEqual(count, 1)
    }

    func testIngestReturnsApplyResult() {
        let receiver = MX2FeedbackReceiver(port: 0)
        XCTAssertEqual(receiver.ingest(oscMessage("/Syndicate/Deck/1/Playing") { $0.int(1) }),
                       .changed)
        XCTAssertEqual(receiver.ingest(oscMessage("/Syndicate/Deck/1/Playing") { $0.int(1) }),
                       .unchanged)
        XCTAssertEqual(receiver.ingest(oscMessage("/nope")), .ignored)
    }

    func testResetClearsStateAndCounters() {
        let receiver = MX2FeedbackReceiver(port: 0)
        receiver.ingest(oscMessage("/Syndicate/Deck/1/Playing") { $0.int(1) })
        receiver.ingest(Data([0]))
        receiver.reset()
        XCTAssertEqual(receiver.state, MX2FeedbackState())
        XCTAssertEqual(receiver.receivedPacketCount, 0)
        XCTAssertEqual(receiver.rejectedPacketCount, 0)
    }

    func testReceiverAcceptsPreseededState() {
        var state = MX2FeedbackState()
        state[deck: 4].loop = true
        let receiver = MX2FeedbackReceiver(port: 0, state: state)
        XCTAssertTrue(receiver.state[deck: 4].loop)
    }

    func testOversizedPacketDoesNotCrash() {
        let receiver = MX2FeedbackReceiver(port: 0)
        let junk = Data(repeating: 0x41, count: 60_000)
        XCTAssertEqual(receiver.ingest(junk), .ignored)
        XCTAssertEqual(receiver.rejectedPacketCount, 1)
    }
}
