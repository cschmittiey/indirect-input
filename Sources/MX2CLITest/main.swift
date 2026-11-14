import Foundation
import CoreMIDI
import Network
import BridgeCore

@main
struct MX2CLITest {
    static func main() async {
        let receiver = OSCReceiver()
        receiver.start()
        let sender = OSCSender()
        sender.configure(host: "127.0.0.1", port: 19090)
        var client: MIDIClientRef = 0
        var input: MIDIPortRef = 0
        var destination: MIDIEndpointRef = 0
        var secondClient: MIDIClientRef = 0
        var injectedSource: MIDIEndpointRef = 0
        guard MIDIClientCreate("MX2 Bridge Test Client" as CFString, nil, nil, &client) == noErr else {
            fatalError("Could not create MIDI test client")
        }
        guard MIDIInputPortCreateWithProtocol(client, "Test input" as CFString, ._1_0, &input, { eventList, _ in
            var packet = eventList.pointee.packet
            for _ in 0..<eventList.pointee.numPackets {
                if let message = MIDIControllerMessage(eventPacket: packet) {
                    Task { @MainActor in
                        print("INPUT ch\(message.channel) CC\(message.controller) = \(message.value)")
                        if let event = BrowseEvent(channel: message.channel,
                                                   controller: message.controller,
                                                   value: message.value) {
                            let outgoing = BridgeRouting.message(for: event)
                            print("OUTPUT \(outgoing.address) \(outgoing.integer)")
                            sender.send(outgoing)
                        }
                    }
                }
                packet = MIDIEventPacketNext(&packet).pointee
            }
        }) == noErr else {
            fatalError("Could not create MIDI test input")
        }
        guard MIDIDestinationCreate(client, "MX2 Bridge Test Receiver" as CFString, { _, _, _ in }, nil, &destination) == noErr else {
            fatalError("Could not create MIDI test receiver")
        }
        guard MIDIClientCreate("MX2 Bridge Test Sender" as CFString, nil, nil, &secondClient) == noErr,
              MIDISourceCreate(secondClient, "MX2 Bridge Test" as CFString, &injectedSource) == noErr,
              MIDIPortConnectSource(input, injectedSource, nil) == noErr else {
            fatalError("Could not create MIDI test connection")
        }
        print("MIDI: virtual test endpoint connected")
        for value in [UInt8(63), 65] {
            let bytes: [UInt8] = [0xB0, 19, value]
            var list = MIDIPacketList()
            withUnsafeMutablePointer(to: &list) { pointer in
                let packet = MIDIPacketListInit(pointer)
                _ = bytes.withUnsafeBufferPointer { buffer in
                    MIDIPacketListAdd(pointer, 1024, packet, 0,
                                      buffer.count, buffer.baseAddress!)
                }
                MIDIReceived(injectedSource, pointer)
            }
            print("SENT CC19 = \(value)")
            try? await Task.sleep(for: .milliseconds(300))
        }
        try? await Task.sleep(for: .milliseconds(500))
        let passed = receiver.up && receiver.down
        print("RESULT: \(passed ? "PASS" : "FAIL")")
        exit(passed ? 0 : 1)
    }
}

@MainActor
final class OSCReceiver {
    var up = false
    var down = false
    private var connection: NWConnection?

    func start() {
        let listener = try! NWListener(using: .udp, on: 19090)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.connection = connection
                connection.start(queue: .main)
                self?.receive()
            }
        }
        listener.start(queue: .main)
    }

    private func receive() {
        connection?.receiveMessage { [weak self] data, _, _, _ in
            Task { @MainActor in
                if let data, let address = String(data: data.prefix(while: { $0 != 0 }), encoding: .utf8) {
                    print("UDP RECEIVED \(address)")
                    if address.hasSuffix("/Up") { self?.up = true }
                    if address.hasSuffix("/Down") { self?.down = true }
                }
                self?.receive()
            }
        }
    }
}
