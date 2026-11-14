import AppKit
import SwiftUI
import BridgeCore

@MainActor
final class BridgeModel: ObservableObject {
    @Published var midiConnected = false
    @Published var midiStatus = "Starting MIDI"
    @Published var host = "127.0.0.1"
    @Published var port = "9090"
    @Published var cc = "16"
    @Published var midiChannel = 0
    @Published var shiftedNavigation = false
    @Published var loadOnPress = false
    @Published var loadDeck = 1
    @Published var lastInput = "No encoder input yet"
    @Published var lastOutput = "No OSC sent yet"
    @Published var eventCount = 0
    @Published var flash = false

    let midi = MIDIMonitor()
    let osc = OSCSender()

    private var shiftPressed = false

    init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: "OSCHost") ?? host
        port = defaults.string(forKey: "OSCPort") ?? port
        cc = defaults.string(forKey: "BrowseCC") ?? cc
        midiChannel = defaults.integer(forKey: "MIDIChannel")
        shiftedNavigation = defaults.bool(forKey: "ShiftedNavigation")
        loadOnPress = defaults.bool(forKey: "LoadOnPress")
        loadDeck = defaults.integer(forKey: "LoadDeck") == 0 ? 1 : defaults.integer(forKey: "LoadDeck")
        midi.onStatus = { [weak self] connected, status in
            self?.midiConnected = connected
            self?.midiStatus = status
        }
        midi.onMessage = { [weak self] message in self?.handle(message) }
        osc.onError = { [weak self] error in self?.lastOutput = "UDP error: \(error)" }
        midi.start()
    }

    func handle(_ event: MX2MIDIEvent) {
        switch event {
        case let .note(channel, number, velocity):
            lastInput = "Ch \(channel) · Note \(number) = \(velocity)"
            guard channel == midiChannel || midiChannel == 0, number == 12 else {
                if loadOnPress, channel == midiChannel || midiChannel == 0, number == 30, velocity > 0 {
                    send(BridgeRouting.loadMessage(deck: loadDeck))
                }
                return
            }
            shiftPressed = velocity > 0
        case let .controlChange(channel, controller, value):
            lastInput = "Ch \(channel) · CC \(controller) = \(value)"
            guard channel == midiChannel || midiChannel == 0,
                  controller == UInt8(cc),
                  let event = BrowseEvent(channel: channel,
                                          controller: controller,
                                          value: value) else { return }
            send(BridgeRouting.message(for: event, shifted: shiftedNavigation && shiftPressed))
        }
    }

    private func send(_ outgoing: OSCMessage) {
        osc.send(outgoing)
        eventCount += 1
        lastOutput = "\(outgoing.address) · \(outgoing.integer)"
        flash = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.flash = false
        }
    }

    func apply() {
        guard let value = UInt16(port), value > 0 else {
            lastOutput = "Port must be 1–65535"
            return
        }
        guard let controller = UInt8(cc), controller <= 127 else {
            lastOutput = "CC must be 0–127"
            return
        }
        osc.configure(host: host, port: value)
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: "OSCHost")
        defaults.set(port, forKey: "OSCPort")
        defaults.set(cc, forKey: "BrowseCC")
        defaults.set(midiChannel, forKey: "MIDIChannel")
        defaults.set(shiftedNavigation, forKey: "ShiftedNavigation")
        defaults.set(loadOnPress, forKey: "LoadOnPress")
        defaults.set(loadDeck, forKey: "LoadDeck")
        lastOutput = "Ready to send to \(host):\(value)"
    }

    func selectTestDevice() {
        midi.reconnect()
    }

    func selectMX2() {
        midi.selectDevice(named: "Traktor MX2")
    }

    func openSyndicateSettings() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.syndicate.app").first?.activate()
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: 43, keyDown: true)
        event?.flags = .maskCommand
        event?.post(tap: .cghidEventTap)
        let release = CGEvent(keyboardEventSource: source, virtualKey: 43, keyDown: false)
        release?.flags = .maskCommand
        release?.post(tap: .cghidEventTap)
    }
}

struct ContentView: View {
    @ObservedObject var model: BridgeModel
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MX2 → SYNDICATE")
                        .font(.system(size: 19, weight: .bold, design: .monospaced))
                    Text("Browse encoder · OSC bridge")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(model.flash ? Color.green : Color.green.opacity(0.25))
                    .frame(width: 12, height: 12)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(model.midiConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.midiStatus)
                    .font(.callout)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("CC \(model.cc)  ·  63 = UP  ·  65 = DOWN")
                    .font(.system(.body, design: .monospaced))
                Text("Send to \(model.host):\(model.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text(model.lastInput).font(.caption)
                Text(model.lastOutput)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(model.eventCount) encoder events")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Connection settings", isExpanded: $showSettings) {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Host", content: { TextField("127.0.0.1", text: $model.host) })
                    LabeledContent("OSC port", content: { TextField("9090", text: $model.port) })
                    LabeledContent("Browse CC", content: { TextField("19", text: $model.cc) })
                    LabeledContent("MIDI channel", content: {
                        Picker("", selection: $model.midiChannel) {
                            Text("Both MX2 channels").tag(0)
                            Text("1 · left").tag(1)
                            Text("2 · right").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    })
                    Toggle("Shift + wheel navigates the library tree", isOn: $model.shiftedNavigation)
                    Toggle("Press browse encoder to load", isOn: $model.loadOnPress)
                    if model.loadOnPress {
                        Picker("Load into deck", selection: $model.loadDeck) {
                            ForEach(1...4, id: \.self) { Text("Deck \($0)").tag($0) }
                        }
                    }
                    Text("CC 16 on either MX2 channel is the default. Shift is Note 12; encoder press is Note 30. Enable Syndicate’s OSC input separately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Use MX2") { model.selectMX2() }
                        Button("Reconnect") { model.selectTestDevice() }
                        Spacer()
                        Button("Apply") { model.apply() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.top, 10)
            }

            Text("In Syndicate: Settings → OSC → enable OSC INPUT. No MIDI mapping is needed for this encoder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Syndicate Settings") { model.openSyndicateSettings() }
        }
        .padding(20)
        .frame(width: 410)
        .textFieldStyle(.roundedBorder)
    }
}
