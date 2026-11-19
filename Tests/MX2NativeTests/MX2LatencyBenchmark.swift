import XCTest
import Foundation
import Darwin
@testable import MX2Native
import IndirectInputCore

// A synthetic, hardware-free benchmark of the *production* input path:
//
//   HID-shaped report bytes → MX2Decoder → MX2NativeController.handle
//     → MX2Mapping (through the controller's own state) → OSCMessage.packet
//     → UDP loopback → OSCParser
//
// Every socket is bound to 127.0.0.1:0, so the run never touches 9090/9096 and never
// needs a device. Both endpoints are printed, and the corpus is deterministic, so two
// runs on the same machine are comparable.
//
// The one substituted component is the send syscall: the app's OSCSender wraps a
// Network.framework NWConnection, which lives in the executable target and cannot be
// imported by a test. This harness does the same thing one layer down — one
// `sendto(2)` per OSC message, one datagram per message — and the bytes come from the
// production encoder either way. docs/latency.md states that plainly rather than
// implying the framework wrapper itself was measured.

// MARK: - Clock

/// Monotonic nanoseconds. `CLOCK_UPTIME_RAW` does not advance while the machine sleeps,
/// which is what a latency number wants.
@inline(__always)
func benchNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

@inline(__always)
func microseconds(_ nanos: UInt64) -> Double { Double(nanos) / 1_000 }

// MARK: - Statistics

struct BenchStats {
    let label: String
    /// Microseconds, one entry per observation.
    let samples: [Double]

    var count: Int { samples.count }
    private var sorted: [Double] { samples.sorted() }
    var mean: Double { samples.isEmpty ? .nan : samples.reduce(0, +) / Double(samples.count) }
    var minimum: Double { sorted.first ?? .nan }
    var maximum: Double { sorted.last ?? .nan }

    /// Linear interpolation between the two nearest ranks. With a few thousand samples
    /// the difference from nearest-rank is invisible, and it never reads as if a
    /// percentile were an actual observation.
    func percentile(_ p: Double) -> Double {
        let s = sorted
        guard let first = s.first else { return .nan }
        if s.count == 1 { return first }
        let rank = (p / 100) * Double(s.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Swift.min(s.count - 1, lower + 1)
        return s[lower] + (s[upper] - s[lower]) * (rank - Double(lower))
    }

    /// One markdown row, in the shape docs/latency.md uses.
    var markdownRow: String {
        String(format: "| %@ | %d | %.2f | %.2f | %.2f | %.2f | %.2f |",
               label, count, percentile(50), percentile(90), percentile(99), mean, maximum)
    }

    var json: [String: Any] {
        [
            "label": label, "count": count,
            "p50_us": percentile(50), "p90_us": percentile(90), "p99_us": percentile(99),
            "mean_us": mean, "min_us": minimum, "max_us": maximum
        ]
    }
}

// MARK: - Ephemeral UDP loopback

/// A sender/receiver UDP pair on 127.0.0.1 with kernel-assigned ports, plus a
/// busy-poll receive. A blocking `recv` would fold a scheduler wakeup into every
/// sample; polling returns the instant the datagram is readable and keeps the
/// measurement single-threaded, so there is no cross-thread handoff to account for.
final class BenchUDP {
    let sendDescriptor: Int32
    let receiveDescriptor: Int32
    let sendPort: UInt16
    let receivePort: UInt16
    let receiveBufferBytes: Int32

    private let destination: sockaddr_in
    private let storage: UnsafeMutablePointer<UInt8>
    private static let capacity = 2048

    init() throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, 0)
        guard receiver >= 0 else { throw BenchError.socket("receive socket", errno) }
        let sender = socket(AF_INET, SOCK_DGRAM, 0)
        guard sender >= 0 else {
            let code = errno
            close(receiver)
            throw BenchError.socket("send socket", code)
        }

        // Bind-and-name, twice: both endpoints get a kernel-assigned port, so the
        // report can name a real source port instead of "whatever the kernel picks on
        // the first send".
        func bindEphemeral(_ descriptor: Int32, _ role: String) throws -> UInt16 {
            var address = BenchUDP.loopback(port: 0)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, length)
                }
            }
            guard bound == 0 else { throw BenchError.socket("bind \(role)", errno) }
            let named = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard named == 0 else { throw BenchError.socket("getsockname \(role)", errno) }
            return UInt16(bigEndian: address.sin_port)
        }

        let receiverPort: UInt16
        let senderPort: UInt16
        do {
            receiverPort = try bindEphemeral(receiver, "receiver")
            senderPort = try bindEphemeral(sender, "sender")
        } catch {
            close(sender)
            close(receiver)
            throw error
        }

        // The default loopback receive buffer is a few hundred kilobytes, which a burst
        // of thousands of datagrams overruns — the kernel then drops silently and the
        // run reports a transport artifact as if it were app behaviour. Ask for room.
        var requested: Int32 = 8 * 1024 * 1024
        _ = setsockopt(receiver, SOL_SOCKET, SO_RCVBUF, &requested,
                       socklen_t(MemoryLayout<Int32>.size))

        var bufferSize: Int32 = 0
        var sizeLength = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(receiver, SOL_SOCKET, SO_RCVBUF, &bufferSize, &sizeLength)

        receiveDescriptor = receiver
        sendDescriptor = sender
        receivePort = receiverPort
        sendPort = senderPort
        receiveBufferBytes = bufferSize
        destination = BenchUDP.loopback(port: receiverPort)
        storage = .allocate(capacity: BenchUDP.capacity)

        // Warm the route so the first measured send does not pay for it, then wait for
        // the socket to fall quiet before handing it to the caller.
        _ = send(OSCMessage(address: "/Syndicate/Deck/1/PlayPause", integer: 1).packet)
        settle()
    }

    deinit {
        storage.deallocate()
        close(sendDescriptor)
        close(receiveDescriptor)
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    /// One datagram per message, exactly as `OSCSender.send` does over NWConnection.
    @discardableResult
    func send(_ packet: Data) -> Bool {
        var target = destination
        let sent = packet.withUnsafeBytes { buffer in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sendDescriptor, buffer.baseAddress, buffer.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == packet.count
    }

    /// Spins until a datagram is readable, timestamping it the moment `recv` returns.
    /// Returns the payload and that timestamp; `nil` on timeout.
    func receive(timeoutNanoseconds: UInt64 = 250_000_000) -> (Data, UInt64)? {
        let deadline = benchNow() &+ timeoutNanoseconds
        while true {
            let count = recv(receiveDescriptor, storage, BenchUDP.capacity, MSG_DONTWAIT)
            let stamp = benchNow()
            if count > 0 { return (Data(bytes: storage, count: count), stamp) }
            if stamp > deadline { return nil }
        }
    }

    /// Everything already queued, in arrival order, so the socket buffer never becomes
    /// the bottleneck by accident.
    @discardableResult
    func drain() -> Int {
        var received = 0
        while true {
            let count = recv(receiveDescriptor, storage, BenchUDP.capacity, MSG_DONTWAIT)
            if count <= 0 { break }
            received += 1
        }
        return received
    }

    /// Blocks until nothing arrives for `settle`, then returns how much it swallowed.
    ///
    /// Loopback delivery is asynchronous, so the datagram count right after a send loop
    /// is not final. Without this barrier the tail of one stage is counted as the head
    /// of the next and the run reports a phantom loss or a stray packet.
    @discardableResult
    func settle(quietForNanoseconds quiet: UInt64 = 5_000_000) -> Int {
        var swallowed = 0
        while true {
            swallowed += drainCounted()
            let until = benchNow() &+ quiet
            while benchNow() < until {}
            let again = drainCounted()
            if again == 0 { return swallowed }
            swallowed += again
        }
    }

    private func drainCounted() -> Int {
        var received = 0
        while true {
            let count = recv(receiveDescriptor, storage, BenchUDP.capacity, MSG_DONTWAIT)
            if count <= 0 { break }
            received += 1
        }
        return received
    }

    var endpoints: String { "127.0.0.1:\(sendPort) → 127.0.0.1:\(receivePort)" }
}

enum BenchError: Error, CustomStringConvertible {
    case socket(String, Int32)
    case timeout(String)

    var description: String {
        switch self {
        case let .socket(call, code):
            return "\(call) failed: \(String(cString: strerror(code))) (errno \(code))"
        case let .timeout(detail):
            return "no datagram for: \(detail)"
        }
    }
}

// MARK: - Deterministic synthetic controller

/// Absolute report snapshots, built with the byte layouts the decoder documents:
/// report 1 = 82 button bits + six 4-bit encoders, report 2 = 26 little-endian
/// 12-bit axes, report 3 = two little-endian u32 platter counters.
struct SynthMX2 {
    var buttons = [Bool](repeating: false, count: 82)
    var analogs = [UInt16](repeating: 0, count: 26)
    var encoders = [UInt8](repeating: 0, count: 6)
    var jogs: [UInt32] = [0, 0]

    func buttonReport() -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 15)
        report[0] = 1
        for index in 0..<82 where buttons[index] {
            report[1 + index / 8] |= UInt8(1 << (index % 8))
        }
        for index in 0..<6 {
            report[12 + index / 2] |= (encoders[index] & 0x0F) << (4 * (index % 2))
        }
        return report
    }

    func analogReport() -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 53)
        report[0] = 2
        for index in 0..<26 {
            let value = Swift.min(analogs[index], 4095)
            report[1 + index * 2] = UInt8(value & 0xFF)
            report[2 + index * 2] = UInt8(value >> 8)
        }
        return report
    }

    func jogReport() -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 20)
        report[0] = 3
        for side in 0..<2 {
            let base = 8 + side * 8
            for byte in 0..<4 {
                report[base + byte] = UInt8((jogs[side] >> (8 * UInt32(byte))) & 0xFF)
            }
        }
        return report
    }

    /// The three snapshots the decoder needs before it will emit anything.
    func baselineReports() -> [[UInt8]] { [buttonReport(), analogReport(), jogReport()] }
}

/// One report and the OSC addresses it must produce, in order. An empty `expected` is
/// a deliberate silence — the pinned decisions in the mapping (deck FX, crossfader,
/// preview, filter, stems) are part of the contract and are asserted here too, just
/// not timed.
struct BenchSample {
    let label: String
    let report: [UInt8]
    let expected: [String]
}

// Control indices, from `MX2Decoder.buttons` / `.analogs`.
enum BenchIndex {
    static let favoriteLeft = 4
    static let addToListLeft = 5
    static let previewLeft = 6
    static let viewLeft = 7
    static let fluxLeft = 8
    static let reverseLeft = 9
    static let turntableLeft = 10
    static let jogModeLeft = 11
    static let shiftLeft = 12
    static let syncLeft = 13
    static let masterLeft = 14
    static let keyLockLeft = 15
    static let bankHotcuesLeft = 16
    static let bankStemsLeft = 17
    static let bankPatternLeft = 18
    static let bankLoopsLeft = 19
    static let padLeft1 = 20
    static let cueLeft = 28
    static let playLeft = 29
    static let cueRight = 58
    static let playRight = 59
    static let fxButtonLeft1 = 0
    static let fxAssignLeft1 = 60
    static let channelFXLeft = 62
    static let headphoneLeft = 63
    static let globalFX1 = 68
    static let filterButton = 72
    static let microphoneButton = 73
    static let browsePressLeft = 74
    static let jogTouchLeft = 80

    // Encoder nibble slots.
    static let browseEncoderLeft = 0
    static let moveEncoderLeft = 1
    static let sizeEncoderLeft = 2
    static let browseEncoderRight = 3

    // Report-2 axes.
    static let crossfader = 23

    static let loopSizes = ["ThirtySecond", "Sixteenth", "Eighth", "Quarter",
                            "Half", "One", "Two", "Four"]
}

// MARK: - The script

/// Builds the deterministic report script. Every report is derived from the generator
/// state, so replaying the script reproduces byte-identical input; only the measured
/// latencies vary.
final class BenchScript {
    private(set) var synth = SynthMX2()
    private(set) var samples: [BenchSample] = []
    /// Subset with no toggle state and no bank-dependent meaning, safe to replay.
    private(set) var cycleSamples: [BenchSample] = []

    private let root = "/Syndicate"

    init() {
        for report in synth.baselineReports() {
            samples.append(BenchSample(label: "baseline", report: report, expected: []))
        }
    }

    private func emit(_ label: String, _ report: [UInt8], _ expected: [String],
                      cycle: Bool = false) {
        let sample = BenchSample(label: label, report: report, expected: expected)
        samples.append(sample)
        if cycle { cycleSamples.append(sample) }
    }

    private func press(_ bit: Int, _ down: Bool, _ expected: [String], cycle: Bool = false) {
        synth.buttons[bit] = down
        emit("button \(bit) \(down ? "down" : "up")", synth.buttonReport(), expected, cycle: cycle)
    }

    private func turn(_ encoder: Int, _ delta: Int, _ expected: [String]) {
        let next = (Int(synth.encoders[encoder]) + delta + 16) % 16
        synth.encoders[encoder] = UInt8(next)
        emit("encoder \(encoder) \(delta)", synth.buttonReport(), expected, cycle: true)
    }

    private func move(_ axis: Int, _ raw: UInt16, _ expected: [String]) {
        synth.analogs[axis] = raw
        emit("analog \(axis) \(raw)", synth.analogReport(), expected, cycle: true)
    }

    private func platter(_ side: Int, _ position: UInt32, _ expected: [String]) {
        synth.jogs[side] = position
        emit("jog \(side) \(position)", synth.jogReport(), expected, cycle: true)
    }

    /// Transport, pads, mixer switches and the pinned silences. Runs once: several of
    /// these controls carry tracked toggle state, which is exactly what the audit test
    /// covers and what a repeated latency cycle must not perturb.
    func semanticsPhase() {
        let deck = root + "/Deck/1"

        press(BenchIndex.playLeft, true, [deck + "/PlayPause"])
        press(BenchIndex.playLeft, false, [])
        press(BenchIndex.cueLeft, true, [deck + "/Cue"])
        press(BenchIndex.cueLeft, false, [deck + "/Cue"])
        press(BenchIndex.syncLeft, true, [deck + "/TempoSync"])
        press(BenchIndex.syncLeft, false, [])
        press(BenchIndex.masterLeft, true, [deck + "/TempoMaster"])
        press(BenchIndex.masterLeft, false, [])
        press(BenchIndex.reverseLeft, true, [deck + "/Reverse"])
        press(BenchIndex.reverseLeft, false, [deck + "/Reverse"])
        press(BenchIndex.playRight, true, [root + "/Deck/2/PlayPause"])
        press(BenchIndex.playRight, false, [])
        press(BenchIndex.cueRight, true, [root + "/Deck/2/Cue"])
        press(BenchIndex.cueRight, false, [root + "/Deck/2/Cue"])
        press(BenchIndex.favoriteLeft, true, [root + "/Browser/Navigation/Left"])
        press(BenchIndex.favoriteLeft, false, [])
        press(BenchIndex.addToListLeft, true, [root + "/Browser/Navigation/Enter"])
        press(BenchIndex.addToListLeft, false, [])
        press(BenchIndex.browsePressLeft, true, [root + "/Browser/L1"])
        press(BenchIndex.browsePressLeft, false, [])

        // Tracked switches: press sends the new state, release sends nothing.
        for (bit, path) in [(BenchIndex.keyLockLeft, deck + "/PitchPreserve"),
                            (BenchIndex.fluxLeft, deck + "/CueSlip"),
                            (BenchIndex.channelFXLeft, root + "/Mixer/CH1/FX"),
                            (BenchIndex.headphoneLeft, root + "/Mixer/CH1/Cue")] {
            press(bit, true, [path])
            press(bit, false, [])
            press(bit, true, [path])
            press(bit, false, [])
        }
        press(BenchIndex.fxAssignLeft1, true, [root + "/Mixer/CH1/FX/Macro/1"])
        press(BenchIndex.fxAssignLeft1, false, [])

        // Deliberate silences, pinned so a benchmark pass cannot hide a regression into
        // an address that should never exist.
        press(BenchIndex.fxButtonLeft1, true, [])
        press(BenchIndex.fxButtonLeft1, false, [])
        press(BenchIndex.globalFX1, true, [])
        press(BenchIndex.filterButton, true, [])
        press(BenchIndex.microphoneButton, true, [])
        press(BenchIndex.previewLeft, true, [])
        press(BenchIndex.turntableLeft, true, [])
        press(BenchIndex.jogModeLeft, true, [])
        press(BenchIndex.jogTouchLeft, true, [])
        press(BenchIndex.jogTouchLeft, false, [])
        move(BenchIndex.crossfader, 2048, [])

        // Stems bank: nothing documented to send.
        press(BenchIndex.bankStemsLeft, true, [])
        press(BenchIndex.padLeft1, true, [])
        press(BenchIndex.padLeft1, false, [])
        press(BenchIndex.bankHotcuesLeft, true, [])
    }

    /// One repeatable cycle of stateless controls. Starts and ends with every pad and
    /// the platter released, so the sequence stays valid when it is replayed.
    func cycle(_ index: Int) {
        let deck = root + "/Deck/1"

        // Hotcues bank: eight pads, press and release.
        press(BenchIndex.bankHotcuesLeft, true, [], cycle: true)
        press(BenchIndex.bankHotcuesLeft, false, [], cycle: true)
        for pad in 0..<8 {
            press(BenchIndex.padLeft1 + pad, true, [deck + "/HotCue"], cycle: true)
            press(BenchIndex.padLeft1 + pad, false, [deck + "/HotCue"], cycle: true)
        }

        // Transport on both sides.
        press(BenchIndex.playLeft, true, [deck + "/PlayPause"], cycle: true)
        press(BenchIndex.playLeft, false, [], cycle: true)
        press(BenchIndex.cueLeft, true, [deck + "/Cue"], cycle: true)
        press(BenchIndex.cueLeft, false, [deck + "/Cue"], cycle: true)
        press(BenchIndex.syncLeft, true, [deck + "/TempoSync"], cycle: true)
        press(BenchIndex.syncLeft, false, [], cycle: true)
        press(BenchIndex.masterLeft, true, [deck + "/TempoMaster"], cycle: true)
        press(BenchIndex.masterLeft, false, [], cycle: true)
        press(BenchIndex.playRight, true, [root + "/Deck/2/PlayPause"], cycle: true)
        press(BenchIndex.playRight, false, [], cycle: true)
        press(BenchIndex.cueRight, true, [root + "/Deck/2/Cue"], cycle: true)
        press(BenchIndex.cueRight, false, [root + "/Deck/2/Cue"], cycle: true)

        // Loops bank: one hold per bar fraction.
        press(BenchIndex.bankLoopsLeft, true, [], cycle: true)
        press(BenchIndex.bankLoopsLeft, false, [], cycle: true)
        for (pad, size) in BenchIndex.loopSizes.enumerated() {
            press(BenchIndex.padLeft1 + pad, true, [deck + "/SlipLoop/" + size], cycle: true)
            press(BenchIndex.padLeft1 + pad, false, [deck + "/SlipLoop/" + size], cycle: true)
        }

        // Pattern bank: sampler lane selection is a zero-based Index with no release.
        press(BenchIndex.bankPatternLeft, true, [], cycle: true)
        press(BenchIndex.bankPatternLeft, false, [], cycle: true)
        for pad in 0..<8 {
            press(BenchIndex.padLeft1 + pad, true, [deck + "/Sampler/Lane"], cycle: true)
            press(BenchIndex.padLeft1 + pad, false, [], cycle: true)
        }
        press(BenchIndex.bankHotcuesLeft, true, [], cycle: true)
        press(BenchIndex.bankHotcuesLeft, false, [], cycle: true)

        // Analog sweep across all 26 axes. Values are a deterministic function of the
        // cycle index, so every axis emits on every cycle — and never 0, which is the
        // baseline an all-zero report would already carry. The crossfader is the pinned
        // silence: it must not be emulated with channel volume.
        for axis in 0..<26 {
            let raw = UInt16((index * 257 + axis * 53) % 4095 + 1)
            let path: String? = switch axis {
            case 0...3: "\(root)/Mixer/CH1/FX/Macro/\(axis + 1)"
            case 4...7: "\(root)/Mixer/CH2/FX/Macro/\(axis - 3)"
            case 8: "\(root)/Mixer/CH1/Trim"
            case 9: "\(root)/Mixer/CH1/EQ/High"
            case 10: "\(root)/Mixer/CH1/EQ/Mid"
            case 11: "\(root)/Mixer/CH1/EQ/Low"
            case 12: "\(root)/Mixer/CH1/Filter1"
            case 13: "\(root)/Mixer/CH2/Trim"
            case 14: "\(root)/Mixer/CH2/EQ/High"
            case 15: "\(root)/Mixer/CH2/EQ/Mid"
            case 16: "\(root)/Mixer/CH2/EQ/Low"
            case 17: "\(root)/Mixer/CH2/Filter1"
            case 18: "\(root)/Header/MasterVolume"
            case 19: "\(root)/Header/CueMix"
            case 20: "\(root)/Header/CueVolume"
            case 21: "\(root)/Mixer/CH1/Volume"
            case 22: "\(root)/Mixer/CH2/Volume"
            case 23: nil // crossfader: no route in 0.3.10
            case 24: "\(deck)/TempoSlider"
            default: "\(root)/Deck/2/TempoSlider"
            }
            move(axis, raw, path.map { [$0] } ?? [])
        }

        // Encoders: one Trigger per detent, and Step amounts stay a single message.
        turn(BenchIndex.browseEncoderLeft, 1, ["\(root)/Browser/Navigation/Down"])
        turn(BenchIndex.browseEncoderLeft, -1, ["\(root)/Browser/Navigation/Up"])
        turn(BenchIndex.moveEncoderLeft, 4, [deck + "/BeatSkip"])
        turn(BenchIndex.sizeEncoderLeft, 3, Array(repeating: deck + "/LoopOut", count: 3))
        turn(BenchIndex.sizeEncoderLeft, -2, Array(repeating: deck + "/LoopIn", count: 2))
        turn(BenchIndex.browseEncoderRight, 1, ["\(root)/Browser/Navigation/Down"])

        // Platter with a finger on it: seek, not bend.
        press(BenchIndex.jogTouchLeft, true, [], cycle: true)
        for step in 1...12 {
            platter(0, UInt32(index % 8) * 96 + UInt32(step) * 8, [deck + "/WaveformSeek"])
        }
        press(BenchIndex.jogTouchLeft, false, [], cycle: true)
    }
}

// MARK: - Report stream for the rate measurements

/// Generates an endless stream of *fresh* reports. Replaying the canned corpus would
/// go silent after the first pass, because the decoder only emits deltas: identical
/// analog values and encoder nibbles are not events.
struct BenchStream {
    private var synth = SynthMX2()
    private var step = 0

    /// Cycle through the three report families the way the hardware interleaves them.
    /// Every report changes at least one value, so every report produces output.
    mutating func nextReport() -> [UInt8] {
        step += 1
        switch step % 10 {
        case 0, 5:
            // Platter with the finger down: a seek, not a bend. Positions advance 40
            // ticks per platter report, well inside the 480-tick half-wrap.
            synth.buttons[BenchIndex.jogTouchLeft] = true
            synth.jogs[0] = UInt32(step * 8 % 960)
            return synth.jogReport()
        case 3, 7:
            // One axis at a time, sweeping the 12-bit range. Axis 23 is the crossfader,
            // which is a pinned silence, so step over it.
            let raw = step / 10 % 26
            let axis = raw == BenchIndex.crossfader ? BenchIndex.crossfader + 1 : raw
            synth.analogs[axis] = UInt16((step * 137) % 4096)
            return synth.analogReport()
        default:
            // Buttons and encoders: the hotcue pads walk 1...8, the browse encoder turns.
            for index in 0..<8 { synth.buttons[BenchIndex.padLeft1 + index] = false }
            synth.buttons[BenchIndex.padLeft1 + (step / 2) % 8] = step % 2 == 0
            synth.encoders[BenchIndex.browseEncoderLeft] = UInt8((step / 2) % 16)
            return synth.buttonReport()
        }
    }
}

// MARK: - Corpus diagnostics

/// Compares addresses positionally and reports the first divergence with a small
/// window. A bare array comparison on ~1900 addresses prints megabytes and still does
/// not say where the sequences stopped agreeing.
func firstDivergence(expected: [String], actual: [String]) -> String? {
    if expected == actual { return nil }
    let limit = Swift.min(expected.count, actual.count)
    var index = 0
    while index < limit, expected[index] == actual[index] { index += 1 }
    let window = 3
    let from = Swift.max(0, index - window)
    var lines = ["first divergence at message \(index) "
                 + "(expected \(expected.count), actual \(actual.count))"]
    for position in from...Swift.min(index + window, Swift.max(expected.count, actual.count) - 1) {
        let want = position < expected.count ? expected[position] : "<none>"
        let got = position < actual.count ? actual[position] : "<none>"
        lines.append("  [\(position)] \(want == got ? "  " : "≠ ")expected \(want) · actual \(got)")
    }
    return lines.joined(separator: "\n")
}

// MARK: - The benchmark

final class MX2LatencyBenchmarkTests: XCTestCase {
    private let cycles = 20

    /// Release-mode run: `swift test -c release --filter MX2LatencyBenchmarkTests`.
    /// Debug builds are dominated by unoptimised Swift and are not the number to quote.
    @MainActor
    func testProductionPathLatencyOverEphemeralUDP() async throws {
        var report: [String] = []
        var json: [String: Any] = [:]

        let udp = try BenchUDP()
        // Ephemeral only. The app's fixed ports must not be involved at all.
        for port in [udp.receivePort, udp.sendPort] {
            XCTAssertNotEqual(port, 9090)
            XCTAssertNotEqual(port, 9096)
            XCTAssertGreaterThan(port, 1023)
        }

        let script = BenchScript()
        script.semanticsPhase()
        for cycle in 0..<cycles { script.cycle(cycle) }
        let messages = script.samples.reduce(0) { $0 + $1.expected.count }

        report.append("=== Indirect Input · production input path · release ===")
        report.append("udp endpoints   \(udp.endpoints)  (SO_RCVBUF \(udp.receiveBufferBytes) bytes)")
        report.append("corpus          \(script.samples.count) reports · \(messages) OSC messages · \(cycles) cycles")

        // MARK: 1. Correctness pass — every address, in order, including the silences.
        let (expected, actual) = try replay(script.samples)
        if let divergence = firstDivergence(expected: expected, actual: actual) {
            XCTFail(divergence)
        }
        XCTAssertEqual(actual.count, messages)

        // MARK: 2. Serialized end-to-end latency, one message set in flight at a time.
        // Every sample is decoded — the baselines included, or the decoder would eat the
        // first press of each report family as its own baseline — but only the samples
        // that produce a message contribute a measurement.
        var endToEnd: [Double] = []
        var inProcess: [Double] = []
        var decoder = MX2Decoder()
        let controller = MX2NativeController()
        controller.mapping.firstDeck = 1
        var pending: [Data] = []
        controller.onControl = { pending.append($0.packet) }

        var timeouts = 0
        var parsed = 0
        var wrongAddress: String?
        for sample in script.samples {
            pending.removeAll(keepingCapacity: true)
            let start = benchNow()
            for event in decoder.decode(sample.report) { controller.handle(event) }
            let routed = benchNow()
            guard !sample.expected.isEmpty else {
                if !pending.isEmpty { wrongAddress = "\(sample.label) must stay silent" }
                continue
            }
            inProcess.append(microseconds(routed - start))
            if pending.count != sample.expected.count {
                wrongAddress = "\(sample.label) produced \(pending.count) messages, "
                    + "expected \(sample.expected.count)"
            }
            for packet in pending {
                if !udp.send(packet) { wrongAddress = "sendto failed for \(sample.label)" }
            }
            // Receive-and-timestamp only. Assertions run after the loop: an XCTest
            // failure handler is not free, and running it between datagrams of a
            // multi-message sample would inflate that sample's own measurement.
            var lastArrival = routed
            var received: [String?] = []
            for _ in sample.expected {
                guard let (datagram, arrival) = udp.receive() else {
                    timeouts += 1
                    break
                }
                // Parse with the production parser: a message that arrives but cannot be
                // decoded is not a delivered message.
                let wire = OSCMessage.parseAll(datagram)
                parsed += wire.count
                received.append(wire.first?.address)
                lastArrival = arrival
            }
            endToEnd.append(microseconds(lastArrival - start))
            // Same claim as the replay above, but about what actually crossed the wire.
            if received != sample.expected.map(Optional.some), wrongAddress == nil {
                wrongAddress = "\(sample.label): wire \(received) ≠ expected \(sample.expected)"
            }
        }
        if let wrongAddress { XCTFail(wrongAddress) }
        XCTAssertEqual(timeouts, 0, "every datagram in the serialized pass must arrive")
        XCTAssertEqual(parsed, messages, "every message must parse after the UDP hop")
        if let leftover = udp.receive(timeoutNanoseconds: 20_000_000) {
            XCTFail("serialized pass left an extra datagram: "
                    + (OSCMessage.parseAll(leftover.0).first?.address ?? "<unparseable>"))
        }

        let endStats = BenchStats(label: "serialized end-to-end (decode→map→encode→UDP→parse)",
                                  samples: endToEnd)
        let inProcessStats = BenchStats(label: "in-process prefix (decode→map→encode)",
                                        samples: inProcess)
        report.append("")
        report.append("| measurement | n | p50 µs | p90 µs | p99 µs | mean µs | max µs |")
        report.append("| --- | --- | --- | --- | --- | --- | --- |")
        report.append(endStats.markdownRow)
        report.append(inProcessStats.markdownRow)

        // MARK: 3. Stage costs, isolated, so the split is attributable.
        let stages = try stageCosts(udp: udp, reports: 4000)
        report.append("")
        report.append("| stage | ns/op |")
        report.append("| --- | --- |")
        for (label, nanos) in stages {
            report.append(String(format: "| %@ | %.0f |", label, nanos))
        }

        // MARK: 3b. Null-path control: the same serialized send/receive loop with a
        // pre-encoded constant packet and no decode, map, encode or parse. Whatever this
        // measures is the harness plus the kernel's loopback turnaround, and the bridge's
        // own contribution is the difference from the end-to-end figure above.
        let control = try nullPathControl(udp: udp, iterations: 2000)
        let bridgeShare = endStats.percentile(50) - control.percentile(50)
        report.append("")
        report.append("| null-path control (send→recv, no decode/map/encode/parse) | n | p50 µs | p90 µs | p99 µs |")
        report.append("| --- | --- | --- | --- | --- |")
        report.append(String(format: "|  | %d | %.2f | %.2f | %.2f |",
                             control.count, control.percentile(50),
                             control.percentile(90), control.percentile(99)))
        report.append(String(format: "| bridge share of serialized p50 |  | %.2f |  |  |",
                             bridgeShare))

        // MARK: 4. Paced stream at the MX2 report cadence (1 kHz, 2 s).
        let paced = try pacedRun(udp: udp, rateHz: 1000, reports: 2000)
        report.append("")
        report.append("| paced 1 kHz, 2 s | value |")
        report.append("| --- | --- |")
        report.append("| reports / packets / received | \(paced.reports) / \(paced.sent) / \(paced.received) |")
        report.append("| lost | \(paced.sent - paced.received) |")
        report.append("| steps over the 1 ms interval | \(paced.overruns) |")
        report.append(String(format: "| latency p50 / p99 / max | %.2f / %.2f / %.2f µs |",
                             paced.latency.percentile(50), paced.latency.percentile(99),
                             paced.latency.maximum))

        // MARK: 5. Unpaced throughput, receive buffer kept empty.
        let rate = try throughputRun(udp: udp, reports: 20_000)
        report.append("")
        report.append(String(format: "| unpaced throughput | %.0f msg/s (%.2f µs/message, %d/%d delivered) |",
                             rate.messagesPerSecond, 1_000_000 / rate.messagesPerSecond,
                             rate.received, rate.sent))
        XCTAssertEqual(rate.sent, rate.received, "an unpaced loopback stream should not drop")

        // MARK: 6. The bend tail: a jog bend schedules its release 80 ms out on purpose.
        let tail = try await bendTail(udp: udp)
        report.append(String(format: "| phase-bend release tail | %.1f ms (scheduled by design) |",
                             tail / 1_000_000))

        json["endpoints"] = ["sender": "127.0.0.1:\(udp.sendPort)",
                             "receiver": "127.0.0.1:\(udp.receivePort)",
                             "so_rcvbuf": udp.receiveBufferBytes]
        json["corpus"] = ["reports": script.samples.count, "messages": messages, "cycles": cycles]
        json["serialized"] = endStats.json
        json["in_process"] = inProcessStats.json
        json["stages_ns"] = Dictionary(uniqueKeysWithValues: stages)
        json["null_path"] = control.json
        json["bridge_share_p50_us"] = bridgeShare
        json["paced"] = ["reports": paced.reports, "sent": paced.sent,
                         "received": paced.received, "overruns": paced.overruns,
                         "p50_us": paced.latency.percentile(50),
                         "p99_us": paced.latency.percentile(99),
                         "max_us": paced.latency.maximum]
        json["throughput"] = ["reports": rate.reports, "sent": rate.sent,
                              "received": rate.received,
                              "msg_per_s": rate.messagesPerSecond]
        json["bend_tail_ms"] = tail / 1_000_000

        let text = report.joined(separator: "\n")
        print("\n" + text + "\n")
        try writeJSONIfRequested(json)
    }

    // MARK: - Passes

    /// Replays the corpus through a fresh decoder and controller and returns what the
    /// mapper produced, so the measured pass is provably the same input.
    @MainActor
    private func replay(_ samples: [BenchSample]) throws -> (expected: [String], actual: [String]) {
        var decoder = MX2Decoder()
        let controller = MX2NativeController()
        controller.mapping.firstDeck = 1
        var collected: [String] = []
        controller.onControl = { collected.append($0.address) }
        var expected: [String] = []
        for sample in samples {
            for event in decoder.decode(sample.report) { controller.handle(event) }
            expected.append(contentsOf: sample.expected)
        }
        return (expected, collected)
    }

    /// Times decode, map, encode, parse and sendto separately over a fixed report count,
    /// so the end-to-end figure is attributable rather than a single opaque sum. The
    /// reports come from the stream generator because the decoder emits deltas: replayed
    /// identical snapshots would produce no events and time nothing.
    @MainActor
    private func stageCosts(udp: BenchUDP, reports: Int) throws -> [(String, Double)] {
        var stream = BenchStream()
        var reports_: [[UInt8]] = []
        reports_.reserveCapacity(reports)
        for _ in 0..<reports { reports_.append(stream.nextReport()) }

        var decoder = MX2Decoder()
        _ = decoder.decode([1] + [UInt8](repeating: 0, count: 14))
        var decoded: [(report: [UInt8], events: [MX2InputEvent])] = []
        decoded.reserveCapacity(reports)
        for report in reports_ { decoded.append((report, decoder.decode(report))) }

        var freshDecoder = MX2Decoder()
        _ = freshDecoder.decode([1] + [UInt8](repeating: 0, count: 14))
        let decodeStart = benchNow()
        for entry in decoded { _ = freshDecoder.decode(entry.report) }
        let decodeEnd = benchNow()

        let controller = MX2NativeController()
        controller.mapping.firstDeck = 1
        var sink: [OSCMessage] = []
        sink.reserveCapacity(reports * 4)
        controller.onControl = { sink.append($0) }
        let mapStart = benchNow()
        for entry in decoded {
            for event in entry.events { controller.handle(event) }
        }
        let mapEnd = benchNow()

        let encodeStart = benchNow()
        var packets: [Data] = []
        packets.reserveCapacity(sink.count)
        for message in sink { packets.append(message.packet) }
        let encodeEnd = benchNow()

        let parseStart = benchNow()
        var parsed = 0
        for packet in packets { parsed += OSCMessage.parseAll(packet).count }
        let parseEnd = benchNow()
        XCTAssertEqual(parsed, packets.count, "every encoded packet must parse")

        // Stage 1 must leave the socket empty; if it does not, say so before the staged
        // send is blamed for a datagram that arrived earlier. `settle` waits out the
        // loopback's asynchronous tail rather than trusting a single drain.
        let leftovers = udp.settle()
        XCTAssertEqual(leftovers, 0,
                       "the serialized pass left \(leftovers) datagram(s) queued")

        let sendStart = benchNow()
        for packet in packets { XCTAssertTrue(udp.send(packet)) }
        let sendEnd = benchNow()
        let delivered = packets.count - udp.settle()
        XCTAssertEqual(delivered, 0, "\(delivered) staged packet(s) never arrived")

        let events = decoded.reduce(0) { $0 + $1.events.count }
        XCTAssertGreaterThan(events, 0, "the stream must produce events to time")
        return [
            ("decode (report → events)", Double(decodeEnd - decodeStart) / Double(decoded.count)),
            ("map (event → OSC, controller state)", Double(mapEnd - mapStart) / Double(max(1, events))),
            ("encode (OSCMessage → datagram)", Double(encodeEnd - encodeStart) / Double(max(1, sink.count))),
            ("parse (datagram → arguments)", Double(parseEnd - parseStart) / Double(max(1, packets.count))),
            ("sendto (packet → kernel)", Double(sendEnd - sendStart) / Double(max(1, packets.count)))
        ]
    }

    /// The same serialized send-then-receive loop with a pre-encoded constant packet and
    /// no decode, map, encode or parse. This is the floor: harness overhead plus the
    /// kernel's loopback turnaround, which the end-to-end figure cannot go below.
    private func nullPathControl(udp: BenchUDP, iterations: Int) throws -> BenchStats {
        let packet = OSCMessage(address: "/Syndicate/Deck/1/PlayPause", integer: 1).packet
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = benchNow()
            XCTAssertTrue(udp.send(packet))
            guard udp.receive() != nil else { throw BenchError.timeout("null-path control") }
            samples.append(microseconds(benchNow() - start))
        }
        XCTAssertEqual(udp.settle(), 0)
        return BenchStats(label: "null-path control", samples: samples)
    }

    @MainActor
    private func pacedRun(udp: BenchUDP, rateHz: Int,
                          reports: Int) throws -> (reports: Int, sent: Int, received: Int,
                                                   overruns: Int, latency: BenchStats) {
        var stream = BenchStream()
        var decoder = MX2Decoder()
        _ = decoder.decode([1] + [UInt8](repeating: 0, count: 14))
        let controller = MX2NativeController()
        controller.mapping.firstDeck = 1
        var pending: [Data] = []
        controller.onControl = { pending.append($0.packet) }

        let interval = UInt64(1_000_000_000 / rateHz)
        var latencies: [Double] = []
        var sent = 0
        var received = 0
        var overruns = 0
        let start = benchNow()

        for index in 0..<reports {
            let deadline = start &+ UInt64(index) * interval
            while benchNow() < deadline {}

            let report = stream.nextReport()
            pending.removeAll(keepingCapacity: true)
            let origin = benchNow()
            for event in decoder.decode(report) { controller.handle(event) }
            for message in pending { if udp.send(message) { sent += 1 } }
            let produced = pending.count

            var seen = 0
            var last: UInt64?
            while seen < produced, let (datagram, arrival) = udp.receive(timeoutNanoseconds: 50_000_000) {
                _ = OSCMessage.parseAll(datagram)
                seen += 1
                last = arrival
            }
            received += seen
            if let last { latencies.append(microseconds(last - origin)) }
            if benchNow() - deadline > interval { overruns += 1 }
        }

        return (reports, sent, received, overruns, BenchStats(label: "paced", samples: latencies))
    }

    @MainActor
    private func throughputRun(udp: BenchUDP,
                               reports: Int) throws -> (reports: Int, sent: Int, received: Int,
                                                        messagesPerSecond: Double) {
        var stream = BenchStream()
        var decoder = MX2Decoder()
        _ = decoder.decode([1] + [UInt8](repeating: 0, count: 14))
        let controller = MX2NativeController()
        controller.mapping.firstDeck = 1
        var pending: [Data] = []
        controller.onControl = { pending.append($0.packet) }

        var sent = 0
        var received = 0
        let start = benchNow()
        for _ in 0..<reports {
            let report = stream.nextReport()
            pending.removeAll(keepingCapacity: true)
            for event in decoder.decode(report) { controller.handle(event) }
            for message in pending { if udp.send(message) { sent += 1 } }
            received += udp.drain()
        }
        let end = benchNow()
        // Settle, not drain: the last few datagrams are still in flight when the send
        // loop ends, and counting only what is already queued reports them as drops and
        // leaves them to be mistaken for stray traffic in the next stage.
        received += udp.settle()
        let seconds = Double(end - start) / 1_000_000_000
        return (reports, sent, received, Double(sent) / seconds)
    }

    /// With no finger on the platter the mapper sends a Bend, and the controller
    /// schedules its release 80 ms later. Measured rather than assumed: the tail is a
    /// deliberate design property, not a latency bug.
    ///
    /// The number is the delay between the bend being routed and the release being
    /// *emitted* — timestamped inside `onControl`. Timing it after a sleep would only
    /// measure the sleep.
    @MainActor
    private func bendTail(udp: BenchUDP) async throws -> Double {
        var synth = SynthMX2()
        var decoder = MX2Decoder()
        _ = decoder.decode([1] + [UInt8](repeating: 0, count: 14))

        // Establish a baseline, then move the platter with no touch: pure bend.
        synth.buttons[BenchIndex.jogTouchLeft] = false
        synth.jogs[0] = 0
        _ = decoder.decode(synth.buttonReport())
        _ = decoder.decode(synth.jogReport())

        let controller = MX2NativeController()
        controller.mapping.firstDeck = 1
        var emitted: [(packet: Data, at: UInt64)] = []
        controller.onControl = { emitted.append(($0.packet, benchNow())) }

        synth.jogs[0] = 12
        let start = benchNow()
        for event in decoder.decode(synth.jogReport()) { controller.handle(event) }
        XCTAssertEqual(emitted.count, 1, "a bend sends its sign")
        for message in emitted { XCTAssertTrue(udp.send(message.packet)) }
        guard let (bend, _) = udp.receive(timeoutNanoseconds: 250_000_000) else {
            throw BenchError.timeout("phase bend")
        }
        _ = OSCMessage.parseAll(bend)

        // Poll for the scheduled release rather than sleeping a fixed amount: the tail
        // is what is being measured, and the main queue must be free to run the timer.
        let deadline = benchNow() &+ 500_000_000
        while emitted.count < 2, benchNow() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(emitted.count, 2, "the bend must release itself")
        guard emitted.count == 2 else { return .nan }

        XCTAssertTrue(udp.send(emitted[1].packet))
        guard let (release, _) = udp.receive(timeoutNanoseconds: 250_000_000) else {
            throw BenchError.timeout("bend release")
        }
        _ = OSCMessage.parseAll(release)
        // Both datagrams must have cleared the socket before the next stage.
        XCTAssertEqual(udp.settle(), 0)
        return Double(emitted[1].at - start)
    }

    private func writeJSONIfRequested(_ object: [String: Any]) throws {
        guard let path = ProcessInfo.processInfo.environment["INDIRECT_INPUT_BENCH_JSON"],
              !path.isEmpty else { return }
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
