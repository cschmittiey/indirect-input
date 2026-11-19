import AppKit
import Foundation
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

    // MARK: - Indicator strings

    /// Short, stable status text for the three signal-path lamps. These are the
    /// only strings the view matches on, so they must not drift; the enum keeps
    /// the vocabulary in one place and the published properties typed.
    enum Indicator: String {
        case idle = "Idle"
        case waiting = "Waiting"
        case connected = "Connected"
        case listening = "Listening"
        case received = "Received"
        case accepted = "Accepted"
        case error = "Error"
    }

    /// Mirrors the HID link only — never the RGB transport result.
    @Published private(set) var hidIndicator = Indicator.idle.rawValue
    /// Feedback receiver lifecycle: idle, listening, first frame, or bind error.
    @Published private(set) var feedbackIndicator = Indicator.idle.rawValue
    /// RGB output report acknowledgement, kept separate from the HID link so a
    /// working HID connection with a failing LED transport is visible as such.
    @Published private(set) var rgbIndicator = Indicator.idle.rawValue

    let osc = OSCSender()
    let native = MX2NativeController()
    let feedback = MX2FeedbackClient()

    static let defaultLogURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".local/state/indirect-input/native-events.log")

    // MARK: - Diagnostic log

    // The log sits directly on the HID and feedback hot paths — up to a few
    // thousand lines a second while a platter or a meter stream is moving. Two
    // measured costs dominated the old implementation:
    //
    //   * `ISO8601DateFormatter()` constructed per line: ~95 µs, almost all of it
    //     object setup rather than formatting. One shared format style is ~0.23 µs.
    //   * `FileHandle(forWritingTo:)` + `seekToEnd` + `close` per line: ~31 µs of
    //     open/close syscalls. A kept-open `O_APPEND` descriptor is ~3 µs.
    //
    // Together that took a single log line from ~129 µs to ~3.5 µs. Nothing about
    // the file's shape changes: same path, same ISO-8601 prefix, same append-only
    // line-per-event layout, so the existing log stays readable.
    private static let timestampStyle = Date.ISO8601FormatStyle()
    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)
    /// Overridable so tests write to their own file instead of the user's log.
    private let nativeLogURL: URL
    private var logDescriptor: Int32 = -1
    private var logDirectoryCreated = false

    private func logNative(_ line: String) {
        guard let descriptor = logFileDescriptor() else { return }
        var bytes = Array(Date().formatted(Self.timestampStyle).utf8)
        bytes.reserveCapacity(bytes.count + line.utf8.count + 2)
        bytes.append(0x20)
        bytes.append(contentsOf: line.utf8)
        bytes.append(0x0A)
        // One write(2) per line; short writes are legal so loop until drained.
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = write(descriptor, base + written, buffer.count - written)
                guard result > 0 else { return }
                written += result
            }
        }
    }

    /// Opens the append-only log once and keeps it. Returns nil if the file cannot
    /// be created, which leaves logging silently off rather than retrying a failing
    /// open on every event.
    private func logFileDescriptor() -> Int32? {
        if logDescriptor >= 0 { return logDescriptor }
        if !logDirectoryCreated {
            try? FileManager.default.createDirectory(at: nativeLogURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            logDirectoryCreated = true
        }
        let descriptor = open(nativeLogURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { return nil }
        logDescriptor = descriptor
        return descriptor
    }

    /// Uppercase hex with single spaces, without a format string per byte
    /// (~9.6 µs/line for 15 bytes vs ~0.1 µs through the table).
    private static func hex(_ report: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(report.count * 3)
        for byte in report {
            if !out.isEmpty { out.append(0x20) }
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    // Test seams. These expose the hot-path helpers so the tests exercise the real
    // implementation rather than a copy that could drift from it.
    static func hexForTesting(_ report: [UInt8]) -> String { hex(report) }
    var nativeLogURLForTesting: URL { nativeLogURL }
    func logNativeForTesting(_ line: String) { logNative(line) }
    func applyNativeStateForTesting() { applyNativeState() }
    func sendForTesting(_ message: OSCMessage) { send(message) }
    func flushLogForTesting() {
        guard logDescriptor >= 0 else { return }
        close(logDescriptor)
        logDescriptor = -1
    }

    // MARK: - Status classification

    /// RGB transport statuses all begin with "RGB"; no connection status does.
    /// `sendRGB` reports some failures only through `onStatus` (wrong frame size,
    /// no device), so those still have to reach the RGB lamp.
    static func isRGBStatus(_ status: String) -> Bool {
        status.hasPrefix("RGB")
    }

    /// An open failure, as opposed to "no device attached yet".
    static func isConnectionFailure(_ status: String) -> Bool {
        status.hasPrefix("Could not")
    }

    /// Bind failures only. Malformed-packet and "did not change state" notices are
    /// ordinary traffic and must not flip a listening receiver to an error.
    static func feedbackIndicatorValue(for status: String) -> Indicator? {
        if status.hasPrefix("Listening on") { return .listening }
        if status.contains("could not bind") || status.contains("unavailable") { return .error }
        return nil
    }

    // Assign through these so a repeated status does not republish. `@Published`
    // notifies on every set, and the view only needs the value when it changes.
    private func setHIDIndicator(_ value: Indicator) {
        guard hidIndicator != value.rawValue else { return }
        hidIndicator = value.rawValue
    }

    private func setFeedbackIndicator(_ value: Indicator) {
        guard feedbackIndicator != value.rawValue else { return }
        feedbackIndicator = value.rawValue
    }

    private func setRGBIndicator(_ value: Indicator) {
        guard rgbIndicator != value.rawValue else { return }
        rgbIndicator = value.rawValue
    }

    /// Previews can render the interface without opening HID or the feedback port.
    /// `logURL` exists so tests append to a scratch file rather than the user's log.
    init(startServices: Bool = true, logURL: URL = BridgeModel.defaultLogURL) {
        nativeLogURL = logURL
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
            self?.handleNativeStatus(status, connected: connected)
        }
        native.onRawReport = { [weak self] report in
            guard report.first == 1 else { return }
            self?.logNative("RAW " + Self.hex(report))
        }
        native.onControl = { [weak self] message in
            guard let self else { return }
            // `describe` allocates a String; it was being called twice per outgoing
            // control message to build two nearly identical lines.
            let arguments = Self.describe(message)
            self.nativeOutput = "\(message.address) · \(arguments)"
            self.logNative("OUT \(message.address) \(arguments)")
            self.send(message)
        }
        native.onEvent = { [weak self] event in
            guard let self else { return }
            self.nativeInput = String(describing: event)
            self.logNative("IN \(event)")
            self.applyNativeState()
            if let bank = self.native.banks.first, self.padBank != bank {
                self.padBank = bank
            }
        }
        native.onRGB = { [weak self] image, status in
            self?.handleRGBStatus(image, status: status)
        }
        native.onStateChange = { [weak self] in self?.applyNativeState() }
        feedback.onStatus = { [weak self] status in
            self?.handleFeedbackStatus(status)
        }
        feedback.onState = { [weak self] state in self?.handleFeedbackState(state) }
        feedback.onResend = { [weak self] in
            self?.osc.send(OSCMessage(address: "/Syndicate/Feedback/Resend", integer: 1))
        }
        feedback.onRGB = { [weak self] image in self?.native.sendRGB(image) }
        setHIDIndicator(.waiting)
        setFeedbackIndicator(.idle)
        native.start()
        feedback.start()
        osc.send(OSCMessage(address: "/Syndicate/Feedback/Resend", integer: 1))
    }

    /// Mirrors the controller's toggle state into the feedback client.
    ///
    /// Every assignment to one of those properties republishes, and a republish
    /// costs three full LED renders plus an output report. `onEvent` and
    /// `onStateChange` both fire on every input event, so assigning unconditionally
    /// meant up to fifteen renders per jog tick even when nothing had moved. Only
    /// the properties that actually changed are written; the rendered frame is
    /// identical either way because the render input is identical.
    private func applyNativeState() {
        if feedback.shift != native.shift {
            feedback.shift = native.shift
        }
        let banks = native.banks.map(Self.padMode(for:))
        // The controller always holds two banks, but only mirror when it actually
        // has some: an empty array must not blank the client's pad modes.
        if !banks.isEmpty, feedback.banks != banks {
            feedback.banks = banks
        }
        if feedback.cueActive != native.cueActive {
            feedback.cueActive = native.cueActive
        }
        if feedback.headphoneCue != native.headphoneCue {
            feedback.headphoneCue = native.headphoneCue
        }
    }

    // MARK: - Status handling

    /// One HID status callback. RGB transport statuses arrive on the same hook and
    /// must not move the HID lamp, which is the point of keeping the two separate.
    func handleNativeStatus(_ status: String, connected: Bool) {
        nativeStatus = status
        nativeConnected = connected
        // Also persist it. UI-only status made a silent RGB transport failure
        // completely invisible when diagnosing from the log.
        logNative("STATUS \(connected ? "+" : "-") \(status)")
        if Self.isRGBStatus(status) {
            // "RGB sent" is an ack of an LED frame, not of the HID link.
            if connected {
                setRGBIndicator(.accepted)
            } else {
                setRGBIndicator(.error)
            }
            return
        }
        if Self.isConnectionFailure(status) {
            setHIDIndicator(.error)
        } else {
            setHIDIndicator(connected ? .connected : .waiting)
        }
    }

    func handleRGBStatus(_ image: [UInt8], status: IOReturn) {
        // Transport acceptance is not proof of visible light. Nonzero bytes
        // include dim values, so do not describe this count as lit LEDs.
        // Counted with reduce rather than filter+count to avoid building a
        // second 105-byte array on every frame.
        let populated = image.reduce(into: 0) { count, value in
            if value != 0 { count += 1 }
        }
        rgbStatus = status == kIOReturnSuccess
            ? "RGB frame accepted · \(populated) nonzero LED values"
            : "RGB error \(status)"
        setRGBIndicator(status == kIOReturnSuccess ? .accepted : .error)
    }

    func handleFeedbackStatus(_ status: String) {
        feedbackStatus = status
        if let indicator = Self.feedbackIndicatorValue(for: status) {
            setFeedbackIndicator(indicator)
        }
    }

    /// Last Progress forwarded per deck, so only real Progress changes reseed.
    private var seededProgress: [Int: Double] = [:]

    func handleFeedbackState(_ state: MX2FeedbackState) {
        feedbackRenders += 1
        // Seed the jog seek origin from real playback position. Without this the
        // first touched platter turn seeks relative to the start of the track.
        // Only when Progress itself moved: this hook fires for every meter frame, and
        // reseeding from a stale (or never-subscribed, so 0) Progress on each one
        // dragged the seek origin back to wherever Progress last said.
        for deck in state.deckNumbers {
            let progress = state[deck: deck].progress
            guard seededProgress[deck] != progress else { continue }
            seededProgress[deck] = progress
            native.seedJogPosition(deck: deck, progress: progress)
        }
        feedbackStatus = "Feedback: \(state.deckNumbers.count) decks · \(state.meters.count) meters · \(feedbackRenders) frames"
        setFeedbackIndicator(.received)
        // Logging every frame would swamp the log at meter rates, so log the
        // first few and then every 50th: enough to see feedback live, cheap.
        if feedbackRenders <= 5 || feedbackRenders % 50 == 0 {
            logNative("FB #\(feedbackRenders) decks=\(state.deckNumbers.map(String.init).joined(separator: ","))"
                + " meters=\(state.meters.count) palette=\(state.palette.isEmpty ? "empty" : "set")")
        }
        // The receiver's own render path already pushed the frame to HID via
        // `onRGB`; this hook is for status and logging only.
    }

    /// One reusable timer for the activity flash. A `Task` per outgoing message
    /// left a sleeping task behind for every event, so a dense burst held hundreds
    /// of them alive for 120 ms to clear a single flag.
    private var flashReset: DispatchWorkItem?

    private func send(_ outgoing: OSCMessage) {
        osc.send(outgoing)
        eventCount += 1
        lastOutput = "\(outgoing.address) · \(outgoing.integer)"
        flash = true
        flashReset?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flash = false
            self?.flashReset = nil
        }
        flashReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
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
        if feedback.banks != [mode, mode] {
            feedback.banks = [mode, mode]
        }
    }

    static func describe(_ message: OSCMessage) -> String {
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
