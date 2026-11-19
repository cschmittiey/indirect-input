import XCTest
import Network
import IndirectInputCore
@testable import IndirectInputApp

/// Exercises the sender against real loopback UDP. This is the one place a socket is
/// unavoidable: the property under test is that packets actually leave the process.
@MainActor
final class OSCSenderTests: XCTestCase {

    /// A bound UDP listener. It must be an `NWListener` (or a bound BSD socket): an
    /// unbound `NWConnection` reports `.ready` and silently receives nothing.
    private final class Listener: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "osc.test.listener")
        private var payloads: [Data] = []

        let port: UInt16

        /// Retries a few ports in case the random one is taken on this machine.
        init() throws {
            var lastError: Error?
            for _ in 0..<20 {
                let candidate = UInt16.random(in: 49_000...59_000)
                guard let candidatePort = NWEndpoint.Port(rawValue: candidate) else { continue }
                do {
                    listener = try NWListener(using: .udp, on: candidatePort)
                    self.port = candidate
                    return
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? NWError.posix(.EADDRINUSE)
        }

        func start() {
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            listener.start(queue: queue)
        }

        private func receive(on connection: NWConnection) {
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data { self.payloads.append(data) }
                if error == nil { self.receive(on: connection) }
            }
        }

        private func snapshot() -> [Data] { queue.sync { payloads } }

        /// Waits for `count` datagrams, pumping the main run loop so the sender's
        /// main-queue connection can progress.
        func waitForDatagrams(_ count: Int, timeout: TimeInterval = 3) -> [Data] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let current = snapshot()
                if current.count >= count { return current }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return snapshot()
        }

        func stop() { listener.cancel() }
    }

    private func makeSender(to port: UInt16) -> OSCSender {
        let sender = OSCSender()
        sender.configure(host: "127.0.0.1", port: port)
        return sender
    }

    func testSendDeliversTheEncodedPacket() throws {
        let listener = try Listener()
        listener.start()
        defer { listener.stop() }

        let sender = makeSender(to: listener.port)
        let message = OSCMessage(address: "/Syndicate/Deck/1/PhaseBend", integer: 1)
        sender.send(message)

        let datagrams = listener.waitForDatagrams(1)
        XCTAssertEqual(datagrams.count, 1, "one send must produce exactly one datagram")
        XCTAssertEqual(datagrams.first, message.packet,
                       "payload on the wire must be the encoded packet, byte for byte")
    }

    /// `init` configures the default destination and the model then applies a saved
    /// one. Re-configuring to the same endpoint must stay a no-op, and must keep
    /// delivering rather than leaving a cancelled socket behind.
    func testReconfigureToSameEndpointKeepsWorking() throws {
        let listener = try Listener()
        listener.start()
        defer { listener.stop() }

        let sender = makeSender(to: listener.port)
        sender.configure(host: "127.0.0.1", port: listener.port)
        sender.configure(host: "127.0.0.1", port: listener.port)

        sender.send(OSCMessage(address: "/Syndicate/Browser/L2", integer: 1))
        XCTAssertEqual(listener.waitForDatagrams(1).count, 1,
                       "a repeated configure must not break sending")
        XCTAssertEqual(sender.port, listener.port)
    }

    func testReconfigureToNewEndpointRedirects() throws {
        let first = try Listener()
        let second = try Listener()
        first.start()
        second.start()
        defer { first.stop(); second.stop() }

        let sender = makeSender(to: first.port)
        sender.send(OSCMessage(address: "/Syndicate/Browser/L1", integer: 1))
        XCTAssertEqual(first.waitForDatagrams(1).count, 1, "first destination must receive")

        sender.configure(host: "127.0.0.1", port: second.port)
        sender.send(OSCMessage(address: "/Syndicate/Browser/L2", integer: 1))

        XCTAssertEqual(second.waitForDatagrams(1).count, 1,
                       "packets must follow the new destination")
        XCTAssertEqual(sender.port, second.port)
        XCTAssertEqual(first.waitForDatagrams(2, timeout: 0.3).count, 1,
                       "the old destination must not keep receiving")
    }

    func testSendWithDefaultConfigurationIsSilentNotFatal() {
        // `init` already points at the default, so this must simply not trap.
        let sender = OSCSender()
        sender.send(OSCMessage(address: "/Syndicate/Feedback/Resend", integer: 1))
        XCTAssertEqual(sender.host, "127.0.0.1")
        XCTAssertEqual(sender.port, 9090)
    }

    func testHostAndPortTrackTheLastConfigure() throws {
        let listener = try Listener()
        defer { listener.stop() }
        let sender = makeSender(to: listener.port)
        XCTAssertEqual(sender.host, "127.0.0.1")
        XCTAssertEqual(sender.port, listener.port)
    }
}
