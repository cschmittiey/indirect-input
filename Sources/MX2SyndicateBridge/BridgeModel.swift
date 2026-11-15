import AppKit
import SwiftUI
import BridgeCore
import MX2Native
import MX2Feedback

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
    @Published var nativeStatus = "Native idle"
    @Published var nativeConnected = false
    @Published var nativeInput = "No native input yet"
    @Published var nativeOutput = "No native OSC sent yet"
    @Published var feedbackStatus = "Feedback not started"
    @Published var rgbStatus = "RGB not sent"
    @Published var deckPair = 1
    @Published var padBank: MX2PadBank = .hotcues

    let midi = MIDIMonitor()
    let osc = OSCSender()
    let native = MX2NativeController()
    let feedback = MX2FeedbackClient()

    private var shiftPressed = false
    private let nativeLogURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".local/state/indirect-input/native-events.log")

    private func logNative(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        let directory = nativeLogURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: nativeLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: nativeLogURL)
        }
    }

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
        native.onStatus = { [weak self] status, connected in
            self?.nativeStatus = status
            self?.nativeConnected = connected
        }
        native.onRawReport = { [weak self] report in
            guard report.first == 1 else { return }
            self?.logNative("RAW " + report.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        native.onControl = { [weak self] message in
            self?.nativeOutput = "\(message.address) · \(Self.describe(message))"
            self?.logNative("OUT \(message.address) \(Self.describe(message))")
            self?.send(message)
        }
        native.onEvent = { [weak self] event in
            self?.nativeInput = String(describing: event)
            self?.logNative("IN \(event)")
            self?.feedback.shift = self?.native.shift ?? [false, false]
            if let bank = self?.native.banks[0] {
                self?.padBank = bank
                self?.feedback.banks = self?.native.banks.map(Self.padMode(for:)) ?? [.hotcues, .hotcues]
            }
        }
        native.onRGB = { [weak self] _, status in
            self?.rgbStatus = status == 0 ? "RGB acknowledged" : "RGB error \(status)"
        }
        native.onStateChange = { [weak self] in
            guard let self else { return }
            self.feedback.cueActive = self.native.cueActive
            self.feedback.headphoneCue = self.native.headphoneCue
            self.feedback.shift = self.native.shift
        }
        feedback.onStatus = { [weak self] status in self?.feedbackStatus = status }
        feedback.onState = { [weak self] state in
            guard let self else { return }
            self.feedbackStatus = "Feedback: \(state.deckNumbers.count) decks · \(state.meters.count) meters"
        }
        feedback.onResend = { [weak self] in
            self?.osc.send(OSCMessage(address: "/Syndicate/Feedback/Resend", integer: 1))
        }
        feedback.onRGB = { [weak self] image in self?.native.sendRGB(image) }
        native.start()
        feedback.start()
        osc.send(OSCMessage(address: "/Syndicate/Feedback/Resend", integer: 1))
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

    private func send(_ outgoing: BridgeCore.OSCMessage) {
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

    func setDeckPair(_ pair: Int) {
        deckPair = pair
        native.mapping.firstDeck = pair
        feedback.configure(firstDeck: pair)
        osc.send(OSCMessage(address: "/Syndicate/Feedback/Resend", integer: 1))
    }

    func setPadBank(_ bank: MX2PadBank) {
        padBank = bank
        native.banks = [bank, bank]
        let mode = Self.padMode(for: bank)
        feedback.banks = [mode, mode]
    }

    static func describe(_ message: BridgeCore.OSCMessage) -> String {
        message.arguments.map {
            switch $0 {
            case let .int(value): return String(value)
            case let .float(value): return String(format: "%.3f", value)
            case let .string(value): return value
            }
        }.joined(separator: ", ")
    }

    static func padMode(for bank: MX2PadBank) -> MX2PadMode {
        switch bank {
        case .hotcues: .hotcues
        case .loops: .loops
        case .stems: .stems
        case .pattern: .pattern
        }
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
        TabView {
            midiPage.tabItem { Text("MIDI Browse") }
            nativePage.tabItem { Text("Native + RGB") }
        }
        .frame(width: 430)
    }

    private var midiPage: some View {
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

    private var nativePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("INDIRECT INPUT")
                    .font(.system(size: 19, weight: .bold, design: .monospaced))
                Text("MX2 · Native companion")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Circle().fill(model.nativeConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.nativeStatus).font(.callout)
            }
            LabeledContent("Deck pair") {
                Picker("", selection: Binding(
                    get: { model.deckPair }, set: { model.setDeckPair($0) })) {
                    Text("1 + 2").tag(1)
                    Text("3 + 4").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            LabeledContent("Pad bank") {
                Picker("", selection: Binding(
                    get: { model.padBank }, set: { model.setPadBank($0) })) {
                    Text("Cues").tag(MX2PadBank.hotcues)
                    Text("FX").tag(MX2PadBank.stems)
                    Text("Sampler").tag(MX2PadBank.pattern)
                    Text("Loops").tag(MX2PadBank.loops)
                }
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(model.nativeInput).font(.caption)
                Text(model.nativeOutput).font(.caption).foregroundStyle(.secondary)
                Text(model.feedbackStatus).font(.caption).foregroundStyle(.secondary)
                Text(model.rgbStatus).font(.caption).foregroundStyle(.secondary)
                Text("\(model.eventCount) OSC events")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            Text("Native mode gives full HID controls and RGB. MIDI Browse remains available as a fallback. In Syndicate, enable OSC INPUT and subscribe to Playing, Cues, Loop, and Meter feedback on port 9096.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Resend feedback") {
                    model.osc.send(OSCMessage(address: "/Syndicate/Feedback/Resend", integer: 1))
                }
                Button("Open OSC Settings") { model.openSyndicateSettings() }
            }
        }
        .padding(20)
    }
}

