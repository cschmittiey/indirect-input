import AppKit
import SwiftUI
import IndirectInputCore
import MX2Native
import MX2Feedback

@MainActor
final class BridgeModel: ObservableObject {
    @Published var host = "127.0.0.1"
    @Published var port = "9090"
    @Published var lastOutput = "No OSC sent yet"
    @Published var eventCount = 0
    @Published var flash = false
    @Published var nativeStatus = "Native idle"
    @Published var nativeConnected = false
    @Published var nativeInput = "No native input yet"
    @Published var nativeOutput = "No native OSC sent yet"
    @Published var feedbackStatus = "Feedback not started"
    @Published var rgbStatus = "RGB not sent"
    /// Count of feedback state updates observed through the client's onState hook.
    @Published var feedbackRenders = 0
    @Published var deckPair = 1
    @Published var padBank: MX2PadBank = .hotcues

    let osc = OSCSender()
    let native = MX2NativeController()
    let feedback = MX2FeedbackClient()

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

    /// Previews can render the interface without opening HID or the feedback port.
    init(startServices: Bool = true) {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: "OSCHost") ?? host
        port = defaults.string(forKey: "OSCPort") ?? port
        guard startServices else { return }
        osc.onError = { [weak self] error in
            self?.lastOutput = "UDP error: \(error)"
            self?.nativeOutput = "UDP error: \(error)"
        }
        if let savedPort = UInt16(port), savedPort > 0 {
            osc.configure(host: host, port: savedPort)
        }
        native.onStatus = { [weak self] status, connected in
            self?.nativeStatus = status
            self?.nativeConnected = connected
            // Also persist it. UI-only status made a silent RGB transport failure
            // completely invisible when diagnosing from the log.
            self?.logNative("STATUS \(connected ? "+" : "-") \(status)")
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
        native.onRGB = { [weak self] image, status in
            guard let self else { return }
            // Transport acceptance is not proof of visible light. Nonzero bytes
            // include dim values, so do not describe this count as lit LEDs.
            let populated = image.filter { $0 != 0 }.count
            self.rgbStatus = status == kIOReturnSuccess
                ? "RGB frame accepted · \(populated) nonzero LED values"
                : "RGB error \(status)"
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
            self.feedbackRenders += 1
            // Seed the jog seek origin from real playback position. Without this the
            // first touched platter turn seeks relative to the start of the track.
            for deck in state.deckNumbers {
                self.native.seedJogPosition(deck: deck, progress: state[deck: deck].progress)
            }
            self.feedbackStatus = "Feedback: \(state.deckNumbers.count) decks · \(state.meters.count) meters · \(self.feedbackRenders) frames"
            // Logging every frame would swamp the log at meter rates, so log the
            // first few and then every 50th: enough to see feedback live, cheap.
            if self.feedbackRenders <= 5 || self.feedbackRenders % 50 == 0 {
                self.logNative("FB #\(self.feedbackRenders) decks=\(state.deckNumbers.map(String.init).joined(separator: ","))"
                    + " meters=\(state.meters.count) palette=\(state.palette.isEmpty ? "empty" : "set")")
            }
            // The receiver's own render path already pushed the frame to HID via
            // `onRGB`; this hook is for status and logging only.
        }
        feedback.onResend = { [weak self] in
            self?.osc.send(OSCMessage(address: "/Syndicate/Feedback/Resend", integer: 1))
        }
        feedback.onRGB = { [weak self] image in self?.native.sendRGB(image) }
        native.start()
        feedback.start()
        osc.send(OSCMessage(address: "/Syndicate/Feedback/Resend", integer: 1))
    }

    private func send(_ outgoing: IndirectInputCore.OSCMessage) {
        osc.send(outgoing)
        eventCount += 1
        lastOutput = "\(outgoing.address) · \(outgoing.integer)"
        flash = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.flash = false
        }
    }

    @Published var connectionNotice = ""

    func apply() {
        let destination = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else {
            connectionNotice = "Enter an OSC host."
            return
        }
        guard let value = UInt16(port), value > 0 else {
            connectionNotice = "Port must be 1–65535."
            return
        }
        host = destination
        osc.configure(host: destination, port: value)
        let defaults = UserDefaults.standard
        defaults.set(destination, forKey: "OSCHost")
        defaults.set(port, forKey: "OSCPort")
        connectionNotice = "Destination saved · \(destination):\(value)"
        requestFeedback()
    }

    func requestFeedback() {
        osc.send(OSCMessage(address: "/Syndicate/Feedback/Resend", integer: 1))
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([nativeLogURL])
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

    static func describe(_ message: IndirectInputCore.OSCMessage) -> String {
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

// The native-only SwiftUI surface lives in ContentView.swift.

