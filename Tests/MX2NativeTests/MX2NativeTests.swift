import XCTest
@testable import MX2Native
import BridgeCore
import MX2Feedback

final class MX2NativeTests: XCTestCase {
    func testInitialHIDSnapshotDoesNotFireControls() {
        // `decode` drops the report ID, so payload byte N lives at `report[N + 1]`.
        // The decoder emits a *bounded* set of events: a button press it noticed and
        // the browse encoder moving underneath it.
        var decoder = MX2Decoder()
        var report = [UInt8](repeating: 0, count: 15)
        report[0] = 1
        XCTAssertEqual(decoder.decode(report), [], "an all-zero first report must only baseline")
        // Button 80 (left jog touch) held: first report baselines, so silence.
        report[1 + 80 / 8] = 1 << (80 % 8)
        XCTAssertEqual(decoder.decode(report), [.button(.jogTouch(.left), pressed: true)])

        report[12] = 0x01 // Left browse encoder's low nibble moves to one.
        XCTAssertEqual(decoder.decode(report), [.encoder(.browse(.left), delta: 1)])

        report[12] = 0x00
        XCTAssertEqual(decoder.decode(report), [.encoder(.browse(.left), delta: -1)])
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
    func testIdleFeedbackFrameLeavesUnfedControlsDark() {
        // This test used to assert the static-layout bug: bright orange FX buttons and
        // a dim blue Sync on an idle controller, which is what made the deck look
        // broken. With no feedback the frame must be dark apart from the selected
        // bank indicator, so anything that lights up is genuinely tracked state.
        let client = MX2FeedbackClient()
        let image = client.renderForTesting()
        XCTAssertEqual(image.count, 105)
        XCTAssertEqual(image[30], 0) // Right deck FX1: no feedback, no light.
        XCTAssertEqual(image[43], 0) // Right deck Sync: inactive is dark, not dim blue.
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
        XCTAssertEqual(image[29], 30) // Left deck is playing; right deck stays stopped.
        for pad in 0..<8 { XCTAssertNotEqual(image[20 + pad], 0) }
    }


    func testJogDeltaWrapsAt960() {
        // Left jog absolute position is a little-endian u32 at payload offset 7,
        // which is report index 8 once the report ID is dropped.
        func report(position: UInt32) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 20)
            bytes[0] = 3
            for shift in 0..<4 {
                bytes[8 + shift] = UInt8((position >> (8 * shift)) & 0xFF)
            }
            return bytes
        }

        var decoder = MX2Decoder()
        XCTAssertTrue(decoder.decode(report(position: 952)).isEmpty) // Baselines only.

        // 952 -> 100 is 852 backwards, which is nearer +108 forwards on a 960-tick
        // wheel, so the decoder must report the short way round.
        XCTAssertEqual(decoder.decode(report(position: 100)), [.jog(.left, delta: 108)])
    }

    func testJogDeltaTakesTheShortWayForSmallMoves() {
        func report(position: UInt32) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 20)
            bytes[0] = 3
            for shift in 0..<4 {
                bytes[8 + shift] = UInt8((position >> (8 * shift)) & 0xFF)
            }
            return bytes
        }

        var decoder = MX2Decoder()
        _ = decoder.decode(report(position: 500))
        XCTAssertEqual(decoder.decode(report(position: 501)), [.jog(.left, delta: 1)])
        XCTAssertEqual(decoder.decode(report(position: 500)), [.jog(.left, delta: -1)])
    }
}
