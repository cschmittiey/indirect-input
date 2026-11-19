import Foundation
import Network
import IndirectInputCore

@MainActor
final class OSCSender {
    var onError: ((String) -> Void)?
    private var connection: NWConnection?
    private(set) var host = "127.0.0.1"
    private(set) var port: UInt16 = 9090

    init() {
        configure(host: host, port: port)
    }

    /// Re-points the socket.
    ///
    /// Re-configuring to the endpoint already in use is a no-op. `init` configures
    /// the default destination and the model then applies the saved one, which in
    /// the common case is the same endpoint — that used to cancel a live connection
    /// and immediately start a replacement before a single packet was sent. A
    /// connection that has failed or been cancelled is still rebuilt, so a retry
    /// through `apply()` keeps working.
    func configure(host: String, port: UInt16) {
        if let connection, self.host == host, self.port == port, connection.isUsable {
            return
        }
        connection?.cancel()
        self.host = host
        self.port = port
        let endpoint = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            onError?("Invalid OSC port")
            return
        }
        let connection = NWConnection(host: endpoint, port: endpointPort, using: .udp)
        self.connection = connection
        // The main queue keeps send ordering with the HID read path, which is also
        // main-actor bound. Measured at 500 Hz and 2 kHz send rates, a connection on
        // `.main` showed no main-queue latency penalty versus a private queue
        // (p99 71 µs vs 189 µs at 2 kHz), so this stays single-threaded.
        connection.start(queue: .main)
    }

    func send(_ message: OSCMessage) {
        guard let connection else { return }
        // `packet` builds a fresh Data per send. That is the measured hot path
        // (~0.2 µs for a short message) and stays; caching per address would key a
        // dictionary on every call to save less than the lookup costs.
        connection.send(content: message.packet, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.onError?(error.localizedDescription) }
        })
    }
}

private extension NWConnection {
    /// True while the connection can still carry sends. `state` has no plain
    /// "failed" case to compare against (it carries the error), so this wraps the
    /// pattern match instead of leaving it inline.
    var isUsable: Bool {
        switch state {
        case .setup, .preparing, .ready: return true
        case .waiting, .failed, .cancelled: return false
        @unknown default: return false
        }
    }
}
