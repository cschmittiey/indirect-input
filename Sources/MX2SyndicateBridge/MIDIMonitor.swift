import Foundation
import CoreMIDI
import BridgeCore

@MainActor
final class MIDIMonitor {
    var onMessage: ((MX2MIDIEvent) -> Void)?
    var onStatus: ((Bool, String) -> Void)?

    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var source: MIDIEndpointRef = 0
    private(set) var deviceName = "Traktor MX2"
    private var savedUniqueID: MIDIUniqueID? {
        didSet { UserDefaults.standard.set(savedUniqueID, forKey: "MIDIUniqueID") }
    }
    private var reconnectWork: DispatchWorkItem?

    init() {
        let stored = UserDefaults.standard.integer(forKey: "MIDIUniqueID")
        savedUniqueID = stored == 0 ? nil : MIDIUniqueID(stored)
        createClient()
    }

    func start() {
        reconnect()
    }

    func selectDevice(named name: String) {
        guard name != deviceName || source == 0 else { return }
        disconnect()
        deviceName = name
        savedUniqueID = nil
        UserDefaults.standard.set(name, forKey: "MIDIDeviceName")
        reconnect()
    }

    func reconnect() {
        guard client != 0, inputPort != 0 else { return }
        source = MIDIEndpoints.matchingSource(name: deviceName, uniqueID: savedUniqueID) ?? 0
        guard source != 0 else {
            onStatus?(false, "Waiting for \(deviceName)")
            scheduleReconnect()
            return
        }
        let status = MIDIPortConnectSource(inputPort, source, nil)
        guard status == noErr else {
            onStatus?(false, "MIDI connection error \(status)")
            scheduleReconnect()
            return
        }
        savedUniqueID = MIDIEndpoints.uniqueID(source)
        reconnectWork?.cancel()
        onStatus?(true, "\(deviceName) connected")
    }

    private func createClient() {
        var status = MIDIClientCreateWithBlock("MX2 Syndicate Bridge" as CFString, &client) {
            [weak self] notification in
            guard let self else { return }
            if notification.pointee.messageID == .msgSetupChanged {
                Task { @MainActor in self.reconnect() }
            }
        }
        guard status == noErr else {
            onStatus?(false, "Could not create MIDI client: \(status)")
            return
        }
        status = MIDIInputPortCreateWithProtocol(client, "MX2 input" as CFString,
                                                  ._1_0, &inputPort) {
            [weak self] eventList, _ in
            var packet = eventList.pointee.packet
            for _ in 0..<eventList.pointee.numPackets {
                if let message = MX2MIDIEvent(eventPacket: packet) {
                    Task { @MainActor in self?.onMessage?(message) }
                }
                packet = MIDIEventPacketNext(&packet).pointee
            }
        }
        guard status == noErr else {
            onStatus?(false, "Could not create MIDI input: \(status)")
            return
        }
    }

    private func disconnect() {
        guard source != 0 else { return }
        MIDIPortDisconnectSource(inputPort, source)
        source = 0
    }

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reconnect() }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    deinit {
        if source != 0 { MIDIPortDisconnectSource(inputPort, source) }
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }
}
