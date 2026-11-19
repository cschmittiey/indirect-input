import Foundation

/// Owns one bound loopback UDP socket and its read source.
///
/// Deliberately isolation-free: the read source fires on a private queue, and dispatch
/// handlers declared inside an actor-isolated type inherit that isolation, which trips
/// Swift 6's runtime executor check. Keeping the socket in a plain class makes the
/// handler genuinely nonisolated; packets reach the `@MainActor` receiver through
/// `onPacket` as immutable `Data` values.
final class FeedbackSocket: @unchecked Sendable {

    let port: UInt16
    /// Called on the private read queue for each datagram. Set before `start()`.
    var onPacket: (@Sendable (Data) -> Void)?

    private let queue = DispatchQueue(label: "MX2FeedbackReceiver.osc", qos: .userInitiated)
    private var fileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    /// Signalled by the cancel handler once `close(2)` has completed. Recreated on each
    /// `start()` so a later stop can wait again.
    private var closeCompleted = DispatchSemaphore(value: 0)

    init(port: UInt16) {
        self.port = port
    }

    var isRunning: Bool { readSource != nil }

    /// Binds `port` on 127.0.0.1 and begins reading.
    /// - Returns: `nil` on success, or a human-readable failure reason.
    func start() -> String? {
        guard !isRunning else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return Self.describe(errno) }

        // Non-blocking: the drain loop reads until `recv` reports "no more data". A
        // blocking descriptor would park the loop when the queue empties, and since the
        // cancel handler shares that queue, `stop()` would deadlock behind it.
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let reason = Self.describe(errno)
            close(fd)
            return reason
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let reason = Self.describe(errno)
            close(fd)
            return reason
        }

        fileDescriptor = fd
        closeCompleted = DispatchSemaphore(value: 0)
        let completed = closeCompleted

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let handler = onPacket
        // One receive buffer per socket, reused for every datagram. The handlers all
        // run on the same serial queue, so nothing reads it concurrently; allocating
        // and zeroing 64 KB per datagram was pure waste at meter rates.
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: FeedbackTransport.maximumDatagramSize, alignment: 1)
        source.setEventHandler {
            Self.drain(fd: fd, buffer: buffer, deliver: handler)
        }
        // Closing in the cancel handler means `close(2)` can never race an in-flight
        // read, and `stop()` waits on `completed` for it to land.
        source.setCancelHandler {
            close(fd)
            buffer.deallocate()
            completed.signal()
        }
        readSource = source
        source.resume()
        return nil
    }

    /// Cancels reading and releases the port. Safe to call repeatedly or before `start`.
    ///
    /// Waits until the descriptor is actually closed: rebinding the same port right
    /// after stopping — what happens when a user changes the port and changes back —
    /// would otherwise race the close and fail with `EADDRINUSE`.
    func stop() {
        guard let source = readSource else { return }
        readSource = nil
        fileDescriptor = -1
        source.setEventHandler {}
        source.cancel()
        // Bounded: if the queue were ever wedged, degrade to "leaked descriptor" rather
        // than hanging the main actor that called stop().
        _ = closeCompleted.wait(timeout: .now() + 2)
    }

    /// Reads every queued datagram on `fd`, handing each to `deliver`.
    private static func drain(fd: Int32, buffer: UnsafeMutableRawBufferPointer,
                              deliver: (@Sendable (Data) -> Void)?) {
        while true {
            let count = recv(fd, buffer.baseAddress, buffer.count, 0)
            guard count > 0 else { return }
            deliver?(Data(bytes: buffer.baseAddress!, count: count))
        }
    }

    private static func describe(_ code: Int32) -> String {
        if code == EADDRINUSE { return "address already in use" }
        return "\(String(cString: strerror(code))) (errno \(code))"
    }
}
