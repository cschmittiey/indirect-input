import Foundation
import Network
import BridgeCore

@MainActor
final class OSCSender {
    var onError: ((String) -> Void)?
    private var connection: NWConnection?
    private(set) var host = "127.0.0.1"
    private(set) var port: UInt16 = 9090

    init() {
        configure(host: host, port: port)
    }

    func configure(host: String, port: UInt16) {
        connection?.cancel()
        self.host = host
        self.port = port
        let endpoint = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            onError?("Invalid OSC port")
            return
        }
        connection = NWConnection(host: endpoint, port: endpointPort, using: .udp)
        connection?.start(queue: .main)
    }

    func send(_ message: OSCMessage) {
        guard let connection else { return }
        connection.send(content: message.packet, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { @MainActor in self?.onError?(error.localizedDescription) }
            }
        })
    }
}
