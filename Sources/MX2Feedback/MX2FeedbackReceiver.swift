import Foundation

/// Receives Syndicate's OSC feedback on a loopback UDP port and keeps an
/// `MX2FeedbackState` up to date for the LED renderer.
///
/// Threading: all state, counters and callbacks are `@MainActor`, so the app can read
/// them directly and drive HID from the same actor. Packet bytes are read on a private
/// serial queue and handed over as immutable `Data`, so no mutable state crosses
/// threads.
///
/// Transport: a plain BSD UDP socket, not `NWListener`. `bind(2)` reports
/// `EADDRINUSE` synchronously, which lets `start()` fail as an ordinary error rather
/// than an async listener state change, and it is the only option that behaves
/// predictably on current macOS for loopback UDP.
@MainActor
public final class MX2FeedbackReceiver {

    public enum State: Equatable, Sendable {
        case idle
        case listening(port: UInt16)
        /// Bind failed — commonly `EADDRINUSE` because Syndicate or a second copy of
        /// this app already owns the port. `start()` has already returned `false`.
        case failed(port: UInt16, message: String)
    }

    public static let defaultPort: UInt16 = 9096
    public static let loopback = "127.0.0.1"
    public static let maximumDatagramSize = FeedbackTransport.maximumDatagramSize

    public private(set) var state: MX2FeedbackState
    public private(set) var status: State = .idle
    /// Datagrams that parsed into at least one message.
    public private(set) var receivedPacketCount = 0
    /// Datagrams dropped as malformed.
    public private(set) var rejectedPacketCount = 0

    /// Fires on the main actor whenever `state` actually changed.
    public var onStateChange: ((MX2FeedbackState) -> Void)?
    /// Fires on the main actor for bind failures and malformed packets.
    public var onError: ((String) -> Void)?
    /// Fires on the main actor when a nonzero `/Syndicate/Feedback/Resend` arrives;
    /// the app should push its current state back to Syndicate.
    public var onResendRequested: (() -> Void)?

    public let port: UInt16

    private let socket: FeedbackSocket

    public init(port: UInt16 = MX2FeedbackReceiver.defaultPort,
                state: MX2FeedbackState = MX2FeedbackState()) {
        self.port = port
        self.state = state
        self.socket = FeedbackSocket(port: port)
        self.socket.onPacket = { [weak self] packet in
            // The socket calls this off the main actor; hop once per datagram.
            Task { @MainActor in self?.ingest(packet) }
        }
    }

    // MARK: - Lifecycle

    /// Binds the UDP socket and starts reading.
    /// - Returns: `true` when listening. On failure it sets `.failed`, reports through
    ///   `onError`, and returns `false` — it never throws or crashes, so a port
    ///   conflict degrades to "no feedback" instead of taking the app down.
    @discardableResult
    public func start() -> Bool {
        guard status != .listening(port: port) else { return true }
        if let reason = socket.start() {
            status = .failed(port: port, message: reason)
            onError?("Port \(port) unavailable: \(reason)")
            return false
        }
        status = .listening(port: port)
        return true
    }

    /// Stops reading and frees the port. Safe to call repeatedly or before `start()`.
    public func stop() {
        socket.stop()
        status = .idle
    }

    /// Clears state and counters, leaving the socket as-is.
    public func reset() {
        state = MX2FeedbackState()
        receivedPacketCount = 0
        rejectedPacketCount = 0
    }

    // MARK: - Ingest

    /// Feeds one datagram through the parser and state machine.
    ///
    /// Exposed so tests, and any future replay tool, can drive the receiver without a
    /// socket. Also used by the socket path once it hops to the main actor.
    @discardableResult
    public func ingest(_ packet: Data) -> MX2FeedbackState.ApplyResult {
        // Parse once: the parsed messages drive both the state and the counters, so
        // "received" means "at least one well-formed message arrived".
        let messages = OSCMessage.parseAll(packet)
        guard !messages.isEmpty else {
            rejectedPacketCount += 1
            onError?("Ignored malformed OSC packet (\(packet.count) bytes)")
            return .ignored
        }
        receivedPacketCount += 1

        var result = MX2FeedbackState.ApplyResult.ignored
        for message in messages {
            switch state.apply(message) {
            case .changed: result = .changed
            case .resendRequested:
                if result != .changed { result = .resendRequested }
            case .unchanged:
                if result == .ignored { result = .unchanged }
            case .ignored:
                break
            }
        }

        switch result {
        case .changed: onStateChange?(state)
        case .resendRequested: onResendRequested?()
        case .unchanged, .ignored: break
        }
        return result
    }
}
