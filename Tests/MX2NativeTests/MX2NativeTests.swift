import XCTest
@testable import MX2Native
import BridgeCore
import MX2Feedback

final class MX2NativeTests: XCTestCase {
    func testInitialHIDSnapshotDoesNotFireControls() {
        var decoder = MX2Decoder()
        // Baseline every report family before asserting a browse delta. The decoder
        // intentionally shares its first-report initialization across report IDs.
        var baseline = [UInt8](repeating: 0, count: 15)
        baseline[0] = 1
        XCTAssertTrue(decoder.decode(baseline).isEmpty)
        var report = baseline
        report[1 + 80 / 8] = 1 << (80 % 8) // Left jog touch held.
        report[11] = 0x01 // Left browse starts at one.
        XCTAssertTrue(decoder.decode(report).isEmpty)
        report[11] = 0x00 // Only the browse value changes.
        XCTAssertEqual(decoder.decode(report), [
            .encoder(.browse(.left), delta: -1)
        ])
    }

    func testRawCueReportUsesTransportCueNotPlay() {
        var decoder = MX2Decoder()
        let idle = [UInt8](repeating: 0, count: 15)
        XCTAssertTrue(decoder.decode([1] + idle.dropFirst()).isEmpty)
        var pressed = idle
        pressed[0] = 1
        pressed[4] = 0x10 // Traktor MX2 descriptor: left Cue is button ID 28.
        XCTAssertEqual(decoder.decode(pressed), [.button(.cue(.left), pressed: true)])
        var rightDecoder = MX2Decoder()
        XCTAssertTrue(rightDecoder.decode([1] + idle.dropFirst()).isEmpty)
        var right = idle
        right[0] = 1
        right[8] = 0x04 // Traktor MX2 descriptor: right Cue is button ID 58.
        XCTAssertEqual(rightDecoder.decode(right), [.button(.cue(.right), pressed: true)])
    }

    func testJogReportDoesNotReleaseButtonBeforeFirstButtonReport() {
        var decoder = MX2Decoder()
        var jog = [UInt8](repeating: 0, count: 20)
        jog[0] = 3
        XCTAssertTrue(decoder.decode(jog).isEmpty)
        var buttons = [UInt8](repeating: 0, count: 15)
        buttons[0] = 1
        buttons[1 + 28 / 8] = 1 << (28 % 8)
        XCTAssertTrue(decoder.decode(buttons).isEmpty)
        buttons[1 + 28 / 8] = 0
        XCTAssertEqual(decoder.decode(buttons), [.button(.cue(.left), pressed: false)])
    }

    func testAnalogUsesFullTwelveBitRange() {
        var decoder = MX2Decoder()
        XCTAssertTrue(decoder.decode([2] + [UInt8](repeating: 0, count: 52)).isEmpty)
        var data = [UInt8](repeating: 0, count: 52)
        data[0] = 0xFF
        data[1] = 0x0F
        XCTAssertEqual(decoder.decode([2] + data), [.analog(.fxKnob(.left, 1), value: 4095)])
    }

    @MainActor
    func testRestoredRGBLayoutUsesOldOffsetsAndLeavesFilterRegionDark() {
        let client = MX2FeedbackClient()
        let image = client.renderForTesting()
        XCTAssertEqual(image.count, 105)
        XCTAssertEqual(image[30], 14) // Right deck FX1: old bright orange.
        XCTAssertEqual(image[43], 44) // Right deck Sync: old dim blue when inactive.
        for index in 73..<79 { XCTAssertEqual(image[index], 46) }
        for index in 79..<85 { XCTAssertEqual(image[index], 46) }
        for index in 60..<73 { XCTAssertEqual(image[index], 0) }
    }

    @MainActor
    func testCueAndHeadphoneToggleOnSuccessivePresses() {
        let controller = MX2NativeController()
        var messages: [BridgeCore.OSCMessage] = []
        controller.onControl = { messages.append($0) }
        controller.handle(.button(.cue(.left), pressed: true))
        controller.handle(.button(.cue(.left), pressed: false))
        controller.handle(.button(.headphone(.left), pressed: true))
        controller.handle(.button(.headphone(.left), pressed: true))
        XCTAssertEqual(messages.map(\.address), [
            "/Syndicate/Deck/1/Cue", "/Syndicate/Deck/1/Cue",
            "/Syndicate/Mixer/CH1/Cue", "/Syndicate/Mixer/CH1/Cue"
        ])
        XCTAssertEqual(messages.map(\.integer), [1, 0, 1, 0])
    }

    func testTransportAndHotCueUseCurrentDeckPair() {
        let mapping = MX2Mapping()
        XCTAssertEqual(mapping.route(.button(.play(.right), pressed: true),
                                     bank: [.hotcues, .hotcues],
                                     shift: [false, false], jogMode: [false, false]),
                       [OSCMessage(address: "/Syndicate/Deck/2/PlayPause", integer: 1)])
        let message = mapping.route(.button(.pad(.left, 3), pressed: true),
                                    bank: [.hotcues, .hotcues],
                                    shift: [false, false], jogMode: [false, false])
        XCTAssertEqual(message, [OSCMessage(address: "/Syndicate/Deck/1/HotCue",
                                            arguments: [.int(3), .int(1)])])
    }

    func testEncoderShiftAndReleaseRules() {
        let mapping = MX2Mapping()
        XCTAssertEqual(mapping.route(.encoder(.browse(.left), delta: 2),
                                     bank: [.hotcues, .hotcues], shift: [true, false],
                                     jogMode: [false, false]).map(\.address),
                       Array(repeating: "/Syndicate/Browser/Navigation/Right", count: 2))
        XCTAssertTrue(mapping.route(.button(.pad(.left, 1), pressed: false),
                                    bank: [.stems, .stems], shift: [false, false],
                                    jogMode: [false, false]).isEmpty)
    }



    @MainActor
    func testFeedbackUpdatesPlayingStateAndCueColors() {
        let client = MX2FeedbackClient()
        var image: [UInt8] = []
        client.onRGB = { image = $0 }
        client.receivePacket(BridgeCore.OSCMessage(
            address: "/Syndicate/Deck/1/Playing", integer: 1).packet)
        client.receivePacket(BridgeCore.OSCMessage(
            address: "/Syndicate/Deck/1/Cues",
            arguments: (1...8).flatMap { slot in
                [.int(Int32(slot)), .string("Cue \(slot)")]
            }).packet)
        XCTAssertEqual(image[30], 30)
        for pad in 0..<8 { XCTAssertNotEqual(image[21 + pad], 0) }
    }


    func testJogDeltaWrapsAt960() {
        var decoder = MX2Decoder()
        var first = [UInt8](repeating: 0, count: 20)
        first[0] = 3
        first[7] = 132
        first[8] = 0x03
        XCTAssertTrue(decoder.decode(first).isEmpty)
        var second = first
        second[7] = 100
        second[8] = 0
        XCTAssertEqual(decoder.decode(second), [.jog(.left, delta: 160)])
    }
}
