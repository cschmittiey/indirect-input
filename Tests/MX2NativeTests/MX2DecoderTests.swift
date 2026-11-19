import Foundation
import XCTest
@testable import MX2Native
import IndirectInputCore

final class MX2DecoderTests: XCTestCase {
    // Actual IOHIDDeviceGetReport snapshots from the attached 17cc:2420 / ff01:0
    // interface. All three reads returned status 0, lengths 15 / 53 / 20.
    // These pin wire layout, NOT the physical identity of any knob or direction.
    private let hardwareSnapshot = #"["AQAAAAAAAAAAAAAAAAAA","Av8H/wf/B/8H/wf/B/8H/wfyB/8H/wf/B/8HRwj/B/8H/wf/BwAAdQVqBf8P/w8AAAEKqQg=","AwAAAKn+WdZPAgAAq/5Z1gIAAAA="]"#

    // Descriptor-derived names, still requiring one-control-at-a-time human sweeps.
    private let claimedAnalogs: [MX2Analog] = [
        .fxKnob(.left, 1), .fxKnob(.left, 2), .fxKnob(.left, 3), .fxKnob(.left, 4),
        .fxKnob(.right, 1), .fxKnob(.right, 2), .fxKnob(.right, 3), .fxKnob(.right, 4),
        .gain(.left), .eqHigh(.left), .eqMid(.left), .eqLow(.left), .channelFX(.left),
        .gain(.right), .eqHigh(.right), .eqMid(.right), .eqLow(.right), .channelFX(.right),
        .mainVolume, .cueMix, .cueVolume, .volume(.left), .volume(.right), .crossfader,
        .tempo(.left), .tempo(.right)
    ]

    private enum ProbeError: Error { case invalidBase64(Int), unknownPacket(Int) }

    /// JSON is an ordered array of base64 packets, HID including report ID, or OSC.
    /// Replay stays synchronous: no controller, timers, sockets, or HID scheduling.
    private func replay(_ json: Data, trace: Bool = false) throws -> [[MX2InputEvent]] {
        var decoder = MX2Decoder()
        var results: [[MX2InputEvent]] = []
        var previous: [UInt16] = []
        for (packet, base64) in try JSONDecoder().decode([String].self, from: json).enumerated() {
            guard let data = Data(base64Encoded: base64), !data.isEmpty else {
                throw ProbeError.invalidBase64(packet)
            }
            if data.first == 0x2F || data.starts(with: Array("#bundle\0".utf8)) {
                let messages = OSCMessage.parseAll(data)
                if trace { print("packet \(packet) OSC \(messages.map(\.address))") }
                continue
            }
            let bytes = Array(data)
            guard let id = bytes.first, [1, 2, 3].contains(id) else { throw ProbeError.unknownPacket(packet) }
            let events = decoder.decode(bytes)
            if trace, id == 2, bytes.count == 53 {
                let values = (0..<26).map { UInt16(bytes[1 + $0 * 2]) | UInt16(bytes[2 + $0 * 2]) << 8 }
                for index in values.indices where previous.isEmpty || previous[index] != values[index] {
                    print("packet \(packet) ANALOG \(index) claimed=\(claimedAnalogs[index]) value=\(values[index])\(values[index] > 4095 ? " OUT-OF-RANGE: report rejected" : "")")
                }
                previous = values
            }
            if trace { print("packet \(packet) HID \(id) events=\(events)") }
            results.append(events)
        }
        return results
    }

    // Run a future capture without editing code:
    // MX2_MAPPING_CAPTURE=/absolute/capture.json swift test --filter MX2DecoderTests.testMappingProbeCapture
    func testMappingProbeCapture() throws {
        let path = ProcessInfo.processInfo.environment["MX2_MAPPING_CAPTURE"]
        let json = try path.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
            ?? Data(hardwareSnapshot.utf8)
        let frames = try replay(json, trace: path != nil)
        XCTAssertFalse(frames.isEmpty, "capture must contain at least one HID report, not only OSC")
        if path == nil { XCTAssertEqual(frames, [[], [], []]) }
        for event in frames.flatMap({ $0 }) {
            if case .analog(_, let value) = event { XCTAssertLessThanOrEqual(value, 4095) }
        }
    }

    func testProbeReplaysMixedOSCAndHIDInOrder() throws {
        // The OSC packet is a captured Syndicate clock message, not HID bytes.
        let clock = "L1N5bmRpY2F0ZS9IZWFkZXIvQ2xvY2sALGkAAAAAAAE="
        var values = [UInt16](repeating: 0, count: 26)
        let baseline = Data(analogReport(values)).base64EncodedString()
        values[10] = 2047
        let changed = Data(analogReport(values)).base64EncodedString()
        XCTAssertEqual(try replay(JSONEncoder().encode([baseline, clock, changed, changed])),
                       [[], [.analog(.eqMid(.left), value: 2047)], []])
        XCTAssertThrowsError(try replay(Data(#"["not base64!"]"#.utf8)))
        XCTAssertThrowsError(try replay(Data(#"["/w=="]"#.utf8)))
        XCTAssertThrowsError(try replay(Data("{}".utf8)))
    }

    func testHardwareAnalogSnapshotHasNoLeadingCounterAndPinsFieldBoundary() throws {
        let packets = try JSONDecoder().decode([Data].self, from: Data(hardwareSnapshot.utf8))
        let report = Array(packets[1])
        let values: [UInt16] = [
            2047, 2047, 2047, 2047, 2047, 2047, 2047, 2047, 2034, 2047, 2047, 2047, 2047,
            2119, 2047, 2047, 2047, 2047, 0, 1397, 1386, 4095, 4095, 0, 2561, 2217
        ]
        XCTAssertEqual(report, analogReport(values))
        // Hardware descriptor: Usage 4, 16 bits * 21; then Usage 5, 16 bits * 5.
        XCTAssertEqual(Array(report[43...44]), [0xFF, 0x0F]) // payload 42, first fader
        var decoder = MX2Decoder()
        XCTAssertEqual(decoder.decode(analogReport([UInt16](repeating: 0, count: 26))), [])
        let expected = zip(claimedAnalogs, values).filter { $0.1 != 0 }.map { MX2InputEvent.analog($0.0, value: $0.1) }
        XCTAssertEqual(decoder.decode(report), expected)
        XCTAssertEqual(decoder.decode(report), [])
    }

    func testAllAnalogChannelsPreserveTwelveBitBoundaries() {
        var decoder = MX2Decoder()
        XCTAssertEqual(decoder.decode(analogReport([UInt16](repeating: 0, count: 26))), [])
        for value: UInt16 in [1, 2047, 2048, 4095, 0] {
            XCTAssertEqual(decoder.decode(analogReport([UInt16](repeating: value, count: 26))),
                           claimedAnalogs.map { .analog($0, value: value) })
        }
    }

    func testEveryTwelveBitCodeIsPreserved() {
        var decoder = MX2Decoder()
        var values = [UInt16](repeating: 0, count: 26)
        XCTAssertEqual(decoder.decode(analogReport(values)), [])
        for value in UInt16(1)...4095 {
            values[0] = value
            XCTAssertEqual(decoder.decode(analogReport(values)), [.analog(.fxKnob(.left, 1), value: value)])
        }
    }

    func testEncoderNibblesAreAbsoluteModuloSixteenPositions() {
        // Traktor EncoderHandler::process 0x100d72590..0x100d725d4 loads the
        // previous nibble, subtracts it, then applies the same +/-16 correction.
        let controls: [MX2Encoder] = [.browse(.left), .move(.left), .size(.left),
                                      .browse(.right), .move(.right), .size(.right)]
        for (index, control) in controls.enumerated() {
            var decoder = MX2Decoder()
            var report = [UInt8](repeating: 0, count: 15)
            report[0] = 1
            report[12 + index / 2] = 15 << (4 * (index % 2))
            XCTAssertEqual(decoder.decode(report), [])
            report[12 + index / 2] = 0
            XCTAssertEqual(decoder.decode(report), [.encoder(control, delta: 1)])
            XCTAssertEqual(decoder.decode(report), [], "a repeated position is NOT another relative tick")
            report[12 + index / 2] = 15 << (4 * (index % 2))
            XCTAssertEqual(decoder.decode(report), [.encoder(control, delta: -1)])
        }
    }

    func testJogHardwareLayoutIgnoresHeaderAndTimestampsAndWrapsBothSides() throws {
        let packets = try JSONDecoder().decode([Data].self, from: Data(hardwareSnapshot.utf8))
        var report = Array(packets[2])
        var decoder = MX2Decoder()
        XCTAssertEqual(decoder.decode(report), [])
        // Payload: 3 header bytes, then two [u32 timestamp, u32 position] records.
        for index in [1, 2, 3, 4, 5, 6, 7, 12, 13, 14, 15] { report[index] ^= 0xFF }
        XCTAssertEqual(decoder.decode(report), [], "timing bytes must not be decoded as position")
        func setPositions(_ left: UInt32, _ right: UInt32) {
            for (offset, value) in [(8, left), (16, right)] {
                for byte in 0..<4 { report[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
            }
        }
        setPositions(959, 0)
        XCTAssertEqual(decoder.decode(report), [.jog(.left, delta: 368), .jog(.right, delta: -2)])
        setPositions(0, 959)
        XCTAssertEqual(decoder.decode(report), [.jog(.left, delta: 1), .jog(.right, delta: -1)])
        setPositions(959, 0)
        XCTAssertEqual(decoder.decode(report), [.jog(.left, delta: -1), .jog(.right, delta: 1)])
        XCTAssertEqual(decoder.decode(report), [])
    }

    private func analogReport(_ values: [UInt16]) -> [UInt8] {
        [2] + values.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }
    }

    func testRejectedReportsCannotInitializeAnyReportFamily() {
        let valid: [[UInt8]] = [
            [1, 1] + [UInt8](repeating: 0, count: 13),
            analogReport([UInt16](repeating: 2047, count: 26)),
            [3] + [UInt8](repeating: 1, count: 19)
        ]
        for report in valid {
            for malformed in [Array(report.dropLast()), report + [0]] {
                var decoder = MX2Decoder()
                XCTAssertEqual(decoder.decode(malformed), [])
                XCTAssertEqual(decoder.decode(report), [],
                               "the first valid snapshot must baseline after malformed input")
            }
        }
        var decoder = MX2Decoder()
        XCTAssertEqual(decoder.decode(analogReport([UInt16](repeating: 4096, count: 26))), [])
        XCTAssertEqual(decoder.decode(valid[1]), [], "invalid analogue data is not a baseline")
    }

    func testOutOfRangeAnalogRejectsWholeReportWithoutChangingBaseline() {
        var decoder = MX2Decoder()
        let baseline = [UInt16](repeating: 100, count: 26)
        XCTAssertTrue(decoder.decode(analogReport(baseline)).isEmpty)
        for index in 0..<26 {
            for invalid in [UInt16(4096), 0x1001, 0xFFFF] {
                var values = baseline
                values[(index + 1) % 26] = 200
                values[index] = invalid
                XCTAssertEqual(decoder.decode(analogReport(values)), [],
                               "reject, do not mask/clamp or partially emit index \(index)=\(invalid)")
                XCTAssertEqual(decoder.decode(analogReport(baseline)), [],
                               "a rejected report must not poison the last valid baseline")
            }
        }
    }
}
